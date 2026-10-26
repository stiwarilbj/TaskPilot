"""TaskPilot-owned, pinned OpenClaw installation. Never discovers a shared CLI.

The descriptor is the only authority for paths and endpoint. Installation and
configuration are serialized; no task/provider data is written to diagnostics.
"""
from __future__ import annotations
import base64
import ctypes
import sqlite3
from contextlib import contextmanager, ExitStack, closing
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
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.request
import uuid

VERSION = 1
ROOT = Path.home() / 'Library/Application Support/Orbit Agent/ManagedOpenClaw'
INTEGRITY_CACHE_VERSION = 1
FULL_INTEGRITY_AUDIT_SECONDS = 60 * 60
INTEGRITY_READ_CHUNK_BYTES = 1024 * 1024
INTEGRITY_CACHE_MAX_BYTES = 64 * 1024 * 1024

class ManagedRuntimeError(RuntimeError): pass

class ACPConnectionError(ManagedRuntimeError):
    def __init__(self, cause):
        self.cause = cause
        self.code = 'transport_' + cause
        super().__init__('Private OpenClaw ACP connection failed (' + cause + '); supervised recovery is required.')

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

def digest(path):
    """Hash a file with bounded memory rather than loading the whole file."""
    hasher = hashlib.sha256()
    with Path(path).open('rb') as source:
        while chunk := source.read(INTEGRITY_READ_CHUNK_BYTES):
            hasher.update(chunk)
    return hasher.hexdigest()

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

def bounded_run(argv, *, env=None, timeout=45, cwd=None, input_data=None, result=False):
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
        if result: return code, text
        if code: raise ManagedRuntimeError('Managed runtime validation failed; the previous installation remains available.')
        return text

def seal(directory):
    # Hash the installed code, not only package.json. Excludes npm cache/logs.
    root = Path(directory).resolve(strict=True)
    files = {}
    for path in sorted(root.rglob('*')):
        if not path.is_file() or path.is_symlink() or path.name == 'integrity.json':
            continue
        name = str(path.relative_to(root))
        value, _ = _hash_installation_file(root, name)
        if value is None:
            raise ManagedRuntimeError('Managed installation changed while it was being sealed.')
        files[name] = value
    return files


def _regular_file_metadata(value):
    return {
        'device': int(value.st_dev),
        'inode': int(value.st_ino),
        'size': int(value.st_size),
        'mode': int(value.st_mode),
        'uid': int(value.st_uid),
        'gid': int(value.st_gid),
        'mtime_ns': int(value.st_mtime_ns),
        'ctime_ns': int(value.st_ctime_ns),
    }


def _has_symlink_component(root, relative_name):
    """Reject links in every path component, including links that stay in-root."""
    current = Path(root)
    for part in Path(relative_name).parts:
        current = current / part
        try:
            if stat.S_ISLNK(current.lstat().st_mode):
                return True
        except OSError:
            return True
    return False


def _hint_uncached_audit_read(descriptor):
    """Best-effort macOS cache policy; never participates in integrity decisions."""
    command = getattr(fcntl, 'F_NOCACHE', None)
    if platform.system() != 'Darwin' or command is None:
        return
    try:
        fcntl.fcntl(descriptor, command, 1)
    except OSError:
        # Filesystems may reject the hint. Keep the same checked hash path.
        pass


def _hash_installation_file(directory, relative_name, *, uncached=False):
    """Hash one sealed regular file and reject path or content races."""
    try:
        root = Path(directory).resolve(strict=True)
        root_before = root.stat()
        relative = Path(relative_name)
        if (not relative_name or relative.is_absolute() or
                any(part in ('', '.', '..') for part in relative.parts)):
            return None, None
        candidate = root.joinpath(*relative.parts)
        if _has_symlink_component(root, relative_name):
            return None, None
        resolved = candidate.resolve(strict=True)
        if not resolved.is_relative_to(root) or not resolved.is_file():
            return None, None
        flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)
        descriptor = os.open(resolved, flags)
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode):
                return None, None
            before_metadata = _regular_file_metadata(before)
            if uncached:
                _hint_uncached_audit_read(descriptor)
            hasher = hashlib.sha256()
            while True:
                try:
                    chunk = os.read(descriptor, INTEGRITY_READ_CHUNK_BYTES)
                except InterruptedError:
                    continue
                if not chunk:
                    break
                hasher.update(chunk)
            after = os.fstat(descriptor)
            after_metadata = _regular_file_metadata(after)
            root_after = root.stat()
            if (before_metadata != after_metadata or candidate.resolve(strict=True) != resolved or
                    (root_before.st_dev, root_before.st_ino) != (root_after.st_dev, root_after.st_ino)):
                return None, None
            return hasher.hexdigest(), after_metadata
        finally:
            os.close(descriptor)
    except (OSError, RuntimeError, ValueError):
        return None, None


