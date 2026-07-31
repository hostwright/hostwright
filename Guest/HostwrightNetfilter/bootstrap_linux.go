//go:build linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

type linuxPreparedBootstrap struct {
	executable string
	arguments  []string
}

func openGuestAgentRequestFile(value string, mode invocationMode) (*os.File, error) {
	expected, err := requestPathForMode(mode)
	if err != nil {
		return nil, err
	}
	if err := validateRequestPath(value, expected); err != nil {
		return nil, err
	}
	fd, err := unix.Open(value, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, newLoaderError("invalid_request_file", "open request file: %v", err)
	}
	file := os.NewFile(uintptr(fd), "hostwright-network-policy")
	if file == nil {
		_ = unix.Close(fd)
		return nil, newLoaderError("invalid_request_file", "wrap request file descriptor")
	}
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		_ = file.Close()
		return nil, newLoaderError("invalid_request_file", "inspect request file: %v", err)
	}
	fileMode := stat.Mode & 0o777
	if stat.Mode&unix.S_IFMT != unix.S_IFREG ||
		stat.Nlink != 1 ||
		fileMode&0o022 != 0 ||
		fileMode&0o111 != 0 ||
		stat.Size <= 0 ||
		stat.Size > maxRequestBytes {
		_ = file.Close()
		return nil, newLoaderError(
			"invalid_request_file",
			"request file must be a read-only-mounted regular file within bounds",
		)
	}
	return file, nil
}

func requestPathForMode(mode invocationMode) (string, error) {
	switch mode {
	case invocationFile:
		return guestAgentUpdateRequestPath, nil
	case invocationBootstrap:
		return guestAgentBootstrapRequestPath, nil
	default:
		return "", newLoaderError(
			"invalid_invocation",
			"request files are unavailable in %s mode",
			mode,
		)
	}
}

func prepareBootstrap(
	value request,
	arguments []string,
) (preparedBootstrap, error) {
	if err := validateBootstrapConfiguration(value); err != nil {
		return nil, err
	}
	if err := validateWorkloadArguments(arguments); err != nil {
		return nil, err
	}
	directoryFD, err := openWorkingDirectory(value.WorkingDirectory)
	if err != nil {
		return nil, err
	}
	if err := unix.Fchdir(directoryFD); err != nil {
		_ = unix.Close(directoryFD)
		return nil, newLoaderError(
			"invalid_working_directory",
			"enter workingDirectory: %v",
			err,
		)
	}
	if err := unix.Close(directoryFD); err != nil {
		return nil, newLoaderError(
			"invalid_working_directory",
			"close workingDirectory descriptor: %v",
			err,
		)
	}
	executable, err := exec.LookPath(arguments[0])
	if err != nil {
		return nil, newLoaderError(
			"invalid_workload_argv",
			"resolve workload executable: %v",
			err,
		)
	}
	return &linuxPreparedBootstrap{
		executable: executable,
		arguments:  append([]string(nil), arguments...),
	}, nil
}

func openWorkingDirectory(value string) (int, error) {
	current, err := unix.Open(
		"/",
		unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0,
	)
	if err != nil {
		return -1, newLoaderError(
			"invalid_working_directory",
			"open container root: %v",
			err,
		)
	}
	if value == "/" {
		return current, nil
	}
	for _, component := range strings.Split(strings.TrimPrefix(value, "/"), "/") {
		next, openErr := unix.Openat(
			current,
			component,
			unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW,
			0,
		)
		_ = unix.Close(current)
		if openErr != nil {
			return -1, newLoaderError(
				"invalid_working_directory",
				"open workingDirectory component: %v",
				openErr,
			)
		}
		current = next
	}
	return current, nil
}

func (bootstrap *linuxPreparedBootstrap) Exec(value request) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := dropBootstrapAuthority(value); err != nil {
		return err
	}
	if err := syscall.Exec(bootstrap.executable, bootstrap.arguments, os.Environ()); err != nil {
		return newLoaderError("workload_exec_failed", "exec workload: %v", err)
	}
	return nil
}

func bootstrapOnlyCapabilities() [5]uint {
	return [5]uint{
		unix.CAP_NET_ADMIN,
		unix.CAP_NET_RAW,
		unix.CAP_SETUID,
		unix.CAP_SETGID,
		unix.CAP_SETPCAP,
	}
}

