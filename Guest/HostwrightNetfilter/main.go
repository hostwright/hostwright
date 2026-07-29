// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

func main() {
	exitCode := run(os.Args[1:], os.Stdin, os.Stdout)
	os.Exit(exitCode)
}

func run(arguments []string, input io.Reader, output io.Writer) int {
	var value request
	invocation, err := parseInvocation(arguments)
	if err != nil {
		_ = writeResponse(output, errorResponse("", err))
		return 64
	}
	if os.Geteuid() != 0 {
		_ = writeResponse(output, errorResponse(
			"",
			newLoaderError("permission_denied", "loader requires guest-agent root authority"),
		))
		return 77
	}

	lock, err := acquireLoaderLock()
	if err != nil {
		_ = writeResponse(output, errorResponse("", err))
		return 75
	}
	defer func() {
		_ = lock.Close()
	}()

	requestInput := input
	var requestFile *os.File
	if invocation.RequestPath != "" {
		requestFile, err = openGuestAgentRequestFile(
			invocation.RequestPath,
			invocation.Mode,
		)
		if err != nil {
			_ = writeResponse(output, errorResponse("", err))
			return 66
		}
		defer func() {
			_ = requestFile.Close()
		}()
		requestInput = requestFile
	}

	value, err = decodeRequest(requestInput)
	if err != nil {
		_ = writeResponse(output, errorResponse(value.Operation, err))
		return 65
	}
	if invocation.Mode != invocationBootstrap && hasBootstrapSettings(value) {
		err := newLoaderError(
			"invalid_request",
			"target identity and workingDirectory are valid only in bootstrap mode",
		)
		_ = writeResponse(output, errorResponse(value.Operation, err))
		return 65
	}
	var bootstrap preparedBootstrap
	if invocation.Mode == invocationBootstrap {
		bootstrap, err = prepareBootstrap(value, invocation.WorkloadArguments)
		if err != nil {
			_ = writeResponse(output, errorResponse(value.Operation, err))
			return 65
		}
	}
	backend, err := newSystemBackend()
	if err != nil {
		_ = writeResponse(output, errorResponse(value.Operation, err))
		return 69
	}
	result, err := executeRequest(context.Background(), backend, value)
	if err != nil {
		_ = writeResponse(output, errorResponse(value.Operation, err))
		return 70
	}
	if invocation.Mode == invocationBootstrap {
		if err := verifyBootstrapPolicy(context.Background(), backend, value); err != nil {
			_ = writeResponse(output, errorResponse(value.Operation, err))
			return 70
		}
		if err := bootstrap.Exec(value); err != nil {
			_ = writeResponse(output, errorResponse(value.Operation, err))
			return 71
		}
		return 0
	}
	if err := writeResponse(output, result); err != nil {
		return 74
	}
	return 0
}

func verifyBootstrapPolicy(
	ctx context.Context,
	backend firewallBackend,
	value request,
) error {
	if value.Operation != operationApply {
		return newLoaderError("invalid_bootstrap", "bootstrap requires an apply request")
	}
	verify := request{
		Schema:              value.Schema,
		Operation:           operationVerify,
		PolicyDigest:        value.PolicyDigest,
		Generation:          value.Generation,
		ProjectUUID:         value.ProjectUUID,
		ServiceResourceUUID: value.ServiceResourceUUID,
		IngressDefault:      value.IngressDefault,
		EgressDefault:       value.EgressDefault,
		Ingress:             value.Ingress,
		Egress:              value.Egress,
		DNSServers:          value.DNSServers,
	}
	if _, err := executeRequest(ctx, backend, verify); err != nil {
		return newLoaderError("verification_failed", "bootstrap policy verification: %v", err)
	}
	return nil
}

func writeResponse(output io.Writer, value response) error {
	encoder := json.NewEncoder(output)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return fmt.Errorf("encode response: %w", err)
	}
	return nil
}
