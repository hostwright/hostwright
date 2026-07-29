// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"testing"
)

func TestNormalizePolicySortsRulesAndDNSServers(t *testing.T) {
	value := unsignedTestRequest(3)
	value.Ingress = []wireRule{
			{CIDR: "2001:db8::/64", Protocol: "udp", DestinationPort: portReference(53)},
			{CIDR: "10.0.0.0/24", Protocol: "tcp", DestinationPort: portReference(443)},
	}
	value.DNSServers = []string{"2001:4860:4860::8888", "1.1.1.1"}
	normalized, err := normalizePolicy(value)
	if err != nil {
		t.Fatalf("normalizePolicy returned error: %v", err)
	}
	if got := normalized.Ingress[0].Prefix.String(); got != "10.0.0.0/24" {
		t.Fatalf("first normalized rule = %q", got)
	}
	if got := normalized.DNSServers[0].String(); got != "1.1.1.1" {
		t.Fatalf("first normalized DNS server = %q", got)
	}
}

func TestNormalizePolicyRejectsNoncanonicalAndDuplicateValues(t *testing.T) {
	tests := []struct {
		name    string
		ingress []wireRule
		dns     []string
	}{
		{
			name: "host bits",
			ingress: []wireRule{
				{CIDR: "10.0.0.1/24", Protocol: "tcp", DestinationPort: portReference(80)},
			},
		},
		{
			name: "mapped IPv4",
			ingress: []wireRule{
				{CIDR: "::ffff:192.0.2.1/128", Protocol: "tcp", DestinationPort: portReference(80)},
			},
		},
		{
			name: "duplicate rule",
			ingress: []wireRule{
				{CIDR: "10.0.0.0/24", Protocol: "tcp", DestinationPort: portReference(80)},
				{CIDR: "10.0.0.0/24", Protocol: "tcp", DestinationPort: portReference(80)},
			},
		},
		{
			name: "duplicate DNS",
			dns:  []string{"1.1.1.1", "1.1.1.1"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			value := unsignedTestRequest(1)
			value.Ingress = test.ingress
			value.DNSServers = test.dns
			_, err := normalizePolicy(value)
			if err == nil {
				t.Fatal("expected normalization error")
			}
		})
	}
}

func TestCompilePolicyInstallsDefaultDropExceptionsAndExactAllows(t *testing.T) {
	value := unsignedTestRequest(4)
	value.Ingress = []wireRule{
			{CIDR: "10.0.0.0/24", Protocol: "tcp", DestinationPort: portReference(443)},
	}
	value.Egress = []wireRule{
			{CIDR: "2001:db8::/64", Protocol: "udp", DestinationPort: portReference(8443)},
	}
	value.DNSServers = []string{"1.1.1.1"}
	normalized, err := normalizePolicy(value)
	if err != nil {
		t.Fatalf("normalizePolicy returned error: %v", err)
	}
	compiled := compilePolicy(normalized)

	counts := make(map[ruleKind]int)
	for _, rule := range compiled.Rules {
		counts[rule.Kind]++
	}
	if counts[ruleLoopback] != 2 {
		t.Fatalf("loopback rules = %d, want 2", counts[ruleLoopback])
	}
	if counts[ruleEstablishedRelated] != 2 {
		t.Fatalf("established rules = %d, want 2", counts[ruleEstablishedRelated])
	}
	if counts[ruleNDP] != 8 {
		t.Fatalf("NDP rules = %d, want 8", counts[ruleNDP])
	}
	if counts[ruleDNS] != 2 {
		t.Fatalf("DNS rules = %d, want 2", counts[ruleDNS])
	}
	if counts[rulePolicy] != 2 {
		t.Fatalf("policy rules = %d, want 2", counts[rulePolicy])
	}
	for _, rule := range compiled.Rules {
		if rule.Kind == ruleDNS {
			if rule.Direction != directionOutput ||
				rule.Prefix.String() != "1.1.1.1/32" ||
				rule.DestinationPort == nil ||
				*rule.DestinationPort != 53 {
				t.Fatalf("unexpected DNS rule: %#v", rule)
			}
		}
	}
}

