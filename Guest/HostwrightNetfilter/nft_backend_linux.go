//go:build linux

// Copyright 2026 Hostwright contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"strconv"
	"strings"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"golang.org/x/sys/unix"
)

const (
	nftTableName   = "hostwright_filter"
	nftInputChain  = "input"
	nftOutputChain = "output"
	markerPrefix   = "hostwright-netfilter:v1:"
)

type nftBackend struct{}

func newNFTBackend() (*nftBackend, error) {
	if _, err := nftables.New(); err != nil {
		return nil, err
	}
	return &nftBackend{}, nil
}

func (backend *nftBackend) Inspect(ctx context.Context) (firewallSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return firewallSnapshot{}, err
	}
	conn, err := nftables.New()
	if err != nil {
		return firewallSnapshot{}, err
	}
	tables, err := conn.ListTables()
	if err != nil {
		return firewallSnapshot{}, err
	}
	var table *nftables.Table
	for _, candidate := range tables {
		if candidate.Family == nftables.TableFamilyINet && candidate.Name == nftTableName {
			if table != nil {
				return firewallSnapshot{Exists: true}, nil
			}
			table = candidate
		}
	}
	if table == nil {
		return firewallSnapshot{}, nil
	}

	chains, err := conn.ListChains()
	if err != nil {
		return firewallSnapshot{}, err
	}
	ownedChains := make(map[string]*nftables.Chain, 2)
	for _, candidate := range chains {
		if candidate.Table == nil ||
			candidate.Table.Family != nftables.TableFamilyINet ||
			candidate.Table.Name != nftTableName {
			continue
		}
		if _, exists := ownedChains[candidate.Name]; exists {
			return firewallSnapshot{Exists: true}, nil
		}
		ownedChains[candidate.Name] = candidate
	}
	if len(ownedChains) != 2 {
		return firewallSnapshot{Exists: true}, nil
	}
	input, inputExists := ownedChains[nftInputChain]
	output, outputExists := ownedChains[nftOutputChain]
	if !inputExists || !outputExists ||
		!isExpectedBaseChain(input, nftables.ChainHookInput) ||
		!isExpectedBaseChain(output, nftables.ChainHookOutput) {
		return firewallSnapshot{Exists: true}, nil
	}

	inputRules, err := conn.GetRules(table, input)
	if err != nil {
		return firewallSnapshot{}, err
	}
	outputRules, err := conn.GetRules(table, output)
	if err != nil {
		return firewallSnapshot{}, err
	}
	allRules := append(inputRules, outputRules...)
	if len(allRules) == 0 {
		return firewallSnapshot{Exists: true}, nil
	}

	identity, expectedCount, err := decodeRuleMarker(allRules[0].UserData)
	if err != nil {
		return firewallSnapshot{Exists: true}, nil
	}
	expectedMarker := encodeRuleMarker(identity, expectedCount)
	for _, rule := range allRules {
		if !bytes.Equal(rule.UserData, expectedMarker) {
			return firewallSnapshot{Exists: true}, nil
		}
	}
	return firewallSnapshot{
		Exists:    true,
		Owned:     true,
		Valid:     expectedCount == len(allRules),
		Identity:  identity,
		RuleCount: len(allRules),
	}, nil
}

func isExpectedBaseChain(chain *nftables.Chain, hook *nftables.ChainHook) bool {
	return chain.Type == nftables.ChainTypeFilter &&
		chain.Hooknum != nil &&
		*chain.Hooknum == *hook &&
		chain.Priority != nil &&
		*chain.Priority == *nftables.ChainPriorityFilter &&
		chain.Policy != nil &&
		*chain.Policy == nftables.ChainPolicyDrop
}

