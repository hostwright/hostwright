// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"crypto/sha256"
	"fmt"
	"net/netip"
	"sort"
	"strconv"
	"strings"
)

const (
	maxPolicyRulesPerDirection = 4096
	maxPolicyRules             = maxPolicyRulesPerDirection * 2
	maxDNSServers              = 16
)

type direction string

const (
	directionInput  direction = "input"
	directionOutput direction = "output"
)

type ipFamily string

const (
	familyIPv4 ipFamily = "ipv4"
	familyIPv6 ipFamily = "ipv6"
)

type transportProtocol string

const (
	protocolTCP transportProtocol = "tcp"
	protocolUDP transportProtocol = "udp"
)

type ruleKind string

const (
	ruleLoopback           ruleKind = "loopback"
	ruleEstablishedRelated ruleKind = "established-related"
	ruleNDP                ruleKind = "ndp"
	rulePolicy             ruleKind = "policy"
	ruleDNS                ruleKind = "dns"
)

type policyIdentity struct {
	Digest     string
	Generation uint64
}

type normalizedRule struct {
	Prefix          netip.Prefix
	Protocol        transportProtocol
	DestinationPort *uint16
}

type normalizedPolicy struct {
	Identity            policyIdentity
	ProjectUUID         string
	ServiceResourceUUID string
	IngressDefault      string
	EgressDefault       string
	Ingress             []normalizedRule
	Egress              []normalizedRule
	DNSServers          []netip.Addr
}

type compiledRule struct {
	Direction       direction
	Kind            ruleKind
	Family          ipFamily
	Protocol        transportProtocol
	Prefix          netip.Prefix
	DestinationPort *uint16
	ICMPv6Type      uint8
}

type compiledPolicy struct {
	Identity policyIdentity
	Rules    []compiledRule
}

func normalizePolicy(value request) (normalizedPolicy, error) {
	if !isCanonicalUUID(value.ProjectUUID) {
		return normalizedPolicy{}, newLoaderError(
			"invalid_project_uuid",
			"projectUUID must be a canonical lowercase UUID",
		)
	}
	if !isCanonicalUUID(value.ServiceResourceUUID) {
		return normalizedPolicy{}, newLoaderError(
			"invalid_service_resource_uuid",
			"serviceResourceUUID must be a canonical lowercase UUID",
		)
	}
	if !isPolicyDefault(value.IngressDefault) {
		return normalizedPolicy{}, newLoaderError(
			"invalid_policy_default",
			"ingressDefault must be allowSameProject or deny",
		)
	}
	if !isPolicyDefault(value.EgressDefault) {
		return normalizedPolicy{}, newLoaderError(
			"invalid_policy_default",
			"egressDefault must be allowSameProject or deny",
		)
	}
	if len(value.Ingress) > maxPolicyRulesPerDirection {
		return normalizedPolicy{}, newLoaderError(
			"too_many_rules",
			"ingress contains %d rules; maximum is %d",
			len(value.Ingress),
			maxPolicyRulesPerDirection,
		)
	}
	if len(value.Egress) > maxPolicyRulesPerDirection {
		return normalizedPolicy{}, newLoaderError(
			"too_many_rules",
			"egress contains %d rules; maximum is %d",
			len(value.Egress),
			maxPolicyRulesPerDirection,
		)
	}
	totalRules := len(value.Ingress) + len(value.Egress)
	if totalRules > maxPolicyRules {
		return normalizedPolicy{}, newLoaderError(
			"too_many_rules",
			"policy contains %d rules; maximum is %d",
			totalRules,
			maxPolicyRules,
		)
	}
	if len(value.DNSServers) > maxDNSServers {
		return normalizedPolicy{}, newLoaderError(
			"too_many_dns_servers",
			"policy contains %d DNS servers; maximum is %d",
			len(value.DNSServers),
			maxDNSServers,
		)
	}

	ingress, err := normalizeRules("ingress", value.Ingress)
	if err != nil {
		return normalizedPolicy{}, err
	}
	egress, err := normalizeRules("egress", value.Egress)
	if err != nil {
		return normalizedPolicy{}, err
	}
	dnsServers, err := normalizeDNSServers(value.DNSServers)
	if err != nil {
		return normalizedPolicy{}, err
	}

	return normalizedPolicy{
		Identity: policyIdentity{
			Digest:     value.PolicyDigest,
			Generation: value.Generation,
		},
		ProjectUUID:         value.ProjectUUID,
		ServiceResourceUUID: value.ServiceResourceUUID,
		IngressDefault:      value.IngressDefault,
		EgressDefault:       value.EgressDefault,
		Ingress:             ingress,
		Egress:              egress,
		DNSServers:          dnsServers,
	}, nil
}

