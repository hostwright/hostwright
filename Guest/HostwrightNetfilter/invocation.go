// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"path"
	"strings"
)

const (
	agentStdioArgument             = "--guest-agent-stdio"
	agentFileArgument              = "--guest-agent-request-file"
	bootstrapArgument              = "--bootstrap"
	argumentSeparator              = "--"
	guestAgentUpdateRequestPath    = "/run/hostwright/network-policy.json"
	guestAgentBootstrapRequestPath = "/run/hostwright/bootstrap-policy.json"
	maxWorkloadArguments           = 256
	maxWorkloadArgBytes            = 128 * 1024
)

type invocationMode string

const (
	invocationStdio     invocationMode = "stdio"
	invocationFile      invocationMode = "file"
	invocationBootstrap invocationMode = "bootstrap"
)

type invocation struct {
	Mode              invocationMode
	RequestPath       string
	WorkloadArguments []string
}

func parseInvocation(arguments []string) (invocation, error) {
	if len(arguments) == 1 && arguments[0] == agentStdioArgument {
		return invocation{Mode: invocationStdio}, nil
	}
	if len(arguments) == 2 && arguments[0] == agentFileArgument {
		if err := validateRequestPath(
			arguments[1],
			guestAgentUpdateRequestPath,
		); err != nil {
			return invocation{}, err
		}
		return invocation{
			Mode:        invocationFile,
			RequestPath: arguments[1],
		}, nil
	}
	if len(arguments) >= 4 &&
		arguments[0] == bootstrapArgument &&
		arguments[2] == argumentSeparator {
		if err := validateRequestPath(
			arguments[1],
			guestAgentBootstrapRequestPath,
		); err != nil {
			return invocation{}, err
		}
		workloadArguments := arguments[3:]
		if err := validateWorkloadArguments(workloadArguments); err != nil {
			return invocation{}, err
		}
		return invocation{
			Mode:              invocationBootstrap,
			RequestPath:       arguments[1],
			WorkloadArguments: workloadArguments,
		}, nil
	}
	return invocation{}, newLoaderError(
		"invalid_invocation",
		"expected %s, %s %s, or %s %s -- <argv>",
		agentStdioArgument,
		agentFileArgument,
		guestAgentUpdateRequestPath,
		bootstrapArgument,
		guestAgentBootstrapRequestPath,
	)
}

func validateRequestPath(value, expected string) error {
	if value != expected ||
		!path.IsAbs(value) ||
		path.Clean(value) != value ||
		strings.ContainsRune(value, '\x00') {
		return newLoaderError(
			"invalid_request_path",
			"request file must be exactly %s",
			expected,
		)
	}
	return nil
}

func validateWorkloadArguments(values []string) error {
	if len(values) == 0 || values[0] == "" {
		return newLoaderError("invalid_workload_argv", "workload argv must not be empty")
	}
	if len(values) > maxWorkloadArguments {
		return newLoaderError(
			"invalid_workload_argv",
			"workload argv exceeds %d arguments",
			maxWorkloadArguments,
		)
	}
	totalBytes := 0
	for _, value := range values {
		if strings.ContainsRune(value, '\x00') {
			return newLoaderError("invalid_workload_argv", "workload argv contains NUL")
		}
		totalBytes += len(value)
		if totalBytes > maxWorkloadArgBytes {
			return newLoaderError(
				"invalid_workload_argv",
				"workload argv exceeds %d bytes",
				maxWorkloadArgBytes,
			)
		}
	}
	return nil
}

func hasBootstrapSettings(value request) bool {
	return value.TargetUID != nil ||
		value.TargetGID != nil ||
		value.WorkingDirectory != ""
}
