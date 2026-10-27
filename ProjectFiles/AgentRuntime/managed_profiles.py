"""Bounded retirement of identity-recorded, private TaskPilot instances only."""
from contextlib import ExitStack, nullcontext
import itertools
import json
import math
import os
from pathlib import Path
import stat
import time
import uuid

MARKER = '.taskpilot-profile.json'
GRACE_SECONDS = 7 * 24 * 60 * 60
MAX_PROFILES = 128
MAX_OWNERS = 16
MAX_REMOVALS = 512


def _uuid(name):
    try: return str(uuid.UUID(name)) == name
    except (ValueError, AttributeError): return False


def _identity(info):
    return {'device':info.st_dev, 'inode':info.st_ino}


def _owner(value):
    return (isinstance(value, dict) and set(value) == {'pid', 'seconds', 'microseconds'} and
            all(type(v) is int for v in value.values()) and value['pid'] > 0 and
            value['seconds'] > 0 and 0 <= value['microseconds'] < 1_000_000)


def _gone(owner):
    import managed_openclaw as managed
    current = managed.process_identity(owner['pid'])
    if current is not None: return current != owner
    # Inaccessible birth metadata is uncertainty, not proof of a dead owner.
    try: os.kill(owner['pid'], 0)
    except ProcessLookupError: return True
    except OSError: return False
    return False


def _record(fd):
    source = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
    with os.fdopen(source, 'rb') as stream:
        info = os.fstat(source)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > 8192):
            raise ValueError('Untrusted profile record')
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError('Duplicate profile record field')
                result[key] = value
            return result
        data = stream.read(8193)
        if len(data) > 8192: raise ValueError('Oversized profile record')
        value = json.loads(data.decode('utf-8'), object_pairs_hook=unique)
    if (not isinstance(value, dict) or set(value) != {'version', 'directory', 'created_at', 'unreferenced_since', 'owners', 'collectable'} or
            type(value['version']) is not int or value['version'] != 1 or
            value['directory'] != _identity(os.fstat(fd)) or
            not isinstance(value['directory'], dict) or
            any(type(v) is not int for v in value['directory'].values()) or
            type(value['collectable']) is not bool or not isinstance(value['owners'], list) or
            not 0 < len(value['owners']) <= MAX_OWNERS or not all(_owner(o) for o in value['owners'])):
        raise ValueError('Invalid profile record')
    for key in ('created_at', 'unreferenced_since'):
        number = value[key]
        if number is None and key == 'unreferenced_since': continue
        if type(number) not in (int, float) or not math.isfinite(number) or number < 0:
            raise ValueError('Invalid profile age')
    return value


def _write_record(fd, value):
    """Keep record updates in the opened instance even if its pathname moves."""
    data = json.dumps(value, separators=(',', ':'), allow_nan=False).encode()
    if len(data) > 8192: raise ValueError('Oversized profile record')
    name = '.profile-' + str(uuid.uuid4())
    output = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
    try:
        with os.fdopen(output, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, MARKER, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        try: os.unlink(name, dir_fd=fd)
        except FileNotFoundError: pass


def register_owner(root, state, *, created=False, installation_lock_held=False):
    """Do not adopt legacy/untracked directories. Unknown owners disable cleanup."""
    import managed_openclaw as managed
    root, state = Path(root), Path(state)
    if state.parent != root / 'instances' or not _uuid(state.name): return
    with nullcontext() if installation_lock_held else managed.locked(root):
        managed.check_private_directory(state)
        fd = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            owner = managed.process_identity(os.getpid())
            if not _owner(owner): return  # No trustworthy birth identity: never create a collectable record.
            try: value = _record(fd)
            except (OSError, ValueError, RecursionError):
                if not created: return
                value = dict(version=1, directory=_identity(os.fstat(fd)), created_at=time.time(),
                             unreferenced_since=None, owners=[], collectable=True)
            original = json.dumps(value, separators=(',', ':'))
            owners = [o for o in value['owners'] if not _gone(o)]
            if owner not in owners: owners.append(owner)
            if len(owners) > MAX_OWNERS:
                value['collectable'] = False  # Never forget a potentially live owner to make room.
            value.update(owners=owners[:MAX_OWNERS], unreferenced_since=None)
            if _identity(state.lstat()) != value['directory']: return
            if not created and json.dumps(value, separators=(',', ':')) == original: return
            _write_record(fd, value)
        finally: os.close(fd)


def _open_directory(parent, name, expected=None, *, private=False):
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode) or before.st_uid != os.getuid(): raise ValueError('Unexpected directory')
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    try:
        after = os.fstat(fd)
        if (_identity(before) != _identity(after) or expected is not None and expected != _identity(after) or
                private and stat.S_IMODE(after.st_mode) != 0o700):
            raise ValueError('Changed directory')
    except BaseException:
        os.close(fd)
        raise
    return fd


