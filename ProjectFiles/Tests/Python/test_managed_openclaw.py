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
        executable=self.root/'private/openclaw'; executable.parent.mkdir(exist_ok=True);executable.write_text('fixture')
        return dict(version=1,instance_id='128bdc78-d592-43a3-b4e1-b6fe3a0e57cd',port=24200,
            endpoint='ws://127.0.0.1:24200',installation_fingerprint='fixture',configuration_fingerprint='config',
            **{k:str(executable) for k in ('executable','node','entry','state','config','workspace','token_file')})
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
        install=self.root/'install';install.mkdir();f=install/'code';f.write_text('good')
        managed.atomic_json(install/'integrity.json',{'fingerprint':'pin','files':managed.seal(install)})
        self.assertTrue(managed.validate_install(install,'pin'))
        f.write_text('bad');self.assertFalse(managed.validate_install(install,'pin'))
        f.unlink();outside=self.root/'outside';outside.write_text('good');f.symlink_to(outside)
        self.assertFalse(managed.validate_install(install,'pin'))
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
        managed.atomic_json(target/'integrity.json',{'fingerprint':pin,'files':managed.seal(target)})
        return target,pin,{'openclaw_version':'2026.9.5','node_version':'24.22.1'}
    def test_failed_promotion_preserves_descriptor_and_compatible_configuration(self):
        with patch.object(managed,'install',return_value=self.fake_install('old')), patch.object(managed,'bounded_run'):
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
        with patch.object(managed,'install',return_value=old), patch.object(managed,'bounded_run'):
            first=managed.ensure(self.root,self.root)
        managed.mark_working(self.path)
        new=self.fake_install('new')
        with patch.object(managed,'install',return_value=new),patch.object(managed,'bounded_run'):
            second=managed.ensure(self.root,self.root)
        self.assertNotEqual(first['instance_id'],second['instance_id'])
        with patch.object(managed,'bounded_run') as writer:
            self.assertEqual(managed.rollback(self.path),first)
            self.assertIn('patch',writer.call_args.args[0])
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
