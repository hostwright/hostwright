//go:build linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

const loaderRuntimeDirectory = "/run/hostwright-loader"

func acquireLoaderLock() (*os.File, error) {
	if err := os.Mkdir(loaderRuntimeDirectory, 0o700); err != nil && !os.IsExist(err) {
		return nil, newLoaderError(
			"lock_failed",
			"create runtime directory: %v",
			err,
		)
	}
	info, err := os.Lstat(loaderRuntimeDirectory)
	if err != nil {
		return nil, newLoaderError("lock_failed", "inspect runtime directory: %v", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || stat.Uid != 0 ||
		info.Mode().Perm() != 0o700 {
		return nil, newLoaderError(
			"lock_failed",
			"runtime directory must be a root-owned 0700 directory",
		)
	}

	lockFD, err := unix.Open(
		loaderRuntimeDirectory+"/netfilter.lock",
		unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return nil, newLoaderError("lock_failed", "open loader lock: %v", err)
	}
	lock := os.NewFile(uintptr(lockFD), "hostwright-netfilter-lock")
	if lock == nil {
		_ = unix.Close(lockFD)
		return nil, newLoaderError("lock_failed", "wrap loader lock descriptor")
	}
	if err := lock.Chmod(0o600); err != nil {
		_ = lock.Close()
		return nil, newLoaderError("lock_failed", "set loader lock mode: %v", err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		_ = lock.Close()
		return nil, newLoaderError("lock_failed", "acquire loader lock: %v", err)
	}
	lockInfo, err := lock.Stat()
	if err != nil {
		_ = lock.Close()
		return nil, newLoaderError("lock_failed", "inspect loader lock: %v", err)
	}
	lockStat, ok := lockInfo.Sys().(*syscall.Stat_t)
	if !ok || !lockInfo.Mode().IsRegular() || lockStat.Uid != 0 ||
		lockInfo.Mode().Perm() != 0o600 {
		_ = lock.Close()
		return nil, newLoaderError(
			"lock_failed",
			"loader lock must be a root-owned 0600 regular file",
		)
	}
	return lock, nil
}

func newSystemBackend() (firewallBackend, error) {
	backend, err := newNFTBackend()
	if err != nil {
		return nil, newLoaderError("backend_unavailable", "initialize nftables: %v", err)
	}
	return backend, nil
}
