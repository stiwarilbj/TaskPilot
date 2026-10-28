"""TaskPilot-owned, pinned OpenClaw installation. Never discovers a shared CLI.

The descriptor is the only authority for paths and endpoint. Installation and
configuration are serialized; no task/provider data is written to diagnostics.
"""
from __future__ import annotations
import base64
import ctypes
import errno
import sqlite3
from contextlib import contextmanager, ExitStack, closing
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import shutil
import socket
import stat
import struct
import subprocess
import tarfile
import tempfile
import threading
import time
import unicodedata
import urllib.request
import uuid

import runtime_descriptor_generated as descriptor_contract
from lock_order import LockCategory, reserve

VERSION = 1
ROOT = Path.home() / 'Library/Application Support/Orbit Agent/ManagedOpenClaw'
INTEGRITY_CACHE_VERSION = 1
FULL_INTEGRITY_AUDIT_SECONDS = 60 * 60
INTEGRITY_READ_CHUNK_BYTES = 1024 * 1024
INTEGRITY_CACHE_MAX_BYTES = 64 * 1024 * 1024
NATIVE_ADDON_FACTS_VERSION = 1
PROVISIONING_RESERVE_BYTES = 512 * 1024 * 1024
PROVISIONING_TEMPORARY_BYTES = 256 * 1024 * 1024
SQLITE_HEALTH_TIMEOUT_SECONDS = 0.75
SQLITE_BUSY_TIMEOUT_MILLISECONDS = 100
SQLITE_PROGRESS_INTERVAL = 500
SQLITE_HEALTH_FILES = ('openclaw.sqlite', 'agents/main/agent/openclaw-agent.sqlite')

class ManagedRuntimeError(RuntimeError): pass

class ConfigurationPathError(ManagedRuntimeError):
    code = 'private_configuration_path_changed'

class ProvisioningResourceError(ManagedRuntimeError):
    def __init__(self, phase, required=None, available=None):
        self.code = 'local_resource_disk_space' if available is not None else 'local_resource_disk_space_check'
        self.phase, self.required_bytes, self.available_bytes = phase, required, available
        if available is None:
            detail = 'Could not check available disk space before private OpenClaw provisioning. Check the storage volume and retry.'
        else:
            mib = 1024 * 1024
            needed = (required + mib - 1) // mib
            free = available // mib
            detail = (f'Not enough disk space before private OpenClaw {phase}: '
                      f'at least {needed} MiB free is needed; {free} MiB is available. Free disk space and retry.')
        super().__init__(self.code + ': ' + detail + ' The current working runtime was left intact.')


def provisioning_space(manifest):
    """Pinned estimates, not measured requirements or an integrity assertion."""
    value = manifest.get('provisioning_space')
    names = ('node_archive_bytes', 'node_expanded_bytes', 'package_archive_bytes', 'package_expanded_bytes')
    if (not isinstance(value, dict) or set(value) != {'version', *names} or
            type(value['version']) is not int or value['version'] != 1 or
            any(type(value[name]) is not int or not 0 < value[name] <= 64 * 1024**3 for name in names) or
            value['node_expanded_bytes'] < value['node_archive_bytes'] or
            value['package_expanded_bytes'] < value['package_archive_bytes']):
        raise ManagedRuntimeError('Bundled OpenClaw provisioning space estimates are invalid; reinstall TaskPilot.')
    return value


def require_provisioning_space(directory, manifest, phase):
    estimates = provisioning_space(manifest)
    # Free space already excludes allocated archives, Node and package files.
    # Count only the remaining peak allocations, never the active installation.
    remaining = {
        'download': ('node_archive_bytes', 'node_expanded_bytes', 'package_archive_bytes', 'package_expanded_bytes'),
        'extraction': ('node_expanded_bytes', 'package_archive_bytes', 'package_expanded_bytes'),
        'npm installation': ('package_archive_bytes', 'package_expanded_bytes'),
        'promotion': (),
    }
    required = PROVISIONING_RESERVE_BYTES + sum(estimates[key] for key in remaining[phase])
    if phase != 'promotion': required += PROVISIONING_TEMPORARY_BYTES
    try:
        available = shutil.disk_usage(directory).free
        if type(available) is not int or available < 0: raise ValueError()
    except (OSError, ValueError, OverflowError) as error:
        raise ProvisioningResourceError(phase) from error
    if available < required: raise ProvisioningResourceError(phase, required, available)


class PrivateDirectoryError(ManagedRuntimeError):
    def __init__(self, code):
        self.code = 'private_directory_' + code
        super().__init__(self.code + ': TaskPilot private storage needs attention; verify ownership and permissions.')


def _extended_acl_entry_count(fd):
    """Return the number of extended ACL entries, failing closed if unreadable."""
    library = ctypes.CDLL(None, use_errno=True)
    getter = getattr(library, 'acl_get_fd_np', None)
    entry_getter = getattr(library, 'acl_get_entry', None)
    free = getattr(library, 'acl_free', None)
    if getter is None or entry_getter is None or free is None:
        raise OSError(errno.ENOTSUP, 'extended ACL inspection is unavailable')
    getter.argtypes = (ctypes.c_int, ctypes.c_int)
    getter.restype = ctypes.c_void_p
    entry_getter.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p))
    entry_getter.restype = ctypes.c_int
    free.argtypes = (ctypes.c_void_p,)
    free.restype = ctypes.c_int
    ctypes.set_errno(0)
    acl = getter(fd, 0x100)  # Darwin ACL_TYPE_EXTENDED
    if not acl:
        error = ctypes.get_errno()
        # Darwin reports ENOENT when the vnode has no extended ACL.
        if error == errno.ENOENT: return 0
        raise OSError(error or errno.EIO, 'extended ACL could not be inspected')
    try:
        count = 0
        entry = ctypes.c_void_p()
        while True:
            ctypes.set_errno(0)
            result = entry_getter(acl, 0 if count == 0 else -1, ctypes.byref(entry))
            if result == 0:
                count += 1
                if count > 128:
                    raise OSError(errno.EOVERFLOW, 'extended ACL entry limit exceeded')
                continue
            error = ctypes.get_errno()
            # macOS uses EINVAL to indicate end-of-list for acl_get_entry.
            if error == errno.EINVAL:
                return count
            raise OSError(error or errno.EIO, 'extended ACL could not be enumerated')
    finally:
        free(acl)


def _unexpected_private_directory_flags(flags):
    # Hiding and backup-exclusion flags do not grant access or inhibit cleanup.
    permitted = getattr(stat, 'UF_HIDDEN', 0) | getattr(stat, 'UF_NODUMP', 0)
    return bool(flags & ~permitted)


