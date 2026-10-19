"""Build the pinned embedded Hysteria2 core; downloads only official Go tools.

All downloaded tools, caches and temporary outputs stay in ignored build/.
Android SDK/NDK and a JDK are prerequisites, never downloaded implicitly.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'packages/hysteria2'
MODULE = PACKAGE / 'go'
LOCK = json.loads((PACKAGE / 'build-lock.json').read_text(encoding='utf-8'))
BUILD = ROOT / 'build/hysteria2'
TOOLS = ROOT / 'build/tools/hysteria2'


def run(args, env, cwd=MODULE, capture=False):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True,
                          text=True, encoding='utf-8', stdout=subprocess.PIPE if capture else None).stdout


def digest(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()


def bootstrap_go(explicit):
    suffix = '.exe' if os.name == 'nt' else ''
    if explicit:
        return Path(explicit).resolve()
    go = TOOLS / ('go' + LOCK['go']) / 'go/bin' / ('go' + suffix)
    if go.exists():
        return go
    host = ('windows' if os.name == 'nt' else platform.system().lower()) + '-amd64'
    if platform.machine().lower() not in ('amd64', 'x86_64') or host not in LOCK['goArchives']:
        raise RuntimeError('Supply --go pointing to the exact pinned Go toolchain on this host')
    spec = LOCK['goArchives'][host]
    TOOLS.mkdir(parents=True, exist_ok=True)
    archive = TOOLS / spec['file']
    if not archive.exists() or digest(archive) != spec['sha256']:
        print('Downloading official ' + spec['file'], flush=True)
        temporary = archive.with_suffix('.download')
        with urllib.request.urlopen('https://go.dev/dl/' + spec['file'], timeout=120) as src:
            with temporary.open('wb') as dst:
                shutil.copyfileobj(src, dst)
        if digest(temporary) != spec['sha256']:
            temporary.unlink()
            raise RuntimeError('Go archive SHA256 mismatch')
        temporary.replace(archive)
    destination = go.parents[2]
    destination.mkdir(parents=True, exist_ok=True)
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as z:
            for name in z.namelist():
                if not (destination / name).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError('Unsafe Go archive member')
            z.extractall(destination)
    else:
        with tarfile.open(archive) as tar:
            tar.extractall(destination, filter='data')
    return go


def environment(go):
    env = os.environ.copy()
    env.update(GOTOOLCHAIN='local', GOWORK='off', GOFLAGS='-mod=readonly',
               GOPROXY='https://proxy.golang.org', GOSUMDB='sum.golang.org',
               GOPATH=str(TOOLS / 'gopath'), GOMODCACHE=str(TOOLS / 'modules'),
               GOCACHE=str(TOOLS / 'cache'), GOBIN=str(TOOLS / 'bin'),
               GOROOT=str(go.parents[1]))
    env['PATH'] = os.pathsep.join([str(go.parent), str(TOOLS / 'bin'), env['PATH']])
    # Host tests must not inherit an Android cross-compile environment.
    for key in ('GOOS', 'GOARCH', 'GOARM', 'CC', 'CXX', 'ANDROID_NDK_HOME'):
        env.pop(key, None)
    version = run([go, 'version'], env, capture=True).strip()
    if not version.startswith('go version go' + LOCK['go'] + ' '):
        raise RuntimeError('Expected Go ' + LOCK['go'] + ', got ' + version)
    return env


def json_stream(raw):
    decoder = json.JSONDecoder()
    while raw.strip():
        raw = raw.lstrip()
        item, end = decoder.raw_decode(raw)
        yield item
        raw = raw[end:]


def verify_upstream(go, env):
    for name in (LOCK['upstream']['module'], LOCK['upstream']['extras']):
        info = json.loads(run([go, 'mod', 'download', '-json', name + '@' + LOCK['upstream']['version']], env, capture=True))
        if info.get('Origin', {}).get('Hash') != LOCK['upstream']['commit']:
            raise RuntimeError('Upstream commit mismatch for ' + name)
    run([go, 'mod', 'verify'], env)


def tests(go, env):
    run([go, 'test', '-count=1', '-timeout=120s', './...'], env)
    run([go, 'vet', './...'], env)
    classes = BUILD / 'registry-tests'
    classes.mkdir(parents=True, exist_ok=True)
    sources = list((PACKAGE / 'android/src/main/java/dev/emby/hysteria2').glob('LeaseRegistry.java'))
    sources += list((PACKAGE / 'android/src/test/java/dev/emby/hysteria2').glob('LeaseRegistryTest.java'))
    run(['javac', '-encoding', 'UTF-8', '-d', classes, *sources], env)
    run(['java', '-ea', '-cp', classes, 'dev.emby.hysteria2.LeaseRegistryTest'], env)
    run([sys.executable, '-m', 'unittest', 'discover', '-s', PACKAGE / 'tool', '-p', 'test_*.py'], env)


def notices(go, env):
    packages = list(json_stream(run([go, 'list', '-deps', '-json', './mobile', 'golang.org/x/mobile/bind'], env, capture=True)))
    modules = {p['Module']['Path']: p['Module'] for p in packages if 'Module' in p and not p['Module'].get('Main')}
    sections = [('Go ' + LOCK['go'], [(Path(env['GOROOT']) / 'LICENSE')])]
    records = []
    for name, mod in sorted(modules.items()):
        if 'Replace' in mod:
            raise RuntimeError('Replaced modules are not permitted in native builds')
        directory = Path(mod['Dir'])
        files = sorted(p for p in directory.iterdir() if p.is_file() and
                       p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')))
        if not files:
            raise RuntimeError('Missing license for linked module: ' + name)
        texts = '\n'.join(p.read_text(encoding='utf-8') for p in files if p.name.upper().startswith(('LICENSE', 'COPYING')))
        if 'Permission is hereby granted' in texts:
            license_id = 'MIT'
        elif 'Apache License' in texts and 'Version 2.0' in texts:
            license_id = 'Apache-2.0'
        elif 'Redistribution and use in source and binary forms' in texts:
            license_id = 'BSD-3-Clause' if 'Neither the name' in texts else 'BSD-2-Clause'
        else:
            raise RuntimeError('Review unrecognized dependency license: ' + name)
        records.append({'module': name, 'version': mod['Version'], 'sum': mod.get('Sum'),
                        'license': license_id, 'licenses': {p.name: digest(p) for p in files}})
        sections.append((name + ' ' + mod['Version'], files))
    sections.append(('hysteria2 wrapper', [PACKAGE / 'LICENSE']))
    text = 'Embedded Hysteria2 Android native dependencies\n\n'
    for title, paths in sections:
        text += '=== ' + title + ' ===\n'
        for path in paths:
            text += '\n--- ' + path.name + ' ---\n' + path.read_text(encoding='utf-8') + '\n'
    return text.encode('utf-8'), records


def verifier():
    spec = importlib.util.spec_from_file_location('verify_hysteria2', PACKAGE / 'tool/verify_artifact.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_aar(go, env, sdk):
    if not sdk:
        raise RuntimeError('Set ANDROID_HOME or pass --android-sdk')
    sdk = Path(sdk).resolve()
    ndk = sdk / 'ndk' / LOCK['ndk']
    if not (ndk / 'source.properties').exists():
        raise RuntimeError('Install the pinned Android NDK ' + LOCK['ndk'])
    if ('Pkg.Revision = ' + LOCK['ndk']) not in (ndk / 'source.properties').read_text():
        raise RuntimeError('Android NDK revision mismatch')
    if not (sdk / 'platforms' / ('android-' + str(LOCK['androidPlatform'])) / 'android.jar').exists():
        raise RuntimeError('Install Android SDK platform ' + str(LOCK['androidPlatform']))
    env = env.copy()
    env.update(ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk), ANDROID_NDK_HOME=str(ndk))
    suffix = '.exe' if os.name == 'nt' else ''
    (TOOLS / 'bin').mkdir(parents=True, exist_ok=True)
    for name in ('gobind', 'gomobile'):
        run([go, 'build', '-trimpath', '-o', TOOLS / 'bin' / (name + suffix), 'golang.org/x/mobile/cmd/' + name], env)
    BUILD.mkdir(parents=True, exist_ok=True)
    raw = BUILD / 'hysteria2-raw.aar'
    run([TOOLS / 'bin' / ('gomobile' + suffix), 'bind', '-target=' + LOCK['gomobileTarget'],
         '-androidapi=' + str(LOCK['androidApi']), '-javapkg=dev.emby.hysteria2.core',
         '-trimpath', '-ldflags=-s -w -buildid= -extldflags=-Wl,-z,max-page-size=16384', '-o', raw, './mobile'], env)
    notice, dependencies = notices(go, env)
    output = PACKAGE / 'android/libs'
    output.mkdir(parents=True, exist_ok=True)
    aar = output / 'hysteria2.aar'
    temporary = output / 'hysteria2.tmp.aar'
    # Normalize ZIP metadata; Go build IDs and absolute source paths are removed.
    with zipfile.ZipFile(raw) as src, zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as dst:
        members = {name: src.read(name) for name in src.namelist() if not name.endswith('/')}
        members['assets/hysteria2/THIRD_PARTY_NOTICES.txt'] = notice
        for name, data in sorted(members.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            dst.writestr(info, data)
    check = verifier()
    manifest = {'schema': 1, 'upstream': LOCK['upstream'], 'go': LOCK['go'], 'mobile': LOCK['mobile'],
                'ndk': LOCK['ndk'], 'abis': LOCK['abis'], 'sha256': digest(temporary),
                'inputs': check.source_inputs(PACKAGE), 'libraries': check.libraries(temporary),
                'noticesSha256': hashlib.sha256(notice).hexdigest(), 'dependencies': dependencies}
    temporary.replace(aar)
    provenance = output / 'hysteria2.provenance.json'
    provenance.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    check.verify(aar, provenance, PACKAGE)
    print('hysteria2_aar=PASSED ' + str(aar), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['test', 'aar', 'all', 'verify'], nargs='?', default='all')
    parser.add_argument('--android-sdk', default=os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT'))
    parser.add_argument('--go', help='Use exactly Go ' + LOCK['go'] + ' instead of bootstrapping it')
    args = parser.parse_args()
    if args.mode == 'verify':
        output = PACKAGE / 'android/libs'
        verifier().verify(output / 'hysteria2.aar', output / 'hysteria2.provenance.json', PACKAGE)
        print('hysteria2_provenance=PASSED')
        return
    go = bootstrap_go(args.go)
    env = environment(go)
    verify_upstream(go, env)
    if args.mode in ('test', 'all'):
        tests(go, env)
    if args.mode in ('aar', 'all'):
        build_aar(go, env, args.android_sdk)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print('hysteria2_build=FAILED ' + str(exc), file=sys.stderr)
        sys.exit(1)