def _integrity_cache_location(directory, fingerprint, manifest_digest, identity):
    cache_root = Path(directory).parent / '.integrity-cache'
    key_payload = json.dumps({
        'version': INTEGRITY_CACHE_VERSION,
        'fingerprint': fingerprint,
        'manifest_digest': manifest_digest,
        'directory': identity,
    }, sort_keys=True, separators=(',', ':')).encode()
    cache_key = hashlib.sha256(key_payload).hexdigest()
    return cache_root, cache_key


def _read_integrity_manifest(directory, fingerprint):
    root = Path(directory).resolve(strict=True)
    root_stat = root.stat()
    identity = {
        'path': str(root),
        'device': int(root_stat.st_dev),
        'inode': int(root_stat.st_ino),
    }
    manifest_path = root / 'integrity.json'
    if manifest_path.is_symlink():
        return None
    manifest_bytes = manifest_path.read_bytes()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    record = json.loads(manifest_bytes)
    if not isinstance(record, dict):
        return None
    files = record.get('files')
    if record.get('fingerprint') != fingerprint or not isinstance(files, dict) or not files:
        return None
    for name, expected in files.items():
        if (not isinstance(name, str) or not isinstance(expected, str) or len(expected) != 64 or
                any(character not in '0123456789abcdef' for character in expected)):
            return None
        relative = Path(name)
        if relative.is_absolute() or any(part in ('', '.', '..') for part in relative.parts):
            return None
    cache_root, cache_key = _integrity_cache_location(root, fingerprint, manifest_digest, identity)
    return root, identity, manifest_digest, files, cache_root, cache_key


def _valid_integrity_cache(cache, fingerprint, manifest_digest, identity, files):
    if not isinstance(cache, dict) or set(cache) != {
            'version', 'fingerprint', 'manifest_digest', 'directory',
            'last_full_audit_monotonic_ns', 'files'}:
        return False
    cached_identity = cache.get('directory')
    if (not isinstance(cached_identity, dict) or set(cached_identity) != {'path', 'device', 'inode'} or
            not isinstance(cached_identity.get('path'), str) or
            type(cached_identity.get('device')) is not int or cached_identity['device'] < 0 or
            type(cached_identity.get('inode')) is not int or cached_identity['inode'] < 0):
        return False
    if (type(cache.get('version')) is not int or cache.get('version') != INTEGRITY_CACHE_VERSION or
            cache.get('fingerprint') != fingerprint or
            cache.get('manifest_digest') != manifest_digest or cached_identity != identity):
        return False
    cached_files = cache.get('files')
    if not isinstance(cached_files, dict) or set(cached_files) != set(files):
        return False
    for name, expected in files.items():
        entry = cached_files.get(name)
        if not isinstance(entry, dict) or set(entry) != {'digest', 'metadata'} or entry.get('digest') != expected:
            return False
        metadata = entry.get('metadata')
        if not isinstance(metadata, dict) or set(metadata) != {
                'device', 'inode', 'size', 'mode', 'uid', 'gid', 'mtime_ns', 'ctime_ns'}:
            return False
        if any(type(value) is not int or value < 0 for value in metadata.values()):
            return False
    timestamp = cache.get('last_full_audit_monotonic_ns')
    return type(timestamp) is int and timestamp >= 0


def _write_integrity_cache(cache_root, cache_key, cache):
    _prepare_integrity_cache_root(cache_root)
    atomic_json(cache_root / (cache_key + '.json'), cache)


def _prepare_integrity_cache_root(cache_root):
    cache_root = Path(cache_root)
    cache_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    value = cache_root.lstat()
    if (not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid()):
        raise OSError('Integrity cache directory is not privately owned.')
    if stat.S_IMODE(value.st_mode) != 0o700:
        os.chmod(cache_root, 0o700)