func (backend *nftBackend) Replace(ctx context.Context, policy compiledPolicy) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	current, err := backend.Inspect(ctx)
	if err != nil {
		return err
	}
	if current.Exists && !current.Owned {
		return fmt.Errorf("refusing to replace table with invalid ownership metadata")
	}
	if current.Exists {
		switch {
		case current.Identity.Generation > policy.Identity.Generation:
			return fmt.Errorf("installed generation is newer")
		case current.Identity.Generation == policy.Identity.Generation &&
			current.Identity.Digest != policy.Identity.Digest:
			return fmt.Errorf("installed generation has a different digest")
		}
	}

	conn, err := nftables.New()
	if err != nil {
		return err
	}
	if current.Exists {
		conn.DelTable(&nftables.Table{
			Family: nftables.TableFamilyINet,
			Name:   nftTableName,
		})
	}
	table := conn.AddTable(&nftables.Table{
		Family: nftables.TableFamilyINet,
		Name:   nftTableName,
	})
	drop := nftables.ChainPolicyDrop
	input := conn.AddChain(&nftables.Chain{
		Name:     nftInputChain,
		Table:    table,
		Type:     nftables.ChainTypeFilter,
		Hooknum:  nftables.ChainHookInput,
		Priority: nftables.ChainPriorityFilter,
		Policy:   &drop,
	})
	output := conn.AddChain(&nftables.Chain{
		Name:     nftOutputChain,
		Table:    table,
		Type:     nftables.ChainTypeFilter,
		Hooknum:  nftables.ChainHookOutput,
		Priority: nftables.ChainPriorityFilter,
		Policy:   &drop,
	})
	marker := encodeRuleMarker(policy.Identity, len(policy.Rules))
	for _, rule := range policy.Rules {
		chain := input
		if rule.Direction == directionOutput {
			chain = output
		}
		expressions, err := expressionsForRule(rule)
		if err != nil {
			return err
		}
		conn.AddRule(&nftables.Rule{
			Table:    table,
			Chain:    chain,
			Exprs:    expressions,
			UserData: marker,
		})
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := conn.Flush(); err != nil {
		return err
	}
	return ctx.Err()
}

func (backend *nftBackend) Remove(ctx context.Context, expected policyIdentity) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	current, err := backend.Inspect(ctx)
	if err != nil {
		return err
	}
	if !current.Exists {
		return nil
	}
	if !current.Owned || current.Identity != expected {
		return fmt.Errorf("refusing to remove policy without exact ownership")
	}
	conn, err := nftables.New()
	if err != nil {
		return err
	}
	conn.DelTable(&nftables.Table{
		Family: nftables.TableFamilyINet,
		Name:   nftTableName,
	})
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := conn.Flush(); err != nil {
		return err
	}
	return ctx.Err()
}

func expressionsForRule(rule compiledRule) ([]expr.Any, error) {
	switch rule.Kind {
	case ruleLoopback:
		key := expr.MetaKeyIIFNAME
		if rule.Direction == directionOutput {
			key = expr.MetaKeyOIFNAME
		}
		return []expr.Any{
			&expr.Meta{Key: key, Register: 1},
			&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte("lo\x00")},
			&expr.Verdict{Kind: expr.VerdictAccept},
		}, nil
	case ruleEstablishedRelated:
		return []expr.Any{
			&expr.CT{Register: 1, Key: expr.CtKeySTATE},
			&expr.Bitwise{
				SourceRegister: 1,
				DestRegister:   1,
				Len:            4,
				Mask:           []byte{0x06, 0x00, 0x00, 0x00},
				Xor:            []byte{0x00, 0x00, 0x00, 0x00},
			},
			&expr.Cmp{
				Op:       expr.CmpOpNeq,
				Register: 1,
				Data:     []byte{0x00, 0x00, 0x00, 0x00},
			},
			&expr.Verdict{Kind: expr.VerdictAccept},
		}, nil
	case ruleNDP:
		return []expr.Any{
			&expr.Meta{Key: expr.MetaKeyNFPROTO, Register: 1},
			&expr.Cmp{
				Op:       expr.CmpOpEq,
				Register: 1,
				Data:     []byte{unix.NFPROTO_IPV6},
			},
			&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1},
			&expr.Cmp{
				Op:       expr.CmpOpEq,
				Register: 1,
				Data:     []byte{unix.IPPROTO_ICMPV6},
			},
			&expr.Payload{
				DestRegister: 1,
				Base:         expr.PayloadBaseTransportHeader,
				Offset:       0,
				Len:          1,
			},
			&expr.Cmp{
				Op:       expr.CmpOpEq,
				Register: 1,
				Data:     []byte{rule.ICMPv6Type},
			},
			&expr.Verdict{Kind: expr.VerdictAccept},
		}, nil
	case rulePolicy, ruleDNS:
		return expressionsForAddressRule(rule)
	default:
		return nil, fmt.Errorf("unsupported compiled rule kind %q", rule.Kind)
	}
}

