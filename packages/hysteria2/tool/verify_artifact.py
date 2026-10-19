"""Verify Hysteria2 AAR provenance, license coverage, ABIs and ELF 16 KB support."""
import argparse
import hashlib
import io
import json
import struct
import zipfile
from pathlib import Path

ELF_ABIS = {'armeabi-v7a': (1, 40), 'arm64-v8a': (2, 183), 'x86_64': (2, 62)}
NOTICE = 'assets/hysteria2/THIRD_PARTY_NOTICES.txt'
JAVA_CLASS = 'dev/emby/hysteria2/core/hybridge/Hybridge.class'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source_inputs(package):
    files = [package / 'build-lock.json', package / 'LICENSE', package / 'go/go.mod', package / 'go/go.sum']
    files += sorted((package / 'go').rglob('*.go'))
    return {p.relative_to(package).as_posix(): sha(p.read_bytes()) for p in files}


def check_elf(data, abi):
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Invalid little-endian ELF: ' + abi)
    bits, machine = ELF_ABIS[abi]
    if data[4] != bits or struct.unpack_from('<HH', data, 16) != (3, machine):
        raise ValueError('ELF ABI/type mismatch: ' + abi)
    if bits == 1:
        offset = struct.unpack_from('<I', data, 28)[0]
        size, count = struct.unpack_from('<HH', data, 42)
        fmt = '<IIIIIIII'
    else:
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        fmt = '<IIQQQQQQ'
    if size < struct.calcsize(fmt) or offset + count * size > len(data):
        raise ValueError('Invalid ELF program headers: ' + abi)
    loads = 0
    for index in range(count):
        header = struct.unpack_from(fmt, data, offset + index * size)
        if header[0] != 1:
            continue
        loads += 1
        file_offset, address = header[1:3] if bits == 1 else header[2:4]
        alignment = header[-1]
        if alignment < 16384 or alignment & (alignment - 1) or file_offset % 16384 != address % 16384:
            raise ValueError('ELF LOAD segment is not 16 KB compatible: ' + abi)
    if not loads:
        raise ValueError('ELF has no LOAD segments: ' + abi)


def libraries(aar):
    with zipfile.ZipFile(aar) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate AAR entries')
        expected = {'jni/' + abi + '/libgojni.so' for abi in ELF_ABIS}
        actual = {name for name in names if name.endswith('.so')}
        if actual != expected:
            raise ValueError('Expected exactly all three Hysteria2 JNI ABIs')
        result = {}
        for name in sorted(expected):
            data = archive.read(name)
            check_elf(data, name.split('/')[1])
            result[name] = sha(data)
        return result


def verify(aar, provenance, package):
    lock = json.loads((package / 'build-lock.json').read_text(encoding='utf-8'))
    manifest = json.loads(provenance.read_text(encoding='utf-8'))
    for key in ('schema', 'go', 'mobile', 'ndk', 'upstream', 'abis'):
        if manifest.get(key) != lock[key]:
            raise ValueError('Build pin mismatch: ' + key)
    if manifest['inputs'] != source_inputs(package):
        raise ValueError('Stale Hysteria2 source inputs; rebuild the AAR')
    if sha(aar.read_bytes()) != manifest['sha256']:
        raise ValueError('Hysteria2 AAR SHA256 mismatch')
    if libraries(aar) != manifest['libraries']:
        raise ValueError('Hysteria2 JNI library provenance mismatch')
    with zipfile.ZipFile(aar) as archive:
        notice = archive.read(NOTICE)
        if sha(notice) != manifest['noticesSha256']:
            raise ValueError('Native license notice mismatch')
        with zipfile.ZipFile(io.BytesIO(archive.read('classes.jar'))) as classes:
            if JAVA_CLASS not in classes.namelist():
                raise ValueError('Missing gomobile Hybridge class')
    dependencies = {entry['module']: entry for entry in manifest['dependencies']}
    for module in (lock['upstream']['module'], lock['upstream']['extras']):
        item = dependencies.get(module, {})
        if item.get('version') != lock['upstream']['version'] or not item.get('licenses'):
            raise ValueError('Missing upstream native license: ' + module)
    for item in dependencies.values():
        if not item.get('licenses') or not item.get('sum') or item.get('license') not in {
                'MIT', 'BSD-2-Clause', 'BSD-3-Clause', 'Apache-2.0'}:
            raise ValueError('Missing or unaudited native dependency license: ' + item['module'])
    return manifest


def verify_apk(apk, manifest):
    """Check packaged bytes too; split APKs may contain a subset of the three ABIs."""
    found = 0
    with zipfile.ZipFile(apk) as archive:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError('Duplicate APK entries')
        for member in archive.infolist():
            if not member.filename.endswith('/libgojni.so'):
                continue
            found += 1
            name = member.filename.replace('lib/', 'jni/', 1)
            data = archive.read(member)
            if manifest['libraries'].get(name) != sha(data):
                raise ValueError('APK Hysteria2 JNI provenance mismatch')
            check_elf(data, name.split('/')[1])
            if member.compress_type == zipfile.ZIP_STORED:
                with apk.open('rb') as raw:
                    raw.seek(member.header_offset + 26)
                    filename_len, extra_len = struct.unpack('<HH', raw.read(4))
                data_offset = member.header_offset + 30 + filename_len + extra_len
                if data_offset % 16384:
                    raise ValueError('Uncompressed APK JNI entry is not ZIP 16 KB aligned')
        if sha(archive.read(NOTICE)) != manifest['noticesSha256']:
            raise ValueError('APK omitted native license notices')
    if not found:
        raise ValueError('APK contains no Hysteria2 JNI library')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--apk', type=Path, action='append', default=[])
    args = parser.parse_args()
    output = args.package / 'android/libs'
    manifest = verify(output / 'hysteria2.aar', output / 'hysteria2.provenance.json', args.package)
    for apk in args.apk:
        verify_apk(apk, manifest)
    print('hysteria2_native_provenance_and_16kb=PASSED')


if __name__ == '__main__':
    main()
