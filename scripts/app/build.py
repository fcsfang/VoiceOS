#!/usr/bin/env python3
"""Build a local development app; no permissions request, install or daemon."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, shutil, subprocess
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--semantic-model', type=Path, help='explicit reviewed local CoreML asset directory; no download')
args = parser.parse_args()
env = dict(os.environ)
env.pop('SDKROOT', None)
subprocess.run(['xcrun', '--sdk', 'macosx', 'swift', 'build'], cwd=ROOT, env=env, check=True)
bin_path = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', 'swift', 'build', '--show-bin-path'], cwd=ROOT, env=env, text=True).strip())
app = ROOT / 'dist' / 'VoiceOS.app'
mac = app / 'Contents' / 'MacOS'
mac.mkdir(parents=True, exist_ok=True)
shutil.copy2(bin_path / 'VoiceOS', mac / 'VoiceOS')
resources = app / 'Contents' / 'Resources' / 'BGE'
if resources.exists(): shutil.rmtree(resources)  # Only generated build resources.
if args.semantic_model:
    source = args.semantic_model.resolve()
    manifest = json.loads((source / 'manifest.json').read_text())
    assert manifest['format'] == 'voiceos-bge-coreml-v1'
    assert manifest['revision'] == '7999e1d3359715c523056ef9478215996d62a620'
    resources.mkdir(parents=True)
    for entry in manifest['files']:
        relative = Path(entry['path'])
        assert not relative.is_absolute() and '..' not in relative.parts
        assert relative.parts[0] == 'Encoder.mlmodelc' or entry['path'] == 'vocab.txt'
        file = source / relative
        assert file.is_file() and not file.is_symlink() and file.resolve().is_relative_to(source)
        data = file.read_bytes()
        assert len(data) == entry['bytes'] and hashlib.sha256(data).hexdigest() == entry['sha256']
        target = resources / relative; target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(data)
    shutil.copy2(source / 'manifest.json',resources / 'manifest.json')
    notice = app / 'Contents' / 'Resources' / 'ThirdParty' / 'BGE-MIT.txt'
    notice.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT / 'docs' / 'licenses' / 'BGE-MIT.txt',notice)
info = dict(CFBundleIdentifier='local.voiceos.app', CFBundleName='VoiceOS', CFBundleDisplayName='VoiceOS', CFBundleExecutable='VoiceOS', CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1', LSMinimumSystemVersion='26.0', NSHighResolutionCapable=True, NSRemindersFullAccessUsageDescription='VoiceOS 在你明确选定的清单创建任务并回读完成状态；其他清单的任务不会读取或修改。')
with (app / 'Contents' / 'Info.plist').open('wb') as f: plistlib.dump(info, f)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
print(app)
