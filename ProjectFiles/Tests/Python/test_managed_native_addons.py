"""Digest-bound compatibility facts; synthetic binaries, no runtime launches."""
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed


def macho(architecture='arm64', minimum=(13, 5, 0)):
    header = bytearray(32)
    header[:4] = b'\xcf\xfa\xed\xfe'
    struct.pack_into('<I', header, 4, {'arm64':0x0100000C, 'x86_64':0x01000007}[architecture])
    command = b''
    if minimum is not None:
        encoded = (minimum[0] << 16) | (minimum[1] << 8) | minimum[2]
        command = struct.pack('<IIIIII', 0x32, 24, 1, encoded, 14 << 16, 0)
        struct.pack_into('<II', header, 16, 1, len(command))
    return bytes(header) + command


class NativeAddonFactsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.package = self.root / 'package'
        self.package.mkdir(mode=0o700)
        self.addon = self.package / 'fixture.node'
        self.addon.write_bytes(macho())
        self.manifest = dict(compatibility=dict(version=1, architectures=['arm64', 'x86_64'], minimum_macos='13.5'),
                             node_archives={'arm64':{}, 'x86_64':{}})
        self.facts = {}

    def scan(self, **kwargs):
        options = dict(process_arch='arm64', macos_version='14.0', facts=self.facts)
        options.update(kwargs)
        return managed.verify_native_addons(self.package, self.manifest, **options)

    def test_repeated_scan_and_serialized_seal_reuse_facts_but_still_hash_contents(self):
        with patch.object(managed, '_thin_mach_o_slice', wraps=managed._thin_mach_o_slice) as parse:
            self.assertEqual(self.scan(), 1)
            parse.assert_called_once()
        seal = dict(fingerprint='fixture', files=managed.seal(self.package), native_addons=self.facts)
        managed.atomic_json(self.package / 'integrity.json', seal)
        self.facts = json.loads((self.package / 'integrity.json').read_text())['native_addons']
        with patch.object(managed, '_thin_mach_o_slice') as parse, \
             patch.object(managed.hashlib, 'sha256', wraps=managed.hashlib.sha256) as hashed:
            self.assertEqual(self.scan(sealed_files=seal['files']), 1)
            parse.assert_not_called()
            hashed.assert_called_once()
        self.assertEqual(self.facts['digests'], {managed.digest(self.addon):[['arm64', [13, 5, 0]]]})
        self.assertTrue(managed.validate_install(self.package, 'fixture', force_full=True))

    def test_identical_bytes_share_parsing_and_removed_digests_are_not_retained(self):
        (self.package / 'duplicate.node').write_bytes(self.addon.read_bytes())
        with patch.object(managed, '_thin_mach_o_slice', wraps=managed._thin_mach_o_slice) as parse:
            self.assertEqual(self.scan(), 2)
            parse.assert_called_once()
        self.addon.unlink()
        (self.package / 'duplicate.node').unlink()
        self.assertEqual(self.scan(), 0)
        self.assertEqual(self.facts['digests'], {})

    def test_changed_digest_reparses_and_never_hides_incompatible_or_malformed_binary(self):
        self.scan()
        for contents, error in ((macho(minimum=(15, 0, 0)), 'newer macOS'),
                                (macho(minimum=None), 'minimum version'),
                                (macho()[:10], 'truncated')):
            with self.subTest(error=error):
                self.addon.write_bytes(contents)
                previous = copy.deepcopy(self.facts)
                with patch.object(managed, '_thin_mach_o_slice', wraps=managed._thin_mach_o_slice) as parse:
                    with self.assertRaisesRegex(managed.ManagedRuntimeError, error): self.scan()
                    parse.assert_called_once()
                self.assertEqual(self.facts, previous)

    def test_seal_mismatch_or_unsealed_file_fails_before_cache_reuse(self):
        self.scan()
        seal = managed.seal(self.package)
        self.addon.write_bytes(macho(minimum=(13, 6, 0)))
        # Even forged new facts cannot change the seal's expected digest.
        self.scan()
        with patch.object(managed, '_thin_mach_o_slice') as parse:
            for expected in (seal, {}):
                with self.subTest(expected=expected), self.assertRaisesRegex(managed.ManagedRuntimeError, 'seal'):
                    self.scan(sealed_files=expected)
            parse.assert_not_called()

    def test_sealed_addon_cannot_disappear_or_become_a_symlink_during_recovery(self):
        self.scan()
        seal = managed.seal(self.package)
        other = self.package / 'target'
        other.write_bytes(self.addon.read_bytes())
        self.addon.unlink()
        for linked in (False, True):
            with self.subTest(linked=linked):
                if linked: self.addon.symlink_to(other.name)
                with self.assertRaisesRegex(managed.ManagedRuntimeError, 'inventory'):
                    self.scan(sealed_files=seal)

    def test_universal_file_retains_all_slices_and_warm_scan_reads_no_headers(self):
        arm, x64 = macho('arm64'), macho('x86_64', (14, 0, 0))
        table = (struct.pack('>IIIII', 0x0100000C, 0, 48, len(arm), 0) +
                 struct.pack('>IIIII', 0x01000007, 0, 48 + len(arm), len(x64), 0))
        self.addon.write_bytes(struct.pack('>II', 0xcafebabe, 2) + table + arm + x64)
        self.assertEqual(self.scan(), 1)
        self.assertEqual(self.facts['digests'][managed.digest(self.addon)],
                         [['arm64', [13, 5, 0]], ['x86_64', [14, 0, 0]]])
        with patch.object(managed, '_read_exact') as headers:
            self.assertEqual(self.scan(macos_version='14.0.0'), 1)
            headers.assert_not_called()
        self.assertEqual(self.scan(process_arch='x86_64'), 1)

    def test_host_architecture_os_and_manifest_policy_changes_invalidate_parsed_facts(self):
        self.scan()
        baseline = copy.deepcopy(self.facts)
        for changes in ({'macos_version':'14.1'}, {'process_arch':'x86_64'}, {'macos_version':''}):
            with self.subTest(changes=changes):
                self.facts = copy.deepcopy(baseline)
                with patch.object(managed, '_thin_mach_o_slice', wraps=managed._thin_mach_o_slice) as parse:
                    self.scan(**changes)
                    parse.assert_called_once()
        self.facts = baseline
        self.manifest['compatibility']['minimum_macos'] = '13.0'
        with patch.object(managed, '_thin_mach_o_slice', wraps=managed._thin_mach_o_slice) as parse:
            self.scan()
            parse.assert_called_once()

    def test_legacy_outdated_and_malformed_facts_fall_back_to_parsing(self):
        self.scan()
        baseline = copy.deepcopy(self.facts)
        key = managed.digest(self.addon)
        cases = [{}, dict(baseline, version=999), dict(baseline, version=True),
                 dict(baseline, digests={'invalid':[]}), dict(baseline, digests={key:[['arm64', [13, True, 0]]]}),
                 dict(baseline, digests={key:[['unknown', [13, 5, 0]]]}),
                 dict(baseline, digests={key:[['arm64', [13, 5]]]}),
                 dict(baseline, digests={key:[['arm64', [13, 256, 0]]]}),
                 dict(baseline, digests={key:[['arm64', [13, 5, 0], 'extra']]}),
                 dict(baseline, digests={key:None}), dict(baseline, digests={key:[['arm64', [13, 5, 0]]]*17}),
                 dict(baseline, target=dict(baseline['target'], macos_version=[14, False, 0]))]
        for facts in cases:
            with self.subTest(facts=facts):
                self.facts = facts
                with patch.object(managed, '_thin_mach_o_slice', wraps=managed._thin_mach_o_slice) as parse:
                    self.assertEqual(self.scan(), 1)
                    parse.assert_called_once()
                self.assertEqual(self.facts, baseline)

    def test_foreign_and_non_macho_prebuild_facts_are_cached_without_claiming_compatibility(self):
        self.addon.write_bytes(macho('x86_64', (15, 0, 0)))
        (self.package / 'linux.node').write_bytes(b'\x7fELF' + b'\0'*40)
        self.assertEqual(self.scan(), 0)
        with patch.object(managed, '_thin_mach_o_slice') as parse:
            self.assertEqual(self.scan(), 0)
            parse.assert_not_called()
        with self.assertRaisesRegex(managed.ManagedRuntimeError, 'newer macOS'):
            self.scan(process_arch='x86_64')

    def test_replacement_between_hash_and_parse_is_rejected_without_caching(self):
        original = managed._thin_mach_o_slice
        def replace(*args):
            parsed = original(*args)
            path = self.addon
            replacement = path.with_suffix('.replacement')
            replacement.write_bytes(path.read_bytes())
            replacement.replace(path)
            return parsed
        with patch.object(managed, '_thin_mach_o_slice', side_effect=replace), \
             self.assertRaisesRegex(managed.ManagedRuntimeError, 'changed during'):
            self.scan()
        self.assertEqual(self.facts, {})

    def test_mutation_during_digest_read_is_rejected_even_on_a_warm_cache(self):
        self.scan()
        previous = copy.deepcopy(self.facts)
        original = managed.os.read
        changed = False
        def read(*args):
            nonlocal changed
            data = original(*args)
            if not changed:
                changed = True
                with self.addon.open('ab') as output: output.write(b'changed')
            return data
        with patch.object(managed.os, 'read', side_effect=read), \
             self.assertRaisesRegex(managed.ManagedRuntimeError, 'changed during'):
            self.scan()
        self.assertEqual(self.facts, previous)

    def test_bounds_hash_failure_and_timeout_do_not_commit_partial_facts(self):
        self.scan()
        previous = copy.deepcopy(self.facts)
        with self.assertRaisesRegex(managed.ManagedRuntimeError, 'bounded work limit'):
            self.scan(maximum_files=0)
        with patch.object(managed, '_inspect_mach_o_file', side_effect=managed.ManagedRuntimeError('changed during hashing')), \
             self.assertRaisesRegex(managed.ManagedRuntimeError, 'changed'):
            self.scan()
        with patch.object(managed.time, 'monotonic', side_effect=[0, 0, 31]), \
             self.assertRaisesRegex(managed.ManagedRuntimeError, 'bounded work limit'):
            self.scan()
        self.assertEqual(self.facts, previous)


if __name__ == '__main__':
    unittest.main()
