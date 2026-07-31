// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"testing"
)

type fakeFirewallBackend struct {
	snapshot    firewallSnapshot
	inspectErr  error
	replaceErr  error
	removeErr   error
	inspectCall int
	replaceCall int
	removeCall  int
}

func (backend *fakeFirewallBackend) Inspect(ctx context.Context) (firewallSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return firewallSnapshot{}, err
	}
	backend.inspectCall++
	if backend.inspectErr != nil {
		return firewallSnapshot{}, backend.inspectErr
	}
	return backend.snapshot, nil
}

func TestExecuteRejectsDigestMismatchBeforeBackendAccess(t *testing.T) {
	backend := &fakeFirewallBackend{}
	value := signedTestRequest(1)
	value.Egress = []wireRule{
		{CIDR: "0.0.0.0/0", Protocol: "tcp"},
	}
	if _, err := executeRequest(context.Background(), backend, value); err == nil {
		t.Fatal("expected digest mismatch")
	}
	if backend.inspectCall != 0 || backend.replaceCall != 0 {
		t.Fatalf(
			"backend accessed before digest verification: inspect=%d replace=%d",
			backend.inspectCall,
			backend.replaceCall,
		)
	}
}

func (backend *fakeFirewallBackend) Replace(
	ctx context.Context,
	policy compiledPolicy,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	backend.replaceCall++
	if backend.replaceErr != nil {
		return backend.replaceErr
	}
	backend.snapshot = firewallSnapshot{
		Exists:    true,
		Owned:     true,
		Valid:     true,
		Identity:  policy.Identity,
		RuleCount: len(policy.Rules),
	}
	return nil
}

func (backend *fakeFirewallBackend) Remove(
	ctx context.Context,
	_ policyIdentity,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	backend.removeCall++
	if backend.removeErr != nil {
		return backend.removeErr
	}
	backend.snapshot = firewallSnapshot{}
	return nil
}

func TestExecuteApplyReplacesAndVerifiesPolicy(t *testing.T) {
	backend := &fakeFirewallBackend{}
	value := minimalApplyRequest(2)
	result, err := executeRequest(context.Background(), backend, value)
	if err != nil {
		t.Fatalf("executeRequest returned error: %v", err)
	}
	if result.Status != "applied" || result.RuleCount != 12 {
		t.Fatalf("unexpected response: %#v", result)
	}
	if backend.replaceCall != 1 {
		t.Fatalf("replace calls = %d, want 1", backend.replaceCall)
	}

	result, err = executeRequest(context.Background(), backend, value)
	if err != nil {
		t.Fatalf("idempotent executeRequest returned error: %v", err)
	}
	if result.Status != "unchanged" || backend.replaceCall != 1 {
		t.Fatalf("unexpected idempotent result: %#v", result)
	}
}

func TestExecuteApplyRejectsInvalidOwnershipAndGenerationConflicts(t *testing.T) {
	tests := []struct {
		name     string
		snapshot firewallSnapshot
	}{
		{
			name: "invalid ownership",
			snapshot: firewallSnapshot{
				Exists: true,
			},
		},
		{
			name: "newer generation",
			snapshot: firewallSnapshot{
				Exists:   true,
				Owned:    true,
				Valid:    true,
				Identity: policyIdentity{Digest: testDigest, Generation: 3},
			},
		},
		{
			name: "same generation different digest",
			snapshot: firewallSnapshot{
				Exists: true,
				Owned:  true,
				Valid:  true,
				Identity: policyIdentity{
					Digest:     "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
					Generation: 2,
				},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			backend := &fakeFirewallBackend{snapshot: test.snapshot}
			if _, err := executeRequest(
				context.Background(),
				backend,
				minimalApplyRequest(2),
			); err == nil {
				t.Fatal("expected apply rejection")
			}
			if backend.replaceCall != 0 {
				t.Fatalf("replace calls = %d, want 0", backend.replaceCall)
			}
		})
	}
}

