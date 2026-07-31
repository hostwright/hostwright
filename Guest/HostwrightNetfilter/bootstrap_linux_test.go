//go:build linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"testing"

	"golang.org/x/sys/unix"
)

func TestBootstrapOnlyCapabilitiesContainExactAuthority(t *testing.T) {
	got := bootstrapOnlyCapabilities()
	want := [5]uint{
		unix.CAP_NET_ADMIN,
		unix.CAP_NET_RAW,
		unix.CAP_SETUID,
		unix.CAP_SETGID,
		unix.CAP_SETPCAP,
	}
	if got != want {
		t.Fatalf("bootstrap-only capabilities = %#v, want %#v", got, want)
	}
}

func TestClearBootstrapCapabilitySetsPreservesUnrelatedAuthority(t *testing.T) {
	data := [2]unix.CapUserData{
		{
			Effective:   ^uint32(0),
			Permitted:   ^uint32(0),
			Inheritable: ^uint32(0),
		},
		{
			Effective:   ^uint32(0),
			Permitted:   ^uint32(0),
			Inheritable: ^uint32(0),
		},
	}

	clearBootstrapCapabilitySets(&data)

	for _, capability := range bootstrapOnlyCapabilities() {
		index := capability / 32
		mask := uint32(1) << (capability % 32)
		if data[index].Effective&mask != 0 ||
			data[index].Permitted&mask != 0 ||
			data[index].Inheritable&mask != 0 {
			t.Fatalf("capability %d remains in a workload capability set", capability)
		}
	}

	unrelated := uint(unix.CAP_CHOWN)
	index := unrelated / 32
	mask := uint32(1) << (unrelated % 32)
	if data[index].Effective&mask == 0 ||
		data[index].Permitted&mask == 0 ||
		data[index].Inheritable&mask == 0 {
		t.Fatal("clearing bootstrap authority removed unrelated capabilities")
	}
}