func expressionsForAddressRule(rule compiledRule) ([]expr.Any, error) {
	if !rule.Prefix.IsValid() {
		return nil, fmt.Errorf("compiled rule has invalid prefix")
	}
	addressLength := uint32(4)
	addressOffset := uint32(12)
	nfProtocol := byte(unix.NFPROTO_IPV4)
	if rule.Family == familyIPv6 {
		addressLength = 16
		addressOffset = 8
		nfProtocol = byte(unix.NFPROTO_IPV6)
	}
	if rule.Direction == directionOutput {
		if rule.Family == familyIPv4 {
			addressOffset = 16
		} else {
			addressOffset = 24
		}
	}

	address := rule.Prefix.Masked().Addr().AsSlice()
	mask := net.CIDRMask(rule.Prefix.Bits(), int(addressLength*8))
	if address == nil || mask == nil {
		return nil, fmt.Errorf("compiled prefix cannot be represented")
	}
	protocol := byte(unix.IPPROTO_TCP)
	if rule.Protocol == protocolUDP {
		protocol = byte(unix.IPPROTO_UDP)
	}
	result := []expr.Any{
		&expr.Meta{Key: expr.MetaKeyNFPROTO, Register: 1},
		&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte{nfProtocol}},
		&expr.Payload{
			DestRegister: 1,
			Base:         expr.PayloadBaseNetworkHeader,
			Offset:       addressOffset,
			Len:          addressLength,
		},
		&expr.Bitwise{
			SourceRegister: 1,
			DestRegister:   1,
			Len:            addressLength,
			Mask:           mask,
			Xor:            make([]byte, addressLength),
		},
		&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: address},
		&expr.Meta{Key: expr.MetaKeyL4PROTO, Register: 1},
		&expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: []byte{protocol}},
	}
	if rule.DestinationPort != nil {
		port := make([]byte, 2)
		binary.BigEndian.PutUint16(port, *rule.DestinationPort)
		result = append(result, &expr.Payload{
			DestRegister: 1,
			Base:         expr.PayloadBaseTransportHeader,
			Offset:       2,
			Len:          2,
		}, &expr.Cmp{Op: expr.CmpOpEq, Register: 1, Data: port})
	}
	result = append(result, &expr.Verdict{Kind: expr.VerdictAccept})
	return result, nil
}

func encodeRuleMarker(identity policyIdentity, ruleCount int) []byte {
	return []byte(fmt.Sprintf(
		"%s%d:%s:%d",
		markerPrefix,
		identity.Generation,
		identity.Digest,
		ruleCount,
	))
}

func decodeRuleMarker(value []byte) (policyIdentity, int, error) {
	text := string(value)
	if !strings.HasPrefix(text, markerPrefix) {
		return policyIdentity{}, 0, fmt.Errorf("marker prefix is invalid")
	}
	parts := strings.Split(strings.TrimPrefix(text, markerPrefix), ":")
	if len(parts) != 3 {
		return policyIdentity{}, 0, fmt.Errorf("marker field count is invalid")
	}
	generation, err := strconv.ParseUint(parts[0], 10, 64)
	if err != nil || generation == 0 || strconv.FormatUint(generation, 10) != parts[0] {
		return policyIdentity{}, 0, fmt.Errorf("marker generation is invalid")
	}
	if !isCanonicalDigest(parts[1]) {
		return policyIdentity{}, 0, fmt.Errorf("marker digest is invalid")
	}
	ruleCount, err := strconv.Atoi(parts[2])
	if err != nil || ruleCount <= 0 || strconv.Itoa(ruleCount) != parts[2] {
		return policyIdentity{}, 0, fmt.Errorf("marker rule count is invalid")
	}
	return policyIdentity{
		Digest:     parts[1],
		Generation: generation,
	}, ruleCount, nil
}
