// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"path"
	"strings"
)

type preparedBootstrap interface {
	Exec(request) error
}

func validateBootstrapConfiguration(value request) error {
	if value.Operation != operationApply {
		return newLoaderError("invalid_bootstrap", "bootstrap requires an apply request")
	}
	if value.WorkingDirectory == "" ||
		!path.IsAbs(value.WorkingDirectory) ||
		path.Clean(value.WorkingDirectory) != value.WorkingDirectory ||
		strings.ContainsRune(value.WorkingDirectory, '\x00') {
		return newLoaderError(
			"invalid_working_directory",
			"workingDirectory must be a canonical absolute container path",
		)
	}
	if value.TargetUID != nil && *value.TargetUID == ^uint32(0) {
		return newLoaderError("invalid_target_uid", "targetUID is not a valid numeric UID")
	}
	if value.TargetGID != nil && *value.TargetGID == ^uint32(0) {
		return newLoaderError("invalid_target_gid", "targetGID is not a valid numeric GID")
	}
	return nil
}
