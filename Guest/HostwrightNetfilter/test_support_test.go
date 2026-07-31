// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

const (
	testDigest      = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	testProjectUUID = "11111111-1111-4111-8111-111111111111"
	testServiceUUID = "22222222-2222-4222-8222-222222222222"
)

func unsignedTestRequest(generation uint64) request {
	return request{
		Schema:              protocolSchema,
		Operation:           operationApply,
		PolicyDigest:        testDigest,
		Generation:          generation,
		ProjectUUID:         testProjectUUID,
		ServiceResourceUUID: testServiceUUID,
		IngressDefault:      "deny",
		EgressDefault:       "deny",
	}
}

func signedTestRequest(generation uint64) request {
	value := unsignedTestRequest(generation)
	normalized, err := normalizePolicy(value)
	if err != nil {
		panic(err)
	}
	value.PolicyDigest = canonicalPolicyDigest(normalized)
	return value
}