def check_private_directory(path, *, repair=False, allow_mode_drift=False):
    """Known directory only. No symlink following or recursive chmod."""
    path = Path(path)
    try:
        before = path.lstat()
        if stat.S_ISLNK(before.st_mode): raise PrivateDirectoryError('symlink')
        if not stat.S_ISDIR(before.st_mode): raise PrivateDirectoryError('unavailable')
        if before.st_uid != os.getuid(): raise PrivateDirectoryError('ownership')
        fd = os.open(path, getattr(os, 'O_EVTONLY', os.O_RDONLY) | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0))
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino, opened.st_uid) != (before.st_dev, before.st_ino, os.getuid()):
                raise PrivateDirectoryError('changed')
            if _unexpected_private_directory_flags(int(getattr(opened, 'st_flags', 0))):
                raise PrivateDirectoryError('flags')
            try:
                extended_acl_entries = _extended_acl_entry_count(fd)
            except OSError as error:
                raise PrivateDirectoryError('acl') from error
            if extended_acl_entries:
                # No ACL is removed automatically: provenance cannot be proved.
                raise PrivateDirectoryError('acl')
            if stat.S_IMODE(opened.st_mode) != 0o700:
                if repair: os.fchmod(fd, 0o700)
                elif not allow_mode_drift: raise PrivateDirectoryError('permissions')
            after, named = os.fstat(fd), path.lstat()
            if (after.st_dev, after.st_ino, after.st_uid) != (named.st_dev, named.st_ino, os.getuid()) or named.st_uid != os.getuid() or after.st_mode != named.st_mode or not stat.S_ISDIR(named.st_mode):
                raise PrivateDirectoryError('changed')
            if not allow_mode_drift and stat.S_IMODE(after.st_mode) != 0o700:
                raise PrivateDirectoryError('permissions')
        finally: os.close(fd)
    except OSError as error:
        raise PrivateDirectoryError('permissions' if error.errno in (errno.EACCES, errno.EPERM) else 'unavailable') from error


def managed_directory_paths(root, descriptor=None):
    try:
        return descriptor_contract.directory_paths(root, descriptor)
    except descriptor_contract.DescriptorError as error:
        raise PrivateDirectoryError('changed') from error


def check_managed_directories(root, descriptor=None, *, repair=False):
    paths = managed_directory_paths(root, descriptor)
    # Reject unexpected targets before repairing any known mode drift.
    for path in paths: check_private_directory(path, allow_mode_drift=repair)
    if repair:
        for path in paths: check_private_directory(path, repair=True)

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


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try: os.fsync(fd)
    finally: os.close(fd)


_MACH_CPU_ARCHITECTURES = {0x0100000C: 'arm64', 0x01000007: 'x86_64'}


def _version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', value):
        raise ManagedRuntimeError('Bundled OpenClaw compatibility version is invalid.')
    return tuple(int(part) for part in (value.split('.') + ['0'])[:3])


def runtime_compatibility(manifest):
    value = manifest.get('compatibility')
    architectures = value.get('architectures') if isinstance(value, dict) else None
    archives = manifest.get('node_archives')
    if (not isinstance(value, dict) or set(value) != {'version', 'architectures', 'minimum_macos'} or
            type(value.get('version')) is not int or value['version'] != 1 or
            not isinstance(architectures, list) or not architectures or
            any(not isinstance(arch, str) for arch in architectures) or
            len(set(architectures)) != len(architectures) or
            any(arch not in {'arm64', 'x86_64'} for arch in architectures) or
            not isinstance(archives, dict) or set(architectures) - set(archives)):
        raise ManagedRuntimeError('Bundled OpenClaw architecture compatibility is invalid.')
    minimum = _version_tuple(value['minimum_macos'])
    return set(value['architectures']), minimum


def _read_exact(fd, offset, size, limit=1024 * 1024):
    if offset < 0 or size < 0 or size > limit:
        raise ManagedRuntimeError('Managed runtime binary metadata exceeds its bounds.')
    data = os.pread(fd, size, offset)
    if len(data) != size: raise ManagedRuntimeError('Managed runtime binary header is truncated.')
    return data


def _thin_mach_o_slice(fd, offset, size):
    magic = _read_exact(fd, offset, min(size, 4), limit=4)
    formats = {
        b'\xcf\xfa\xed\xfe': ('<', 32), b'\xfe\xed\xfa\xcf': ('>', 32),
        b'\xce\xfa\xed\xfe': ('<', 28), b'\xfe\xed\xfa\xce': ('>', 28),
    }
    if magic not in formats: return None
    endian, header_size = formats[magic]
    header = _read_exact(fd, offset, header_size, limit=64)
    cpu = struct.unpack_from(endian + 'i', header, 4)[0] & 0xffffffff
    if header_size == 32:
        command_count, command_bytes = struct.unpack_from(endian + 'II', header, 16)
    else:
        command_count, command_bytes = struct.unpack_from(endian + 'II', header, 16)
    if command_count > 4096 or command_bytes > 1024 * 1024 or header_size + command_bytes > size:
        raise ManagedRuntimeError('Managed runtime binary load commands exceed their bounds.')
    commands = _read_exact(fd, offset + header_size, command_bytes)
    cursor = 0; minimum = None
    for _ in range(command_count):
        if cursor + 8 > len(commands): raise ManagedRuntimeError('Managed runtime binary load command is truncated.')
        command, command_size = struct.unpack_from(endian + 'II', commands, cursor)
        if command_size < 8 or cursor + command_size > len(commands):
            raise ManagedRuntimeError('Managed runtime binary load command is invalid.')
        if command == 0x32 and command_size >= 24:  # LC_BUILD_VERSION
            encoded = struct.unpack_from(endian + 'I', commands, cursor + 12)[0]
            minimum = ((encoded >> 16) & 0xffff, (encoded >> 8) & 0xff, encoded & 0xff)
        elif command == 0x24 and command_size >= 16:  # LC_VERSION_MIN_MACOSX
            encoded = struct.unpack_from(endian + 'I', commands, cursor + 8)[0]
            minimum = ((encoded >> 16) & 0xffff, (encoded >> 8) & 0xff, encoded & 0xff)
        cursor += command_size
    architecture = _MACH_CPU_ARCHITECTURES.get(cpu)
    if architecture is None: return None
    return architecture, minimum


def inspect_mach_o(path):
    """Read bounded Mach-O headers through a no-follow descriptor."""
    return _inspect_mach_o_file(path)[1]


