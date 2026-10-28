"""Synthetic tar namespaces; no network, installed runtime, or extraction."""
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed


def member(name, kind=tarfile.REGTYPE, target='', size=0):
    value = tarfile.TarInfo(name)
    value.type, value.linkname, value.size = kind, target, size
    return value


class ManagedArchivePathTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.stage = Path(temporary.name)
        self.limits = dict(version=1, max_members=20000, max_namespace_nodes=250000,
                           max_expanded_bytes=512 * 1024**2,
                           max_file_bytes=256 * 1024**2, max_depth=64)

    def validate(self, entries, limits=None):
        return managed.validate_node_archive_members(entries, self.stage, limits or self.limits)

    def test_duplicates_and_canonical_caseless_aliases_are_rejected_in_either_order(self):
        pairs = [
            ('fixture/bin/node', 'fixture/bin/node'),
            ('fixture/./bin//node', './fixture/bin/node'),
            ('fixture/bin/Node', 'fixture/bin/node'),
            ('fixture/caf\u00e9.txt', 'fixture/cafe\u0301.txt'),
            ('fixture/a\u0301\u0323.txt', 'fixture/a\u0323\u0301.txt'),
            ('fixture/Stra\u00dfe.txt', 'fixture/STRASSE.txt'),
            ('fixture/\u00c9.txt', 'fixture/e\u0301.txt'),
        ]
        for first, second in pairs:
            for paths in ((first, second), (second, first)):
                with self.subTest(paths=paths), self.assertRaisesRegex(managed.ManagedRuntimeError, 'path collision'):
                    self.validate([member(path) for path in paths])

    def test_implicit_parent_spellings_must_match_even_with_distinct_leaf_names(self):
        for first, second in [('fixture/Lib/a', 'fixture/lib/b'),
                              ('fixture/caf\u00e9/a', 'fixture/cafe\u0301/b')]:
            for paths in ((first, second), (second, first)):
                with self.subTest(paths=paths), self.assertRaisesRegex(managed.ManagedRuntimeError, 'path collision'):
                    self.validate([member(path) for path in paths])

    def test_explicit_parent_aliases_and_duplicate_directories_are_rejected(self):
        cases = [
            [member('fixture/dir', tarfile.DIRTYPE), member('fixture/dir/', tarfile.DIRTYPE)],
            [member('fixture/Dir', tarfile.DIRTYPE), member('fixture/dir/child')],
            [member('fixture/dir/child'), member('fixture/Dir', tarfile.DIRTYPE)],
            [member('.', tarfile.DIRTYPE), member('./', tarfile.DIRTYPE)],
        ]
        for entries in cases:
            with self.subTest(names=[entry.name for entry in entries]), self.assertRaisesRegex(managed.ManagedRuntimeError, 'path collision'):
                self.validate(entries)

    def test_file_or_link_cannot_also_be_a_parent_directory(self):
        for kind in (tarfile.REGTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE):
            for parent, child in [('fixture/item', 'fixture/item/child'),
                                  ('fixture/Item', 'fixture/item/child')]:
                entries = [member(parent, kind, 'target'), member(child)]
                for ordered in (entries, entries[::-1]):
                    with self.subTest(kind=kind, names=[entry.name for entry in ordered]), \
                            self.assertRaisesRegex(managed.ManagedRuntimeError, 'path collision'):
                        self.validate(ordered)
        with self.assertRaisesRegex(managed.ManagedRuntimeError, 'path collision'):
            self.validate([member('.')])

    def test_unambiguous_directories_can_be_declared_before_or_after_children(self):
        parents = [member('fixture', tarfile.DIRTYPE), member('./fixture/bin/', tarfile.DIRTYPE)]
        files = [member('fixture/bin/node'), member('fixture/lib/module.js')]
        for entries in (parents + files, files + parents):
            self.validate([member('.', tarfile.DIRTYPE)] + entries)

    def test_distinct_names_and_safe_leaf_links_are_preserved_without_renaming(self):
        entries = [
            member('./fixture/bin/node'),
            member('fixture/bin/npm', tarfile.SYMTYPE, '../lib/npm.js'),
            member('fixture/lib/npm.js'),
            member('fixture/lib/copy.js', tarfile.LNKTYPE, 'fixture/lib/npm.js'),
            member('fixture/caf\u00e9.txt'),
            member('fixture/\uff21.txt'), member('fixture/A.txt'),  # Canonical, not compatibility normalization.
            member('fixture/a/b.txt'), member('fixture/ab.txt'),
        ]
        names = [entry.name for entry in entries]
        self.validate(entries)
        self.assertEqual([entry.name for entry in entries], names)
        self.assertEqual(list(self.stage.iterdir()), [])

    def test_traversal_and_escaping_link_checks_still_reject_before_extraction(self):
        for name in ('../escape', '/absolute', 'fixture/../../escape', 'fixture/lib/../bin/node', 'fixture/\0name'):
            with self.subTest(name=name), self.assertRaisesRegex(managed.ManagedRuntimeError, 'Unsafe Node archive'):
                self.validate([member(name)])
        for kind, target in [(tarfile.SYMTYPE, '../../escape'), (tarfile.LNKTYPE, '../escape'),
                             (tarfile.SYMTYPE, '/outside')]:
            with self.subTest(kind=kind, target=target), self.assertRaisesRegex(managed.ManagedRuntimeError, 'Unsafe Node archive link'):
                self.validate([member('fixture/link', kind, target)])

    def test_archive_member_count_stops_stream_enumeration_at_the_first_excess(self):
        yielded = []
        def entries():
            for index in range(1000):
                yielded.append(index)
                yield member(f'fixture/file-{index}')
        limits = dict(self.limits, max_members=3)
        with self.assertRaisesRegex(managed.ManagedRuntimeError, 'member-count'):
            self.validate(entries(), limits)
        self.assertEqual(len(yielded), 4)

    def test_expanded_bytes_file_size_and_depth_are_checked_as_members_arrive(self):
        cases = [
            ([member('fixture/a', size=6), member('fixture/b', size=6)],
             dict(self.limits, max_expanded_bytes=10, max_file_bytes=8), 'total expanded-size'),
            ([member('fixture/large', size=7)], dict(self.limits, max_file_bytes=6), 'individual-file size'),
            ([member('fixture/one/two/file', size=1)], dict(self.limits, max_depth=3), 'path-depth'),
            ([member('fixture/negative', size=-1)], self.limits, 'invalid file size'),
        ]
        for entries, limits, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(managed.ManagedRuntimeError, message):
                self.validate(entries, limits)

    def test_namespace_entries_are_bounded_before_adding_more_collision_state(self):
        limits = dict(self.limits, max_namespace_nodes=5)
        # Root plus fixture/a/b consume four nodes. The second path adds one
        # node, then its leaf would exceed the cap and must be rejected.
        with self.assertRaisesRegex(managed.ManagedRuntimeError, 'namespace-entry'):
            self.validate([member('fixture/a/b'), member('another/file')], limits)

    def test_manifest_archive_limits_reject_unknown_or_unsafe_values(self):
        base = dict(version=1, max_members=20_000, max_namespace_nodes=250_000,
                    max_expanded_bytes=512 * 1024**2,
                    max_file_bytes=256 * 1024**2, max_depth=64)
        cases = [None, {}, {**base, 'extra': 1}, {**base, 'max_members': 50_001},
                 {**base, 'max_namespace_nodes': 500_001},
                 {**base, 'max_expanded_bytes': True}, {**base, 'max_file_bytes': 512 * 1024**2 + 1},
                 {**base, 'max_depth': 257}]
        for limits in cases:
            with self.subTest(limits=limits), self.assertRaises(managed.ManagedRuntimeError):
                managed.validate_node_archive_limits(limits)


if __name__ == '__main__': unittest.main()
