import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('validator', Path(__file__).with_name('validate-run.py'))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class StageAttemptTests(unittest.TestCase):
    def setUp(self):
        self.commit = 'a' * 40
        self.run = dict(id=42, path='.github/workflows/trusted-release.yml', event='workflow_dispatch',
                        head_branch='main', head_sha=self.commit, head_repository=dict(full_name='hostwright/hostwright'),
                        status='completed', conclusion='success', run_attempt=2)
        def job(name, attempt, conclusion='success'):
            return dict(name=name, run_id=42, head_sha=self.commit, run_attempt=attempt,
                        status='completed', conclusion=conclusion, runner_id=71, runner_name='runner', runner_group_id=3,
                        created_at='2026-11-15T08:00:00Z', started_at='2026-11-15T08:00:01Z',
                        completed_at='2026-11-15T08:00:02Z', steps=[],
                        runner_group_name='hostwright-release',
                        labels=['self-hosted', 'macOS', 'ARM64', 'hostwright-release'] if name.startswith('Build,') else ['ubuntu-24.04'])
        self.rows = [job('Validate reviewed release inputs', 1), job('Build, sign, notarize, and verify', 1),
                     job('Attest the retained signed artifacts', 1, 'cancelled'),
                     job('Attest the retained signed artifacts', 2)]
        self.rows[1].update(started_at='2026-11-15T08:00:03Z', completed_at='2026-11-15T10:00:00Z')
        for row in self.rows[2:]:
            row.update(started_at='2026-11-15T10:01:00Z', completed_at='2026-11-15T10:02:00Z')

    def validate(self, run=None, rows=None, attempt='1'):
        rows = self.rows if rows is None else rows
        validator.validate(self.run if run is None else run, 'trusted-release.yml', attempt,
                           dict(total_count=len(rows), jobs=rows), self.commit)

    def test_attestation_retry_keeps_actual_successful_build_attempt(self):
        self.validate()

    def test_github_carried_forward_job_records_keep_original_execution(self):
        carried = [dict(row, run_attempt=2, created_at='2026-11-15T10:01:00Z') for row in self.rows[:2]]
        self.validate(rows=self.rows + carried)

    def test_changed_carried_forward_execution_is_rejected(self):
        for key, value in [('started_at', '2026-11-15T10:01:00Z'), ('runner_id', 72),
                           ('steps', [{'name': 'new build'}]), ('created_at', '2026-11-15T07:00:00Z')]:
            carried = dict(self.rows[1], run_attempt=2, created_at='2026-11-15T10:01:00Z')
            carried[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(rows=self.rows + [carried])

    def test_missing_original_cannot_be_replaced_by_carried_record(self):
        rows = [self.rows[0], dict(self.rows[1], run_attempt=2), *self.rows[2:]]
        with self.assertRaises(ValueError): self.validate(rows=rows)

    def test_single_successful_attempt_remains_supported(self):
        run = dict(self.run, run_attempt=1)
        self.validate(run, [self.rows[0], self.rows[1], dict(self.rows[2], conclusion='success')])

    def test_cancelled_overall_run_is_not_accepted(self):
        with self.assertRaises(ValueError): self.validate(dict(self.run, conclusion='cancelled'))

    def test_wrong_source_workflow_branch_or_repository_rejected(self):
        for key, value in [('head_sha', 'b' * 40), ('path', '.github/workflows/other.yml'),
                           ('head_branch', 'feature'), ('head_repository', {'full_name': 'other/repo'})]:
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate(dict(self.run, **{key: value}))

    def test_different_or_failed_effective_build_rejected(self):
        for change in [dict(conclusion='failure'), dict(run_attempt=2)]:
            rows = copy.deepcopy(self.rows)
            rows[1].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError): self.validate(rows=rows)

    def test_later_failed_build_cannot_reuse_older_success(self):
        rows = self.rows + [dict(self.rows[1], run_attempt=2, conclusion='failure')]
        with self.assertRaises(ValueError): self.validate(rows=rows)

    def test_missing_failed_or_earlier_attestation_rejected(self):
        for rows in [self.rows[:-1], self.rows[:-1] + [dict(self.rows[-1], conclusion='failure')]]:
            with self.assertRaises(ValueError): self.validate(rows=rows)

    def test_wrong_run_or_future_job_attempt_rejected(self):
        for key, value in [('run_id', 43), ('head_sha', 'b' * 40), ('run_attempt', 3)]:
            rows = copy.deepcopy(self.rows)
            rows[-1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate(rows=rows)

    def test_duplicate_missing_and_unknown_jobs_rejected(self):
        for rows in [self.rows + [self.rows[-1]], self.rows + [self.rows[2]], self.rows[1:], self.rows + [dict(self.rows[0], name='Other')]]:
            with self.assertRaises(ValueError): self.validate(rows=rows)

    def test_wrong_runner_group_or_hosted_build_rejected(self):
        for key, value in [('runner_group_id', 1), ('runner_group_name', 'default'), ('labels', ['ubuntu-24.04'])]:
            rows = copy.deepcopy(self.rows)
            rows[1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate(rows=rows)

    def test_self_hosted_attestation_rejected(self):
        rows = copy.deepcopy(self.rows)
        rows[-1]['labels'] = ['self-hosted']
        with self.assertRaises(ValueError): self.validate(rows=rows)

    def test_truncated_history_rejected(self):
        with self.assertRaises(ValueError):
            validator.validate(self.run, 'trusted-release.yml', '1', dict(total_count=101, jobs=self.rows), self.commit)

    def test_legacy_exact_attempt_check_unchanged_without_job_proof(self):
        with self.assertRaises(ValueError): validator.validate(self.run, 'trusted-release.yml', '1')
        validator.validate(self.run, 'trusted-release.yml', '2')


if __name__ == '__main__':
    unittest.main()