func TestCompilePolicyDeduplicatesExplicitDNSAllow(t *testing.T) {
	value := unsignedTestRequest(5)
	value.Egress = []wireRule{
			{CIDR: "1.1.1.1/32", Protocol: "tcp", DestinationPort: portReference(53)},
	}
	value.DNSServers = []string{"1.1.1.1"}
	normalized, err := normalizePolicy(value)
	if err != nil {
		t.Fatalf("normalizePolicy returned error: %v", err)
	}
	compiled := compilePolicy(normalized)
	seenTCP := 0
	for _, rule := range compiled.Rules {
		if rule.Direction == directionOutput &&
			rule.Prefix.IsValid() &&
			rule.Prefix.String() == "1.1.1.1/32" &&
			rule.Protocol == protocolTCP &&
			rule.DestinationPort != nil &&
			*rule.DestinationPort == 53 {
			seenTCP++
		}
	}
	if seenTCP != 1 {
		t.Fatalf("TCP DNS allow count = %d, want 1", seenTCP)
	}
}

func TestCompilePolicySupportsExactAnyPortRule(t *testing.T) {
	value := unsignedTestRequest(6)
	value.Ingress = []wireRule{
			{CIDR: "192.0.2.0/24", Protocol: "tcp"},
	}
	normalized, err := normalizePolicy(value)
	if err != nil {
		t.Fatalf("normalizePolicy returned error: %v", err)
	}
	compiled := compilePolicy(normalized)
	found := false
	for _, rule := range compiled.Rules {
		if rule.Kind == rulePolicy {
			found = true
			if rule.DestinationPort != nil {
				t.Fatalf("any-port rule gained a port: %#v", rule)
			}
		}
	}
	if !found {
		t.Fatal("compiled policy did not contain the any-port rule")
	}
}

func TestNormalizePolicyEnforcesPerDirectionLimit(t *testing.T) {
	rules := make([]wireRule, maxPolicyRulesPerDirection+1)
	value := unsignedTestRequest(1)
	value.Ingress = rules
	_, err := normalizePolicy(value)
	if err == nil {
		t.Fatal("expected per-direction rule limit rejection")
	}
}

func TestCanonicalPolicyDigestMatchesLanguageNeutralLineFormat(t *testing.T) {
	value := unsignedTestRequest(1)
	normalized, err := normalizePolicy(value)
	if err != nil {
		t.Fatalf("normalizePolicy returned error: %v", err)
	}
	const expected = "f1f50748f20baf7276ee4a2de4f9e5f83b6845e36880507f29729776559e76bf"
	if got := canonicalPolicyDigest(normalized); got != expected {
		t.Fatalf("canonical digest = %q, want %q", got, expected)
	}
}

func TestCanonicalPolicyDigestMatchesSwiftGoldenVector(t *testing.T) {
	value := unsignedTestRequest(7)
	value.ProjectUUID = "22222222-2222-4222-8222-222222222222"
	value.ServiceResourceUUID = "11111111-1111-4111-8111-111111111111"
	value.DNSServers = []string{"1.1.1.1"}
	value.Ingress = []wireRule{
		{CIDR: "10.0.0.0/24", Protocol: "tcp", DestinationPort: portReference(443)},
	}
	value.Egress = []wireRule{
		{CIDR: "2001:db8::/64", Protocol: "udp"},
	}
	normalized, err := normalizePolicy(value)
	if err != nil {
		t.Fatalf("normalizePolicy returned error: %v", err)
	}
	const expectedBytes = "hostwright-netfilter-v1\n" +
		"generation=7\n" +
		"projectUUID=22222222-2222-4222-8222-222222222222\n" +
		"serviceResourceUUID=11111111-1111-4111-8111-111111111111\n" +
		"ingressDefault=deny\n" +
		"egressDefault=deny\n" +
		"dns=1.1.1.1\n" +
		"ingress=10.0.0.0/24|tcp|443\n" +
		"egress=2001:db8::/64|udp|*\n"
	if got := string(canonicalPolicyBytes(normalized)); got != expectedBytes {
		t.Fatalf("canonical bytes = %q, want %q", got, expectedBytes)
	}
	const expected = "11648e11c0396db47980bdefbb677cdbe37b4e56513fd0e8c16c8e13d71c3c7f"
	if got := canonicalPolicyDigest(normalized); got != expected {
		t.Fatalf("canonical digest = %q, want %q", got, expected)
	}
}
