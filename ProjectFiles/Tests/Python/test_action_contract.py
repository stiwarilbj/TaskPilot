import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'AgentRuntime'))
import action_contract_generated as contract
import openclaw_runtime as runtime
import request_policy as policy
from response_validation import normalize_action, ResponseValidationError


class ActionContractTests(unittest.TestCase):
    def test_shared_corpus_and_defaults(self):
        corpus = json.loads((ROOT / 'Tests/Fixtures/action-contract-cases.json').read_text())
        for case in corpus['cases']:
            with self.subTest(case=case['name']):
                action = copy.deepcopy(case['action'])
                if 'repeat' in case:
                    item = case['repeat']; action[item['field']] = item['text'] * item['count']
                if 'special' in case: action[case['special']['field']] = float('inf')
                if 'error' in case:
                    with self.assertRaises(contract.ActionContractError) as raised: contract.validate_action(action)
                    self.assertEqual(str(raised.exception), case['error'])
                else:
                    self.assertEqual(contract.validate_action(action), case['normalized'])
                    self.assertEqual(contract.validate_action(action), contract.validate_action(contract.validate_action(action)))
        for kind, defaults in corpus['defaults'].items():
            for field, value in defaults.items(): self.assertEqual(contract.action_default(kind, field), value)

    def test_every_example_binds_to_an_observed_target(self):
        observation = {'applications': [{'pid': 42}], 'elements': [
            {'id': 'current:e1', 'pid': 42, 'role': 'AXTextField'}, {'id': 'current:e2', 'pid': 42, 'role': 'AXButton'}],
            'system_context': {'task_routes': [{'route_id': 'finder'}]}}
        for kind in contract.VALID_ACTIONS:
            with self.subTest(kind=kind):
                action = contract.action_example(kind)
                action = json.loads(json.dumps(action).replace('<current element_id>', 'current:e2').replace('<current field_id>', 'current:e1').replace('<supplied route_id>', 'finder'))
                if 'pid' in action: action['pid'] = 42
                normalize_action(action, observation)
                self.assertEqual(action['type'], kind)
        contract.action_example('key')['modifiers'] = ['invalid']
        self.assertNotIn('modifiers', contract.action_example('key'))

    def test_generation_is_deterministic_and_check_does_not_write(self):
        path = ROOT / 'Scripts/generate-action-contract.py'
        spec = importlib.util.spec_from_file_location('contract_generator', path)
        generator = importlib.util.module_from_spec(spec); spec.loader.exec_module(generator)
        self.assertEqual(generator.artifacts(), generator.artifacts())
        self.assertEqual(subprocess.run([sys.executable, str(path), '--check'], capture_output=True).returncode, 0)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'stale.py'; target.write_text('stale')
            before = target.stat().st_mtime_ns
            with mock.patch.object(generator, 'ROOT', target.parent), mock.patch.object(generator, 'artifacts', return_value={target: 'replacement'}), mock.patch.object(sys, 'argv', [str(path), '--check']), mock.patch.object(sys, 'stderr', io.StringIO()):
                self.assertEqual(generator.main(), 1)
            self.assertEqual(target.read_text(), 'stale'); self.assertEqual(target.stat().st_mtime_ns, before)

    def test_mismatched_or_missing_contract_blocks_startup(self):
        for hash_value, version in [('old', contract.CONTRACT_VERSION), (contract.CONTRACT_HASH, 0), (contract.CONTRACT_HASH, True), (contract.CONTRACT_HASH, '1'), (None, None)]:
            payload = {'kind': 'runtime_configuration', 'gemini_api_key': 'not-disclosed',
                       'action_contract_hash': hash_value, 'action_contract_version': version}
            with mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(payload))), mock.patch.object(runtime, 'ACPClient') as client, mock.patch.object(runtime, 'bridge_call') as bridge:
                with self.assertRaisesRegex(RuntimeError, 'contracts do not match') as raised: runtime.read_runtime_configuration()
                self.assertNotIn('not-disclosed', str(raised.exception)); client.assert_not_called(); bridge.assert_not_called()

    def test_contract_changes_invalidate_readiness_and_decision_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            first = policy.RuntimeState('credential', 'version', Path(directory))
            with mock.patch.object(policy, 'CONTRACT_HASH', 'changed'):
                self.assertNotEqual(first.identity, policy.RuntimeState('credential', 'version', Path(directory)).identity)
        self.assertIn('CONTRACT_HASH', runtime.routed_json_prompt.__code__.co_names)

    def test_dispatch_owners_and_key_aliases_are_complete(self):
        self.assertEqual(len(contract.VALID_ACTIONS), 16)
        self.assertEqual(contract.TRUSTED_NATIVE_ACTIONS, {'read_file', 'write_file', 'run_command'})
        self.assertEqual({k for k,v in contract.CONTRACT['actions'].items() if v['owner']=='runtime'}, {'none', 'wait'})
        self.assertEqual(set(contract.CONTRACT['fields']['key']['choices']), contract.KEYS)
        self.assertEqual(set(contract.CONTRACT['fields']['modifiers']['items']['choices']), set(contract.CONTRACT['modifier_aliases']))