def _workspace_empty(fd):
    try: workspace = _open_directory(fd, 'workspace')
    except FileNotFoundError: return True
    try:
        with os.scandir(workspace) as entries: return next(entries, None) is None
    finally: os.close(workspace)


def _remove_contents(fd, device, remaining, deadline, depth=0):
    if depth > 32: return False
    with os.scandir(fd) as entries:
        for entry in entries:
            if depth == 0 and entry.name == MARKER: continue
            if remaining[0] <= 0 or time.monotonic() >= deadline: return False
            before = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
            if before.st_dev != device or before.st_uid != os.getuid(): return False
            if stat.S_ISDIR(before.st_mode):
                child = _open_directory(fd, entry.name, _identity(before))
                try:
                    if depth == 0 and entry.name == 'workspace':
                        # A concurrent writer must not turn workspace cleanup into deletion of outputs.
                        with os.scandir(child) as contents:
                            if next(contents, None) is not None: return False
                    elif not _remove_contents(child, device, remaining, deadline, depth + 1): return False
                finally: os.close(child)
                if _identity(os.stat(entry.name, dir_fd=fd, follow_symlinks=False)) != _identity(before): return False
                os.rmdir(entry.name, dir_fd=fd)
            else:
                if _identity(os.stat(entry.name, dir_fd=fd, follow_symlinks=False)) != _identity(before): return False
                os.unlink(entry.name, dir_fd=fd)  # Symlinks are unlinked, never followed.
            remaining[0] -= 1
    return True


def collect(root, *, now=None, grace_seconds=GRACE_SECONDS, budget_seconds=2, max_removals=MAX_REMOVALS):
    import managed_openclaw as managed
    from request_policy import configuration_transaction
    root = Path(root)
    result = dict(version=1, inspected=0, removed=0, deferred=0)
    now = time.time() if now is None else now
    if (type(now) not in (int, float) or not math.isfinite(now) or now < 0 or
            type(grace_seconds) not in (int, float) or not math.isfinite(grace_seconds) or grace_seconds < 0 or
            type(budget_seconds) not in (int, float) or not math.isfinite(budget_seconds) or budget_seconds < 0 or
            type(max_removals) is not int or max_removals < 0):
        raise ValueError('Invalid profile collection bound')
    deadline, remaining = time.monotonic() + budget_seconds, [max_removals]
    managed.check_private_directory(root)
    with ExitStack() as locks:
        try:
            locks.enter_context(configuration_transaction(blocking=False))
            locks.enter_context(managed.locked(root, blocking=False))
            locks.enter_context(managed.ProvisioningJournal(root))
        except BlockingIOError:
            result['deferred'] += 1
            return result  # Housekeeping must never wait behind startup or work.
        managed.require_offline(root)
        protected = set()
        for name in ('runtime.json', 'working-runtime.json', 'previous-runtime.json'):
            path = root / name
            try: path.lstat()
            except FileNotFoundError: continue
            # An unreadable/invalid descriptor may protect unknown data: abort, never guess.
            descriptor = managed.load_descriptor(path)
            state = Path(descriptor['state'])
            if state.parent != root / 'instances' or not _uuid(state.name):
                result['deferred'] += 1
                return result
            protected.add(state.name)
        managed.check_private_directory(root / 'instances')
        parent = os.open(root / 'instances', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            with os.scandir(parent) as entries:
                names = [entry.name for entry in itertools.islice(entries, MAX_PROFILES)]
            for name in names:
                if remaining[0] <= 0 or time.monotonic() >= deadline: break
                if not _uuid(name): continue
                result['inspected'] += 1
                fd = None
                try:
                    fd = _open_directory(parent, name, private=True)
                    record = _record(fd)
                    if name in protected:
                        if record['unreferenced_since'] is not None:
                            record['unreferenced_since'] = None
                            _write_record(fd, record)
                        continue
                    if not record['collectable'] or any(not _gone(o) for o in record['owners']) or not _workspace_empty(fd):
                        if record['unreferenced_since'] is not None:
                            record['unreferenced_since'] = None
                            _write_record(fd, record)
                        result['deferred'] += 1
                        continue
                    since = record['unreferenced_since']
                    if since is None or since > now or record['created_at'] > now:
                        record['unreferenced_since'] = now
                        _write_record(fd, record)
                        result['deferred'] += 1
                        continue
                    if now - since < grace_seconds:
                        result['deferred'] += 1
                        continue
                    if not _remove_contents(fd, record['directory']['device'], remaining, deadline):
                        result['deferred'] += 1
                        continue
                    if (_identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != record['directory'] or
                            _record(fd) != record):
                        result['deferred'] += 1
                        continue
                    os.unlink(MARKER, dir_fd=fd)
                    os.rmdir(name, dir_fd=parent)
                    os.fsync(parent)
                    result['removed'] += 1
                except (OSError, ValueError, RecursionError):
                    result['deferred'] += 1
                finally:
                    if fd is not None: os.close(fd)
        finally: os.close(parent)
    return result
