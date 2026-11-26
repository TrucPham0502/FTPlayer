#!/usr/bin/env python3
"""Stage and install only patched hls.o for every shipped FFmpeg architecture."""
import argparse
import hashlib
import json
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(*args, cwd=None):
    return subprocess.check_output([str(a) for a in args], cwd=cwd)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('ffmpeg_source', type=Path, help='Complete source matching VendorPatches metadata')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
patches = root / 'SDK/VendorPatches'
metadata_path = patches / 'metadata.json'
metadata = json.loads(metadata_path.read_text())
source = args.ffmpeg_source.resolve()
assert digest(source / 'libavformat/hls.c') == metadata['sourceOriginalSHA256'], 'FFmpeg source does not match the recorded base'
assert digest(patches / 'hls.c') == metadata['sourcePatchedSHA256'], 'Patched source hash differs'
work = Path(tempfile.mkdtemp(prefix='FPlayer-hls-patch-'))
copy = work / 'source'
copy.mkdir()
source_dirs = {'libavcodec', 'libavformat', 'libavutil', 'libavfilter', 'libavdevice', 'libswscale', 'libswresample', 'compat', 'ffbuild', 'doc', 'tests', 'tools', 'fftools'}
for path in source.iterdir():
    if path.is_file() and path.name not in {'config.h', 'config.asm', 'config_components.h'}:
        shutil.copy2(path, copy / path.name)
    elif path.name in source_dirs:
        shutil.copytree(path, copy / path.name, ignore=shutil.ignore_patterns('*.o', '*.a', '*.d', '*.so', '*.dylib', '*.framework', 'config.mak', 'config.log'))
shutil.copy2(patches / 'hls.c', copy / 'libavformat/hls.c')
report = {'work': str(work), 'source': str(source), 'binaries': {}, 'configurations': {}}
staged = {}
mac_objects = {}
for platform, sdk, arch in [('ios-arm64', 'iphoneos', 'arm64'), ('ios-arm64-simulator', 'iphonesimulator', 'arm64'), ('macos-arm64', 'macosx', 'arm64'), ('macos-x86_64', 'macosx', 'x86_64')]:
    slice_name = 'macos-arm64_x86_64' if platform.startswith('macos-') else platform
    binary = root / 'SDK/Vendor/FFmpeg/libavformat.xcframework' / slice_name / 'libavformat.framework/libavformat'
    build = work / platform
    build.mkdir()
    original = build / 'original.a'
    if platform.startswith('macos-'):
        run('lipo', binary, '-thin', arch, '-output', original)
    else:
        shutil.copy2(binary, original)
    # Preserve the currently shipped feature flags, rather than stale metadata.
    configs = [line for line in run('strings', original).decode(errors='replace').splitlines() if line.startswith('--') and '--enable-cross-compile' in line]
    assert len(set(configs)) == 1, f'Ambiguous FFmpeg configuration: {platform}'
    config = shlex.split(configs[0])
    config = [x for x in config if not x.startswith(('--prefix=', '--cc=', '--sysroot='))]
    config += ['--prefix=' + str(build / 'install'), '--cc=' + run('xcrun', '-find', 'clang').decode().strip(), '--sysroot=' + run('xcrun', '--sdk', sdk, '--show-sdk-path').decode().strip()]
    report['configurations'][platform] = config
    subprocess.run([str(copy / 'configure')] + config, cwd=build, check=True)
    subprocess.run(['make', '-j4', 'libavformat/hls.o'], cwd=build, check=True)
    replacement = build / 'patched.a'
    shutil.copy2(original, replacement)
    members = run('ar', '-t', original).decode().splitlines()
    assert members.count('hls.o') == 1
    subprocess.run(['ar', '-r', str(replacement), str(build / 'libavformat/hls.o')], check=True)
    subprocess.run(['ranlib', str(replacement)], check=True)
    assert run('ar', '-t', replacement).decode().splitlines() == members
    unchanged = [member for member in members if member != 'hls.o' and not member.startswith(('__.SYMDEF', '/'))]
    assert hashlib.sha256(run('ar', '-p', original, *unchanged)).digest() == hashlib.sha256(run('ar', '-p', replacement, *unchanged)).digest(), 'Non-HLS object changed'
    if platform.startswith('macos-'):
        mac_objects[arch] = replacement
    else:
        staged[binary] = replacement
mac_binary = root / 'SDK/Vendor/FFmpeg/libavformat.xcframework/macos-arm64_x86_64/libavformat.framework/libavformat'
mac_stage = work / 'macos-universal.a'
run('lipo', '-create', mac_objects['arm64'], mac_objects['x86_64'], '-output', mac_stage)
staged[mac_binary] = mac_stage
# Nothing is installed until all four objects compile and all other members verify.
for binary, replacement in staged.items():
    before = digest(binary)
    shutil.copy2(binary, work / (binary.parents[1].name + '-backup.a'))
    shutil.copy2(replacement, binary)
    report['binaries'][binary.parents[1].name] = {'before': before, 'after': digest(binary)}
metadata['hlsObjectRebuild'] = {'sourceSHA256': metadata['sourcePatchedSHA256'], 'binaries': report['binaries']}
metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
for platform, config in report['configurations'].items():
    (patches / (platform + '-configuration.json')).write_text(json.dumps(config, indent=2) + '\n')
(work / 'rebuild-report.json').write_text(json.dumps(report, indent=2) + '\n')
print('Installed patched hls.o for all shipped architectures; other objects verified unchanged.')
print('Build evidence and backups:', work)