def validate_install(directory, fingerprint, *, force_full=False, now_monotonic_ns=None, stats=None):
    """Validate the seal, reusing digests only while the file identity is unchanged.

    Cache failures never authorize a file: they cause a full uncached hash pass.
    A changed file is always rehashed against the immutable integrity manifest.
    The native host also passes force_full for installation notification hints:
    discard digest reuse, not the prior inode baseline or expected seal values.
    Missed/unsupported notifications never replace metadata checks or audit age.
    """
    result = stats if stats is not None else {}
    result.clear()
    result.update(audit_mode='full', cache_hits=0, files_hashed=0, bytes_hashed=0,
                  integrity_passed=False)
    cache_fd = None
    cache_path = None
    cache_root = None
    cache_key = None
    try:
        loaded = _read_integrity_manifest(directory, fingerprint)
        if loaded is None:
            return False
        root, identity, manifest_digest, files, cache_root, cache_key = loaded
        cache_path = cache_root / (cache_key + '.json')

        # A nonblocking lock avoids making health checks wait behind another
        # validator. Without the lock, verify every file and do not write cache.
        try:
            _prepare_integrity_cache_root(cache_root)
            cache_fd = os.open(cache_root / (cache_key + '.lock'),
                               os.O_CREAT | os.O_RDWR | getattr(os, 'O_CLOEXEC', 0) |
                               getattr(os, 'O_NOFOLLOW', 0), 0o600)
            lock_stat = os.fstat(cache_fd)
            if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.getuid():
                os.close(cache_fd)
                cache_fd = None
                raise OSError('Integrity cache lock is not privately owned.')
            if stat.S_IMODE(lock_stat.st_mode) != 0o600:
                os.fchmod(cache_fd, 0o600)
            try:
                fcntl.flock(cache_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(cache_fd)
                cache_fd = None
        except OSError:
            if cache_fd is not None:
                os.close(cache_fd)
                cache_fd = None

        cache = None
        if cache_fd is not None:
            try:
                if not cache_path.is_symlink() and cache_path.stat().st_size <= INTEGRITY_CACHE_MAX_BYTES:
                    cache = json.loads(cache_path.read_text())
            except (OSError, ValueError, UnicodeError):
                cache = None
        cache_valid = _valid_integrity_cache(cache, fingerprint, manifest_digest, identity, files)
        now = time.monotonic_ns() if now_monotonic_ns is None else now_monotonic_ns
        if type(now) is not int or now < 0:
            now = time.monotonic_ns()
            force_full = True
        cache_time = cache.get('last_full_audit_monotonic_ns') if cache_valid else None
        full_due = (not cache_valid or type(cache_time) is not int or now < cache_time or
                    now - cache_time >= FULL_INTEGRITY_AUDIT_SECONDS * 1_000_000_000)
        do_full = force_full or full_due or cache_fd is None
        result['audit_mode'] = 'full' if do_full else 'incremental'
        # Keep the prior inode baseline even during scheduled full audits so
        # replacing a sealed path with a same-content file is still detected.
        previous_files = cache.get('files', {}) if cache_valid else {}
        verified = {}
        for name, expected in files.items():
            # Resolve and stat on every pass. A matching metadata tuple permits
            # digest reuse, but the seal's expected digest remains authoritative.
            if not do_full:
                try:
                    current_root = root.stat()
                    if (current_root.st_dev, current_root.st_ino) != (identity['device'], identity['inode']):
                        return False
                    candidate = root / name
                    if _has_symlink_component(root, name):
                        return False
                    resolved = candidate.resolve(strict=True)
                    if not resolved.is_relative_to(root):
                        return False
                    current = _regular_file_metadata(resolved.stat())
                except (OSError, RuntimeError, ValueError):
                    return False
                old = previous_files[name]
                if not do_full and old['digest'] == expected and old['metadata'] == current:
                    verified[name] = old
                    result['cache_hits'] += 1
                    continue

            actual, metadata = _hash_installation_file(root, name, uncached=do_full)
            result['files_hashed'] += 1
            if metadata is not None:
                result['bytes_hashed'] += metadata['size']
            if actual is None or actual != expected:
                return False
            old = previous_files.get(name)
            if old is not None and (old['metadata']['device'], old['metadata']['inode']) != (
                    metadata['device'], metadata['inode']):
                return False
            verified[name] = {'digest': expected, 'metadata': metadata}

        final_root = root.stat()
        if (final_root.st_dev, final_root.st_ino) != (identity['device'], identity['inode']):
            return False

        # A successful full pass is the only operation that advances the
        # integrity audit age. Incremental checks cannot defer it.
        if do_full:
            last_full = now if now_monotonic_ns is not None else time.monotonic_ns()
        else:
            last_full = cache_time
        result['integrity_passed'] = True
        if cache_fd is not None:
            next_cache = {
                'version': INTEGRITY_CACHE_VERSION,
                'fingerprint': fingerprint,
                'manifest_digest': manifest_digest,
                'directory': identity,
                'last_full_audit_monotonic_ns': last_full,
                'files': verified,
            }
            if next_cache != cache:
                try:
                    _write_integrity_cache(cache_root, cache_key, next_cache)
                except OSError:
                    # Validation is already proven from file contents. A cache
                    # failure cannot corrupt the seal or readiness. If this was
                    # an incremental pass, confirm every file without cache
                    # reuse before returning success.
                    if not do_full:
                        result['integrity_passed'] = False
                        result['audit_mode'] = 'full'
                        retry_verified = {}
                        for name, expected in files.items():
                            actual, metadata = _hash_installation_file(root, name, uncached=True)
                            result['files_hashed'] += 1
                            if metadata is not None:
                                result['bytes_hashed'] += metadata['size']
                            if actual is None or actual != expected:
                                return False
                            old = previous_files.get(name)
                            if old is not None and (old['metadata']['device'], old['metadata']['inode']) != (
                                    metadata['device'], metadata['inode']):
                                return False
                            retry_verified[name] = {'digest': expected, 'metadata': metadata}
                        verified = retry_verified
                        result['integrity_passed'] = True
        return True
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, json.JSONDecodeError):
        return False
    finally:
        if cache_fd is not None:
            try:
                fcntl.flock(cache_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(cache_fd)

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

def managed_environment(inherited, node=None):
    """Policy v1 shared with Swift. The diagnostic bitmask never hashes values."""
    prefixes = ('OPENCLAW_', 'NODE_', 'NPM_', 'npm_', 'GOOGLE_', 'GEMINI_')
    env = {k:v for k,v in inherited.items() if not k.startswith(prefixes + ('LC_',))}
    env.pop('LANGUAGE', None)
    env.update(LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8',
               PATH=(str(Path(node).parent) + ':' if node else '') + '/usr/bin:/bin:/usr/sbin:/sbin',
               OPENCLAW_HIDE_BANNER='1', OPENCLAW_SUPPRESS_NOTES='1', OPENCLAW_NO_RESPAWN='1')
    proxies = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    for name in proxies:
        value = inherited.get(name, inherited.get(name.lower()))
        if value is not None: env[name] = env[name.lower()] = value
    code = 1 if any(k.startswith(('NODE_', 'NPM_', 'npm_')) for k in inherited) else 0
    if any(inherited.get(k) != env.get(k) for k in inherited.keys() | env.keys()
           if k in ('LANG', 'LANGUAGE') or k.startswith('LC_')): code |= 2
    if any(inherited.get(k) != env.get(k) for name in proxies for k in (name, name.lower())): code |= 4
    if inherited.get('PATH') != env.get('PATH'): code |= 8
    return env, {'version': 1, 'mismatch_code': code}


def isolated_environment():
    return managed_environment(dict(os.environ))[0]


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

def ensure(resources: Path, root: Path = ROOT, key: str = '', *, drained=False):
    from request_policy import configuration_transaction
    with configuration_transaction(), locked(root), ExitStack() as cleanup:
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
        port = previous['port'] if previous else private_port()
        desired = desired_settings(workspace, token, port)
        # Save a compatible snapshot before promoting a changed installation.
        if previous and previous['installation_fingerprint'] != fingerprint:
            atomic_json(root / 'previous-runtime.json', previous)
            if config.exists(): shutil.copyfile(config, state / 'previous-config.json')
        try: current_config = json.loads(config.read_text())
        except (OSError, ValueError): current_config = {}
        config_changed = drained or not contains_settings(current_config, desired) or set(current_config.get('agents', {}).get('defaults', {}).get('models', {})) != set(desired['agents']['defaults']['models'])
        offline = False
        if config_changed:
            cleanup.enter_context(configuration_hold(root, already_drained=drained)); offline = True
            require_offline(root)
            atomic_json(config, merge_settings(current_config, desired))
        auth = state / 'agents/main/agent/auth-profiles.json'
        key_record = state / 'credential-fingerprint.json'
        if key and len(key.strip()) < 20:
            raise ManagedRuntimeError('Save a complete Gemini API key in TaskPilot Settings.')
        wrapper = state / 'openclaw'
        node = target / 'node/bin/node'; entry = target / 'package/node_modules/openclaw/openclaw.mjs'
        # Absolute executable and a clean environment: no ambient shared profile.
        script = wrapper_script(state, config, node, entry)
        if not wrapper.exists() or wrapper.read_text() != script:
            temp = wrapper.with_suffix('.new'); temp.write_text(script); temp.chmod(0o700); temp.replace(wrapper)
        # The pinned release stores authoritative configuration in SQLite and
        # exports JSON. Replacing JSON alone is reverted by the next command.
        if config_changed:
            bounded_run([str(wrapper), 'config', 'patch', '--stdin', '--replace-path', 'agents.defaults.models'],
                        input_data=json.dumps(desired).encode(), env=isolated_environment())
            verify_settings(wrapper, desired)
        if key:
            key_fingerprint = hashlib.sha256(key.strip().encode()).hexdigest()
            try: saved_fingerprint = json.loads(key_record.read_text()).get('fingerprint')
            except (OSError, ValueError): saved_fingerprint = None
            if saved_fingerprint != key_fingerprint or not credential_present(state):
                if not offline: cleanup.enter_context(configuration_hold(root, already_drained=drained)); offline = True
                require_offline(root)
                # Only our private legacy file can exist here. Do not invoke doctor
                # or import any shared store. The supported auth command writes
                # OpenClaw's current credential schema (SQLite in this release).
                auth.unlink(missing_ok=True)
                bounded_run([str(wrapper), 'models', 'auth', 'paste-api-key',
                    '--provider', 'google', '--profile-id', 'google:orbit'],
                    input_data=(key.strip() + '\n').encode(), env=isolated_environment())
            try: saved_key = (root.parent / 'gemini-api-key').read_text().strip()
            except OSError: saved_key = ''
            atomic_json(key_record, {'fingerprint':key_fingerprint,
                                    'verification_until':time.time() + 300 if saved_key and saved_key != key.strip() else 0})
        descriptor = {'version':VERSION, 'instance_id':identity, 'installation_fingerprint':fingerprint,
            'openclaw_version':manifest['openclaw_version'], 'node_version':manifest['node_version'],
            'node':str(node),'entry':str(entry),'executable':str(wrapper),'state':str(state),
            'config':str(config),'workspace':str(workspace),'token_file':str(token), 'port':port,
            'endpoint':f'ws://127.0.0.1:{port}',
            'configuration_fingerprint':configuration_fingerprint(desired, key_record)}
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
        return d
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ManagedRuntimeError('TaskPilot private OpenClaw is not installed or its descriptor is invalid.') from error

def activate_environment(path):
    d = load_descriptor(path)
    env, diagnostic = managed_environment(dict(os.environ), d['node'])
    # Best-effort, bounded, content-free record. Diagnostic I/O never blocks readiness.
    record = path.parent / 'environment-diagnostics.json'
    try:
        if not record.exists() or record.stat().st_size > 256 or json.loads(record.read_text()) != diagnostic:
            atomic_json(record, diagnostic)
    except ValueError:
        try: atomic_json(record, diagnostic)
        except OSError: pass
    except OSError:
        pass
    os.environ.clear(); os.environ.update(env)
    os.environ.update(OPENCLAW_STATE_DIR=d['state'], OPENCLAW_CONFIG_PATH=d['config'],
        OPENCLAW_PROFILE='taskpilot', ORBIT_OPENCLAW_PATH=d['executable'],
        TASKPILOT_MANAGED_DESCRIPTOR=str(path),
        TASKPILOT_MANAGED_FINGERPRINT=d['instance_id'] + ':' + d['installation_fingerprint'] + ':' + d['configuration_fingerprint'])
    return d

def request_recovery(path, *, fault=False):
    # Coalesced signal contains no request/task contents. Host owns the budget.
    atomic_json(path.parent / 'health-request.json', {'requested':time.time(), 'fault':fault})

def wait_for_health(path, *, sleep=time.sleep, now=time.monotonic, status=None, force=False):
    requested_at = time.time() if force else 0
    requested = False
    while True:
        try:
            state = json.loads((path.parent / 'health.json').read_text())
            descriptor = load_descriptor(path)
            if state.get('instance_id') == descriptor['instance_id'] and state.get('configuration_fingerprint') == descriptor['configuration_fingerprint']:
                if state.get('state') == 'needs_repair': raise ManagedRuntimeError(state.get('detail','Private OpenClaw needs repair in Settings.'))
                if healthy_record(state, descriptor, requested_at=requested_at): return descriptor
        except (OSError, ValueError): pass
        if not requested:
            request_recovery(path, fault=force); requested = True
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
        d['configuration_fingerprint'] = configuration_fingerprint(desired_settings(d['workspace'], Path(d['token_file']), port), Path(d['state']) / 'credential-fingerprint.json')
        atomic_json(path, d)
        return d


def command(operation, resources=None, descriptor=None, *, force_integrity=False):
    path = Path(descriptor) if descriptor else ROOT / 'runtime.json'
    if operation == 'ensure':
        key = __import__('sys').stdin.readline(8192).strip()
        result = ensure(Path(resources), path.parent, key)
    elif operation == 'audit': result = audit(path, force_integrity=force_integrity)
    elif operation == 'repair': result = repair(path, Path(resources))
    elif operation == 'relocate':
        require_offline(path.parent)
        result = relocate(path)
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
    require_offline(path.parent)
    with locked(path.parent):
        d = load_descriptor(path.parent / 'working-runtime.json')
        if not validate_install(Path(d['node']).parents[2], d['installation_fingerprint'], force_full=True):
            raise ManagedRuntimeError('The last working OpenClaw installation is unavailable; reconfigure in Settings.')
        failed = load_descriptor(path)
        if d['installation_fingerprint'] == failed['installation_fingerprint']:
            raise ManagedRuntimeError('No different verified compatible installation is available for rollback.')
        configuration = json.loads((path.parent / 'working-config.json').read_text())
        bounded_run([d['executable'], 'config', 'patch', '--stdin'],
                    input_data=json.dumps(configuration).encode(), env=isolated_environment())
        atomic_json(Path(d['config']), configuration)
        atomic_json(path.parent / 'rejected-installation.json', {'fingerprint':failed['installation_fingerprint']})
        atomic_json(path, d)
        return d


def process_identity(pid):
    """Same PROC_PIDTBSDINFO birth identity used by native ProcessSupport.

    Do not accept kill(pid, 0): a reused PID is a different owner. Fail closed on
    unsupported platforms, inaccessible processes, and zombies.
    """
    if platform.system() != 'Darwin' or type(pid) is not int or pid <= 0: return None
    class BSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in
                    ('flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','reserved')]
        _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
        _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles','pgid','jobc','tdev','tpgid','nice')]
        _fields_ += [('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]
    try:
        lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        info = BSDInfo()
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info) or info.status == 5: return None
        return dict(pid=info.pid, seconds=info.seconds, microseconds=info.microseconds)
    except (OSError, AttributeError): return None


def identity_alive(value):
    return (isinstance(value, dict) and set(value) == {'pid','seconds','microseconds'} and
            all(type(v) is int and v >= 0 for v in value.values()) and
            process_identity(value['pid']) == value)


def healthy_record(record, descriptor, *, requested_at=0, wall_time=None):
    checked = record.get('checked_at')
    return (record.get('version') == VERSION and record.get('state') == 'healthy' and
            record.get('instance_id') == descriptor['instance_id'] and
            record.get('installation_fingerprint') == descriptor['installation_fingerprint'] and
            record.get('configuration_fingerprint') == descriptor['configuration_fingerprint'] and
            type(checked) in (int, float) and requested_at <= checked and
            0 <= (time.time() if wall_time is None else wall_time) - checked < 45 and
            identity_alive(record.get('host_identity')) and identity_alive(record.get('gateway_identity')))


def require_offline(root):
    # The supervisor must drain its owned tree before any offline CLI writer.
    for name in ('gateway-root.json', 'gateway-processes.json'):
        try:
            value = json.loads((root / name).read_text())
            if any(identity_alive(v) for v in (value if isinstance(value, list) else [value])):
                raise ManagedRuntimeError('Private Gateway must finish drainage before configuration repair.')
        except (OSError, ValueError): pass


def contains_settings(actual, expected):
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(k in actual and contains_settings(actual[k], v) for k,v in expected.items())
    return type(actual) is type(expected) and actual == expected


def verify_settings(wrapper, expected):
    # Read back authoritative SQLite configuration using the supported CLI.
    # Only managed top-level keys are compared; CLI metadata is not our setting.
    for key, value in expected.items():
        actual = json.loads(bounded_run([str(wrapper), 'config', 'get', key, '--json'], env=isolated_environment()))
        if key == 'gateway' and isinstance(actual, dict) and actual.get('auth', {}).get('token') == '__OPENCLAW_REDACTED__':
            value = {**value, 'auth':{**value['auth'], 'token':'__OPENCLAW_REDACTED__'}}
        if not contains_settings(actual, value):
            raise ManagedRuntimeError('Private configuration readback did not match TaskPilot settings.')


def credential_present(state):
    # Shared auth profiles are stored in this instance's machine database in
    # the pinned release; per-agent overrides may live in the agent database.
    sources = [('state/openclaw.sqlite','config_machine_state','value_json',"state_key = 'authProfiles.store'"),
               ('agents/main/agent/openclaw-agent.sqlite','auth_profile_store','store_json',"store_key = 'primary'")]
    for name, table, column, predicate in sources:
        database = Path(state) / name
        try:
            with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=1)) as connection:
                row = connection.execute(f"SELECT 1 FROM {table} WHERE {predicate} AND json_extract({column}, '$.profiles.\"google:orbit\".provider') = 'google' AND json_extract({column}, '$.profiles.\"google:orbit\".type') = 'api_key' AND json_type({column}, '$.profiles.\"google:orbit\".key') = 'text' AND length(json_extract({column}, '$.profiles.\"google:orbit\".key')) > 0 LIMIT 1").fetchone()
                if row is not None: return True
        except (OSError, sqlite3.Error): continue
    return False


