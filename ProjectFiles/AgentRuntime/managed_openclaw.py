"""TaskPilot-owned, pinned OpenClaw installation. Never discovers a shared CLI.

The descriptor is the only authority for paths and endpoint. Installation and
configuration are serialized; no task/provider data is written to diagnostics.
"""
from __future__ import annotations
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import shlex
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.request
import uuid

VERSION = 1
ROOT = Path.home() / 'Library/Application Support/Orbit Agent/ManagedOpenClaw'

class ManagedRuntimeError(RuntimeError): pass

def atomic_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, separators=(',', ':')); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)

@contextmanager
def locked(root: Path):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / 'installation.lock').open('a') as f:
        os.chmod(f.name, 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        yield

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def specification(resources: Path):
    manifest = json.loads((resources / 'runtime-manifest.json').read_text())
    lock = json.loads((resources / 'package-lock.json').read_text())
    package = lock['packages']['node_modules/openclaw']
    if (manifest['version'] != VERSION or package['version'] != manifest['openclaw_version']
            or package['integrity'] != manifest['openclaw_integrity']):
        raise ManagedRuntimeError('Bundled OpenClaw lock does not match its manifest; reinstall TaskPilot.')
    for name, entry in lock['packages'].items():
        if not name: continue
        if not entry.get('integrity') or not entry.get('resolved', '').startswith('https://registry.npmjs.org/'):
            raise ManagedRuntimeError('Bundled dependency lock contains an unverified source.')
    fingerprint = hashlib.sha256(b''.join((resources / n).read_bytes() for n in
        ('runtime-manifest.json', 'package.json', 'package-lock.json'))).hexdigest()
    return manifest, fingerprint

def download(url, destination, expected):
    h = hashlib.sha256(); count = 0
    with urllib.request.urlopen(url, timeout=45) as response, destination.open('wb') as f:
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > 1024 * 1024 * 1024: raise ManagedRuntimeError('Runtime download exceeds its size limit.')
            h.update(chunk); f.write(chunk)
    if h.hexdigest() != expected:
        destination.unlink(missing_ok=True)
        raise ManagedRuntimeError('Official Node checksum did not match. Installation was not activated.')

def bounded_run(argv, *, env=None, timeout=45, cwd=None, input_data=None):
    # Disk-backed capture prevents unbounded communicate() allocation for npm.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as input_file:
        if input_data is not None:
            input_file.write(input_data); input_file.seek(0)
        process = subprocess.Popen(argv, stdout=output, stderr=output,
                                   stdin=input_file if input_data is not None else subprocess.DEVNULL,
                                   env=env, cwd=cwd, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            import signal
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait(); raise
        output.seek(0); text = output.read(65536).decode('utf-8', 'replace')
        if code: raise ManagedRuntimeError('Managed runtime validation failed; the previous installation remains available.')
        return text

def seal(directory):
    # Hash the installed code, not only package.json. Excludes npm cache/logs.
    return {str(p.relative_to(directory)): digest(p) for p in sorted(directory.rglob('*'))
            if p.is_file() and not p.is_symlink() and p.name != 'integrity.json'}

def validate_install(directory, fingerprint):
    try:
        record = json.loads((directory / 'integrity.json').read_text())
        return (record['fingerprint'] == fingerprint and bool(record['files']) and
                all((directory / name).resolve().is_relative_to(directory.resolve()) and digest(directory / name) == value
                    for name, value in record['files'].items()))
    except (OSError, ValueError, KeyError): return False

def install(resources, root):
    manifest, fingerprint = specification(resources)
    target = root / 'installations' / fingerprint
    if validate_install(target, fingerprint): return target, fingerprint, manifest
    stage = root / 'installations' / ('.stage-' + uuid.uuid4().hex)
    stage.mkdir(parents=True, mode=0o700)
    try:
        archive = manifest['node_archives'].get(platform.machine())
        if archive is None: raise ManagedRuntimeError('This Mac architecture is unsupported by the bundled runtime.')
        payload = stage / 'node.tar.gz'
        download('https://nodejs.org/dist/v' + manifest['node_version'] + '/' + archive['name'], payload, archive['sha256'])
        with tarfile.open(payload) as tar:
            # Reject traversal and escaping links, including on older Python.
            for member in tar.getmembers():
                resolved = (stage / member.name).resolve()
                if not resolved.is_relative_to(stage.resolve()): raise ManagedRuntimeError('Unsafe Node archive.')
                if member.issym() or member.islnk():
                    parent = resolved.parent if member.issym() else stage
                    if not (parent / member.linkname).resolve().is_relative_to(stage.resolve()):
                        raise ManagedRuntimeError('Unsafe Node archive link.')
            tar.extractall(stage, filter='data')
        payload.unlink()
        extracted = stage / archive['name'].removesuffix('.tar.gz')
        extracted.rename(stage / 'node')
        package = stage / 'package'; package.mkdir()
        for name in ('package.json', 'package-lock.json'): shutil.copyfile(resources / name, package / name)
        env = isolated_environment(); env['PATH'] = str(stage / 'node/bin') + ':/usr/bin:/bin'
        bounded_run([str(stage / 'node/bin/node'), str(stage / 'node/lib/node_modules/npm/bin/npm-cli.js'),
            'ci', '--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org/',
            '--cache', str(stage / 'npm-cache')], env=env, timeout=900, cwd=package)
        shutil.rmtree(stage / 'npm-cache', ignore_errors=True)
        actual = json.loads((package / 'node_modules/openclaw/package.json').read_text())
        if actual['version'] != manifest['openclaw_version']: raise ManagedRuntimeError('Unexpected OpenClaw version.')
        version = bounded_run([str(stage / 'node/bin/node'), str(package / 'node_modules/openclaw/openclaw.mjs'), '--version'], env=env)
        if manifest['openclaw_version'] not in version: raise ManagedRuntimeError('OpenClaw did not pass its launch check.')
        atomic_json(stage / 'integrity.json', {'fingerprint': fingerprint, 'files': seal(stage)})
        if target.exists():
            # Preserve corrupt installation for diagnosis, never overwrite active code.
            target.rename(target.with_name('.corrupt-' + uuid.uuid4().hex))
        stage.rename(target)
        return target, fingerprint, manifest
    finally:
        if stage.exists(): shutil.rmtree(stage)

def isolated_environment():
    env = {k:v for k,v in os.environ.items() if not k.startswith(('OPENCLAW_', 'NODE_', 'NPM_', 'npm_', 'GOOGLE_', 'GEMINI_'))}
    env.update(OPENCLAW_HIDE_BANNER='1', OPENCLAW_SUPPRESS_NOTES='1', OPENCLAW_NO_RESPAWN='1')
    return env

def private_port():
    # Reserve sufficient spacing for OpenClaw's derived browser ports.
    for _ in range(128):
        port = 22000 + secrets.randbelow(200) * 128
        sockets = []
        try:
            for candidate in (port, port + 2, port + 110):
                s = socket.socket(); sockets.append(s); s.bind(('127.0.0.1', candidate))
            return port
        except OSError: pass
        finally:
            for s in sockets: s.close()
    raise ManagedRuntimeError('No private Gateway endpoint is available.')

def ensure(resources: Path, root: Path = ROOT, key: str = ''):
    from request_policy import configuration_transaction
    with configuration_transaction(), locked(root):
        target, fingerprint, manifest = install(resources, root)
        try:
            rejected = json.loads((root / 'rejected-installation.json').read_text())
            if rejected.get('fingerprint') == fingerprint:
                # Keep a tested rollback usable; do not reactivate a rejected update every refresh.
                return load_descriptor(root / 'runtime.json')
        except (OSError, ValueError): pass
        active = root / 'runtime.json'
        try: previous = load_descriptor(active)
        except ManagedRuntimeError: previous = None
        identity = previous['instance_id'] if previous and previous['installation_fingerprint'] == fingerprint else str(uuid.uuid4())
        state = root / 'instances' / identity; state.mkdir(parents=True, exist_ok=True, mode=0o700)
        config = state / 'openclaw.json'; workspace = state / 'workspace'; workspace.mkdir(exist_ok=True, mode=0o700)
        token = state / 'gateway-token'
        if not token.exists():
            fd = os.open(token, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, 'w') as f: f.write(secrets.token_hex(32))
        from request_policy import ALL_MODELS
        port = previous['port'] if previous else private_port()
        desired = {'gateway': {'mode':'local', 'bind':'loopback', 'port':port,
                    'auth': {'mode':'token','token':token.read_text()}},
            'agents': {'defaults': {'workspace':str(workspace), 'model':{'primary':ALL_MODELS[0], 'fallbacks':list(ALL_MODELS[1:])},
                'imageModel': {'primary':ALL_MODELS[0], 'fallbacks':list(ALL_MODELS[1:])},
                'models':{m:{} for m in ALL_MODELS}}},
            # This pinned release supplies Google model support as a bundled
            # plugin. Disabling the plugin system removes the provider catalog.
            'plugins': {'enabled':True, 'allow':['google'],
                        'entries': {'google': {'enabled':True}}},
            'browser': {'enabled':False}}
        # Save a compatible snapshot before promoting a changed installation.
        if previous and previous['installation_fingerprint'] != fingerprint:
            atomic_json(root / 'previous-runtime.json', previous)
            if config.exists(): shutil.copyfile(config, state / 'previous-config.json')
        if not config.exists() or json.loads(config.read_text()) != desired:
            atomic_json(config, desired)
        auth = state / 'agents/main/agent/auth-profiles.json'
        key_record = state / 'credential-fingerprint.json'
        if key and len(key.strip()) < 20:
            raise ManagedRuntimeError('Save a complete Gemini API key in TaskPilot Settings.')
        wrapper = state / 'openclaw'
        node = target / 'node/bin/node'; entry = target / 'package/node_modules/openclaw/openclaw.mjs'
        # Absolute executable and a clean environment: no ambient shared profile.
        script = '#!/bin/sh\nunset OPENCLAW_HOME OPENCLAW_PROFILE OPENCLAW_GATEWAY_TOKEN OPENCLAW_GATEWAY_URL NODE_OPTIONS NODE_PATH\n'
        for name, value in {'OPENCLAW_STATE_DIR':str(state),'OPENCLAW_CONFIG_PATH':str(config),
                            'OPENCLAW_PROFILE':'taskpilot','OPENCLAW_NO_RESPAWN':'1',
                            'OPENCLAW_HIDE_BANNER':'1','OPENCLAW_SUPPRESS_NOTES':'1'}.items():
            script += 'export ' + name + '=' + shlex.quote(value) + '\n'
        script += 'exec ' + shlex.quote(str(node)) + ' ' + shlex.quote(str(entry)) + ' "$@"\n'
        if not wrapper.exists() or wrapper.read_text() != script:
            temp = wrapper.with_suffix('.new'); temp.write_text(script); temp.chmod(0o700); temp.replace(wrapper)
        # The pinned release stores authoritative configuration in SQLite and
        # exports JSON. Replacing JSON alone is reverted by the next command.
        bounded_run([str(wrapper), 'config', 'patch', '--stdin'],
                    input_data=json.dumps(desired).encode(), env=isolated_environment())
        if key:
            key_fingerprint = hashlib.sha256(key.strip().encode()).hexdigest()
            try: saved_fingerprint = json.loads(key_record.read_text()).get('fingerprint')
            except (OSError, ValueError): saved_fingerprint = None
            if saved_fingerprint != key_fingerprint:
                # Only our private legacy file can exist here. Do not invoke doctor
                # or import any shared store. The supported auth command writes
                # OpenClaw's current credential schema (SQLite in this release).
                auth.unlink(missing_ok=True)
                process = subprocess.run([str(wrapper), 'models', 'auth', 'paste-api-key',
                    '--provider', 'google', '--profile-id', 'google:orbit'],
                    input=key.strip() + '\n', text=True, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=45, env=isolated_environment())
                if process.returncode:
                    raise ManagedRuntimeError('Private OpenClaw could not save the Gemini credential. Reconfigure in Settings.')
                atomic_json(key_record, {'fingerprint':key_fingerprint})
        descriptor = {'version':VERSION, 'instance_id':identity, 'installation_fingerprint':fingerprint,
            'openclaw_version':manifest['openclaw_version'], 'node_version':manifest['node_version'],
            'node':str(node),'entry':str(entry),'executable':str(wrapper),'state':str(state),
            'config':str(config),'workspace':str(workspace),'token_file':str(token), 'port':port,
            'endpoint':f'ws://127.0.0.1:{port}',
            'configuration_fingerprint':hashlib.sha256((json.dumps(desired,sort_keys=True) + (digest(key_record) if key_record.exists() else '')).encode()).hexdigest()}
        bounded_run([str(wrapper),'config','validate'], timeout=45, env=isolated_environment())
        atomic_json(active, descriptor)
        if not previous or previous['installation_fingerprint'] != fingerprint:
            atomic_json(root / 'activation-verification.json', {'installation_fingerprint':fingerprint})
        return descriptor

def load_descriptor(path: Path = ROOT / 'runtime.json'):
    try:
        d = json.loads(path.read_text())
        if d['version'] != VERSION or str(uuid.UUID(d['instance_id'])) != d['instance_id']: raise ValueError()
        root = path.parent.resolve()
        for name in ('node','entry','executable','state','config','workspace','token_file'):
            if not Path(d[name]).is_absolute() or not Path(d[name]).resolve().is_relative_to(root): raise ValueError()
        if type(d['port']) is not int or not 1024 < d['port'] < 65400 or d['endpoint'] != f"ws://127.0.0.1:{d['port']}": raise ValueError()
        if not Path(d['executable']).is_file(): raise ValueError()
        return d
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ManagedRuntimeError('TaskPilot private OpenClaw is not installed or its descriptor is invalid.') from error

def activate_environment(path):
    d = load_descriptor(path)
    for key in list(os.environ):
        if key.startswith('OPENCLAW_'): os.environ.pop(key)
    os.environ.update(OPENCLAW_STATE_DIR=d['state'], OPENCLAW_CONFIG_PATH=d['config'],
        OPENCLAW_PROFILE='taskpilot', ORBIT_OPENCLAW_PATH=d['executable'],
        TASKPILOT_MANAGED_DESCRIPTOR=str(path),
        TASKPILOT_MANAGED_FINGERPRINT=d['instance_id'] + ':' + d['installation_fingerprint'] + ':' + d['configuration_fingerprint'])
    return d

def request_recovery(path):
    # Coalesced signal contains no request/task contents. Host owns the budget.
    atomic_json(path.parent / 'health-request.json', {'requested':time.time()})

def wait_for_health(path, *, sleep=time.sleep, now=time.monotonic, status=None, force=False):
    requested_at = time.time() if force else 0
    requested = False
    while True:
        try:
            state = json.loads((path.parent / 'health.json').read_text())
            descriptor = load_descriptor(path)
            if state.get('instance_id') == descriptor['instance_id'] and state.get('configuration_fingerprint') == descriptor['configuration_fingerprint']:
                if state.get('state') == 'needs_repair': raise ManagedRuntimeError(state.get('detail','Private OpenClaw needs repair in Settings.'))
                if state.get('state') == 'healthy' and requested_at <= state.get('checked_at',0) and time.time() - state.get('checked_at',0) < 45: return descriptor
        except (OSError, ValueError): pass
        if not requested:
            request_recovery(path); requested = True
        if status: status('Waiting for TaskPilot’s private OpenClaw Gateway to recover…')
        sleep(1)  # SIGTERM/Stop interrupts this, including when provider is idle.

def relocate(path):
    with locked(path.parent):
        d = load_descriptor(path)
        port = private_port()
        config = Path(d['config']); value = json.loads(config.read_text())
        value['gateway']['port'] = port
        bounded_run([d['executable'], 'config', 'patch', '--stdin'],
                    input_data=json.dumps({'gateway':{'port':port}}).encode(), env=isolated_environment())
        atomic_json(config, value)
        d.update(port=port, endpoint=f'ws://127.0.0.1:{port}')
        d['configuration_fingerprint'] = hashlib.sha256((d['configuration_fingerprint'] + str(port)).encode()).hexdigest()
        atomic_json(path, d)
        return d


def command(operation, resources=None, descriptor=None):
    path = Path(descriptor) if descriptor else ROOT / 'runtime.json'
    if operation == 'ensure':
        key = __import__('sys').stdin.readline(8192).strip()
        result = ensure(Path(resources), path.parent, key)
    elif operation == 'relocate': result = relocate(path)
    elif operation == 'rollback': result = rollback(path)
    else: raise ManagedRuntimeError('Unsupported managed runtime operation.')
    print(json.dumps(result, separators=(',', ':')))
    return 0

def mark_working(path):
    with locked(path.parent):
        d = load_descriptor(path)
        atomic_json(path.parent / 'working-runtime.json', d)
        atomic_json(path.parent / 'working-config.json', json.loads(Path(d['config']).read_text()))

def rollback(path):
    with locked(path.parent):
        d = load_descriptor(path.parent / 'working-runtime.json')
        if not validate_install(Path(d['node']).parents[2], d['installation_fingerprint']):
            raise ManagedRuntimeError('The last working OpenClaw installation is unavailable; reconfigure in Settings.')
        configuration = json.loads((path.parent / 'working-config.json').read_text())
        bounded_run([d['executable'], 'config', 'patch', '--stdin'],
                    input_data=json.dumps(configuration).encode(), env=isolated_environment())
        atomic_json(Path(d['config']), configuration)
        failed = load_descriptor(path)
        atomic_json(path.parent / 'rejected-installation.json', {'fingerprint':failed['installation_fingerprint']})
        atomic_json(path, d)
        return d