def _inspect_mach_o_file(path, *, cached_facts=None, expected_digest=None):
    """When caching, hash and parse the same open object before retaining facts."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0))
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > 512 * 1024 * 1024:
            raise ManagedRuntimeError('Managed runtime binary is not a bounded regular file.')
        digest_value = None
        if cached_facts is not None:
            hasher = hashlib.sha256(); bytes_read = 0
            while True:
                try: chunk = os.read(fd, INTEGRITY_READ_CHUNK_BYTES)
                except InterruptedError: continue
                if not chunk: break
                bytes_read += len(chunk)
                if bytes_read > before.st_size:
                    raise ManagedRuntimeError('Managed runtime binary changed during compatibility inspection.')
                hasher.update(chunk)
            digest_value = hasher.hexdigest()
            if expected_digest is not None and digest_value != expected_digest:
                raise ManagedRuntimeError('Native module does not match the installation seal.')
            cached = cached_facts.get(digest_value)
            if cached is not None:
                _check_binary_identity(path, fd, before)
                return digest_value, cached
        prefix = _read_exact(fd, 0, min(before.st_size, 8), limit=8)
        fat = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
               b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
        slices = []
        if prefix[:4] in fat:
            endian, fat64 = fat[prefix[:4]]
            if len(prefix) < 8: raise ManagedRuntimeError('Managed runtime universal binary header is truncated.')
            count = struct.unpack_from(endian + 'I', prefix, 4)[0]
            entry_size = 32 if fat64 else 20
            if count < 1 or count > 16: raise ManagedRuntimeError('Managed runtime universal binary has an invalid architecture count.')
            table = _read_exact(fd, 8, count * entry_size, limit=16 * 32)
            for index in range(count):
                entry = index * entry_size
                cpu = struct.unpack_from(endian + 'I', table, entry)[0]
                if fat64: slice_offset, slice_size = struct.unpack_from(endian + 'QQ', table, entry + 8)
                else: slice_offset, slice_size = struct.unpack_from(endian + 'II', table, entry + 8)
                if slice_offset + slice_size > before.st_size or slice_size <= 0:
                    raise ManagedRuntimeError('Managed runtime universal binary slice is invalid.')
                parsed = _thin_mach_o_slice(fd, slice_offset, slice_size)
                if parsed is not None and parsed[0] == _MACH_CPU_ARCHITECTURES.get(cpu): slices.append(parsed)
        else:
            parsed = _thin_mach_o_slice(fd, 0, before.st_size)
            if parsed is not None: slices.append(parsed)
        _check_binary_identity(path, fd, before)
        return digest_value, slices
    finally: os.close(fd)


def _check_binary_identity(path, fd, before):
    metadata = _regular_file_metadata(before)
    if metadata != _regular_file_metadata(os.fstat(fd)) or metadata != _regular_file_metadata(Path(path).lstat()):
        raise ManagedRuntimeError('Managed runtime binary changed during compatibility inspection.')


def verify_binary_compatibility(path, manifest, *, process_arch=None, macos_version=None, required=True):
    target = _binary_compatibility_target(manifest, process_arch, macos_version)
    return _verify_binary_slices(inspect_mach_o(path), target, required=required)


def _binary_compatibility_target(manifest, process_arch, macos_version):
    supported, minimum = runtime_compatibility(manifest)
    process_arch = process_arch or platform.machine()
    if process_arch not in supported:
        raise ManagedRuntimeError('This Mac architecture is not supported by the pinned private OpenClaw runtime.')
    if macos_version is None: macos_version = platform.mac_ver()[0]
    if macos_version and _version_tuple(macos_version) < minimum:
        raise ManagedRuntimeError('This macOS version is older than the bundled private runtime supports.')
    return dict(architecture=process_arch, macos_version=list(_version_tuple(macos_version)) if macos_version else None,
                minimum_macos=list(minimum), supported_architectures=sorted(supported))


def _verify_binary_slices(slices, target, *, required=True):
    if not slices and not required: return False
    matching = [minimum_os for architecture, minimum_os in slices if architecture == target['architecture']]
    if not matching or any(version is None for version in matching):
        raise ManagedRuntimeError('Staged OpenClaw binary does not declare a supported macOS architecture and minimum version.')
    if any(tuple(version) > tuple(target['macos_version'] or target['minimum_macos']) for version in matching):
        raise ManagedRuntimeError('Staged OpenClaw binary requires a newer macOS version than this app process.')
    return True


def _native_addon_cached_facts(facts, target, maximum_files):
    """Malformed or differently targeted facts are only cache misses."""
    if (not isinstance(facts, dict) or set(facts) != {'version', 'target', 'digests'} or
            type(facts['version']) is not int or facts['version'] != NATIVE_ADDON_FACTS_VERSION or
            not isinstance(facts['target'], dict) or facts['target'] != target or
            json.dumps(facts['target'], sort_keys=True) != json.dumps(target, sort_keys=True) or
            not isinstance(facts['digests'], dict) or
            len(facts['digests']) > maximum_files):
        return {}
    for digest_value, slices in facts['digests'].items():
        if (not isinstance(digest_value, str) or not re.fullmatch('[0-9a-f]{64}', digest_value) or
                not isinstance(slices, list) or len(slices) > 16): return {}
        for item in slices:
            if (not isinstance(item, list) or len(item) != 2 or not isinstance(item[0], str) or
                    item[0] not in _MACH_CPU_ARCHITECTURES.values()): return {}
            minimum = item[1]
            if minimum is not None and (not isinstance(minimum, list) or len(minimum) != 3 or
                    any(type(value) is not int or not 0 <= value <= limit
                        for value, limit in zip(minimum, (65535, 255, 255)))): return {}
    return facts['digests']


def verify_native_addons(package, manifest, *, process_arch=None, macos_version=None,
                         maximum_directories=8192, maximum_files=32768, timeout=30,
                         facts=None, sealed_files=None):
    """Reuse parsed facts only for a checked digest and the exact host/policy target.

    `facts` is an optional in/out seal extension. Every file is still hashed;
    recovered stages additionally require the seal's expected file digest.
    """
    started = time.monotonic(); directories = 0; files = 0; addons = 0
    root = Path(package).resolve(strict=True)
    root_identity = root.stat()
    target = _binary_compatibility_target(manifest, process_arch, macos_version)
    cached = dict(_native_addon_cached_facts(facts, target, maximum_files))
    inspected = {}; inspected_paths = set()
    for current, names, filenames in os.walk(root, followlinks=False):
        directories += 1; files += len(filenames)
        if (directories > maximum_directories or files > maximum_files or
                time.monotonic() - started > timeout):
            raise ManagedRuntimeError('Native module compatibility inspection exceeded its bounded work limit.')
        names[:] = [name for name in names if not (Path(current) / name).is_symlink()]
        for filename in filenames:
            if not filename.endswith('.node'): continue
            path = Path(current) / filename
            if path.is_symlink(): continue
            name = str(path.relative_to(root))
            if _has_symlink_component(root, name) or sealed_files is not None and name not in sealed_files:
                raise ManagedRuntimeError('Native module changed or does not match the installation seal.')
            value, slices = _inspect_mach_o_file(path, cached_facts=cached,
                                               expected_digest=sealed_files[name] if sealed_files is not None else None)
            if _has_symlink_component(root, name):
                raise ManagedRuntimeError('Native module changed during compatibility inspection.')
            inspected_paths.add(name)
            inspected[value] = cached[value] = [[arch, list(minimum) if minimum is not None else None]
                                               for arch, minimum in slices]
            if time.monotonic() - started > timeout:
                raise ManagedRuntimeError('Native module compatibility inspection exceeded its bounded work limit.')
            if not slices or not any(architecture == target['architecture'] for architecture, _ in slices):
                # Packages may ship alternative platform prebuilds beside the
                # host-selected module. OpenClaw's own --version launch above
                # already proves its eagerly loaded native dependencies resolve.
                continue
            if _verify_binary_slices(slices, target, required=False):
                addons += 1
                if addons > 512: raise ManagedRuntimeError('Native module compatibility inspection exceeded its file limit.')
    current_root = root.stat()
    if (root_identity.st_dev, root_identity.st_ino) != (current_root.st_dev, current_root.st_ino):
        raise ManagedRuntimeError('Native module directory changed during compatibility inspection.')
    if sealed_files is not None and inspected_paths != {name for name in sealed_files if name.endswith('.node')}:
        raise ManagedRuntimeError('Native module inventory does not match the installation seal.')
    if facts is not None:
        facts.clear()
        facts.update(version=NATIVE_ADDON_FACTS_VERSION, target=target, digests=inspected)
    return addons


class ProvisioningJournal:
    """One private transaction marker, held under the installation lock.

    A separate inherited lease prevents recovery while an orphaned installer or
    configuration child is still running. Markers are hints, never integrity or
    readiness proof. No executable paths, settings, tokens or keys are recorded.
    """
    phases = {'staging', 'sealing', 'sealed', 'promoting', 'promoted',
              'configuration', 'readback', 'activating', 'activated'}
    def __init__(self, root):
        self.root = Path(root)
        self.path = self.root / 'provisioning.json'
        self.fd = None

    def __enter__(self):
        check_private_directory(self.root)
        fd = os.open(self.root / 'provisioning-lease.lock',
                     os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                raise ManagedRuntimeError('Private provisioning lease needs attention.')
            os.fchmod(fd, 0o600)
            try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ManagedRuntimeError('A previous private provisioning helper is still finishing; try again after it exits.') from error
            self.fd = fd
            return self
        except BaseException:
            os.close(fd)
            raise

    def __exit__(self, *_):
        # Do not explicitly unlock: children may still hold this same lease
        # after controller death. Its final close releases kernel ownership.
        os.close(self.fd)
        self.fd = None

    @staticmethod
    def valid(record):
        if not isinstance(record, dict) or set(record) != {'version', 'phase', 'fingerprint', 'stage_id', 'stage_identity'}:
            return False
        if (type(record['version']) is not int or record['version'] != 1 or
                not isinstance(record['phase'], str) or record['phase'] not in ProvisioningJournal.phases):
            return False
        if not isinstance(record['fingerprint'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', record['fingerprint']):
            return False
        stage, identity = record['stage_id'], record['stage_identity']
        if stage is None:
            return identity is None and record['phase'] not in {'staging', 'sealing', 'sealed', 'promoting'}
        if not isinstance(stage, str) or not re.fullmatch(r'[0-9a-f]{32}', stage): return False
        if record['phase'] not in {'staging', 'sealing', 'sealed', 'promoting', 'promoted'}: return False
        if identity is None: return record['phase'] == 'staging'
        return (isinstance(identity, dict) and set(identity) == {'device', 'inode'} and
                all(type(v) is int and v >= 0 for v in identity.values()) and identity['inode'] > 0)

    def read(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                        stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > 4096):
                    raise ValueError()
                def unique(pairs):
                    result = {}
                    for key, value in pairs:
                        if key in result: raise ValueError()
                        result[key] = value
                    return result
                data = source.read(4097)
                if len(data) > 4096: raise ValueError()
                record = json.loads(data.decode('utf-8'), object_pairs_hook=unique)
                if not self.valid(record): raise ValueError()
                return record
        except FileNotFoundError: return None
        except (OSError, ValueError, TypeError, RecursionError) as error:
            raise ManagedRuntimeError('Private provisioning journal needs attention; the active installation was left unchanged.') from error

    def record(self, phase, fingerprint, stage_id=None, stage_identity=None):
        value = dict(version=1, phase=phase, fingerprint=fingerprint,
                     stage_id=stage_id, stage_identity=stage_identity)
        if self.fd is None or not self.valid(value): raise ManagedRuntimeError('Invalid private provisioning phase.')
        atomic_json(self.path, value)
        sync_directory(self.root)
        return value

    def clear(self):
        self.path.unlink(missing_ok=True)
        sync_directory(self.root)

    def run(self, argv, **kwargs):
        return bounded_run(argv, pass_fds=(self.fd,), **kwargs)

    def stage(self, record):
        if not self.valid(record) or record['stage_id'] is None:
            raise ManagedRuntimeError('Invalid private provisioning stage.')
        return self.root / 'installations' / ('.stage-' + record['stage_id'])

    def open_stage(self, record):
        stage = self.stage(record)
        try:
            fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except FileNotFoundError: return None
        except OSError as error:
            raise ManagedRuntimeError('Private provisioning staging identity changed; no staging data was removed.') from error
        info = os.fstat(fd)
        identity = {'device': info.st_dev, 'inode': info.st_ino}
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700 or record['stage_identity'] not in (None, identity):
            os.close(fd)
            raise ManagedRuntimeError('Private provisioning staging identity changed; no staging data was removed.')
        return fd

    def discard_stage(self, record):
        """Remove only the recorded staging object, using descriptor-relative IO."""
        check_private_directory(self.root / 'installations')
        fd = self.open_stage(record)
        if fd is None: return
        try:
            info = os.fstat(fd)
            # A crash between mkdir and binding its inode can leave only an
            # empty directory: no payload work starts before the binding write.
            if record['stage_identity'] is not None:
                if not shutil.rmtree.avoids_symlink_attacks:
                    raise ManagedRuntimeError('Safe private staging cleanup is unavailable on this platform.')
                with os.scandir(fd) as entries:
                    for entry in entries:
                        if entry.is_dir(follow_symlinks=False): shutil.rmtree(entry.name, dir_fd=fd)
                        else: os.unlink(entry.name, dir_fd=fd)
            parent = os.open(self.root / 'installations', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                name = self.stage(record).name
                current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    raise ManagedRuntimeError('Private provisioning staging identity changed; no replacement was removed.')
                try: os.rmdir(name, dir_fd=parent)
                except OSError as error:
                    if record['stage_identity'] is None and error.errno in (errno.ENOTEMPTY, errno.EEXIST):
                        raise ManagedRuntimeError('Unbound private provisioning stage is not empty; no data was removed.') from error
                    raise
                os.fsync(parent)
            finally: os.close(parent)
        finally: os.close(fd)

    def recover_stage(self, fingerprint):
        record = self.read()
        if record is None or record['stage_id'] is None: return None
        check_private_directory(self.root / 'installations')
        fd = self.open_stage(record)
        if fd is None: return None # Promotion may already have completed.
        os.close(fd)
        if (record['fingerprint'] == fingerprint and record['phase'] in {'sealed', 'promoting'} and
                validate_install(self.stage(record), fingerprint, force_full=True)):
            return record
        self.discard_stage(record)
        self.clear()
        return None

@contextmanager
def locked(root: Path, *, blocking=True):
    with reserve(LockCategory.INSTALLATION) as rank:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        check_private_directory(root, allow_mode_drift=True)
        fd = os.open(root / 'installation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0), 0o600)
        with os.fdopen(fd, 'a') as f:
            lock_stat = os.fstat(f.fileno())
            if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.getuid() or lock_stat.st_nlink != 1:
                raise PrivateDirectoryError('ownership')
            os.fchmod(f.fileno(), 0o600)
            with rank.waiting():
                fcntl.flock(f, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
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
    provisioning_space(manifest)
    runtime_compatibility(manifest)
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

def _identity_at(path, expected):
    path = Path(path)
    try: value = path.lstat()
    except FileNotFoundError: return None
    if (stat.S_ISLNK(value.st_mode) or value.st_uid != os.getuid() or
            expected == 'file' and value.st_nlink != 1):
        raise ConfigurationPathError('Private configuration identity needs attention.')
    if expected == 'directory' and not stat.S_ISDIR(value.st_mode):
        raise ConfigurationPathError('Private configuration directory changed.')
    if expected == 'file' and not stat.S_ISREG(value.st_mode):
        raise ConfigurationPathError('Private configuration file changed.')
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode), value.st_uid,
            value.st_nlink if expected == 'file' else None)


class ConfigurationPathFence:
    """Detect state/config path replacement around supported CLI operations."""
    def __init__(self, state, config):
        self.state, self.config = Path(state), Path(config)

    def snapshot(self):
        state = _identity_at(self.state, 'directory')
        config = _identity_at(self.config, 'file')
        if state is None:
            raise ConfigurationPathError('Private state directory disappeared.')
        return state, config

    def verify(self, snapshot):
        if self.snapshot() != snapshot:
            raise ConfigurationPathError('A private configuration path was replaced during a CLI operation.')


def bounded_run(argv, *, env=None, timeout=45, cwd=None, input_data=None, result=False, pass_fds=(), path_fence=None):
    # Disk-backed capture prevents unbounded communicate() allocation for npm.
    fence_snapshot = path_fence.snapshot() if path_fence is not None else None
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as input_file:
        if input_data is not None:
            input_file.write(input_data); input_file.seek(0)
        process = subprocess.Popen(argv, stdout=output, stderr=output,
                                   stdin=input_file if input_data is not None else subprocess.DEVNULL,
                                   env=env, cwd=cwd, start_new_session=True, pass_fds=pass_fds)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            import signal
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait(); raise
        if path_fence is not None:
            path_fence.verify(fence_snapshot)
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
    check_private_directory(directory)
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
    required = {
            'version', 'fingerprint', 'manifest_digest', 'directory',
            'last_full_audit_monotonic_ns', 'files'}
    if (not isinstance(cache, dict) or not required <= set(cache) <= required | {'full_audit_required'} or
            type(cache.get('full_audit_required', False)) is not bool):
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
    A forced pass latches full_audit_required in the cache until successful, so
    notification loss cannot silently revert to metadata reuse after a failure.
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
        if force_full and cache_valid and not cache.get('full_audit_required', False):
            cache = dict(cache, full_audit_required=True)
            try:
                _write_integrity_cache(cache_root, cache_key, cache)
            except OSError:
                # Still hash everything now; the host retains its pending full
                # audit too. Cache persistence failure cannot authorize reuse.
                try:
                    cache_path.unlink(missing_ok=True)
                except OSError:
                    pass
        now = time.monotonic_ns() if now_monotonic_ns is None else now_monotonic_ns
        if type(now) is not int or now < 0:
            now = time.monotonic_ns()
            force_full = True
        cache_time = cache.get('last_full_audit_monotonic_ns') if cache_valid else None
        full_due = (not cache_valid or cache.get('full_audit_required', False) or type(cache_time) is not int or now < cache_time or
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
                'full_audit_required': False,
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

def validate_node_archive_members(members, stage):
    """Validate the entire namespace before extraction, independent of volume settings.

    Keys use canonical caseless Unicode matching. Original member names remain
    unchanged; normalization detects ambiguity rather than silently renaming it.
    Implicit directories participate, including when declared later in the tar.
    """
    stage = Path(stage).resolve()
    paths = {(): ((), True, False)}  # spelling, directory, explicitly declared
    for member in members:
        parts = member.name.split('/')
        if member.name.startswith('/') or '\0' in member.name or '..' in parts:
            raise ManagedRuntimeError('Unsafe Node archive.')
        parts = tuple(part for part in parts if part not in ('', '.'))
        resolved = (stage / member.name).resolve()
        if not resolved.is_relative_to(stage): raise ManagedRuntimeError('Unsafe Node archive.')
        if member.issym() or member.islnk():
            parent = resolved.parent if member.issym() else stage
            if not (parent / member.linkname).resolve().is_relative_to(stage):
                raise ManagedRuntimeError('Unsafe Node archive link.')
        keys = tuple(unicodedata.normalize('NFD', unicodedata.normalize('NFD', part).casefold()) for part in parts)
        for length in range(len(parts) + 1):
            key, spelling = keys[:length], parts[:length]
            leaf = length == len(parts)
            directory = not leaf or member.isdir()
            previous = paths.get(key)
            if previous is not None:
                old_spelling, old_directory, declared = previous
                if old_spelling != spelling or old_directory != directory or leaf and declared:
                    raise ManagedRuntimeError('Unsafe Node archive path collision.')
            else:
                declared = False
            paths[key] = (spelling, directory, declared or leaf)


def install(resources, root, *, journal=None):
    root = Path(root)
    if journal is None:
        with locked(root), ProvisioningJournal(root) as owned:
            (root / 'installations').mkdir(exist_ok=True, mode=0o700)
            check_private_directory(root / 'installations')
            return install(resources, root, journal=owned)
    manifest, fingerprint = specification(resources)
    pending = journal.read()
    recovered = journal.recover_stage(fingerprint)
    target = root / 'installations' / fingerprint
    if validate_install(target, fingerprint, force_full=pending is not None):
        if recovered: journal.discard_stage(recovered)
        return target, fingerprint, manifest
    if recovered:
        stage = journal.stage(recovered)
        integrity = json.loads((stage / 'integrity.json').read_text())
        previous_facts = integrity.get('native_addons')
        facts = dict(previous_facts) if isinstance(previous_facts, dict) else {}
        prefix = 'package/node_modules/'
        sealed_files = {name[len(prefix):]: value for name, value in integrity['files'].items()
                        if name.startswith(prefix)}
        verify_native_addons(stage / 'package/node_modules', manifest, facts=facts, sealed_files=sealed_files)
        if facts != previous_facts:
            # Optional derived facts may be refreshed without changing a single
            # expected file digest. A cache-write failure only loses this reuse.
            try:
                atomic_json(stage / 'integrity.json', dict(integrity, native_addons=facts))
                sync_directory(stage)
            except OSError: pass
        _promote_installation(journal, recovered, target, manifest)
        return target, fingerprint, manifest
    require_provisioning_space(root / 'installations', manifest, 'download')
    stage_id = uuid.uuid4().hex
    record = journal.record('staging', fingerprint, stage_id)
    stage = journal.stage(record)
    stage.mkdir(mode=0o700)
    info = stage.lstat()
    identity = {'device': info.st_dev, 'inode': info.st_ino}
    try:
        record = journal.record('staging', fingerprint, stage_id, identity)
        archive = manifest['node_archives'].get(platform.machine())
        if archive is None: raise ManagedRuntimeError('This Mac architecture is unsupported by the bundled runtime.')
        payload = stage / 'node.tar.gz'
        download('https://nodejs.org/dist/v' + manifest['node_version'] + '/' + archive['name'], payload, archive['sha256'])
        with tarfile.open(payload) as tar:
            members = tar.getmembers()
            validate_node_archive_members(members, stage)
            require_provisioning_space(stage, manifest, 'extraction')
            tar.extractall(stage, members=members, filter='data')
        payload.unlink()
        extracted = stage / archive['name'].removesuffix('.tar.gz')
        extracted.rename(stage / 'node')
        staged_node = stage / 'node/bin/node'
        verify_binary_compatibility(staged_node, manifest)
        runtime_version = journal.run([str(staged_node), '--version'], env=isolated_environment())
        if runtime_version.strip() != 'v' + manifest['node_version']:
            raise ManagedRuntimeError('The staged Node runtime failed its bounded launch compatibility check.')
        package = stage / 'package'; package.mkdir()
        for name in ('package.json', 'package-lock.json'): shutil.copyfile(resources / name, package / name)
        env = isolated_environment(); env['PATH'] = str(stage / 'node/bin') + ':/usr/bin:/bin'
        require_provisioning_space(stage, manifest, 'npm installation')
        journal.run([str(stage / 'node/bin/node'), str(stage / 'node/lib/node_modules/npm/bin/npm-cli.js'),
            'ci', '--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org/',
            '--cache', str(stage / 'npm-cache')], env=env, timeout=900, cwd=package)
        shutil.rmtree(stage / 'npm-cache', ignore_errors=True)
        actual = json.loads((package / 'node_modules/openclaw/package.json').read_text())
        if actual['version'] != manifest['openclaw_version']: raise ManagedRuntimeError('Unexpected OpenClaw version.')
        version = journal.run([str(stage / 'node/bin/node'), str(package / 'node_modules/openclaw/openclaw.mjs'), '--version'], env=env)
        if manifest['openclaw_version'] not in version: raise ManagedRuntimeError('OpenClaw did not pass its launch check.')
        addon_facts = {}
        verify_native_addons(package / 'node_modules', manifest, facts=addon_facts)
        record = journal.record('sealing', fingerprint, stage_id, identity)
        files = seal(stage)
        sealed_addons = {value for name, value in files.items()
                         if name.startswith('package/node_modules/') and name.endswith('.node')}
        if set(addon_facts.get('digests', {})) != sealed_addons:
            raise ManagedRuntimeError('Native modules changed while the installation was being sealed.')
        atomic_json(stage / 'integrity.json', {'fingerprint': fingerprint, 'files': files, 'native_addons': addon_facts})
        sync_directory(stage)
        record = journal.record('sealed', fingerprint, stage_id, identity)
    except Exception:
        # Normal download/build failures discard only their bound stage. A
        # process crash/BaseException leaves the marker for the next owner.
        journal.discard_stage(record)
        journal.clear()
        raise
    _promote_installation(journal, record, target, manifest)
    return target, fingerprint, manifest


def _promote_installation(journal, record, target, manifest):
    fd = journal.open_stage(record)
    if fd is None: raise ManagedRuntimeError('Sealed private staging directory disappeared before promotion.')
    try:
        require_provisioning_space(journal.stage(record), manifest, 'promotion')
        journal.record('promoting', record['fingerprint'], record['stage_id'], record['stage_identity'])
        if target.exists() or target.is_symlink():
            check_private_directory(target)
            if validate_install(target, record['fingerprint'], force_full=True):
                journal.discard_stage(record)
                journal.record('promoted', record['fingerprint'])
                return
            # Never move a verified installation. Retain damaged code for
            # diagnosis; no recovery cleanup follows this quarantine name.
            target.rename(target.with_name('.corrupt-' + uuid.uuid4().hex))
            sync_directory(target.parent)
        info = os.fstat(fd)
        current = journal.stage(record).lstat()
        if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
            raise ManagedRuntimeError('Private staging directory changed before promotion.')
        journal.stage(record).rename(target)
        sync_directory(target.parent)
        journal.record('promoted', record['fingerprint'], record['stage_id'], record['stage_identity'])
    finally: os.close(fd)

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
        offline = False
        try: existing = load_descriptor(root / 'runtime.json')
        except PrivateDirectoryError: raise
        except ManagedRuntimeError: existing = None
        try: check_managed_directories(root, existing)
        except PrivateDirectoryError as error:
            if error.code != 'private_directory_permissions': raise
            cleanup.enter_context(configuration_hold(root, already_drained=drained))
            require_offline(root)
            check_managed_directories(root, existing, repair=True)
            offline = True
        for name in ('installations', 'instances'):
            (root / name).mkdir(exist_ok=True, mode=0o700)
        journal = cleanup.enter_context(ProvisioningJournal(root))
        interrupted = journal.read()
        # Recover the activation flag before overwriting its phase. A second
        # interruption during configuration must not lose this obligation.
        if (interrupted is not None and interrupted['phase'] in {'activating', 'activated'} and
                existing and existing['installation_fingerprint'] == interrupted['fingerprint']):
            atomic_json(root / 'activation-verification.json', {'installation_fingerprint':interrupted['fingerprint']})
            sync_directory(root)
        target, fingerprint, manifest = install(resources, root, journal=journal)
        try:
            rejected = json.loads((root / 'rejected-installation.json').read_text())
        except (OSError, ValueError): rejected = None
        if isinstance(rejected, dict) and rejected.get('fingerprint') == fingerprint:
            # Keep a tested rollback usable; do not reactivate a rejected update every refresh.
            journal.clear()
            return load_descriptor(root / 'runtime.json')
        check_private_directory(target)
        active = root / 'runtime.json'
        try: previous = load_descriptor(active)
        except ManagedRuntimeError: previous = None
        active_path_fence = ConfigurationPathFence(root, active)
        active_path_snapshot = active_path_fence.snapshot()
        journal.record('configuration', fingerprint)
        identity = previous['instance_id'] if previous and previous['installation_fingerprint'] == fingerprint else str(uuid.uuid4())
        state = root / 'instances' / identity
        try: state.mkdir(mode=0o700); created = True
        except FileExistsError: created = False
        from managed_profiles import register_owner
        register_owner(root, state, created=created, installation_lock_held=True)
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
        config_changed = drained or interrupted is not None or not contains_settings(current_config, desired) or set(current_config.get('agents', {}).get('defaults', {}).get('models', {})) != set(desired['agents']['defaults']['models'])
        if config_changed:
            if not offline: cleanup.enter_context(configuration_hold(root, already_drained=drained)); offline = True
            require_offline(root)
            atomic_json(config, merge_settings(current_config, desired))
        configuration_fence = ConfigurationPathFence(state, config)
        configuration_snapshot = configuration_fence.snapshot()
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
        patch_value = configuration_delta(current_config, desired)
        if patch_value:
            patch_command = configuration_patch_arguments(wrapper, patch_value)
            journal.run(patch_command,
                        input_data=json.dumps(patch_value).encode(), env=isolated_environment(),
                        path_fence=configuration_fence)
        if config_changed:
            journal.record('readback', fingerprint)
            verify_settings(wrapper, desired, pass_fds=(journal.fd,), path_fence=configuration_fence)
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
                journal.run([str(wrapper), 'models', 'auth', 'paste-api-key',
                    '--provider', 'google', '--profile-id', 'google:orbit'],
                    input_data=(key.strip() + '\n').encode(), env=isolated_environment(),
                    path_fence=configuration_fence)
            try: saved_key = (root.parent / 'gemini-api-key').read_text().strip()
            except OSError: saved_key = ''
            atomic_json(key_record, {'fingerprint':key_fingerprint,
                                    'verification_until':time.time() + 300 if saved_key and saved_key != key.strip() else 0})
        descriptor = {'version':descriptor_contract.DESCRIPTOR_VERSION, 'instance_id':identity, 'installation_fingerprint':fingerprint,
            'openclaw_version':manifest['openclaw_version'], 'node_version':manifest['node_version'],
            'node':str(node),'entry':str(entry),'executable':str(wrapper),'state':str(state),
            'config':str(config),'workspace':str(workspace),'token_file':str(token), 'port':port,
            'endpoint':f'ws://127.0.0.1:{port}',
            'configuration_fingerprint':configuration_fingerprint(desired, key_record)}
        journal.record('readback', fingerprint)
        journal.run([str(wrapper),'config','validate'], timeout=45, env=isolated_environment(),
                    path_fence=configuration_fence)
        configuration_fence.verify(configuration_snapshot)
        try: check_managed_directories(root, descriptor)
        except PrivateDirectoryError as error:
            if error.code != 'private_directory_permissions': raise
            if not offline: cleanup.enter_context(configuration_hold(root, already_drained=drained)); offline = True
            require_offline(root)
            check_managed_directories(root, descriptor, repair=True)
        journal.record('activating', fingerprint)
        active_path_fence.verify(active_path_snapshot)
        atomic_json(active, descriptor)
        sync_directory(root)
        if (not previous or previous['installation_fingerprint'] != fingerprint or
                interrupted is not None and interrupted['fingerprint'] == fingerprint and
                interrupted['phase'] in {'activating', 'activated'}):
            atomic_json(root / 'activation-verification.json', {'installation_fingerprint':fingerprint})
        journal.record('activated', fingerprint)
        journal.clear()
        return descriptor

def load_descriptor(path: Path = ROOT / 'runtime.json'):
    try:
        return descriptor_contract.parse_descriptor(path.read_bytes(), path.parent)
    except descriptor_contract.DescriptorError as error:
        if error.code == 'symlink': raise PrivateDirectoryError('symlink') from error
        raise ManagedRuntimeError('TaskPilot private OpenClaw is not installed or its descriptor is invalid.') from error
    except OSError as error:
        raise ManagedRuntimeError('TaskPilot private OpenClaw is not installed or its descriptor is invalid.') from error

def activate_environment(path):
    d = load_descriptor(path)
    check_managed_directories(path.parent, d)
    from managed_profiles import register_owner
    register_owner(path.parent, d['state'])
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
        active_identity = _identity_at(path, 'file')
        fence = ConfigurationPathFence(d['state'], d['config'])
        before = fence.snapshot()
        port = private_port()
        config = Path(d['config']); value = json.loads(config.read_text())
        value['gateway']['port'] = port
        bounded_run([d['executable'], 'config', 'patch', '--stdin'],
                    input_data=json.dumps({'gateway':{'port':port}}).encode(), env=isolated_environment(),
                    path_fence=fence)
        fence.verify(before)
        atomic_json(config, value)
        updated = fence.snapshot()
        d.update(port=port, endpoint=f'ws://127.0.0.1:{port}')
        d['configuration_fingerprint'] = configuration_fingerprint(desired_settings(d['workspace'], Path(d['token_file']), port), Path(d['state']) / 'credential-fingerprint.json')
        expected = desired_settings(d['workspace'], Path(d['token_file']), port)
        verify_settings(d['executable'], expected, path_fence=fence)
        bounded_run([d['executable'], 'config', 'validate'], timeout=45,
                    env=isolated_environment(), path_fence=fence)
        fence.verify(updated)
        if _identity_at(path, 'file') != active_identity:
            raise ConfigurationPathError('Active descriptor changed during endpoint relocation.')
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
    elif operation == 'collect-profiles':
        from managed_profiles import collect
        result = collect(path.parent)
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
        active_identity = _identity_at(path, 'file')
        d = load_descriptor(path.parent / 'working-runtime.json')
        if not validate_install(Path(d['node']).parents[2], d['installation_fingerprint'], force_full=True):
            raise ManagedRuntimeError('The last working OpenClaw installation is unavailable; reconfigure in Settings.')
        failed = load_descriptor(path)
        if d['installation_fingerprint'] == failed['installation_fingerprint']:
            raise ManagedRuntimeError('No different verified compatible installation is available for rollback.')
        configuration = json.loads((path.parent / 'working-config.json').read_text())
        fence = ConfigurationPathFence(d['state'], d['config'])
        before = fence.snapshot()
        bounded_run([d['executable'], 'config', 'patch', '--stdin'],
                    input_data=json.dumps(configuration).encode(), env=isolated_environment(),
                    path_fence=fence)
        fence.verify(before)
        atomic_json(Path(d['config']), configuration)
        updated = fence.snapshot()
        verify_settings(d['executable'], configuration, path_fence=fence)
        bounded_run([d['executable'], 'config', 'validate'], timeout=45,
                    env=isolated_environment(), path_fence=fence)
        fence.verify(updated)
        if _identity_at(path, 'file') != active_identity:
            raise ConfigurationPathError('Active descriptor changed during runtime rollback.')
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


def verify_settings(wrapper, expected, *, pass_fds=(), path_fence=None):
    # Read back authoritative SQLite configuration using the supported CLI.
    # Only managed top-level keys are compared; CLI metadata is not our setting.
    for key, value in expected.items():
        actual = json.loads(bounded_run([str(wrapper), 'config', 'get', key, '--json'], env=isolated_environment(),
                                        pass_fds=pass_fds, path_fence=path_fence))
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


def read_only_database_health(path, *, timeout=SQLITE_HEALTH_TIMEOUT_SECONDS,
                              now_monotonic=None, deadline=None):
    """Bounded SQLite integrity check. It never opens a database for writing."""
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 5:
        return 'inconclusive'
    clock = time.monotonic if now_monotonic is None else now_monotonic
    if deadline is None: deadline = clock() + timeout
    if clock() >= deadline: return 'inconclusive'
    database = Path(path)
    try: info = database.lstat()
    except FileNotFoundError: return 'missing'
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or
            info.st_uid != os.getuid() or info.st_nlink != 1):
        return 'inconclusive'
    connection = None
    interrupter = None
    try:
        remaining = deadline - clock()
        if remaining <= 0: return 'inconclusive'
        busy_milliseconds = min(SQLITE_BUSY_TIMEOUT_MILLISECONDS, int(remaining * 1000))
        uri = database.as_uri() + '?mode=ro'
        connection = sqlite3.connect(uri, uri=True,
                                     timeout=busy_milliseconds / 1000)
        connection.execute(f'PRAGMA busy_timeout={busy_milliseconds}')
        connection.set_progress_handler(lambda: 1 if clock() >= deadline else 0,
                                        SQLITE_PROGRESS_INTERVAL)
        # Progress handlers run between SQLite VM steps. An independent
        # interrupt also bounds a long-running statement while it is blocked
        # in a database operation. It is cancelled before the connection is
        # closed and never changes the database.
        if now_monotonic is None:
            remaining = deadline - clock()
            if remaining <= 0: return 'inconclusive'
            interrupter = threading.Timer(max(0.001, remaining), connection.interrupt)
            interrupter.daemon = True
            interrupter.start()
        row = connection.execute('PRAGMA quick_check(1)').fetchone()
        if clock() >= deadline: return 'inconclusive'
        try: after = database.lstat()
        except OSError: return 'inconclusive'
        before_identity = (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
                           info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        after_identity = (after.st_dev, after.st_ino, after.st_mode, after.st_uid, after.st_nlink,
                          after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        if before_identity != after_identity or stat.S_ISLNK(after.st_mode): return 'inconclusive'
        if row == ('ok',): return 'ok'
        return 'corrupt'
    except sqlite3.OperationalError as error:
        message = str(error).lower()
        if any(token in message for token in ('locked', 'busy', 'interrupted', 'unable to open', 'permission denied')):
            return 'inconclusive'
        if any(token in message for token in ('not a database', 'malformed', 'disk image is malformed')):
            return 'corrupt'
        return 'inconclusive'
    except sqlite3.DatabaseError as error:
        message = str(error).lower()
        return 'corrupt' if any(token in message for token in ('not a database', 'malformed', 'disk image is malformed')) else 'inconclusive'
    except OSError:
        return 'inconclusive'
    finally:
        if interrupter is not None:
            interrupter.cancel()
            if interrupter.is_alive(): interrupter.join(timeout=0.1)
        if connection is not None:
            try: connection.close()
            except sqlite3.Error: pass


def known_database_health(state, *, timeout=SQLITE_HEALTH_TIMEOUT_SECONDS,
                          now_monotonic=None):
    root = Path(state)
    return {name: _database_health_with_sidecars(root / name, timeout=timeout,
                                                now_monotonic=now_monotonic)
            for name in SQLITE_HEALTH_FILES}


def _sqlite_sidecar_identity(info):
    # SHM read marks may change during SQLite's read-only query. These are
    # object/access identities, not a claim that its contents stayed frozen.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_nlink)


def _database_health_with_sidecars(database, *, timeout, now_monotonic):
    """Fence only this database's WAL/SHM identities within one shared budget."""
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 5:
        return 'inconclusive'
    clock = time.monotonic if now_monotonic is None else now_monotonic
    deadline = clock() + timeout
    try:
        with ExitStack() as handles:
            sidecars = {}
            for suffix in ('-wal', '-shm'):
                if clock() >= deadline: return 'inconclusive'
                path = database.with_name(database.name + suffix)
                try: before = path.lstat()
                except FileNotFoundError:
                    sidecars[path] = None
                    continue
                if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1):
                    return 'inconclusive'
                # Nonblocking prevents a swapped FIFO from stalling this
                # metadata-only inspection; no bytes are read from sidecars.
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
                handles.callback(os.close, fd)
                identity = _sqlite_sidecar_identity(before)
                if identity != _sqlite_sidecar_identity(os.fstat(fd)):
                    return 'inconclusive'
                sidecars[path] = (fd, identity)
            if clock() >= deadline: return 'inconclusive'
            result = read_only_database_health(database, timeout=timeout,
                                                now_monotonic=now_monotonic, deadline=deadline)
            for path, before in sidecars.items():
                if clock() >= deadline: return 'inconclusive'
                try: after = path.lstat()
                except FileNotFoundError:
                    if before is None: continue
                    return 'inconclusive'
                if before is None: return 'inconclusive'
                fd, identity = before
                if (identity != _sqlite_sidecar_identity(after) or
                        identity != _sqlite_sidecar_identity(os.fstat(fd))):
                    return 'inconclusive'
            if clock() >= deadline: return 'inconclusive'
            if result == 'missing' and any(value is not None for value in sidecars.values()):
                return 'inconclusive'
            return result
    except OSError:
        return 'inconclusive'


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
    try: d = load_descriptor(path)
    except PrivateDirectoryError as error:
        return {'version': VERSION, 'ok': False, 'causes': [error.code],
                'fingerprint': hashlib.sha256(error.code.encode()).hexdigest(), 'full_integrity_ok': False}
    faults = []
    try: check_managed_directories(path.parent, d)
    except PrivateDirectoryError as error:
        # Do not write diagnostics through a suspect directory or read its contents.
        return {'version': VERSION, 'ok': False, 'causes': [error.code],
                'fingerprint': hashlib.sha256((d['installation_fingerprint'] + error.code).encode()).hexdigest(),
                'full_integrity_ok': False}
    integrity_stats = {}
    installation_ok = validate_install(Path(d['node']).parents[2], d['installation_fingerprint'],
                                        force_full=force_integrity, stats=integrity_stats)
    if not installation_ok: faults.append('installation')
    database_health = known_database_health(d['state'])
    database_values = tuple(database_health.values())
    if 'corrupt' in database_values: faults.append('database_corrupt')
    if 'inconclusive' in database_values: faults.append('database_inconclusive')
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
        if not faults and not any(value in {'inconclusive', 'corrupt'} for value in database_values):
            verify_settings(d['executable'], required,
                            path_fence=ConfigurationPathFence(d['state'], d['config']))
    except ConfigurationPathError: faults.append(ConfigurationPathError.code)
    except (OSError, ValueError, ManagedRuntimeError): faults.append('configuration')
    if (not any(value in {'inconclusive', 'corrupt'} for value in database_values) and
            not credential_present(d['state'])):
        faults.append('credential_store')
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
    parts = [d['installation_fingerprint'], d['configuration_fingerprint'], *sorted(set(faults)),
             *[name + ':' + database_health[name] for name in sorted(database_health)]]
    for name in ('config','executable'):
        try: parts.append(digest(d[name]))
        except OSError: parts.append('missing')
    fingerprint = hashlib.sha256(':'.join(parts).encode()).hexdigest()
    result = {'version':VERSION, 'ok':not faults, 'causes':sorted(set(faults)), 'fingerprint':fingerprint,
              'database_health':database_health,
              'retry_after_seconds':5 if 'database_inconclusive' in faults else 0,
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
    if 'database_inconclusive' in result['causes']:
        raise ManagedRuntimeError('Private OpenClaw database health was inconclusive; no repair was attempted. Wait briefly and retry the read-only check.')
    if 'database_corrupt' in result['causes'] or 'private_configuration_path_changed' in result['causes']:
        raise ManagedRuntimeError('A private OpenClaw database or configuration path needs inspection; no automatic repair was attempted.')
    unsafe = [cause for cause in result['causes'] if cause.startswith('private_directory_') and cause != 'private_directory_permissions']
    if unsafe: raise ManagedRuntimeError(unsafe[0] + ': Private storage needs attention; no automatic repair was attempted.')
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
    if 'private_directory_permissions' in result['causes']:
        from request_policy import configuration_transaction
        with configuration_transaction(), locked(path.parent):
            check_managed_directories(path.parent, load_descriptor(path), repair=True)
        result = audit(path, force_integrity=True)
        if result['ok']: return load_descriptor(path)
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


def configuration_delta(actual, desired, path=()):
    """Return only TaskPilot-managed leaves that differ from the readback file."""
    if isinstance(desired, dict):
        result = {}
        actual_map = actual if isinstance(actual, dict) else {}
        for key, value in desired.items():
            # The model catalog is an exact managed set. Replace it as one leaf
            # so removed/legacy model entries cannot survive a recursive merge.
            if path == ('agents', 'defaults') and key == 'models':
                if actual_map.get(key) != value: result[key] = value
                continue
            child = configuration_delta(actual_map.get(key), value, path + (key,))
            if child != {}: result[key] = child
        return result
    return {} if type(actual) is type(desired) and actual == desired else desired


def configuration_patch_arguments(wrapper, delta):
    arguments = [str(wrapper), 'config', 'patch', '--stdin']
    if 'models' in delta.get('agents', {}).get('defaults', {}):
        arguments.extend(['--replace-path', 'agents.defaults.models'])
    return arguments