def direct_command(descriptor):
    directory = Path(descriptor['node']).parents[2]
    if not validate_install(directory, descriptor['installation_fingerprint']):
        raise ManagedRuntimeError('Private installation integrity failed; waiting for supervised repair.')
    return [descriptor['node'], descriptor['entry']]


def handshake_cause(error):
    if isinstance(error, ACPConnectionError): return error.cause
    text = str(error).lower()
    if 'unsupported acp version' in text: return 'incompatible'
    if any(v in text for v in ('unauthorized','authentication','invalid token','token mismatch')): return 'authentication'
    if any(v in text for v in ('timeout','timed out')): return 'timeout'
    if any(v in text for v in ('econnrefused','connection refused')): return 'refused'
    if any(v in text for v in ('invalid json','invalid frame','malformed','protocol')): return 'malformed'
    return 'startup'


def audit(path, *, force_integrity=False):
    started = time.monotonic()
    d = load_descriptor(path)
    faults = []
    integrity_stats = {}
    installation_ok = validate_install(Path(d['node']).parents[2], d['installation_fingerprint'],
                                        force_full=force_integrity, stats=integrity_stats)
    if not installation_ok: faults.append('installation')
    try:
        if Path(d['executable']).read_text() != wrapper_script(d['state'], d['config'], d['node'], d['entry']) or not os.access(d['executable'], os.X_OK): faults.append('wrapper')
    except (OSError, UnicodeError): faults.append('wrapper')
    try:
        config = json.loads(Path(d['config']).read_text())
        from request_policy import ALL_MODELS
        required = desired_settings(d['workspace'], Path(d['token_file']), d['port'])
        key_record = Path(d['state']) / 'credential-fingerprint.json'
        expected_fingerprint = configuration_fingerprint(required, key_record)
        if expected_fingerprint != d['configuration_fingerprint']: faults.append('configuration_fingerprint')
        if not contains_settings(config, required) or set(config.get('agents', {}).get('defaults', {}).get('models', {})) != set(ALL_MODELS): faults.append('configuration')
        if not faults: verify_settings(d['executable'], required)
    except (OSError, ValueError, ManagedRuntimeError): faults.append('configuration')
    if not credential_present(d['state']): faults.append('credential_store')
    try:
        saved_key = (path.parent.parent / 'gemini-api-key').read_text().strip()
        record = json.loads((Path(d['state']) / 'credential-fingerprint.json').read_text())
        key_matches = hashlib.sha256(saved_key.encode()).hexdigest() == record['fingerprint']
        # Explicit Check may temporarily install an unsaved candidate. It cannot
        # displace the saved key indefinitely after cancellation or failure.
        until = record.get('verification_until', 0)
        checking = type(until) in (int, float) and 0 < until - time.time() <= 300
        if not key_matches and not checking: faults.append('credential_store')
    except (OSError, ValueError, KeyError): faults.append('credential_store')
    # Hash contents only for equality/budget identity, never persist raw config.
    parts = [d['installation_fingerprint'], d['configuration_fingerprint'], *sorted(set(faults))]
    for name in ('config','executable'):
        try: parts.append(digest(d[name]))
        except OSError: parts.append('missing')
    fingerprint = hashlib.sha256(':'.join(parts).encode()).hexdigest()
    result = {'version':VERSION, 'ok':not faults, 'causes':sorted(set(faults)), 'fingerprint':fingerprint,
              'full_integrity_ok': integrity_stats.get('audit_mode') == 'full' and installation_ok,
              'environment': managed_environment(dict(os.environ), d['node'])[1],
              'integrity_audit': {key:integrity_stats.get(key) for key in
                  ('audit_mode','cache_hits','files_hashed','bytes_hashed','integrity_passed')},
              'elapsed_ms':round((time.monotonic()-started)*1000)}
    atomic_json(path.parent / 'audit.json', result)
    return result


