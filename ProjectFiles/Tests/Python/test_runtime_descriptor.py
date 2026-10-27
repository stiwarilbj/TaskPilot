"""One descriptor corpus for both readers. All paths and processes are fixtures."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'AgentRuntime'))
import managed_openclaw as managed
import runtime_descriptor_generated as contract


class RuntimeDescriptorTests(unittest.TestCase):
    def test_shared_corpus(self):
        corpus = json.loads((ROOT / 'Tests/Fixtures/runtime-descriptor-cases.json').read_text())
        for case in corpus['cases']:
            with self.subTest(case=case['name']), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                bind = lambda value: json.loads(json.dumps(value).replace('$ROOT', str(root)))
                value = bind(corpus['descriptor'])
                value.update(bind(case.get('set', {})))
                for field in case.get('remove', []): value.pop(field)
                for name, target in bind(case.get('links', {})).items():
                    link = root / name
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(target)
                raw_fields = case.get('raw_fields', {})
                validation_root = case.get('validation_root', root)
                raw = case.get('raw') or '{' + ','.join(
                    json.dumps(key) + ':' + (raw_fields[key] if key in raw_fields else json.dumps(item))
                    for key, item in value.items()) + '}'
                if 'error' in case:
                    with self.assertRaises(contract.DescriptorError) as raised:
                        contract.parse_descriptor(raw.encode(), validation_root)
                    self.assertEqual({'field': raised.exception.field, 'code': raised.exception.code}, case['error'])
                else:
                    self.assertEqual(contract.parse_descriptor(raw.encode(), validation_root), value)
                    path = root / 'runtime.json'; path.write_text(raw)
                    self.assertEqual(managed.load_descriptor(path), value)

    def test_fingerprint_and_stale_descriptor_artifacts_are_checked(self):
        script = ROOT / 'Scripts/generate-action-contract.py'
        spec = importlib.util.spec_from_file_location('descriptor_generator', script)
        generator = importlib.util.module_from_spec(spec); spec.loader.exec_module(generator)
        outputs = generator.runtime_descriptor_artifacts()
        self.assertEqual(outputs, generator.runtime_descriptor_artifacts())
        for path, expected in outputs.items(): self.assertEqual(path.read_text(), expected)
        swift = (ROOT / 'Sources/OrbitAgent/Agent/Runtime/ManagedRuntimeDescriptor.generated.swift').read_text()
        self.assertIn('static let fingerprint = "' + contract.CONTRACT_HASH + '"', swift)
        # A stale descriptor file is included in the existing non-writing check,
        # even when all action artifacts are current.
        descriptor_path = ROOT / 'AgentRuntime/runtime_descriptor_generated.py'
        original_read = Path.read_text
        def read(path, *args, **kwargs):
            if path == descriptor_path: return 'stale'
            return original_read(path, *args, **kwargs)
        with patch.object(Path, 'read_text', read), patch.object(sys, 'argv', [str(script), '--check']), patch('sys.stderr'):
            self.assertEqual(generator.main(), 1)
        baseline = generator.artifacts()[ROOT / 'AgentRuntime/action_contract_generated.py']
        with patch.object(generator, 'runtime_descriptor_artifacts', return_value={descriptor_path: 'changed rules'}):
            self.assertNotEqual(baseline, generator.artifacts()[ROOT / 'AgentRuntime/action_contract_generated.py'])

    def test_parser_bounds_and_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            for data, code in [(b' ' * (contract.DEFINITION['max_bytes'] + 1), 'too_large'),
                               ('{}'.encode('utf-16'), 'invalid_json'),
                               (b'\xef\xbb\xbf{}', 'invalid_json'),
                               (b'{"x":' + b'[' * 512 + b'0' + b']' * 512 + b'}', 'invalid_json')]:
                with self.assertRaises(contract.DescriptorError) as raised:
                    contract.parse_descriptor(data, directory)
                self.assertEqual((raised.exception.field, raised.exception.code), ('descriptor', code))

    def test_invalid_descriptor_never_changes_environment_or_launches(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.json'; path.write_text('{"version":true}')
            with patch.object(managed, 'bounded_run') as launch, patch.object(managed, 'managed_environment') as environment:
                with self.assertRaises(managed.ManagedRuntimeError): managed.activate_environment(path)
                launch.assert_not_called(); environment.assert_not_called()

    def test_private_directory_failure_keeps_its_classification(self):
        corpus = json.loads((ROOT / 'Tests/Fixtures/runtime-descriptor-cases.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            value = json.loads(json.dumps(corpus['descriptor']).replace('$ROOT', directory))
            (root / 'instances').symlink_to(root / 'elsewhere')
            path = root / 'runtime.json'; path.write_text(json.dumps(value))
            with self.assertRaises(managed.PrivateDirectoryError) as raised: managed.load_descriptor(path)
            self.assertEqual(raised.exception.code, 'private_directory_symlink')


if __name__ == '__main__': unittest.main()
