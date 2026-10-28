"""Synthetic tar namespaces; no network, installed runtime, or extraction."""
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed


def member(name, kind=tarfile.REGTYPE, target=''):
    value = tarfile.TarInfo(name)
    value.type, value.linkname = kind, target
    return value


class ManagedArchivePathTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.stage = Path(temporary.name)

    def validate(self, entries):
        managed.validate_node_archive_members(entries, self.stage)

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


if __name__ == '__main__': unittest.main()
