"""Offline staged CLI/interface drift; synthetic commands, no providers."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from Tests.Python import test_managed_provisioning as provisioning

managed = provisioning.managed


class ManagedCLIContractTests(unittest.TestCase):
    def setUp(self):
        self.fixture = provisioning.ProvisioningTests(methodName='runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.stage = self.fixture.base / 'probe'; self.stage.mkdir(mode=0o700)
        (self.stage / 'package').mkdir()
        (self.stage / 'package/package-lock.json').write_text('{}')
        self.manifest = self.fixture.manifest

    def probe_calls(self):
        return [call for call in self.fixture.calls if call[1].get('env', {}).get('OPENCLAW_PROFILE') == 'taskpilot-cli-probe']

    def test_probe_is_sealed_once_and_healthy_install_reuses_it_without_launch(self):
        with self.fixture.build():
            target, fingerprint, _ = managed.install(self.fixture.resources, self.fixture.root)
        self.assertEqual(len(self.probe_calls()), 7)
        record = managed.require_cli_capabilities(target, self.manifest)
        self.assertEqual(record, dict(version=1, package_lock_sha256=managed.digest(target / 'package/package-lock.json'),
                                     capabilities=list(managed.CLI_CAPABILITIES)))
        seal = json.loads((target / 'integrity.json').read_text())
        self.assertEqual(seal['files'][managed.CLI_CAPABILITY_FILE], managed.digest(target / managed.CLI_CAPABILITY_FILE))
        self.assertEqual((target / managed.CLI_CAPABILITY_FILE).stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(target.glob('.cli-probe-*')))
        for _, kwargs in self.probe_calls():
            self.assertLessEqual(kwargs['timeout'], 15)
            self.assertEqual(kwargs['maximum_output'], managed.CLI_PROBE_OUTPUT_BYTES)
            self.assertTrue(kwargs['pass_fds'])  # Existing orphan-helper lease.
        with self.fixture.build() as (downloads, runs):
            self.assertEqual(managed.install(self.fixture.resources, self.fixture.root)[0], target)
            downloads.assert_not_called(); runs.assert_not_called()
        (target / managed.CLI_CAPABILITY_FILE).write_text('{}')
        self.assertFalse(managed.validate_install(target, fingerprint))

    def test_interface_drift_fails_with_fixed_detail_and_no_retained_transcript(self):
        for defect in ('stdin', 'replace', 'json', 'duplicate', 'valid', 'invalid', 'auth', 'wrong-help', 'timeout', 'exception'):
            def run(argv, **kwargs):
                if defect == 'exception': raise RuntimeError('SECRET transcript')
                if defect == 'timeout': raise subprocess.TimeoutExpired(argv, kwargs['timeout'], output='SECRET transcript')
                if 'patch' in argv and defect == 'stdin': raise managed.ManagedRuntimeError('SECRET unsupported --stdin')
                if 'patch' in argv and '--replace-path' in argv and defect == 'replace': return ''
                if 'get' in argv and defect == 'json': return 'SECRET malformed output'
                if 'get' in argv and defect == 'duplicate': return '{"key":1,"key":2}'
                if 'validate' in argv and defect == 'valid': return '{"valid":false}'
                if kwargs.get('result') and defect == 'invalid': return 0, '{"valid":true}'
                if '--help' in argv and defect == 'auth': return 'Usage: openclaw models auth paste-api-key [options]\n'
                if '--help' in argv and defect == 'wrong-help': return 'Usage: other-command\n  --provider <id>\n  --profile-id <id>\n'
                return self.fixture.cli(argv, **kwargs)
            with self.subTest(defect=defect), self.assertRaises(managed.CLIContractError) as error:
                managed.probe_cli_contract(self.stage, self.manifest, run=run)
            self.assertNotIn('SECRET', str(error.exception))
            self.assertEqual(error.exception.code, 'managed_cli_contract')
            self.assertFalse((self.stage / managed.CLI_CAPABILITY_FILE).exists())
            self.assertFalse(list(self.stage.glob('.cli-probe-*')))

    def test_total_deadline_cannot_accumulate_per_probe_allowances(self):
        clock, calls = [0], []
        def run(argv, **kwargs):
            calls.append(argv)
            value = self.fixture.cli(argv, **kwargs)
            clock[0] += managed.CLI_PROBE_SECONDS
            return value
        with self.assertRaises(managed.CLIContractError):
            managed.probe_cli_contract(self.stage, self.manifest, run=run, now=lambda:clock[0])
        self.assertEqual(len(calls), 1)
        self.assertFalse((self.stage / managed.CLI_CAPABILITY_FILE).exists())

    def test_probe_environment_is_credential_free_and_private(self):
        inherited = {'OPENAI_API_KEY':'SECRET', 'GEMINI_API_KEY':'SECRET', 'NODE_OPTIONS':'SECRET', 'HOME':'/shared'}
        with patch.dict(os.environ, inherited):
            managed.probe_cli_contract(self.stage, self.manifest, run=self.fixture.cli)
        for _, kwargs in self.probe_calls():
            env = kwargs['env']
            self.assertFalse(any('SECRET' in value for value in env.values()))
            for key in ('HOME', 'TMPDIR', 'OPENCLAW_STATE_DIR', 'OPENCLAW_CONFIG_PATH'):
                self.assertTrue(Path(env[key]).is_relative_to(self.stage))
        record = json.loads((self.stage / managed.CLI_CAPABILITY_FILE).read_text())
        self.assertEqual(set(record), {'version', 'package_lock_sha256', 'capabilities'})

    def test_record_and_manifest_reject_missing_unknown_ambiguous_or_mismatched_facts(self):
        baseline = managed.probe_cli_contract(self.stage, self.manifest, run=self.fixture.cli)
        records = [dict(baseline, version=True), dict(baseline, capabilities=[]),
                   dict(baseline, capabilities=list(managed.CLI_CAPABILITIES) + ['unknown']),
                   dict(baseline, package_lock_sha256='0'*64)]
        for record in records:
            managed.atomic_json(self.stage / managed.CLI_CAPABILITY_FILE, record)
            with self.assertRaises(managed.CLIContractError): managed.require_cli_capabilities(self.stage, self.manifest)
        for raw in ('{"version":1,"version":1}', ' ' * 4097):
            (self.stage / managed.CLI_CAPABILITY_FILE).write_text(raw)
            with self.assertRaises(managed.CLIContractError): managed.require_cli_capabilities(self.stage, self.manifest)
        (self.stage / managed.CLI_CAPABILITY_FILE).unlink()
        with self.assertRaises(managed.CLIContractError): managed.require_cli_capabilities(self.stage, self.manifest)
        for contract in (None, {}, dict(self.manifest['cli_contract'], version=True),
                         dict(self.manifest['cli_contract'], required_capabilities=[])):
            with self.assertRaises(managed.CLIContractError): managed.required_cli_contract(dict(self.manifest, cli_contract=contract))
        managed.atomic_json(self.stage / managed.CLI_CAPABILITY_FILE, baseline)
        (self.stage / 'package/package-lock.json').write_text('{"changed":true}')
        with self.assertRaises(managed.CLIContractError): managed.require_cli_capabilities(self.stage, self.manifest)

    def test_failed_stage_keeps_working_installation_and_configuration_untouched(self):
        before = self.fixture.preserve_active()
        original = self.fixture.cli
        def incompatible(argv, **kwargs):
            if '--help' in argv: return ''
            return original(argv, **kwargs)
        with self.fixture.build() as (_, runs), self.assertRaises(managed.CLIContractError):
            runs.side_effect = incompatible
            managed.install(self.fixture.resources, self.fixture.root)
        self.fixture.assert_preserved(before)
        self.assertFalse((self.fixture.root / 'installations' / self.fixture.fingerprint).exists())
        self.assertFalse(list((self.fixture.root / 'installations').glob('.stage-*')))

    def test_interrupted_sealed_stage_resumes_without_reprobing(self):
        with self.fixture.build(), self.fixture.crash_at('sealed'), self.assertRaises(provisioning.Interrupted):
            managed.install(self.fixture.resources, self.fixture.root)
        self.assertEqual(len(self.probe_calls()), 7)
        with self.fixture.build() as (downloads, runs):
            target, _, _ = managed.install(self.fixture.resources, self.fixture.root)
            downloads.assert_not_called(); runs.assert_not_called()
        managed.require_cli_capabilities(target, self.manifest)

    def test_repairs_and_relocation_stop_before_configuration_commands(self):
        with self.fixture.build(), patch.object(managed, 'verify_settings'):
            descriptor = managed.ensure(self.fixture.resources, self.fixture.root)
        path = self.fixture.root / 'runtime.json'
        managed.mark_working(path)
        target = Path(descriptor['node']).parents[2]
        record = managed.require_cli_capabilities(target, self.manifest)
        managed.atomic_json(target / managed.CLI_CAPABILITY_FILE, dict(record, capabilities=[]))
        managed.atomic_json(target / 'integrity.json', dict(fingerprint=self.fixture.fingerprint, files=managed.seal(target)))
        config_before, descriptor_before = Path(descriptor['config']).read_bytes(), path.read_bytes()
        with patch.object(managed, 'specification', return_value=(self.manifest, self.fixture.fingerprint)), \
             patch.object(managed, 'bounded_run') as calls, patch.object(managed, 'verify_settings') as readback:
            for operation in (lambda:managed.ensure(self.fixture.resources, self.fixture.root),
                              lambda:managed.relocate(path), lambda:managed.rollback(path),
                              lambda:managed.repair(path, self.fixture.resources)):
                with self.assertRaises(managed.CLIContractError): operation()
            calls.assert_not_called(); readback.assert_not_called()
        self.assertEqual(Path(descriptor['config']).read_bytes(), config_before)
        self.assertEqual(path.read_bytes(), descriptor_before)
        self.assertFalse((self.fixture.root / 'repair-budget.json').exists())

    def test_package_lock_cannot_change_during_probes_or_disagree_with_manifest(self):
        def run(argv, **kwargs):
            result = self.fixture.cli(argv, **kwargs)
            if '--help' in argv: (self.stage / 'package/package-lock.json').write_text('{"changed":true}')
            return result
        with self.assertRaises(managed.CLIContractError): managed.probe_cli_contract(self.stage, self.manifest, run=run)
        self.assertFalse((self.stage / managed.CLI_CAPABILITY_FILE).exists())
        resources = self.fixture.base / 'bundled'; resources.mkdir()
        import shutil
        original = Path(__file__).resolve().parents[2] / 'Resources/OpenClaw/managed'
        for name in ('runtime-manifest.json', 'package.json', 'package-lock.json'):
            shutil.copyfile(original / name, resources / name)
        managed.specification(resources)
        lock = json.loads((resources / 'package-lock.json').read_text()); lock['name'] = 'different-packaging'
        (resources / 'package-lock.json').write_text(json.dumps(lock))
        with self.assertRaises(managed.CLIContractError): managed.specification(resources)

    def test_probe_output_is_bounded_even_when_command_exits_successfully(self):
        with self.assertRaisesRegex(managed.ManagedRuntimeError, 'output exceeded'):
            managed.bounded_run([sys.executable, '-c', 'print("x" * 20000)'],
                                timeout=5, maximum_output=managed.CLI_PROBE_OUTPUT_BYTES)


if __name__ == '__main__': unittest.main()
