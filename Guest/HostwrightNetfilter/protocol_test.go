// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestDecodeRequestAcceptsStrictApplyEnvelope(t *testing.T) {
	value, err := decodeRequest(strings.NewReader(`{
		"schema": 1,
		"operation": "apply",
		"policyDigest": "` + testDigest + `",
		"generation": 7,
		"projectUUID": "` + testProjectUUID + `",
		"serviceResourceUUID": "` + testServiceUUID + `",
		"ingressDefault": "deny",
		"egressDefault": "deny",
		"ingress": [
			{"cidr": "10.0.0.0/24", "protocol": "tcp", "destinationPort": 443}
		],
		"egress": [],
		"dnsServers": ["1.1.1.1"]
	}`))
	if err != nil {
		t.Fatalf("decodeRequest returned error: %v", err)
	}
	if value.Operation != operationApply || value.Generation != 7 {
		t.Fatalf("unexpected request: %#v", value)
	}
	if len(value.Ingress) != 1 ||
		value.Ingress[0].DestinationPort == nil ||
		*value.Ingress[0].DestinationPort != 443 {
		t.Fatalf("unexpected ingress rules: %#v", value.Ingress)
	}
}

func TestDecodeRequestRejectsDuplicateAndUnknownKeys(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{
			name: "duplicate",
			body: `{"schema":1,"schema":1,"operation":"verify","policyDigest":"` +
				testDigest + `","generation":1,"projectUUID":"` + testProjectUUID +
				`","serviceResourceUUID":"` + testServiceUUID +
				`","ingressDefault":"deny","egressDefault":"deny"}`,
		},
		{
			name: "nested duplicate",
			body: `{"schema":1,"operation":"apply","policyDigest":"` + testDigest +
				`","generation":1,"projectUUID":"` + testProjectUUID +
				`","serviceResourceUUID":"` + testServiceUUID +
				`","ingressDefault":"deny","egressDefault":"deny","ingress":[{"cidr":"10.0.0.0/24","cidr":"10.0.0.0/24","protocol":"tcp","destinationPort":80}]}`,
		},
		{
			name: "unknown",
			body: `{"schema":1,"operation":"verify","policyDigest":"` +
				testDigest + `","generation":1,"projectUUID":"` + testProjectUUID +
				`","serviceResourceUUID":"` + testServiceUUID +
				`","ingressDefault":"deny","egressDefault":"deny","unexpected":true}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decodeRequest(strings.NewReader(test.body)); err == nil {
				t.Fatal("expected request rejection")
			}
		})
	}
}

func TestDecodeRequestRejectsMalformedEnvelope(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "uppercase digest", body: validVerifyBody(strings.ToUpper(testDigest), 1)},
		{name: "zero generation", body: validVerifyBody(testDigest, 0)},
		{
			name: "rules on verify",
			body: `{"schema":1,"operation":"verify","policyDigest":"` + testDigest +
				`","generation":1,"projectUUID":"` + testProjectUUID +
				`","serviceResourceUUID":"` + testServiceUUID +
				`","ingressDefault":"deny","egressDefault":"deny","targetUID":1}`,
		},
		{
			name: "multiple documents",
			body: validVerifyBody(testDigest, 1) + "\n" + validVerifyBody(testDigest, 1),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decodeRequest(strings.NewReader(test.body)); err == nil {
				t.Fatal("expected request rejection")
			}
		})
	}
}

func TestDecodeRequestEnforcesByteLimit(t *testing.T) {
	body := bytes.Repeat([]byte{' '}, maxRequestBytes+1)
	if _, err := decodeRequest(bytes.NewReader(body)); err == nil {
		t.Fatal("expected oversized request rejection")
	}
}

func validVerifyBody(digest string, generation uint64) string {
	return `{"schema":1,"operation":"verify","policyDigest":"` + digest +
		`","generation":` + decimal(generation) +
		`,"projectUUID":"` + testProjectUUID +
		`","serviceResourceUUID":"` + testServiceUUID +
		`","ingressDefault":"deny","egressDefault":"deny"}`
}

func decimal(value uint64) string {
	if value == 0 {
		return "0"
	}
	var digits [20]byte
	position := len(digits)
	for value > 0 {
		position--
		digits[position] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[position:])
}
