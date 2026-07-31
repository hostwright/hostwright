//go:build !linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
)

func acquireLoaderLock() (*os.File, error) {
	return nil, newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

func newSystemBackend() (firewallBackend, error) {
	return nil, newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

func openGuestAgentRequestFile(_ string, _ invocationMode) (*os.File, error) {
	return nil, newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

type unsupportedPreparedBootstrap struct{}

func prepareBootstrap(_ request, _ []string) (preparedBootstrap, error) {
	return nil, newLoaderError(
		"unsupported_platform",
		"guest netfilter loader requires Linux",
	)
}

func (unsupportedPreparedBootstrap) Exec(_ request) error {
	return newLoaderError("unsupported_platform", "guest netfilter loader requires Linux")
}
