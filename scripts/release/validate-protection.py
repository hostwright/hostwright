#!/usr/bin/env python3
"""Verify existing release approval and the main deployment restriction."""
import json
import sys
policy = json.load(open(sys.argv[1]))
review = [rule for rule in policy.get('protection_rules', []) if rule.get('type') == 'required_reviewers']
if len(review) != 1 or not review[0].get('reviewers'):
    raise SystemExit('release environment requires the configured release reviewers')
branch = policy.get('deployment_branch_policy') or {}
if branch.get('protected_branches') is True:
    pass
elif branch.get('custom_branch_policies') is True:
    branches = json.load(open(sys.argv[2])).get('branch_policies', [])
    if not branches or any(p.get('name') != 'main' or p.get('type', 'branch') != 'branch' for p in branches):
        raise SystemExit('custom release deployment policy must permit only main')
else:
    raise SystemExit('release deployment branch restriction is missing')
