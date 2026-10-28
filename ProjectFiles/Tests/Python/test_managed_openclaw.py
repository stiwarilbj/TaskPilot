"""Offline installation/descriptor/recovery safety. No real downloads/providers."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'AgentRuntime'))
import managed_openclaw as managed
from task_execution import ExecutionMachine, ExecutionStateError, Phase

class ManagedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.path=self.root/'runtime.json'
    def descriptor(self):
        state = self.root / 'private'; state.mkdir(mode=0o700, exist_ok=True)
        workspace = state / 'workspace'; workspace.mkdir(mode=0o700, exist_ok=True)
        installation = self.root / 'installations/fixture'
        (self.root / 'installations').mkdir(mode=0o700, exist_ok=True)
        installation.mkdir(mode=0o700, exist_ok=True)
        executable = state / 'openclaw'; executable.write_text('fixture')
        return dict(openclaw_version='fixture',node_version='fixture',version=1,instance_id='128bdc78-d592-43a3-b4e1-b6fe3a0e57cd',port=24200,
            endpoint='ws://127.0.0.1:24200',installation_fingerprint='fixture',configuration_fingerprint='config',
            executable=str(executable), node=str(installation / 'node/bin/node'), entry=str(installation / 'entry'),
            state=str(state), workspace=str(workspace), config=str(state/'config'), token_file=str(state/'token'))
    def test_managed_environment_matches_shared_policy_and_contains_no_value_diagnostics(self):
        fixtures=Path(__file__).resolve().parents[1]/'Fixtures/managed-environment-cases.json'
        for case in json.loads(fixtures.read_text()):
            with self.subTest(case=case['name']):
                env,diagnostic=managed.managed_environment(case['inherited'],'/private/node/bin/node')
                self.assertEqual(env,case['expected'])
                self.assertEqual(diagnostic,{'version':1,'mismatch_code':case['code']})
                repeated,clean=managed.managed_environment(env,'/private/node/bin/node')
                self.assertEqual(repeated,env);self.assertEqual(clean['mismatch_code'],0)
                self.assertNotIn('secret',json.dumps(diagnostic))

    def test_wrapper_uses_pinned_node_path_and_utf8_locale(self):
        node=self.root/'node/bin/node';node.parent.mkdir(parents=True)
        # Synthetic executable reports only assertions; no real OpenClaw or provider.
        node.write_text('#!/bin/sh\ntest "$LC_ALL" = en_US.UTF-8 && test "$LANG" = en_US.UTF-8 && test -z "$NODE_OPTIONS" && test "${PATH%%:*}" = "${0%/*}"\n')
        node.chmod(0o700)
        wrapper=self.root/'wrapper';wrapper.write_text(managed.wrapper_script(self.root,self.root/'config',node,self.root/'entry'))
        wrapper.chmod(0o700)
        result=managed.bounded_run([str(wrapper)],env={'PATH':'/bad','NODE_OPTIONS':'--import secret','LANG':'custom'},result=True)
        self.assertEqual(result[0],0)

    def test_activation_replaces_ambient_environment_and_keeps_only_category_diagnostics(self):
        value=self.descriptor();managed.atomic_json(self.path,value)
        with patch.dict(os.environ,{'NODE_OPTIONS':'--import secret','LC_ALL':'custom','PATH':'/shell',
                                    'HTTPS_PROXY':'http://user:secret@proxy'},clear=True):
            managed.activate_environment(self.path)
            self.assertNotIn('NODE_OPTIONS',os.environ)
            self.assertEqual(os.environ['LC_ALL'],'en_US.UTF-8')
            self.assertEqual(os.environ['HTTPS_PROXY'],'http://user:secret@proxy')
            record=self.path.parent/'environment-diagnostics.json'
            self.assertEqual(json.loads(record.read_text()),{'version':1,'mismatch_code':15})
            self.assertEqual(record.stat().st_mode & 0o777,0o600)
        with patch.dict(os.environ,{'NODE_OPTIONS':'secret'},clear=True),patch.object(managed,'atomic_json',side_effect=OSError):
            self.assertEqual(managed.activate_environment(self.path),value)
            self.assertNotIn('NODE_OPTIONS',os.environ)

    def test_descriptor_rejects_shared_paths_remote_endpoints_bad_types_and_versions(self):
        value=self.descriptor()
        for changes in ({'node':'/usr/bin/node'},{'state':str(Path.home()/'.openclaw')},
                        {'endpoint':'ws://localhost:24200'},{'port':True},{'version':2},{'instance_id':'not-a-uuid'}):
            managed.atomic_json(self.path,{**value,**changes})
            with self.subTest(changes=changes),self.assertRaises(managed.ManagedRuntimeError):managed.load_descriptor(self.path)
        managed.atomic_json(self.path,value);self.assertEqual(managed.load_descriptor(self.path),value)
    def test_clean_environment_cannot_inherit_shared_state_provider_key_or_node_injection(self):
        value=self.descriptor();managed.atomic_json(self.path,value)
        with patch.dict(os.environ,{'OPENCLAW_STATE_DIR':'/shared','OPENCLAW_GATEWAY_TOKEN':'secret',
                                    'NODE_OPTIONS':'--import attacker','GEMINI_API_KEY':'secret'},clear=True):
            clean=managed.isolated_environment()
            self.assertNotIn('NODE_OPTIONS',clean);self.assertNotIn('GEMINI_API_KEY',clean)
            managed.activate_environment(self.path)
            self.assertEqual(os.environ['OPENCLAW_STATE_DIR'],value['state'])
            self.assertNotIn('OPENCLAW_GATEWAY_TOKEN',os.environ)
            self.assertTrue(os.environ['TASKPILOT_MANAGED_FINGERPRINT'].endswith(':config'))
    def test_tampered_installed_code_or_escaping_symlink_fails_integrity(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_text('good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin'))
        f.write_text('bad');self.assertFalse(managed.validate_install(install,'pin'))
        f.unlink();self.assertFalse(managed.validate_install(install,'pin'))
        outside=self.root/'outside';outside.write_text('good');f.symlink_to(outside)
        self.assertFalse(managed.validate_install(install,'pin'))

    def test_full_audits_hint_the_checked_descriptor_before_reading(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        actual_read=os.read; hinted=set(); reads=[]
        def hint(fd, command, value):
            self.assertEqual((command,value),(48,1))
            self.assertEqual(os.fstat(fd).st_ino,f.stat().st_ino)
            hinted.add(fd)
        def read(fd,count):
            # The bounded metadata reader also uses os.read; the no-cache hint
            # applies only to sealed payload content, never its small manifest.
            if os.fstat(fd).st_ino == f.stat().st_ino:
                self.assertIn(fd,hinted)
                reads.append(fd)
            return actual_read(fd,count)
        with patch.object(managed.platform,'system',return_value='Darwin'), \
                patch.object(managed.fcntl,'F_NOCACHE',48,create=True), \
                patch.object(managed.fcntl,'fcntl',side_effect=hint) as hints, \
                patch.object(managed.os,'read',side_effect=read):
            for now,force in ((100,False),(200,True),
                    (200+managed.FULL_INTEGRITY_AUDIT_SECONDS*1_000_000_000,False)):
                hinted.clear(); reads.clear(); hints.reset_mock(); stats={}
                self.assertTrue(managed.validate_install(install,'pin',force_full=force,
                    now_monotonic_ns=now,stats=stats))
                self.assertEqual(stats['audit_mode'],'full')
                hints.assert_called_once()
                self.assertTrue(reads)
                with self.assertRaises(OSError):os.fstat(reads[0])

    def test_incremental_rehash_and_sealing_do_not_request_uncached_reads(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        with patch.object(managed,'_hint_uncached_audit_read') as hint:
            managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
            hint.assert_not_called()
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
            hint.assert_called_once();hint.reset_mock()
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200))
            before=f.stat();os.utime(f,ns=(before.st_atime_ns,before.st_mtime_ns+1_000_000))
            stats={}
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
            self.assertEqual(stats['audit_mode'],'incremental')
            self.assertEqual(stats['files_hashed'],1)
            hint.assert_not_called()

    def test_unavailable_or_rejected_cache_hint_never_changes_digest_validation(self):
        import errno
        for system,command,error in (
                ('Linux',48,None),('Darwin',None,None),
                ('Darwin',48,errno.ENOTSUP),('Darwin',48,errno.EINVAL)):
            with self.subTest(system=system,command=command,error=error):
                install=self.root/str(len(list(self.root.iterdir())));install.mkdir(mode=0o700)
                f=install/'code';f.write_bytes(b'good')
                managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
                with patch.object(managed.platform,'system',return_value=system), \
                        patch.object(managed.fcntl,'F_NOCACHE',command,create=True), \
                        patch.object(managed.fcntl,'fcntl',side_effect=OSError(error or 0,'hint rejected')) as hint:
                    self.assertTrue(managed.validate_install(install,'pin',force_full=True,now_monotonic_ns=100))
                    f.write_bytes(b'evil')
                    self.assertFalse(managed.validate_install(install,'pin',force_full=True,now_monotonic_ns=200))
                    self.assertEqual(hint.call_count,2 if system=='Darwin' and command is not None else 0)
                caches=list((install.parent/'.integrity-cache').glob('*.json'))
                matching=[json.loads(p.read_text()) for p in caches
                          if json.loads(p.read_text())['directory']['path']==str(install.resolve())]
                self.assertEqual(len(matching),1)
                self.assertEqual(matching[0]['last_full_audit_monotonic_ns'],100)

    def test_cache_write_failure_full_fallback_also_requests_uncached_reads(self):
        install=self.root/'install';install.mkdir(mode=0o700)
        for name in ('first','second'):(install/name).write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        f=install/'first';before=f.stat();os.utime(f,ns=(before.st_atime_ns,before.st_mtime_ns+1_000_000))
        with patch.object(managed,'_write_integrity_cache',side_effect=OSError('unwritable')), \
                patch.object(managed,'_hint_uncached_audit_read') as hint:
            stats={}
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
            self.assertEqual(stats['audit_mode'],'full')
            self.assertEqual(stats['files_hashed'],3)
            self.assertEqual(hint.call_count,2)

    def test_notification_forced_audit_ignores_digest_reuse_but_retains_identity_baseline(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        metadata=managed._regular_file_metadata(f.stat())
        f.write_bytes(b'evil')
        # A notification must force actual reads even if cached metadata looks unchanged.
        with patch.object(managed,'_regular_file_metadata',return_value=metadata):
            stats={}
            self.assertFalse(managed.validate_install(install,'pin',force_full=True,
                now_monotonic_ns=200,stats=stats))
            self.assertEqual(stats['audit_mode'],'full')
            self.assertEqual(stats['files_hashed'],1)
            self.assertEqual(stats['cache_hits'],0)
        cache=json.loads(next((install.parent/'.integrity-cache').glob('*.json')).read_text())
        self.assertEqual(cache['last_full_audit_monotonic_ns'],100)

    def test_gap_forced_audit_stays_pending_across_invocations_until_full_success(self):
        install=self.root/'install';install.mkdir(mode=0o700)
        for name in ('first','second'):(install/name).write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        cache_file=next((install.parent/'.integrity-cache').glob('*.json'))
        with patch.object(managed,'_hash_installation_file',return_value=(None,None)):
            self.assertFalse(managed.validate_install(install,'pin',force_full=True,now_monotonic_ns=200))
        pending=json.loads(cache_file.read_text())
        self.assertTrue(pending['full_audit_required'])
        self.assertEqual(pending['last_full_audit_monotonic_ns'],100)
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
        self.assertEqual((stats['audit_mode'],stats['files_hashed'],stats['cache_hits']),('full',2,0))
        completed=json.loads(cache_file.read_text())
        self.assertFalse(completed['full_audit_required'])
        self.assertEqual(completed['last_full_audit_monotonic_ns'],300)
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=400,stats=stats))
        self.assertEqual((stats['audit_mode'],stats['files_hashed'],stats['cache_hits']),('incremental',0,2))

    def test_gap_marker_write_failure_discards_stale_cache_and_failed_audit_stays_full(self):
        install=self.root/'install';install.mkdir(mode=0o700);(install/'code').write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        with patch.object(managed,'_write_integrity_cache',side_effect=OSError('disk full')), \
                patch.object(managed,'_hash_installation_file',return_value=(None,None)):
            self.assertFalse(managed.validate_install(install,'pin',force_full=True,now_monotonic_ns=200))
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        self.assertEqual(stats['cache_hits'],0)

    def test_legacy_gap_marker_is_optional_but_malformed_marker_forces_full_pass(self):
        install=self.root/'install';install.mkdir(mode=0o700);(install/'code').write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        cache_file=next((install.parent/'.integrity-cache').glob('*.json'))
        value=json.loads(cache_file.read_text());value.pop('full_audit_required');managed.atomic_json(cache_file,value)
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
        self.assertEqual(stats['audit_mode'],'incremental')
        value=json.loads(cache_file.read_text());value['full_audit_required']=1;managed.atomic_json(cache_file,value)
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')

    def test_integrity_cache_skips_unchanged_content_reads_and_rehashes_changed_metadata(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        stats={}
        with patch.object(managed,'_hash_installation_file',wraps=managed._hash_installation_file) as hashing:
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100,stats=stats))
            self.assertEqual(stats['audit_mode'],'full')
            self.assertEqual(stats['files_hashed'],1)
            hashing.reset_mock()
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
            self.assertEqual(stats['audit_mode'],'incremental')
            self.assertEqual(stats['cache_hits'],1)
            self.assertEqual(stats['files_hashed'],0)
            hashing.assert_not_called()
            f.write_bytes(b'evil')  # Same size; ctime/inode metadata cannot be restored.
            self.assertFalse(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
            self.assertEqual(stats['files_hashed'],1)

    def test_integrity_cache_rejects_replaced_files_even_when_contents_match(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        replacement=install/'replacement';replacement.write_bytes(b'good')
        os.replace(replacement,f)
        stats={}
        self.assertFalse(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
        self.assertEqual(stats['files_hashed'],1)
        self.assertEqual(stats['cache_hits'],0)

        periodic=self.root/'periodic-install';periodic.mkdir(mode=0o700);periodic_file=periodic/'code';periodic_file.write_bytes(b'good')
        managed.atomic_json(periodic/'integrity.json',{'fingerprint':'pin','files':managed.seal(periodic)})
        base=100
        self.assertTrue(managed.validate_install(periodic,'pin',now_monotonic_ns=base))
        replacement=periodic/'replacement';replacement.write_bytes(b'good');os.replace(replacement,periodic_file)
        stats={}
        self.assertFalse(managed.validate_install(periodic,'pin',now_monotonic_ns=base+3600*1_000_000_000,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        self.assertEqual(stats['files_hashed'],1)

    def test_integrity_cache_rehashes_permission_and_restored_mtime_changes(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        before=f.stat();os.chmod(f,0o600)
        os.utime(f,ns=(before.st_atime_ns,before.st_mtime_ns))
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
        self.assertEqual(stats['files_hashed'],1)
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
        self.assertEqual(stats['files_hashed'],0)

    def test_integrity_manifest_change_forces_full_hash_and_never_changes_expected_digest(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        manifest=install/'integrity.json';record=json.loads(manifest.read_text())
        manifest.write_text(json.dumps(record,indent=2))
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        self.assertEqual(stats['files_hashed'],1)
        record['files']['code']='0'*64
        manifest.write_text(json.dumps(record))
        self.assertFalse(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')

    def test_integrity_cache_forces_periodic_full_audit_and_incremental_checks_do_not_reset_it(self):
        install=self.root/'install';install.mkdir(mode=0o700)
        for name in ('first','second'):(install/name).write_bytes(name.encode())
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        stats={};base=10_000_000_000
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=base,stats=stats))
        self.assertEqual(stats['files_hashed'],2)
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=base-1,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')  # Monotonic reset means a reboot or bad clock.
        for offset in (60,600,1800,3599):
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=base+offset*1_000_000_000,stats=stats))
            self.assertEqual(stats['audit_mode'],'incremental')
            self.assertEqual(stats['files_hashed'],0)
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=base+3600*1_000_000_000,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        self.assertEqual(stats['files_hashed'],2)

    def test_integrity_cache_rejects_future_timestamp_and_outdated_schema(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        cache_file=next((install.parent/'.integrity-cache').glob('*.json'))
        for change in (
                lambda value: value.update(last_full_audit_monotonic_ns=10_000),
                lambda value: value.update(version=0),
                lambda value: value.update(version=True)):
            cache=json.loads(cache_file.read_text());change(cache);managed.atomic_json(cache_file,cache)
            stats={}
            self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
            self.assertEqual(stats['audit_mode'],'full')
            self.assertEqual(stats['files_hashed'],1)

        malformed={
            'version':managed.INTEGRITY_CACHE_VERSION,
            'fingerprint':'pin',
            'manifest_digest':'manifest',
            'directory':{'path':'/fixture','device':True,'inode':1},
            'last_full_audit_monotonic_ns':0,
            'files':{},
        }
        self.assertFalse(managed._valid_integrity_cache(
            malformed,'pin','manifest',{'path':'/fixture','device':1,'inode':1},{}))

    def test_non_object_integrity_manifest_fails_as_unsealed_not_an_exception(self):
        install=self.root/'install';install.mkdir(mode=0o700);(install/'code').write_bytes(b'good')
        (install/'integrity.json').write_text('[]')
        self.assertFalse(managed.validate_install(install,'pin'))

    def test_cached_integrity_rejects_symlinked_parent_components_even_when_in_root(self):
        install=self.root/'install';install.mkdir(mode=0o700)
        actual=install/'real';actual.mkdir(mode=0o700);(actual/'code').write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        (install/'real').rename(install/'moved')
        (install/'real').symlink_to(install/'moved',target_is_directory=True)
        stats={}
        self.assertFalse(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))

    def test_integrity_cache_invalidity_lock_contention_and_cache_write_errors_fall_back_to_hashing(self):
        import fcntl
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        cache_files=list((install.parent/'.integrity-cache').glob('*.json'))
        self.assertEqual(len(cache_files),1)
        cache_files[0].write_text('{damaged')
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=200,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        lock_file=next((install.parent/'.integrity-cache').glob('*.lock'))
        lock_fd=os.open(lock_file,os.O_RDWR)
        fcntl.flock(lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        try:
            with patch.object(managed,'_hash_installation_file',wraps=managed._hash_installation_file) as hashing:
                self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=300,stats=stats))
                self.assertEqual(stats['audit_mode'],'full')
                hashing.assert_called_once()
        finally:
            fcntl.flock(lock_fd,fcntl.LOCK_UN);os.close(lock_fd)
        with patch.object(managed,'_write_integrity_cache',side_effect=OSError('read-only')):
            self.assertTrue(managed.validate_install(install,'pin',force_full=True,now_monotonic_ns=400))

        fallback=self.root/'write-failure-install';fallback.mkdir(mode=0o700)
        first=fallback/'first';first.write_bytes(b'good');second=fallback/'second';second.write_bytes(b'also good')
        managed.atomic_json(fallback/'integrity.json',{'fingerprint':'pin','files':managed.seal(fallback)})
        self.assertTrue(managed.validate_install(fallback,'pin',now_monotonic_ns=500))
        first.chmod(0o600)
        stats={}
        with patch.object(managed,'_write_integrity_cache',side_effect=OSError('read-only')):
            with patch.object(managed,'_hash_installation_file',wraps=managed._hash_installation_file) as hashing:
                self.assertTrue(managed.validate_install(fallback,'pin',now_monotonic_ns=600,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        self.assertEqual(stats['files_hashed'],3)  # Changed file, then an uncached full pass.
        self.assertEqual(stats['cache_hits'],1)
        self.assertEqual(hashing.call_count,3)

    def test_integrity_cache_symlink_directory_falls_back_to_uncached_hashing(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        outside=self.root/'outside-cache';outside.mkdir(mode=0o700)
        (install.parent/'.integrity-cache').symlink_to(outside, target_is_directory=True)
        stats={}
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100,stats=stats))
        self.assertEqual(stats['audit_mode'],'full')
        self.assertEqual(stats['files_hashed'],1)
        self.assertEqual(list(outside.iterdir()),[])

    def test_integrity_hash_rejects_a_file_modified_while_reading(self):
        install=self.root/'install';install.mkdir(mode=0o700);f=install/'code';f.write_bytes(b'good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin',now_monotonic_ns=100))
        actual_read=os.read;changed=False
        def mutate_during_read(fd,count):
            nonlocal changed
            data=actual_read(fd,count)
            if not changed and os.fstat(fd).st_ino == f.stat().st_ino:
                changed=True;f.write_bytes(b'evil')
            return data
        with patch.object(managed.os,'read',side_effect=mutate_during_read):
            self.assertFalse(managed.validate_install(install,'pin',force_full=True,now_monotonic_ns=200))
        cache=json.loads(next((install.parent/'.integrity-cache').glob('*.json')).read_text())
        self.assertEqual(cache['last_full_audit_monotonic_ns'],100)
    def test_manifest_and_lock_match_every_official_dependency(self):
        resources=Path(__file__).resolve().parents[2]/'Resources/OpenClaw/managed'
        manifest,fingerprint=managed.specification(resources)
        self.assertEqual(manifest['node_version'],'24.22.1');self.assertEqual(manifest['openclaw_version'],'2026.9.5')
        self.assertEqual(len(fingerprint),64)
        for name in ('runtime-manifest.json','package.json','package-lock.json'):
            (self.root/name).write_bytes((resources/name).read_bytes())
        lock=json.loads((self.root/'package-lock.json').read_text());lock['packages']['node_modules/openclaw']['integrity']='fake'
        (self.root/'package-lock.json').write_text(json.dumps(lock))
        with self.assertRaises(managed.ManagedRuntimeError):managed.specification(self.root)
    def test_checksum_failure_cannot_activate_download(self):
        import io
        destination=self.root/'archive'
        with patch('urllib.request.urlopen',return_value=io.BytesIO(b'tampered')):
            with self.assertRaisesRegex(managed.ManagedRuntimeError,'checksum'):
                managed.download('https://nodejs.org/fixture',destination,'0'*64)
        self.assertFalse(destination.exists());self.assertFalse(self.path.exists())
    def test_failed_install_leaves_active_descriptor_and_no_staging_directory(self):
        resources=Path(__file__).resolve().parents[2]/'Resources/OpenClaw/managed'
        managed.atomic_json(self.path,{'original':True})
        with patch.object(managed,'download',side_effect=OSError('offline')):
            with self.assertRaises(OSError):managed.ensure(resources,self.root)
        self.assertEqual(json.loads(self.path.read_text()),{'original':True})
        self.assertFalse(list((self.root/'installations').glob('.stage-*')))
    def test_port_collision_chooses_another_endpoint_without_signalling(self):
        import socket
        blocker=socket.socket();blocker.bind(('127.0.0.1',22000));self.addCleanup(blocker.close)
        with patch.object(managed.secrets,'randbelow',side_effect=[0,1]):
            self.assertEqual(managed.private_port(),22128)
    def fake_install(self, pin):
        target = self.root/'installations'/pin
        for name in ('node/bin/node','package/node_modules/openclaw/openclaw.mjs'):
            path=target/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
        target.chmod(0o700)
        (self.root/'installations').chmod(0o700)
        lock = target / 'package/package-lock.json'; lock.write_text('{}')
        contract = dict(version=1, required_capabilities=list(managed.CLI_CAPABILITIES), package_lock_sha256=managed.digest(lock))
        managed.atomic_json(target / managed.CLI_CAPABILITY_FILE,
                            dict(version=1, package_lock_sha256=contract['package_lock_sha256'], capabilities=list(managed.CLI_CAPABILITIES)))
        managed.atomic_json(target/'integrity.json',{'fingerprint':pin,'files':managed.seal(target)})
        return target,pin,{'openclaw_version':'2026.9.5','node_version':'24.22.1', 'cli_contract':contract}
    def test_failed_promotion_preserves_descriptor_and_compatible_configuration(self):
        with patch.object(managed,'install',return_value=self.fake_install('old')), patch.object(managed,'bounded_run'), patch.object(managed,'verify_settings'):
            first=managed.ensure(self.root,self.root)
        before=self.path.read_bytes();config=Path(first['config']).read_bytes()
        # Google is a bundled provider plugin in the pinned release. A blanket
        # plugin disable yields an empty catalog even with valid credentials.
        plugins=json.loads(config)['plugins']
        self.assertTrue(plugins['enabled'])
        self.assertEqual(plugins['allow'],['google'])
        self.assertTrue(plugins['entries']['google']['enabled'])
        with patch.object(managed,'install',return_value=self.fake_install('new')), \
             patch.object(managed,'bounded_run',side_effect=managed.ManagedRuntimeError('invalid staged config')):
            with self.assertRaises(managed.ManagedRuntimeError):managed.ensure(self.root,self.root)
        self.assertEqual(self.path.read_bytes(),before)
        self.assertEqual(Path(first['config']).read_bytes(),config)
    def test_verified_rollback_restores_instance_and_rejected_update_is_not_reactivated(self):
        old=self.fake_install('old')
        with patch.object(managed,'install',return_value=old), patch.object(managed,'bounded_run'), patch.object(managed,'verify_settings'):
            first=managed.ensure(self.root,self.root)
        managed.mark_working(self.path)
        new=self.fake_install('new')
        with patch.object(managed,'install',return_value=new),patch.object(managed,'bounded_run'), patch.object(managed,'verify_settings'):
            second=managed.ensure(self.root,self.root)
        self.assertNotEqual(first['instance_id'],second['instance_id'])
        with patch.object(managed,'bounded_run') as writer, patch.object(managed,'verify_settings'):
            self.assertEqual(managed.rollback(self.path),first)
            self.assertTrue(any('patch' in call.args[0] for call in writer.call_args_list))
            self.assertTrue(any('validate' in call.args[0] for call in writer.call_args_list))
        with patch.object(managed,'install',return_value=new):
            self.assertEqual(managed.ensure(self.root,self.root),first)

    def test_atomic_records_are_private(self):
        managed.atomic_json(self.path,{'opaque':'identifier'})
        self.assertEqual(self.path.stat().st_mode&0o777,0o600)
        self.assertFalse(list(self.root.glob('.runtime.json*')))
    def test_configuration_repair_discards_model_faults_but_retains_account_cooldown(self):
        from request_policy import RuntimeState, Failure, PRIMARY_MODELS
        model=PRIMARY_MODELS[0]
        with patch.dict(os.environ,{'TASKPILOT_MANAGED_FINGERPRINT':'instance:install:old'}):
            old=RuntimeState('credential','version',root=self.root)
            old.record_failure(model,Failure('unavailable','catalog unavailable'))
            self.assertTrue(old.health(model))
        with patch.dict(os.environ,{'TASKPILOT_MANAGED_FINGERPRINT':'instance:install:new'}):
            new=RuntimeState('credential','version',root=self.root)
            self.assertEqual(new.health(model),{})
            new.record_failure(model,Failure('quota','account quota',retry_at=9999999999,provider='google',scope='credential'))
        with patch.dict(os.environ,{'TASKPILOT_MANAGED_FINGERPRINT':'instance:install:newer'}):
            self.assertEqual(RuntimeState('credential','version',root=self.root).health(model)['failure_kind'],'quota')
    def test_recovery_forbids_actions_completion_and_pending_receipt_escape(self):
        m=ExecutionMachine(Phase.RECONCILING,pending_action='uncertain')
        m.transition(Phase.RECOVERING)
        for effect in ('execute','complete','plan','verify'):
            with self.assertRaises(ExecutionStateError):m.require(effect)
        with self.assertRaises(ExecutionStateError):m.transition(Phase.PLANNING,recovered=True)
        m.transition(Phase.RECONCILING,recovered=True)
        self.assertEqual(m.pending_action,'uncertain')
    def test_health_needs_matching_generationless_instance_and_configuration(self):
        value=self.descriptor();managed.atomic_json(self.path,value)
        managed.atomic_json(self.root/'health.json',{'state':'needs_repair','instance_id':value['instance_id'],
            'configuration_fingerprint':value['configuration_fingerprint'],'detail':'Repair private config'})
        with self.assertRaisesRegex(managed.ManagedRuntimeError,'Repair private config'):
            managed.wait_for_health(self.path,sleep=lambda _:self.fail('permanent error polled'))

if __name__=='__main__':unittest.main()

class ManagedRecoveryTests(unittest.TestCase):
    setUp = ManagedRuntimeTests.setUp
    descriptor = ManagedRuntimeTests.descriptor
    fake_install = ManagedRuntimeTests.fake_install
    def health(self, descriptor, **changes):
        identity = dict(pid=42, seconds=100, microseconds=10)
        return dict(version=1, state='healthy', instance_id=descriptor['instance_id'],
                    installation_fingerprint=descriptor['installation_fingerprint'],
                    configuration_fingerprint=descriptor['configuration_fingerprint'], checked_at=1000,
                    host_identity=identity, gateway_identity=identity, **changes)

    def test_health_rejects_dead_reused_missing_future_and_stale_identities(self):
        d=self.descriptor(); record=self.health(d)
        with patch.object(managed,'process_identity',return_value=record['host_identity']):
            self.assertTrue(managed.healthy_record(record,d,wall_time=1001))
            for changes in ({'checked_at':900},{'checked_at':1002},{'installation_fingerprint':'old'},
                            {'configuration_fingerprint':'old'},{'gateway_identity':None},
                            {'gateway_identity':{'pid':42,'seconds':99,'microseconds':10}}):
                self.assertFalse(managed.healthy_record({**record,**changes},d,wall_time=1001))
        with patch.object(managed,'process_identity',return_value=None):
            self.assertFalse(managed.healthy_record(record,d,wall_time=1001))

    def test_real_birth_identity_matches_current_process_and_exited_process_is_rejected(self):
        if sys.platform != 'darwin': self.skipTest('macOS process birth identity')
        identity=managed.process_identity(os.getpid());self.assertTrue(managed.identity_alive(identity))
        self.assertFalse(managed.identity_alive({**identity,'seconds':identity['seconds']+1}))
        import subprocess
        child=subprocess.Popen(['/usr/bin/true']);child.wait()
        self.assertIsNone(managed.process_identity(child.pid))

    def test_missing_wrapper_preserves_descriptor_for_direct_fallback_and_repair(self):
        d=self.descriptor();managed.atomic_json(self.path,d);Path(d['executable']).unlink()
        self.assertEqual(managed.load_descriptor(self.path),d)

    def test_direct_fallback_requires_verified_pinned_installation(self):
        target,pin,_=self.fake_install('pin');d=self.descriptor()
        d.update(node=str(target/'node/bin/node'),entry=str(target/'package/node_modules/openclaw/openclaw.mjs'),installation_fingerprint=pin)
        self.assertEqual(managed.direct_command(d),[d['node'],d['entry']])
        Path(d['entry']).write_text('corrupted')
        with self.assertRaises(managed.ManagedRuntimeError):managed.direct_command(d)

    def test_offline_writes_reject_live_birth_owned_gateway(self):
        identity=dict(pid=42,seconds=1,microseconds=2)
        managed.atomic_json(self.root/'gateway-root.json',identity)
        with patch.object(managed,'process_identity',return_value=identity):
            with self.assertRaisesRegex(managed.ManagedRuntimeError,'drainage'):managed.require_offline(self.root)
        with patch.object(managed,'process_identity',return_value=None):managed.require_offline(self.root)

    def test_configuration_hold_waits_for_matching_ack_and_releases_after_exception(self):
        identity=dict(pid=42,seconds=1,microseconds=2)
        managed.atomic_json(self.root/'gateway-root.json',identity)
        alive=[True]
        def tick(_):
            request=json.loads((self.root/'configuration-request.json').read_text())
            managed.atomic_json(self.root/'configuration-ack.json',{'request_id':request['request_id']})
            alive[0]=False
        with patch.object(managed,'process_identity',side_effect=lambda pid: identity if alive[0] else None), patch.object(managed.time,'sleep',side_effect=tick):
            with self.assertRaisesRegex(ValueError,'fixture'):
                with managed.configuration_hold(self.root):raise ValueError('fixture')
        self.assertFalse((self.root/'configuration-request.json').exists())

    def test_repair_reservation_survives_failure_and_throttles_unchanged_defect(self):
        result={'ok':False,'causes':['wrapper'],'fingerprint':'opaque'}
        with patch.object(managed,'audit',return_value=result),patch.object(managed,'ensure',side_effect=managed.ManagedRuntimeError('failed')) as ensure:
            with self.assertRaisesRegex(managed.ManagedRuntimeError,'failed'):managed.repair(self.path,self.root)
            with self.assertRaisesRegex(managed.ManagedRuntimeError,'recently'):managed.repair(self.path,self.root)
            self.assertEqual(ensure.call_count,1)
            with patch.object(managed.time,'time',return_value=__import__('time').time()+601):
                with self.assertRaisesRegex(managed.ManagedRuntimeError,'failed'):managed.repair(self.path,self.root)
            self.assertEqual(ensure.call_count,2)
        self.assertEqual(set(json.loads((self.root/'repair-budget.json').read_text())),{'fingerprint','attempted_at'})

    def test_handshake_classification_never_calls_timeout_incompatible(self):
        for message,kind in [('timed out','timeout'),('connection refused','refused'),('invalid token','authentication'),
                             ('malformed protocol','malformed'),('unsupported ACP version: 2','incompatible'),('not executable','startup')]:
            self.assertEqual(managed.handshake_cause(RuntimeError(message)),kind)

    def test_healthy_ensure_does_not_patch_configuration_and_repairs_missing_wrapper(self):
        with patch.object(managed,'install',return_value=self.fake_install('pin')),patch.object(managed,'bounded_run') as run,patch.object(managed,'verify_settings'):
            first=managed.ensure(self.root,self.root)
            Path(first['executable']).unlink();run.reset_mock()
            second=managed.ensure(self.root,self.root)
            self.assertEqual(first['instance_id'],second['instance_id'])
            self.assertTrue(Path(second['executable']).is_file())
            self.assertEqual([args.args[0][1:3] for args in run.call_args_list],[['config','validate']])

    def test_credential_presence_reads_only_private_store_without_returning_secrets(self):
        import sqlite3
        database=self.root/'state/openclaw.sqlite';database.parent.mkdir(mode=0o700)
        with sqlite3.connect(database) as c:
            c.execute('CREATE TABLE config_machine_state(state_key TEXT, value_json TEXT)')
            c.execute('INSERT INTO config_machine_state VALUES (?,?)',('authProfiles.store',json.dumps({'profiles':{'google:orbit':{'key':'private fixture','provider':'google','type':'api_key'}}})))
        self.assertIs(managed.credential_present(self.root),True)
        c.close()
        database.unlink();self.assertIs(managed.credential_present(self.root),False)
        self.assertFalse(database.exists())

    def test_audit_detects_owned_drift_and_repair_preserves_unrelated_configuration(self):
        parent=self.root; self.root=parent/'managed';self.root.mkdir(mode=0o700);self.path=self.root/'runtime.json'
        key='fixture-private-key-123456789';(parent/'gemini-api-key').write_text(key)
        with patch.object(managed,'install',return_value=self.fake_install('pin')),patch.object(managed,'bounded_run') as cli,patch.object(managed,'verify_settings'),patch.object(managed,'credential_present',return_value=True):
            d=managed.ensure(self.root,self.root,key)
            first_audit=managed.audit(self.path,force_integrity=True)
            self.assertTrue(first_audit['ok'])
            self.assertTrue(first_audit['full_integrity_ok'])
            self.assertEqual(first_audit['integrity_audit']['audit_mode'],'full')
            warm_audit=managed.audit(self.path)
            self.assertTrue(warm_audit['ok'])
            self.assertFalse(warm_audit['full_integrity_ok'])
            self.assertEqual(warm_audit['integrity_audit']['audit_mode'],'incremental')
            self.assertEqual(warm_audit['integrity_audit']['files_hashed'],0)
            config=Path(d['config']);original=json.loads(config.read_text())
            for modify in (lambda v:v['plugins'].update(enabled=False),
                           lambda v:v['agents']['defaults']['models'].update({'google/gemini-3.5-flash':{}}),
                           lambda v:v['gateway'].update(port=30000)):
                value=json.loads(json.dumps(original));modify(value);managed.atomic_json(config,value)
                self.assertIn('configuration',managed.audit(self.path)['causes'])
            value['private_fixture_metadata']={'keep':True};managed.atomic_json(config,value)
            cli.reset_mock()
            managed.repair(self.path,self.root)
            self.assertTrue(managed.audit(self.path)['ok'])
            self.assertEqual(json.loads(config.read_text())['private_fixture_metadata'],{'keep':True})
            self.assertTrue(any('patch' in call.args[0] for call in cli.call_args_list))
            Path(d['executable']).write_text('corrupt wrapper')
            self.assertIn('wrapper',managed.audit(self.path)['causes'])
            Path(d['token_file']).unlink()
            self.assertIn('configuration',managed.audit(self.path)['causes'])
            with patch.object(managed,'credential_present',return_value=False):
                self.assertIn('credential_store',managed.audit(self.path)['causes'])

    def test_rebinding_health_cache_keeps_credential_cooldown_and_changes_verification_identity(self):
        from request_policy import RuntimeState, Failure, PRIMARY_MODELS
        model=PRIMARY_MODELS[0]
        with patch.dict(os.environ,{'TASKPILOT_MANAGED_FINGERPRINT':'old'}):
            state=RuntimeState('credential','version',root=self.root)
            state.record_failure(model,Failure('quota','account quota',retry_at=9999999999,provider='google',scope='credential'))
            identity=state.identity;credential=state.credential
            with patch.dict(os.environ,{'TASKPILOT_MANAGED_FINGERPRINT':'new'}):state.rebind_managed('version','config')
            self.assertNotEqual(state.identity,identity);self.assertEqual(state.credential,credential)
            self.assertEqual(state.health(model)['failure_kind'],'quota')

class PrivateDirectoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_read_only_check_rejects_mode_drift_and_repair_reads_back(self):
        for mode in (0o755, 0o777, 0o1700):
            with self.subTest(mode=mode):
                self.root.chmod(mode)
                with self.assertRaisesRegex(managed.PrivateDirectoryError, 'permissions'):
                    managed.check_private_directory(self.root)
                self.assertEqual(self.root.stat().st_mode & 0o7777, mode)
                managed.check_private_directory(self.root, repair=True)
                self.assertEqual(self.root.stat().st_mode & 0o7777, 0o700)

    def test_unopenable_directory_fails_closed_without_path_chmod(self):
        self.root.chmod(0o000)
        try:
            with self.assertRaisesRegex(managed.PrivateDirectoryError, 'permissions'):
                managed.check_private_directory(self.root, repair=True)
        finally: self.root.chmod(0o700)

    def test_symlink_file_and_foreign_owner_are_never_repaired(self):
        target = self.root / 'target'; target.mkdir(mode=0o755)
        link = self.root / 'link'; link.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(managed.PrivateDirectoryError, 'symlink'):
            managed.check_private_directory(link, repair=True)
        self.assertEqual(target.stat().st_mode & 0o7777, 0o755)
        file = self.root / 'file'; file.write_text('fixture')
        with self.assertRaisesRegex(managed.PrivateDirectoryError, 'unavailable'):
            managed.check_private_directory(file, repair=True)
        with patch.object(managed.os, 'getuid', return_value=os.getuid() + 1), patch.object(managed.os, 'fchmod') as chmod:
            with self.assertRaisesRegex(managed.PrivateDirectoryError, 'ownership'):
                managed.check_private_directory(target, repair=True)
            chmod.assert_not_called()

    def test_all_targets_validated_before_any_mode_repair(self):
        self.root.chmod(0o755)
        other = self.root / 'other'; other.mkdir(mode=0o755)
        (self.root / 'instances').symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(managed.PrivateDirectoryError, 'symlink'):
            managed.check_managed_directories(self.root, repair=True)
        self.assertEqual(self.root.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(other.stat().st_mode & 0o7777, 0o755)

    def test_lock_does_not_chmod_a_hardlinked_unrelated_file(self):
        file = self.root / 'unrelated'; file.write_text('fixture'); file.chmod(0o644)
        os.link(file, self.root / 'installation.lock')
        with self.assertRaisesRegex(managed.PrivateDirectoryError, 'ownership'):
            with managed.locked(self.root): self.fail('unexpected lock admission')
        self.assertEqual(file.stat().st_mode & 0o7777, 0o644)

    def test_path_swap_during_check_is_classified(self):
        real_stat = managed.os.fstat
        def replaced(fd):
            value = real_stat(fd)
            values = list(value); values[1] += 1
            return os.stat_result(values)
        with patch.object(managed.os, 'fstat', side_effect=replaced), patch.object(managed.os, 'fchmod') as chmod:
            with self.assertRaisesRegex(managed.PrivateDirectoryError, 'changed'):
                managed.check_private_directory(self.root, repair=True)
            chmod.assert_not_called()

    def provision(self):
        install = ManagedRuntimeTests.fake_install(self, 'pin')
        with patch.object(managed, 'install', return_value=install), patch.object(managed, 'bounded_run'), patch.object(managed, 'verify_settings'):
            return managed.ensure(self.root, self.root)

    def test_mode_drift_uses_one_serialized_drain_and_preserves_descriptor(self):
        d = self.provision(); before = (self.root / 'runtime.json').read_bytes()
        Path(d['workspace']).chmod(0o755)
        Path(d['state']).chmod(0o755); self.root.chmod(0o755)
        from contextlib import contextmanager
        calls = []
        @contextmanager
        def hold(*args, **kwargs):
            calls.append('drained'); yield
        target = Path(d['node']).parents[2]
        contract = dict(version=1, required_capabilities=list(managed.CLI_CAPABILITIES),
                        package_lock_sha256=managed.digest(target / 'package/package-lock.json'))
        install = (target, 'pin', {'openclaw_version':'2026.9.5', 'node_version':'24.22.1', 'cli_contract':contract})
        with patch.object(managed, 'configuration_hold', hold), patch.object(managed, 'install', return_value=install), patch.object(managed, 'bounded_run'), patch.object(managed, 'verify_settings'):
            managed.ensure(self.root, self.root, drained=True)
        self.assertEqual(calls, ['drained'])
        managed.check_managed_directories(self.root, d)
        self.assertEqual((self.root / 'runtime.json').read_bytes(), before)

    def test_directory_audit_stops_before_integrity_or_cli_and_unsafe_repair(self):
        d = self.provision(); path = self.root / 'runtime.json'
        Path(d['workspace']).chmod(0o755)
        with patch.object(managed, 'validate_install') as integrity, patch.object(managed, 'bounded_run') as cli:
            result = managed.audit(path)
            self.assertEqual(result['causes'], ['private_directory_permissions'])
            integrity.assert_not_called(); cli.assert_not_called()
        workspace = Path(d['workspace']); workspace.rmdir()
        workspace.symlink_to(self.root, target_is_directory=True)
        with patch.object(managed, 'ensure') as ensure:
            with self.assertRaisesRegex(managed.ManagedRuntimeError, 'symlink'):
                managed.repair(path, self.root)
            ensure.assert_not_called()
        self.assertFalse((self.root / 'repair-budget.json').exists())

    def test_escaping_symlink_is_attention_not_new_instance_provisioning(self):
        d = self.provision(); workspace = Path(d['workspace']); workspace.rmdir()
        with tempfile.TemporaryDirectory() as outside:
            workspace.symlink_to(outside, target_is_directory=True)
            with patch.object(managed, 'install') as install:
                with self.assertRaisesRegex(managed.PrivateDirectoryError, 'symlink'):
                    managed.ensure(self.root, self.root)
                install.assert_not_called()
            self.assertEqual(managed.audit(self.root/'runtime.json')['causes'], ['private_directory_symlink'])

    def test_permission_repair_is_reserved_and_does_not_reinstall(self):
        d = self.provision(); Path(d['workspace']).chmod(0o755)
        path = self.root / 'runtime.json'
        initial = managed.audit(path)
        with patch.object(managed, 'audit', side_effect=[initial, {'ok':True}]), patch.object(managed, 'install') as install:
            self.assertEqual(managed.repair(path, self.root), d)
            install.assert_not_called()
        self.assertTrue((self.root / 'repair-budget.json').exists())
        managed.check_managed_directories(self.root, d)

    def test_activation_rejects_drift_before_environment_or_diagnostic_changes(self):
        d = self.provision(); Path(d['workspace']).chmod(0o755)
        before = dict(os.environ)
        with patch.object(managed, 'atomic_json') as write:
            with self.assertRaisesRegex(managed.PrivateDirectoryError, 'permissions'):
                managed.activate_environment(self.root / 'runtime.json')
            write.assert_not_called()
        self.assertEqual(dict(os.environ), before)

    def test_installation_mode_drift_invalidates_even_warm_integrity_cache(self):
        target, pin, _ = ManagedRuntimeTests.fake_install(self, 'pin')
        self.assertTrue(managed.validate_install(target, pin))
        target.chmod(0o755)
        self.assertFalse(managed.validate_install(target, pin))
