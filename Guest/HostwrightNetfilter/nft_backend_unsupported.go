//go:build !linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
)

type nftBackend struct{}

func newNFTBackend() (*nftBackend, error) {
	return nil, newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

func (backend *nftBackend) Inspect(context.Context) (firewallSnapshot, error) {
	return firewallSnapshot{}, newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

func (backend *nftBackend) Replace(context.Context, compiledPolicy) error {
	return newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

func (backend *nftBackend) Remove(context.Context, policyIdentity) error {
	return newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}