func dropBootstrapAuthority(value request) error {
	for _, capability := range bootstrapOnlyCapabilities() {
		if err := unix.Prctl(
			unix.PR_CAPBSET_DROP,
			uintptr(capability),
			0,
			0,
			0,
		); err != nil {
			return newLoaderError(
				"capability_drop_failed",
				"drop capability %d from bounding set: %v",
				capability,
				err,
			)
		}
	}
	if err := unix.Prctl(
		unix.PR_CAP_AMBIENT,
		unix.PR_CAP_AMBIENT_CLEAR_ALL,
		0,
		0,
		0,
	); err != nil {
		return newLoaderError("capability_drop_failed", "clear ambient capabilities: %v", err)
	}

	if value.TargetUID != nil || value.TargetGID != nil {
		if err := unix.Setgroups([]int{}); err != nil {
			return newLoaderError("identity_drop_failed", "clear supplementary groups: %v", err)
		}
	}
	if value.TargetGID != nil {
		if err := unix.Setgid(int(*value.TargetGID)); err != nil {
			return newLoaderError("identity_drop_failed", "set target GID: %v", err)
		}
	}
	if value.TargetUID != nil {
		if err := unix.Setuid(int(*value.TargetUID)); err != nil {
			return newLoaderError("identity_drop_failed", "set target UID: %v", err)
		}
	}

	header := unix.CapUserHeader{
		Version: unix.LINUX_CAPABILITY_VERSION_3,
		Pid:     0,
	}
	data := [2]unix.CapUserData{}
	if err := unix.Capget(&header, &data[0]); err != nil {
		return newLoaderError("capability_drop_failed", "read capabilities: %v", err)
	}
	clearBootstrapCapabilitySets(&data)
	if err := unix.Capset(&header, &data[0]); err != nil {
		return newLoaderError("capability_drop_failed", "write capabilities: %v", err)
	}
	if err := verifyDroppedBootstrapAuthority(value); err != nil {
		return err
	}
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return newLoaderError("capability_drop_failed", "set no-new-privileges: %v", err)
	}
	if err := verifyNoNewPrivileges(); err != nil {
		return err
	}
	return nil
}

func clearBootstrapCapabilitySets(data *[2]unix.CapUserData) {
	for _, capability := range bootstrapOnlyCapabilities() {
		index := capability / 32
		mask := ^(uint32(1) << (capability % 32))
		data[index].Effective &= mask
		data[index].Permitted &= mask
		data[index].Inheritable &= mask
	}
}

func verifyDroppedBootstrapAuthority(value request) error {
	for _, capability := range bootstrapOnlyCapabilities() {
		present, err := unix.PrctlRetInt(
			unix.PR_CAPBSET_READ,
			uintptr(capability),
			0,
			0,
			0,
		)
		if err != nil || present != 0 {
			return newLoaderError(
				"capability_drop_failed",
				"capability %d remains in bounding set",
				capability,
			)
		}
		ambient, err := unix.PrctlRetInt(
			unix.PR_CAP_AMBIENT,
			unix.PR_CAP_AMBIENT_IS_SET,
			uintptr(capability),
			0,
			0,
		)
		if err != nil || ambient != 0 {
			return newLoaderError(
				"capability_drop_failed",
				"capability %d remains ambient",
				capability,
			)
		}
	}

	header := unix.CapUserHeader{
		Version: unix.LINUX_CAPABILITY_VERSION_3,
		Pid:     0,
	}
	data := [2]unix.CapUserData{}
	if err := unix.Capget(&header, &data[0]); err != nil {
		return newLoaderError("capability_drop_failed", "verify capabilities: %v", err)
	}
	for _, capability := range bootstrapOnlyCapabilities() {
		index := capability / 32
		mask := uint32(1) << (capability % 32)
		if data[index].Effective&mask != 0 ||
			data[index].Permitted&mask != 0 ||
			data[index].Inheritable&mask != 0 {
			return newLoaderError(
				"capability_drop_failed",
				"capability %d remains active",
				capability,
			)
		}
	}
	if value.TargetUID != nil && os.Geteuid() != int(*value.TargetUID) {
		return newLoaderError("identity_drop_failed", "effective UID verification failed")
	}
	if value.TargetGID != nil && os.Getegid() != int(*value.TargetGID) {
		return newLoaderError("identity_drop_failed", "effective GID verification failed")
	}
	return nil
}

func verifyNoNewPrivileges() error {
	noNewPrivileges, err := unix.PrctlRetInt(
		unix.PR_GET_NO_NEW_PRIVS,
		0,
		0,
		0,
		0,
	)
	if err != nil || noNewPrivileges != 1 {
		return newLoaderError(
			"capability_drop_failed",
			"no-new-privileges verification failed",
		)
	}
	return nil
}
