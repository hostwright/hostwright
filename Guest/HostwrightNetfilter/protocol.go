// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

const (
	protocolSchema  = 1
	maxRequestBytes = 1024 * 1024
	maxJSONDepth    = 16
	maxErrorBytes   = 512
)

type operation string

const (
	operationApply  operation = "apply"
	operationVerify operation = "verify"
	operationRemove operation = "remove"
)

type request struct {
	Schema              int        `json:"schema"`
	Operation           operation  `json:"operation"`
	PolicyDigest        string     `json:"policyDigest"`
	Generation          uint64     `json:"generation"`
	ProjectUUID         string     `json:"projectUUID"`
	ServiceResourceUUID string     `json:"serviceResourceUUID"`
	IngressDefault      string     `json:"ingressDefault"`
	EgressDefault       string     `json:"egressDefault"`
	Ingress             []wireRule `json:"ingress,omitempty"`
	Egress              []wireRule `json:"egress,omitempty"`
	DNSServers          []string   `json:"dnsServers,omitempty"`
	TargetUID           *uint32    `json:"targetUID,omitempty"`
	TargetGID           *uint32    `json:"targetGID,omitempty"`
	WorkingDirectory    string     `json:"workingDirectory,omitempty"`
}

type wireRule struct {
	CIDR            string  `json:"cidr"`
	Protocol        string  `json:"protocol"`
	DestinationPort *uint16 `json:"destinationPort,omitempty"`
}

type response struct {
	Schema       int            `json:"schema"`
	Operation    operation      `json:"operation"`
	Status       string         `json:"status"`
	PolicyDigest string         `json:"policyDigest,omitempty"`
	Generation   uint64         `json:"generation,omitempty"`
	RuleCount    int            `json:"ruleCount,omitempty"`
	Error        *responseError `json:"error,omitempty"`
}

type responseError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type loaderError struct {
	code    string
	message string
}

func (e *loaderError) Error() string {
	return e.message
}

func newLoaderError(code, format string, args ...any) error {
	return &loaderError{
		code:    code,
		message: fmt.Sprintf(format, args...),
	}
}

func decodeRequest(reader io.Reader) (request, error) {
	limited := &io.LimitedReader{R: reader, N: maxRequestBytes + 1}
	data, err := io.ReadAll(limited)
	if err != nil {
		return request{}, newLoaderError("invalid_request", "read request: %v", err)
	}
	if len(data) == 0 {
		return request{}, newLoaderError("invalid_request", "request is empty")
	}
	if len(data) > maxRequestBytes {
		return request{}, newLoaderError(
			"request_too_large",
			"request exceeds %d bytes",
			maxRequestBytes,
		)
	}
	if !utf8.Valid(data) {
		return request{}, newLoaderError("invalid_request", "request is not valid UTF-8")
	}
	if err := rejectDuplicateKeys(data); err != nil {
		return request{}, err
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()

	var value request
	if err := decoder.Decode(&value); err != nil {
		return request{}, newLoaderError("invalid_request", "decode request: %v", err)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return request{}, err
	}
	if err := validateRequestEnvelope(value); err != nil {
		return request{}, err
	}
	return value, nil
}

func rejectDuplicateKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := walkJSONValue(decoder, 0); err != nil {
		return err
	}
	if err := requireJSONEOF(decoder); err != nil {
		return err
	}
	return nil
}

func walkJSONValue(decoder *json.Decoder, depth int) error {
	if depth > maxJSONDepth {
		return newLoaderError(
			"invalid_request",
			"JSON nesting exceeds %d levels",
			maxJSONDepth,
		)
	}

	token, err := decoder.Token()
	if err != nil {
		return newLoaderError("invalid_request", "decode JSON token: %v", err)
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}

	switch delimiter {
	case '{':
		keys := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return newLoaderError("invalid_request", "decode object key: %v", err)
			}
			key, ok := keyToken.(string)
			if !ok {
				return newLoaderError("invalid_request", "object key is not a string")
			}
			if _, exists := keys[key]; exists {
				return newLoaderError("invalid_request", "duplicate JSON key %q", key)
			}
			keys[key] = struct{}{}
			if err := walkJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return newLoaderError("invalid_request", "decode object end: %v", err)
		}
		if closing != json.Delim('}') {
			return newLoaderError("invalid_request", "invalid object terminator")
		}
	case '[':
		for decoder.More() {
			if err := walkJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return newLoaderError("invalid_request", "decode array end: %v", err)
		}
		if closing != json.Delim(']') {
			return newLoaderError("invalid_request", "invalid array terminator")
		}
	default:
		return newLoaderError("invalid_request", "unexpected JSON delimiter %q", delimiter)
	}
	return nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return newLoaderError("invalid_request", "request contains multiple JSON values")
	}
	return newLoaderError("invalid_request", "decode trailing JSON: %v", err)
}

func validateRequestEnvelope(value request) error {
	if value.Schema != protocolSchema {
		return newLoaderError(
			"unsupported_schema",
			"schema must be %d",
			protocolSchema,
		)
	}
	switch value.Operation {
	case operationApply, operationVerify, operationRemove:
	default:
		return newLoaderError("invalid_operation", "unsupported operation %q", value.Operation)
	}
	if !isCanonicalDigest(value.PolicyDigest) {
		return newLoaderError(
			"invalid_policy_digest",
			"policyDigest must be 64 lowercase hexadecimal characters",
		)
	}
	if value.Generation == 0 {
		return newLoaderError("invalid_generation", "generation must be positive")
	}
	if !isCanonicalUUID(value.ProjectUUID) {
		return newLoaderError(
			"invalid_project_uuid",
			"projectUUID must be a canonical lowercase UUID",
		)
	}
	if !isCanonicalUUID(value.ServiceResourceUUID) {
		return newLoaderError(
			"invalid_service_resource_uuid",
			"serviceResourceUUID must be a canonical lowercase UUID",
		)
	}
	if !isPolicyDefault(value.IngressDefault) || !isPolicyDefault(value.EgressDefault) {
		return newLoaderError(
			"invalid_policy_default",
			"policy defaults must be allowSameProject or deny",
		)
	}
	if value.Operation != operationApply &&
		(value.TargetUID != nil ||
			value.TargetGID != nil ||
			value.WorkingDirectory != "") {
		return newLoaderError(
			"invalid_request",
			"%s does not accept bootstrap settings",
			value.Operation,
		)
	}
	return nil
}

func isCanonicalDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range value {
		if !strings.ContainsRune("0123456789abcdef", character) {
			return false
		}
	}
	return true
}

func errorResponse(operation operation, err error) response {
	code := "internal_error"
	message := "internal error"
	var typed *loaderError
	if errors.As(err, &typed) {
		code = typed.code
		message = typed.message
	}
	if len(message) > maxErrorBytes {
		message = message[:maxErrorBytes]
	}
	return response{
		Schema:    protocolSchema,
		Operation: operation,
		Status:    "error",
		Error: &responseError{
			Code:    code,
			Message: message,
		},
	}
}