func normalizeAndVerifyPolicy(value request) (normalizedPolicy, error) {
	normalized, err := normalizePolicy(value)
	if err != nil {
		return normalizedPolicy{}, err
	}
	computed := canonicalPolicyDigest(normalized)
	if computed != value.PolicyDigest {
		return normalizedPolicy{}, newLoaderError(
			"policy_digest_mismatch",
			"policyDigest does not match the canonical policy document",
		)
	}
	return normalized, nil
}

func isCanonicalUUID(value string) bool {
	if len(value) != 36 ||
		value[8] != '-' ||
		value[13] != '-' ||
		value[18] != '-' ||
		value[23] != '-' {
		return false
	}
	hasNonzero := false
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !strings.ContainsRune("0123456789abcdef", character) {
			return false
		}
		if character != '0' {
			hasNonzero = true
		}
	}
	return hasNonzero
}

func isPolicyDefault(value string) bool {
	return value == "allowSameProject" || value == "deny"
}

func canonicalPolicyDigest(value normalizedPolicy) string {
	return fmt.Sprintf("%x", sha256.Sum256(canonicalPolicyBytes(value)))
}

func canonicalPolicyBytes(value normalizedPolicy) []byte {
	lines := []string{
		"hostwright-netfilter-v1",
		"generation=" + strconv.FormatUint(value.Identity.Generation, 10),
		"projectUUID=" + value.ProjectUUID,
		"serviceResourceUUID=" + value.ServiceResourceUUID,
		"ingressDefault=" + value.IngressDefault,
		"egressDefault=" + value.EgressDefault,
	}
	dnsLines := make([]string, 0, len(value.DNSServers))
	for _, server := range value.DNSServers {
		dnsLines = append(dnsLines, "dns="+server.String())
	}
	sort.Strings(dnsLines)
	lines = append(lines, dnsLines...)
	lines = append(lines, canonicalRuleLines("ingress", value.Ingress)...)
	lines = append(lines, canonicalRuleLines("egress", value.Egress)...)
	return []byte(strings.Join(lines, "\n") + "\n")
}

func canonicalRuleLines(prefix string, values []normalizedRule) []string {
	lines := make([]string, 0, len(values))
	for _, value := range values {
		lines = append(lines, fmt.Sprintf(
			"%s=%s|%s|%s",
			prefix,
			value.Prefix.String(),
			value.Protocol,
			destinationPortCanonical(value.DestinationPort),
		))
	}
	sort.Strings(lines)
	return lines
}

func destinationPortCanonical(value *uint16) string {
	if value == nil {
		return "*"
	}
	return strconv.FormatUint(uint64(*value), 10)
}