def repair(path, resources):
    require_offline(path.parent)
    result = audit(path, force_integrity=True)
    if result['ok']: return load_descriptor(path)
    # Persist reservation before attempting repair; crashes cannot reset it.
    with locked(path.parent):
        record_path = path.parent / 'repair-budget.json'
        try: record = json.loads(record_path.read_text())
        except (OSError, ValueError): record = {}
        now = time.time()
        if record.get('fingerprint') == result['fingerprint'] and 0 <= now - record.get('attempted_at',0) < 600:
            raise ManagedRuntimeError('This private runtime defect was already repaired recently; waiting before another attempt.')
        atomic_json(record_path, {'fingerprint':result['fingerprint'], 'attempted_at':now})
    if 'installation' in result['causes']:
        try: return rollback(path)
        except (ManagedRuntimeError, OSError, ValueError): pass
    key_path = path.parent.parent / 'gemini-api-key'
    try: key = key_path.read_text().strip()
    except OSError: key = ''
    d = ensure(resources, path.parent, key, drained=True)
    if not audit(path, force_integrity=True)['ok']:
        raise ManagedRuntimeError('Private runtime repair did not pass readback; check the saved key or reinstall TaskPilot.')
    return d


@contextmanager
def configuration_hold(root, *, timeout=60, already_drained=False):
    """Ask the existing owner to drain, without killing it or starting another.

    A birth-bound request is removed in finally; the host also releases abandoned
    requests when this requester exits. It never needs our configuration lock.
    """
    try:
        require_offline(root)
        if not already_drained:
            try: health = json.loads((root / 'health.json').read_text())
            except (OSError, ValueError): health = {}
            if health.get('state') != 'stopped' and identity_alive(health.get('host_identity')):
                raise ManagedRuntimeError('The owner must suspend startup before configuration changes.')
    except ManagedRuntimeError:
        identity = process_identity(os.getpid())
        if identity is None: raise ManagedRuntimeError('Cannot establish configuration repair ownership.')
        request = root / 'configuration-request.json'
        token = str(uuid.uuid4())
        atomic_json(request, {'request_id':token, 'owner':identity})
        try:
            deadline = time.monotonic() + timeout
            while True:
                try:
                    ack = json.loads((root / 'configuration-ack.json').read_text())
                    if ack.get('request_id') == token:
                        require_offline(root)
                        break
                except (OSError, ValueError): pass
                if time.monotonic() >= deadline:
                    raise ManagedRuntimeError('Private Gateway could not safely drain for configuration repair.')
                time.sleep(0.1)
            yield
        finally:
            request.unlink(missing_ok=True)
    else:
        yield


