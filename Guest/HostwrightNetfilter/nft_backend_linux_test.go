//go:build linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"net/netip"
	"testing"

	"github.com/google/nftables/expr"
)

func TestRuleMarkerRoundTripIsCanonical(t *testing.T) {
	identity := policyIdentity{Digest: testDigest, Generation: 42}
	marker := encodeRuleMarker(identity, 17)
	decoded, count, err := decodeRuleMarker(marker)
	if err != nil {
		t.Fatalf("decodeRuleMarker returned error: %v", err)
	}
	if decoded != identity || count != 17 {
		t.Fatalf("unexpected marker result: %#v, %d", decoded, count)
	}

	for _, invalid := range [][]byte{
		[]byte("hostwright-netfilter:v1:042:" + testDigest + ":17"),
		[]byte("hostwright-netfilter:v1:42:" + testDigest + ":017"),
		[]byte("hostwright-netfilter:v1:42:ABCDEF:17"),
		[]byte("unowned"),
	} {
		if _, _, err := decodeRuleMarker(invalid); err == nil {
			t.Fatalf("accepted invalid marker %q", invalid)
		}
	}
}

func TestAddressRuleExpressionsMatchFamilyDirectionProtocolAndPort(t *testing.T) {
	rule := compiledRule{
		Direction:       directionOutput,
		Kind:            rulePolicy,
		Family:          familyIPv6,
		Protocol:        protocolUDP,
		Prefix:          netip.MustParsePrefix("2001:db8::/64"),
		DestinationPort: portReference(5353),
	}
	expressions, err := expressionsForAddressRule(rule)
	if err != nil {
		t.Fatalf("expressionsForAddressRule returned error: %v", err)
	}
	if len(expressions) != 10 {
		t.Fatalf("expression count = %d, want 10", len(expressions))
	}
	payload, ok := expressions[2].(*expr.Payload)
	if !ok || payload.Offset != 24 || payload.Len != 16 {
		t.Fatalf("unexpected address payload: %#v", expressions[2])
	}
	bitwise, ok := expressions[3].(*expr.Bitwise)
	if !ok || len(bitwise.Mask) != 16 || bitwise.Mask[0] != 0xff ||
		bitwise.Mask[7] != 0xff || bitwise.Mask[8] != 0 {
		t.Fatalf("unexpected prefix mask: %#v", expressions[3])
	}
	portPayload, ok := expressions[7].(*expr.Payload)
	if !ok || portPayload.Offset != 2 || portPayload.Len != 2 {
		t.Fatalf("unexpected port payload: %#v", expressions[7])
	}
	if _, ok := expressions[9].(*expr.Verdict); !ok {
		t.Fatalf("last expression is not a verdict: %#v", expressions[9])
	}
}

func TestNDPRuleOnlyMatchesDeclaredICMPv6Type(t *testing.T) {
	expressions, err := expressionsForRule(compiledRule{
		Direction:  directionInput,
		Kind:       ruleNDP,
		Family:     familyIPv6,
		ICMPv6Type: 135,
	})
	if err != nil {
		t.Fatalf("expressionsForRule returned error: %v", err)
	}
	if len(expressions) != 7 {
		t.Fatalf("expression count = %d, want 7", len(expressions))
	}
	comparison, ok := expressions[5].(*expr.Cmp)
	if !ok || len(comparison.Data) != 1 || comparison.Data[0] != 135 {
		t.Fatalf("unexpected NDP comparison: %#v", expressions[5])
	}
}

func TestAnyPortRuleOmitsTransportPortExpressions(t *testing.T) {
	expressions, err := expressionsForAddressRule(compiledRule{
		Direction: directionInput,
		Kind:      rulePolicy,
		Family:    familyIPv4,
		Protocol:  protocolTCP,
		Prefix:    netip.MustParsePrefix("192.0.2.0/24"),
	})
	if err != nil {
		t.Fatalf("expressionsForAddressRule returned error: %v", err)
	}
	if len(expressions) != 8 {
		t.Fatalf("expression count = %d, want 8", len(expressions))
	}
	if _, ok := expressions[7].(*expr.Verdict); !ok {
		t.Fatalf("last expression is not a verdict: %#v", expressions[7])
	}
}
