"""Private metadata reads never follow links, overread, or accept ambiguous JSON."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import private_runtime_metadata as metadata
import managed_openclaw as managed


class PrivateRuntimeMetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name); self.path = self.root / 'metadata.json'

    def test_shared_limits_and_json(self):
        fixture = json.loads((Path(__file__).resolve().parents[1] / 'Fixtures/private-runtime-metadata.json').read_text())
        for name, maximum in fixture['limits'].items():
            self.assertEqual(getattr(metadata, name.upper() + '_BYTES'), maximum)
        for case in fixture['cases']:
            with self.subTest(case=case['name']):
                self.path.write_text(case['json'], encoding='utf-8')
                if case['valid']:
                    self.assertEqual(metadata.parse(metadata.read_bytes(self.path)), json.loads(case['json']))
                else:
                    with self.assertRaises(ValueError): metadata.parse(metadata.read_bytes(self.path))
        for data in (b'{"x":"\xff"}', '{}'.encode('utf-16'), b'{"x":\x00}',
                     b'[' * 513 + b'0' + b']' * 513):
            with self.assertRaises(ValueError): metadata.parse(data)

    def test_exact_limit_short_reads_eintr_and_fixed_bounds(self):
        data = b'{"x":1}' + b' ' * 25
        self.path.write_bytes(data)
        original = os.read; allowances = []
        def short(fd, count):
            allowances.append(count)
            if len(allowances) == 1: raise InterruptedError()
            return original(fd, min(3, count))
        with patch.object(metadata.os, 'read', side_effect=short):
            self.assertEqual(metadata.read_bytes(self.path, len(data)), data)
        self.assertLessEqual(max(allowances), len(data))
        with patch.object(metadata.os, 'read') as reads:
            with self.assertRaises(metadata.MetadataError): metadata.read(self.path, len(data) - 1)
            reads.assert_not_called()

    def test_links_nonregular_wrong_owner_and_missing_fail_before_reads(self):
        original = self.root / 'original'; original.write_text('{}')
        with self.assertRaises(FileNotFoundError): metadata.read(self.path)
        for kind in ('symlink', 'hardlink', 'directory', 'fifo', 'owner'):
            with self.subTest(kind=kind):
                if kind == 'symlink': self.path.symlink_to(original)
                elif kind == 'hardlink': os.link(original, self.path)
                elif kind == 'directory': self.path.mkdir()
                elif kind == 'fifo': os.mkfifo(self.path)
                else: self.path.write_text('{}')
                with patch.object(metadata.os, 'read') as reads, \
                     patch.object(metadata.os, 'getuid', return_value=os.getuid() + (kind == 'owner')):
                    with self.assertRaises((OSError, ValueError)): metadata.read(self.path)
                    reads.assert_not_called()
                if kind == 'directory': self.path.rmdir()
                else: self.path.unlink()

    def test_mutation_or_replacement_during_read_rejected_and_descriptor_closed(self):
        original = os.read
        for change in ('replace', 'same_size', 'grow', 'overflow'):
            with self.subTest(change=change):
                self.path.write_bytes(b'{"x":1}')
                touched, descriptors, returned = [], [], []
                def race(fd, count):
                    data = original(fd, count)
                    returned.append(len(data))
                    descriptors.append(fd)
                    if not touched:
                        touched.append(True)
                        if change == 'replace':
                            replacement = self.root / 'new'; replacement.write_bytes(b'{"x":1}'); replacement.replace(self.path)
                        else: self.path.write_bytes({'same_size':b'{"x":2}', 'grow':b'{"x":1} ', 'overflow':b' ' * 100}[change])
                    return data
                with patch.object(metadata.os, 'read', side_effect=race):
                    with self.assertRaises(ValueError): metadata.read(self.path, 32)
                self.assertLessEqual(sum(returned), 32)
                for fd in set(descriptors):
                    with self.assertRaises(OSError): os.fstat(fd)

    def test_invalid_health_and_ack_cannot_authorize_recovery(self):
        self.path.write_text('{"state":"healthy","state":"stopped"}')
        with self.assertRaises(ValueError): metadata.read(self.path)
        self.path.write_text('[]')
        with self.assertRaises(ValueError): metadata.read(self.path)
        # Unknown owner metadata must not be mistaken for a drained Gateway.
        owner = self.root / 'gateway-root.json'
        for data in ('{"pid":1,"pid":2}', '[]', ' ' * (metadata.RECORD_BYTES + 1)):
            owner.write_text(data)
            with self.assertRaisesRegex(managed.ManagedRuntimeError, 'ownership metadata'):
                managed.require_offline(self.root)

    def test_descriptor_is_bounded_before_contract_parser(self):
        self.path.write_bytes(b' ' * (metadata.DESCRIPTOR_BYTES + 1))
        with patch.object(managed.descriptor_contract, 'parse_descriptor') as parser:
            with self.assertRaises(managed.ManagedRuntimeError): managed.load_descriptor(self.path)
            parser.assert_not_called()
        target = self.root / 'real'; target.write_text('{}')
        self.path.unlink(); self.path.symlink_to(target)
        with self.assertRaises(managed.PrivateDirectoryError): managed.load_descriptor(self.path)


if __name__ == '__main__': unittest.main()
