"""Headless fake ACP transports; never connect to a provider or desktop."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'AgentRuntime'))
import managed_openclaw as managed
import openclaw_runtime as runtime

class ManagedConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.path=self.root/'runtime.json'
        self.wrapper=self.root/'wrapper';self.entry=self.root/'entry.py'
        self.d=dict(version=1,instance_id='128bdc78-d592-43a3-b4e1-b6fe3a0e57cd',port=24200,
            endpoint='ws://127.0.0.1:24200',installation_fingerprint='pin',configuration_fingerprint='config',
            executable=str(self.wrapper),node=sys.executable,entry=str(self.entry),state=str(self.root/'state'),
            config=str(self.root/'config'),workspace=str(self.root/'workspace'),token_file=str(self.root/'token'))
        # Descriptor paths must all be private, including our fixture Node link.
        node=self.root/'node';node.write_text('fixture');self.d['node']=str(node)
        managed.atomic_json(self.path,self.d)
        self.env=patch.dict(os.environ,{'TASKPILOT_MANAGED_DESCRIPTOR':str(self.path)})
        self.env.start();self.addCleanup(self.env.stop)

    def test_wrapper_ends_before_direct_node_handshake_with_same_endpoint_and_zero_generations(self):
        self.wrapper.write_text('#!'+sys.executable+'\nimport os, pathlib, sys\npathlib.Path(__file__).with_name("old-pid").write_text(str(os.getpid()))\nsys.exit(1)\n');self.wrapper.chmod(0o700)
        self.entry.write_text('''import json, os, pathlib, sys
old=int(pathlib.Path(__file__).with_name('old-pid').read_text())
try: os.kill(old,0)
except ProcessLookupError: pass
else: raise RuntimeError('old connection was not drained')
assert sys.argv[1:] == ['acp','--no-prefix-cwd','--url','ws://127.0.0.1:24200','--token-file',str(pathlib.Path(__file__).with_name('token'))]
assert os.environ['OPENCLAW_PROFILE'] == 'taskpilot'
for line in sys.stdin:
    request=json.loads(line)
    method=request.get('method')
    if method == 'initialize': result={'protocolVersion':1}
    elif method == 'session/new': result={'sessionId':'fixture','configOptions':[]}
    elif method == 'session/cancel': continue
    else: raise RuntimeError('unexpected request; generation is forbidden')
    print(json.dumps({'id':request['id'],'result':result}),flush=True)
''')
        with patch.object(managed,'direct_command',return_value=[sys.executable,str(self.entry)]) as verified:
            client=runtime.ACPClient(str(self.wrapper))
            self.assertEqual(client.connection_method,'direct_node');self.assertEqual(client.prompt_calls,0)
            process=client.process
            client.close();self.assertIsNotNone(process.poll())
            verified.assert_called_once_with(self.d)
        record=json.loads((self.root/'connection.json').read_text())
        self.assertEqual(set(record),{'version','method','checked_at','elapsed_ms','initial_cause'})

    def test_explicit_incompatible_handshake_never_falls_back(self):
        self.wrapper.write_text('#!'+sys.executable+'''\nimport json,sys
for line in sys.stdin:
 r=json.loads(line)
 if r.get('method') == 'initialize': print(json.dumps({'id':r['id'],'result':{'protocolVersion':2}}),flush=True)
''');self.wrapper.chmod(0o700)
        with patch.object(managed,'direct_command') as alternative:
            with self.assertRaisesRegex(RuntimeError,'unsupported ACP version'):runtime.ACPClient(str(self.wrapper))
            alternative.assert_not_called()

    def test_timeout_fallback_is_sequential_not_incompatible(self):
        events=[]
        def initialize(client,path,**kwargs):
            events.append('direct' if kwargs else 'wrapper')
            if not kwargs:raise TimeoutError('handshake timed out')
        with patch.object(runtime.ACPClient,'_initialize',initialize),patch.object(managed,'direct_command',return_value=['private-node','private-entry']):
            client=runtime.ACPClient(str(self.wrapper))
        self.assertEqual(events,['wrapper','direct']);self.assertEqual(client.connection_method,'direct_node')

    def test_gateway_authentication_rejection_does_not_start_an_alternative(self):
        with patch.object(runtime.ACPClient,'_initialize',side_effect=RuntimeError('Gateway authentication failed')),patch.object(managed,'direct_command') as alternative:
            with self.assertRaisesRegex(RuntimeError,'authentication'):runtime.ACPClient(str(self.wrapper))
            alternative.assert_not_called()