def wrapper_script(state, config, node, entry):
    script = '#!/bin/sh\nunset OPENCLAW_HOME OPENCLAW_PROFILE OPENCLAW_GATEWAY_TOKEN OPENCLAW_GATEWAY_URL NODE_OPTIONS NODE_PATH\n'
    for name, value in {'OPENCLAW_STATE_DIR':str(state),'OPENCLAW_CONFIG_PATH':str(config),
                        'OPENCLAW_PROFILE':'taskpilot','OPENCLAW_NO_RESPAWN':'1',
                        'OPENCLAW_HIDE_BANNER':'1','OPENCLAW_SUPPRESS_NOTES':'1',
                        'LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8',
                        'PATH':str(Path(node).parent) + ':/usr/bin:/bin:/usr/sbin:/sbin'}.items():
        script += 'export ' + name + '=' + shlex.quote(value) + '\n'
    script += 'exec ' + shlex.quote(str(node)) + ' ' + shlex.quote(str(entry)) + ' "$@"\n'
    return script


def configuration_fingerprint(settings, key_record):
    return hashlib.sha256((json.dumps(settings,sort_keys=True) + (digest(key_record) if key_record.exists() else '')).encode()).hexdigest()


def desired_settings(workspace, token, port):
    from request_policy import ALL_MODELS
    return {'gateway':{'mode':'local','bind':'loopback','port':port,
                       'auth':{'mode':'token','token':Path(token).read_text()}},
            'agents':{'defaults':{'workspace':str(workspace),
                       'model':{'primary':ALL_MODELS[0],'fallbacks':list(ALL_MODELS[1:])},
                       'imageModel':{'primary':ALL_MODELS[0],'fallbacks':list(ALL_MODELS[1:])},
                       'models':{m:{} for m in ALL_MODELS}}},
            'plugins':{'enabled':True,'allow':['google'],'entries':{'google':{'enabled':True}}},
            'browser':{'enabled':False}}


def merge_settings(actual, desired):
    """Preserve unrelated metadata while replacing TaskPilot-owned leaves."""
    merged = dict(actual) if isinstance(actual, dict) else {}
    for key, value in desired.items():
        merged[key] = merge_settings(merged.get(key), value) if isinstance(value, dict) else value
    if 'agents' in desired:
        merged['agents']['defaults']['models'] = desired['agents']['defaults']['models']
    return merged