func normalizeRules(field string, values []wireRule) ([]normalizedRule, error) {
	result := make([]normalizedRule, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for index, value := range values {
		prefix, err := netip.ParsePrefix(value.CIDR)
		if err != nil || !prefix.Addr().IsValid() || prefix.Addr().Is4In6() {
			return nil, newLoaderError(
				"invalid_rule",
				"%s[%d].cidr is not a concrete IPv4 or IPv6 prefix",
				field,
				index,
			)
		}
		if prefix.Addr().Zone() != "" {
			return nil, newLoaderError(
				"invalid_rule",
				"%s[%d].cidr must not contain an IPv6 zone",
				field,
				index,
			)
		}
		prefix = prefix.Masked()
		if prefix.String() != value.CIDR {
			return nil, newLoaderError(
				"noncanonical_rule",
				"%s[%d].cidr must be canonical %q",
				field,
				index,
				prefix.String(),
			)
		}

		protocol := transportProtocol(value.Protocol)
		if protocol != protocolTCP && protocol != protocolUDP {
			return nil, newLoaderError(
				"invalid_rule",
				"%s[%d].protocol must be tcp or udp",
				field,
				index,
			)
		}
		if value.DestinationPort != nil && *value.DestinationPort == 0 {
			return nil, newLoaderError(
				"invalid_rule",
				"%s[%d].destinationPort must be between 1 and 65535",
				field,
				index,
			)
		}

		key := fmt.Sprintf(
			"%s|%s|%s",
			prefix,
			protocol,
			destinationPortKey(value.DestinationPort),
		)
		if _, exists := seen[key]; exists {
			return nil, newLoaderError(
				"duplicate_rule",
				"%s[%d] duplicates an earlier rule",
				field,
				index,
			)
		}
		seen[key] = struct{}{}
		result = append(result, normalizedRule{
			Prefix:          prefix,
			Protocol:        protocol,
			DestinationPort: value.DestinationPort,
		})
	}

	sort.Slice(result, func(left, right int) bool {
		leftKey := normalizedRuleSortKey(result[left])
		rightKey := normalizedRuleSortKey(result[right])
		return leftKey < rightKey
	})
	return result, nil
}

func normalizedRuleSortKey(value normalizedRule) string {
	return fmt.Sprintf(
		"%d|%s|%03d|%s|%s",
		familySortOrder(value.Prefix.Addr()),
		value.Prefix.Addr(),
		value.Prefix.Bits(),
		value.Protocol,
		destinationPortKey(value.DestinationPort),
	)
}

func normalizeDNSServers(values []string) ([]netip.Addr, error) {
	result := make([]netip.Addr, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for index, value := range values {
		address, err := netip.ParseAddr(value)
		if err != nil || !address.IsValid() || address.Is4In6() || address.Zone() != "" {
			return nil, newLoaderError(
				"invalid_dns_server",
				"dnsServers[%d] is not a concrete IPv4 or IPv6 address",
				index,
			)
		}
		if address.String() != value {
			return nil, newLoaderError(
				"noncanonical_dns_server",
				"dnsServers[%d] must be canonical %q",
				index,
				address.String(),
			)
		}
		if _, exists := seen[value]; exists {
			return nil, newLoaderError(
				"duplicate_dns_server",
				"dnsServers[%d] duplicates an earlier server",
				index,
			)
		}
		seen[value] = struct{}{}
		result = append(result, address)
	}
	sort.Slice(result, func(left, right int) bool {
		if familySortOrder(result[left]) != familySortOrder(result[right]) {
			return familySortOrder(result[left]) < familySortOrder(result[right])
		}
		return result[left].Compare(result[right]) < 0
	})
	return result, nil
}

func familySortOrder(address netip.Addr) int {
	if address.Is4() {
		return 0
	}
	return 1
}

func compilePolicy(value normalizedPolicy) compiledPolicy {
	rules := make([]compiledRule, 0, 12+len(value.Ingress)+len(value.Egress)+len(value.DNSServers)*2)
	for _, chain := range []direction{directionInput, directionOutput} {
		rules = append(rules,
			compiledRule{Direction: chain, Kind: ruleLoopback},
			compiledRule{Direction: chain, Kind: ruleEstablishedRelated},
		)
		for _, messageType := range []uint8{133, 134, 135, 136} {
			rules = append(rules, compiledRule{
				Direction:  chain,
				Kind:       ruleNDP,
				Family:     familyIPv6,
				ICMPv6Type: messageType,
			})
		}
	}

	for _, rule := range value.Ingress {
		rules = append(rules, compiledPolicyRule(directionInput, rule))
	}
	for _, server := range value.DNSServers {
		prefix := netip.PrefixFrom(server, server.BitLen())
		for _, protocol := range []transportProtocol{protocolTCP, protocolUDP} {
			rules = append(rules, compiledRule{
				Direction:       directionOutput,
				Kind:            ruleDNS,
				Family:          familyForAddress(server),
				Protocol:        protocol,
				Prefix:          prefix,
				DestinationPort: portReference(53),
			})
		}
	}
	for _, rule := range value.Egress {
		rules = append(rules, compiledPolicyRule(directionOutput, rule))
	}

	return compiledPolicy{
		Identity: value.Identity,
		Rules:    deduplicateCompiledRules(rules),
	}
}

func compiledPolicyRule(chain direction, value normalizedRule) compiledRule {
	return compiledRule{
		Direction:       chain,
		Kind:            rulePolicy,
		Family:          familyForAddress(value.Prefix.Addr()),
		Protocol:        value.Protocol,
		Prefix:          value.Prefix,
		DestinationPort: value.DestinationPort,
	}
}

func familyForAddress(address netip.Addr) ipFamily {
	if address.Is4() {
		return familyIPv4
	}
	return familyIPv6
}

func deduplicateCompiledRules(values []compiledRule) []compiledRule {
	result := make([]compiledRule, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		semanticKind := value.Kind
		if semanticKind == rulePolicy || semanticKind == ruleDNS {
			semanticKind = "address-allow"
		}
		key := fmt.Sprintf(
			"%s|%s|%s|%s|%s|%s|%d",
			value.Direction,
			semanticKind,
			value.Family,
			value.Protocol,
			value.Prefix,
			destinationPortKey(value.DestinationPort),
			value.ICMPv6Type,
		)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, value)
	}
	return result
}

func destinationPortKey(value *uint16) string {
	if value == nil {
		return "*"
	}
	return fmt.Sprintf("%05d", *value)
}

func portReference(value uint16) *uint16 {
	result := value
	return &result
}
