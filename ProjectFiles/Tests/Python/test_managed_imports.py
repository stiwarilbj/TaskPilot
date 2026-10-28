"""Fresh-process import boundaries; no network, services, or provider requests."""
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest


RUNTIME = Path(__file__).resolve().parents[2] / 'AgentRuntime'


class ManagedImportTests(unittest.TestCase):
    def isolated(self, body, *, block_download=True):
        prefix = '''
            import sys
            sys.path.insert(0, sys.argv[1])
            blocked = {'tarfile'}
            if sys.argv[2] == 'block': blocked.add('urllib.request')
            assert not blocked.intersection(sys.modules)
            class RejectProvisioningImports:
                def find_spec(self, fullname, path=None, target=None):
                    if fullname in blocked:
                        raise AssertionError('Unexpected provisioning import: ' + fullname)
            sys.meta_path.insert(0, RejectProvisioningImports())
            import managed_openclaw as managed
            assert not blocked.intersection(sys.modules)
            # Keep real audit dependencies eager rather than weakening checks.
            assert {'sqlite3', 'runtime_descriptor_generated', 'managed_spawn'} <= sys.modules.keys()
        '''
        result = subprocess.run([sys.executable, '-c', textwrap.dedent(prefix) + textwrap.dedent(body),
                                 str(RUNTIME), 'block' if block_download else 'allow'],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_audit_dispatch_keeps_provisioning_unloaded(self):
        self.isolated('''
            import io, json, tempfile
            from contextlib import redirect_stdout
            from pathlib import Path
            from unittest.mock import patch
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve() / 'managed'; root.mkdir(mode=0o700)
                installation = root / 'installations/fixture'
                state = root / 'instances/128bdc78-d592-43a3-b4e1-b6fe3a0e57cd'
                workspace = state / 'workspace'
                for directory in (installation, workspace):
                    directory.mkdir(parents=True, mode=0o700)
                for directory in (root / 'installations', root / 'instances', state):
                    directory.chmod(0o700)
                node = installation / 'node/bin/node'
                entry = installation / 'package/openclaw.mjs'
                for path in (node, entry):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('fixture')
                lock = installation / 'package/package-lock.json'; lock.write_text('{}')
                managed.atomic_json(installation / managed.CLI_CAPABILITY_FILE, dict(version=1,
                    package_lock_sha256=managed.digest(lock), capabilities=list(managed.CLI_CAPABILITIES)))
                managed.atomic_json(installation / 'integrity.json',
                                    dict(fingerprint='fixture', files=managed.seal(installation)))
                token = state / 'gateway-token'; token.write_text('fixture-token')
                key = 'fixture-private-key'
                (root.parent / 'gemini-api-key').write_text(key)
                record = state / 'credential-fingerprint.json'
                managed.atomic_json(record, dict(fingerprint=managed.hashlib.sha256(key.encode()).hexdigest()))
                required = managed.desired_settings(workspace, token, 24200)
                config = state / 'openclaw.json'; managed.atomic_json(config, required)
                wrapper = state / 'openclaw'
                wrapper.write_text(managed.wrapper_script(state, config, node, entry)); wrapper.chmod(0o700)
                descriptor = dict(version=1, instance_id=state.name, installation_fingerprint='fixture',
                    configuration_fingerprint=managed.configuration_fingerprint(required, record),
                    openclaw_version='fixture', node_version='fixture', port=24200, endpoint='ws://127.0.0.1:24200',
                    node=str(node), entry=str(entry), executable=str(wrapper), state=str(state),
                    workspace=str(workspace), config=str(config), token_file=str(token))
                path = root / 'runtime.json'; managed.atomic_json(path, descriptor)
                # Only external CLI readback and credentials are faked; audit,
                # descriptor, permissions, integrity and database checks are real.
                with patch.object(managed, 'verify_settings') as readback, \
                     patch.object(managed, 'credential_present', return_value=True):
                    for full in (True, False):
                        output = io.StringIO()
                        with redirect_stdout(output):
                            assert managed.command('audit', descriptor=str(path), force_integrity=full) == 0
                        result = json.loads(output.getvalue())
                        assert result['ok'], result
                        assert result['full_integrity_ok'] == full
                        assert result['integrity_audit']['audit_mode'] == ('full' if full else 'incremental')
                    assert readback.call_count == 2
                assert not blocked.intersection(sys.modules)
        ''')

    def test_verified_install_and_unknown_command_need_no_provisioning_imports(self):
        self.isolated('''
            import tempfile
            from pathlib import Path
            from unittest.mock import patch
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                target = root / 'installations/fixture'; target.mkdir(parents=True, mode=0o700)
                (root / 'installations').chmod(0o700)
                (target / 'code').write_text('fixture')
                (target / 'package').mkdir()
                lock = target / 'package/package-lock.json'; lock.write_text('{}')
                contract = dict(version=1, required_capabilities=list(managed.CLI_CAPABILITIES), package_lock_sha256=managed.digest(lock))
                managed.atomic_json(target / managed.CLI_CAPABILITY_FILE, dict(version=1,
                    package_lock_sha256=managed.digest(lock), capabilities=list(managed.CLI_CAPABILITIES)))
                managed.atomic_json(target / 'integrity.json', dict(fingerprint='fixture', files=managed.seal(target)))
                with patch.object(managed, 'specification', return_value=({'cli_contract':contract}, 'fixture')):
                    assert managed.install(root, root) == (target, 'fixture', {'cli_contract':contract})
                try: managed.command('unknown', descriptor=str(root / 'runtime.json'))
                except managed.ManagedRuntimeError: pass
                else: raise AssertionError('Unsupported operation accepted')
                assert not blocked.intersection(sys.modules)
        ''')

    def test_download_loads_http_support_on_demand_without_archive_support(self):
        self.isolated('''
            import tempfile
            from pathlib import Path
            assert 'urllib.request' not in sys.modules
            with tempfile.TemporaryDirectory() as temporary:
                destination = Path(temporary) / 'archive'
                # The built-in data handler exercises urlopen without networking.
                managed.download('data:,fixture', destination, managed.hashlib.sha256(b'fixture').hexdigest())
                assert destination.read_bytes() == b'fixture'
                assert 'urllib.request' in sys.modules
                assert 'tarfile' not in sys.modules
        ''', block_download=False)


if __name__ == '__main__':
    unittest.main()
