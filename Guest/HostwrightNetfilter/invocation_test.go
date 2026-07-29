// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"testing"
)

func TestParseInvocationAcceptsOnlyLockedGuestAgentModes(t *testing.T) {
	tests := []struct {
		name      string
		arguments []string
		mode      invocationMode
	}{
		{
			name:      "stdio",
			arguments: []string{agentStdioArgument},
			mode:      invocationStdio,
		},
		{
			name:      "file",
			arguments: []string{
				agentFileArgument,
				guestAgentUpdateRequestPath,
			},
			mode:      invocationFile,
		},
		{
			name: "bootstrap",
			arguments: []string{
				bootstrapArgument,
				guestAgentBootstrapRequestPath,
				argumentSeparator,
				"/bin/server",
				"--listen",
			},
			mode: invocationBootstrap,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			value, err := parseInvocation(test.arguments)
			if err != nil {
				t.Fatalf("parseInvocation returned error: %v", err)
			}
			if value.Mode != test.mode {
				t.Fatalf("mode = %q, want %q", value.Mode, test.mode)
			}
		})
	}
}

func TestParseInvocationRejectsPathAndArgumentExpansion(t *testing.T) {
	tests := [][]string{
		{agentFileArgument, "/tmp/network-policy.json"},
		{
			agentFileArgument,
			guestAgentUpdateRequestPath + "/../network-policy.json",
		},
		{agentFileArgument, guestAgentBootstrapRequestPath},
		{
			bootstrapArgument,
			guestAgentUpdateRequestPath,
			argumentSeparator,
			"/bin/server",
		},
		{
			bootstrapArgument,
			guestAgentBootstrapRequestPath,
			argumentSeparator,
		},
		{
			bootstrapArgument,
			guestAgentBootstrapRequestPath,
			argumentSeparator,
			"",
		},
		{
			bootstrapArgument,
			guestAgentBootstrapRequestPath,
			"not-separator",
			"/bin/server",
		},
	}
	for _, arguments := range tests {
		if _, err := parseInvocation(arguments); err == nil {
			t.Fatalf("accepted invalid invocation %#v", arguments)
		}
	}
}

func TestValidateBootstrapConfigurationRequiresApplyAndCanonicalCWD(t *testing.T) {
	valid := minimalApplyRequest(1)
	valid.WorkingDirectory = "/srv/application"
	if err := validateBootstrapConfiguration(valid); err != nil {
		t.Fatalf("valid bootstrap rejected: %v", err)
	}

	for _, workingDirectory := range []string{"", "relative", "/srv/../tmp", "/srv//app"} {
		value := minimalApplyRequest(1)
		value.WorkingDirectory = workingDirectory
		if err := validateBootstrapConfiguration(value); err == nil {
			t.Fatalf("accepted working directory %q", workingDirectory)
		}
	}

	verify := valid
	verify.Operation = operationVerify
	if err := validateBootstrapConfiguration(verify); err == nil {
		t.Fatal("accepted verify request for bootstrap")
	}

	invalidIdentity := valid
	invalid := ^uint32(0)
	invalidIdentity.TargetUID = &invalid
	if err := validateBootstrapConfiguration(invalidIdentity); err == nil {
		t.Fatal("accepted reserved UID value")
	}
}
