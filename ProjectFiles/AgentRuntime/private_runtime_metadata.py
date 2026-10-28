"""Bounded descriptor-owned JSON reads. Errors contain fixed codes, never contents."""
import json
import math
import os
import stat
import unicodedata

REQUEST_BYTES = 4096
RECORD_BYTES = 65536
DESCRIPTOR_BYTES = 131072
CONFIGURATION_BYTES = 4 * 1024 * 1024
PROCESS_LIST_BYTES = 8 * 1024 * 1024
INTEGRITY_BYTES = 64 * 1024 * 1024


class MetadataError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__('private_metadata_' + code)


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def parse(data):
    def pairs(items):
        result, seen = {}, set()
        for key, value in items:
            identity = unicodedata.normalize('NFC', key)
            if identity in seen: raise MetadataError('duplicate_key')
            seen.add(identity)
            result[key] = value
        return result
    def finite(value, depth=0):
        if isinstance(value, float) and not math.isfinite(value): raise MetadataError('invalid_json')
        if isinstance(value, str): value.encode('utf-8', errors='strict')
        if isinstance(value, (dict, list)):
            if depth >= 512: raise MetadataError('invalid_json')
            if isinstance(value, dict):
                for key, item in value.items():
                    key.encode('utf-8', errors='strict'); finite(item, depth + 1)
            else:
                for item in value: finite(item, depth + 1)
    try:
        if data.startswith(b'\xef\xbb\xbf') or b'\0' in data: raise MetadataError('invalid_json')
        value = json.loads(data.decode('utf-8'), object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(MetadataError('invalid_json')))
        if not isinstance(value, (dict, list)): raise MetadataError('invalid_json')
        finite(value)
        return value
    except MetadataError: raise
    except (ValueError, UnicodeError, RecursionError) as error:
        raise MetadataError('invalid_json') from error


def read_bytes(path, maximum=RECORD_BYTES, *, required_mode=None):
    if type(maximum) is not int or not 0 < maximum <= INTEGRITY_BYTES: raise MetadataError('size')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1:
            raise MetadataError('ownership')
        if required_mode is not None and stat.S_IMODE(before.st_mode) != required_mode:
            raise MetadataError('ownership')
        if not 0 <= before.st_size <= maximum: raise MetadataError('size')
        data = bytearray()
        while len(data) < maximum:
            try: chunk = os.read(fd, min(65536, maximum - len(data)))
            except InterruptedError: continue
            if not chunk: break
            data.extend(chunk)
            if len(data) > maximum: raise MetadataError('size')
        after = os.fstat(fd)
        named = os.stat(path, follow_symlinks=False)
        if _identity(before) != _identity(after) or _identity(after) != _identity(named) or len(data) != after.st_size:
            raise MetadataError('changed')
        return bytes(data)
    finally: os.close(fd)


def read(path, maximum=RECORD_BYTES, *, expected=dict, required_mode=None):
    value = parse(read_bytes(path, maximum, required_mode=required_mode))
    if type(value) is not expected: raise MetadataError('invalid_json')
    return value
