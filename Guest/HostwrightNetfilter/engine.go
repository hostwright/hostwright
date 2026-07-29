// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"fmt"
)

type firewallSnapshot struct {
	Exists    bool
	Owned     bool
	Valid     bool
	Identity  policyIdentity
	RuleCount int
}

type firewallBackend interface {
	Inspect(context.Context) (firewallSnapshot, error)
	Replace(context.Context, compiledPolicy) error
	Remove(context.Context, policyIdentity) error
}

func executeRequest(
	ctx context.Context,
	backend firewallBackend,
	value request,
) (response, error) {
	normalized, err := normalizeAndVerifyPolicy(value)
	if err != nil {
		return response{}, err
	}
	switch value.Operation {
	case operationApply:
		return executeApply(ctx, backend, value, normalized)
	case operationVerify:
		return executeVerify(ctx, backend, value, normalized)
	case operationRemove:
		return executeRemove(ctx, backend, value, normalized)
	default:
		return response{}, newLoaderError(
			"invalid_operation",
			"unsupported operation %q",
			value.Operation,
		)
	}
}

func executeApply(
	ctx context.Context,
	backend firewallBackend,
	value request,
	normalized normalizedPolicy,
) (response, error) {
	compiled := compilePolicy(normalized)

	current, err := backend.Inspect(ctx)
	if err != nil {
		return response{}, backendError("inspect policy", err)
	}
	if current.Exists && !current.Owned {
		return response{}, newLoaderError(
			"ownership_conflict",
			"existing Hostwright nftables table does not have valid ownership metadata",
		)
	}
	if current.Exists {
		switch {
		case current.Identity.Generation > compiled.Identity.Generation:
			return response{}, newLoaderError(
				"stale_generation",
				"installed generation %d is newer than requested generation %d",
				current.Identity.Generation,
				compiled.Identity.Generation,
			)
		case current.Identity.Generation == compiled.Identity.Generation &&
			current.Identity.Digest != compiled.Identity.Digest:
			return response{}, newLoaderError(
				"generation_conflict",
				"installed generation %d has a different policy digest",
				current.Identity.Generation,
			)
		case current.Valid &&
			current.Identity == compiled.Identity &&
			current.RuleCount == len(compiled.Rules):
			return successResponse(value, "unchanged", current.RuleCount), nil
		}
	}

	if err := backend.Replace(ctx, compiled); err != nil {
		return response{}, backendError("replace policy", err)
	}
	installed, err := backend.Inspect(ctx)
	if err != nil {
		return response{}, backendError("verify replaced policy", err)
	}
	if !installed.Exists ||
		!installed.Valid ||
		installed.Identity != compiled.Identity ||
		installed.RuleCount != len(compiled.Rules) {
		return response{}, newLoaderError(
			"verification_failed",
			"installed policy does not match requested identity and rule count",
		)
	}
	return successResponse(value, "applied", installed.RuleCount), nil
}

func executeVerify(
	ctx context.Context,
	backend firewallBackend,
	value request,
	normalized normalizedPolicy,
) (response, error) {
	current, err := backend.Inspect(ctx)
	if err != nil {
		return response{}, backendError("inspect policy", err)
	}
	if !current.Exists {
		return response{}, newLoaderError("policy_not_found", "no Hostwright policy is installed")
	}
	if !current.Owned {
		return response{}, newLoaderError(
			"ownership_conflict",
			"installed Hostwright nftables table has invalid ownership metadata",
		)
	}
	if !current.Valid {
		return response{}, newLoaderError(
			"verification_failed",
			"installed Hostwright nftables rules do not match their recorded count",
		)
	}
	expected := normalized.Identity
	if current.Identity != expected {
		return response{}, newLoaderError(
			"policy_mismatch",
			"installed policy identity does not match the requested identity",
		)
	}
	return successResponse(value, "verified", current.RuleCount), nil
}

func executeRemove(
	ctx context.Context,
	backend firewallBackend,
	value request,
	normalized normalizedPolicy,
) (response, error) {
	current, err := backend.Inspect(ctx)
	if err != nil {
		return response{}, backendError("inspect policy", err)
	}
	if !current.Exists {
		return successResponse(value, "absent", 0), nil
	}
	if !current.Owned {
		return response{}, newLoaderError(
			"ownership_conflict",
			"installed Hostwright nftables table has invalid ownership metadata",
		)
	}
	expected := normalized.Identity
	if current.Identity != expected {
		return response{}, newLoaderError(
			"policy_mismatch",
			"installed policy identity does not match the requested identity",
		)
	}
	if err := backend.Remove(ctx, expected); err != nil {
		return response{}, backendError("remove policy", err)
	}
	remaining, err := backend.Inspect(ctx)
	if err != nil {
		return response{}, backendError("verify removed policy", err)
	}
	if remaining.Exists {
		return response{}, newLoaderError(
			"verification_failed",
			"Hostwright policy table remains after removal",
		)
	}
	return successResponse(value, "removed", 0), nil
}

func successResponse(value request, status string, ruleCount int) response {
	return response{
		Schema:       protocolSchema,
		Operation:    value.Operation,
		Status:       status,
		PolicyDigest: value.PolicyDigest,
		Generation:   value.Generation,
		RuleCount:    ruleCount,
	}
}

func backendError(action string, err error) error {
	return newLoaderError("backend_error", "%s: %s", action, boundedError(err))
}

func boundedError(err error) string {
	message := fmt.Sprint(err)
	if len(message) > maxErrorBytes {
		return message[:maxErrorBytes]
	}
	return message
}