func TestExecuteApplyRepairsOwnedRuleLoss(t *testing.T) {
	value := minimalApplyRequest(4)
	backend := &fakeFirewallBackend{
		snapshot: firewallSnapshot{
			Exists: true,
			Owned:  true,
			Valid:  false,
			Identity: policyIdentity{
				Digest:     value.PolicyDigest,
				Generation: value.Generation,
			},
			RuleCount: 11,
		},
	}
	result, err := executeRequest(context.Background(), backend, value)
	if err != nil {
		t.Fatalf("repair returned error: %v", err)
	}
	if result.Status != "applied" || backend.replaceCall != 1 {
		t.Fatalf("unexpected repair result: %#v", result)
	}
}

func TestExecuteVerifyAndRemoveRequireExactIdentity(t *testing.T) {
	verify := signedTestRequest(9)
	verify.Operation = operationVerify
	identity := policyIdentity{Digest: verify.PolicyDigest, Generation: 9}
	backend := &fakeFirewallBackend{
		snapshot: firewallSnapshot{
			Exists:    true,
			Owned:     true,
			Valid:     true,
			Identity:  identity,
			RuleCount: 12,
		},
	}
	result, err := executeRequest(context.Background(), backend, verify)
	if err != nil || result.Status != "verified" {
		t.Fatalf("unexpected verify result: %#v, %v", result, err)
	}

	remove := verify
	remove.Operation = operationRemove
	result, err = executeRequest(context.Background(), backend, remove)
	if err != nil || result.Status != "removed" {
		t.Fatalf("unexpected remove result: %#v, %v", result, err)
	}
	if backend.removeCall != 1 {
		t.Fatalf("remove calls = %d, want 1", backend.removeCall)
	}

	result, err = executeRequest(context.Background(), backend, remove)
	if err != nil || result.Status != "absent" {
		t.Fatalf("unexpected idempotent remove result: %#v, %v", result, err)
	}
}

func TestExecuteReportsBoundedBackendFailure(t *testing.T) {
	backend := &fakeFirewallBackend{inspectErr: errors.New("netlink unavailable")}
	_, err := executeRequest(context.Background(), backend, minimalApplyRequest(1))
	if err == nil {
		t.Fatal("expected backend error")
	}
	var typed *loaderError
	if !errors.As(err, &typed) || typed.code != "backend_error" {
		t.Fatalf("unexpected error: %#v", err)
	}
}

func TestExecuteCancelledContextDoesNotMutatePolicy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	backend := &fakeFirewallBackend{}

	_, err := executeRequest(ctx, backend, minimalApplyRequest(1))
	var typed *loaderError
	if !errors.As(err, &typed) || typed.code != "backend_error" {
		t.Fatalf("error = %#v, want bounded backend cancellation", err)
	}
	if backend.replaceCall != 0 || backend.removeCall != 0 {
		t.Fatalf(
			"cancelled request mutated backend: replace=%d remove=%d",
			backend.replaceCall,
			backend.removeCall,
		)
	}
}

func TestExecuteReplaceFailureRetainsPriorPolicy(t *testing.T) {
	prior := firewallSnapshot{
		Exists:    true,
		Owned:     true,
		Valid:     false,
		Identity:  policyIdentity{Digest: testDigest, Generation: 1},
		RuleCount: 7,
	}
	backend := &fakeFirewallBackend{
		snapshot:   prior,
		replaceErr: errors.New("injected atomic transaction failure"),
	}

	if _, err := executeRequest(
		context.Background(),
		backend,
		minimalApplyRequest(2),
	); err == nil {
		t.Fatal("expected replace failure")
	}
	if backend.snapshot != prior {
		t.Fatalf("failed replacement changed prior snapshot: %#v", backend.snapshot)
	}
}

func minimalApplyRequest(generation uint64) request {
	return signedTestRequest(generation)
}
