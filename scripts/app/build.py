#!/usr/bin/env python3
"""Build a local development app; no permissions request, install or daemon."""
from pathlib import Path
import os, plistlib, shutil, subprocess
ROOT = Path(__file__).resolve().parents[2]
env = dict(os.environ)
env.pop('SDKROOT', None)
subprocess.run(['xcrun', '--sdk', 'macosx', 'swift', 'build'], cwd=ROOT, env=env, check=True)
bin_path = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', 'swift', 'build', '--show-bin-path'], cwd=ROOT, env=env, text=True).strip())
app = ROOT / 'dist' / 'VoiceOS.app'
mac = app / 'Contents' / 'MacOS'
mac.mkdir(parents=True, exist_ok=True)
shutil.copy2(bin_path / 'VoiceOS', mac / 'VoiceOS')
info = dict(CFBundleIdentifier='local.voiceos.app', CFBundleName='VoiceOS', CFBundleDisplayName='VoiceOS', CFBundleExecutable='VoiceOS', CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1', LSMinimumSystemVersion='26.0', NSHighResolutionCapable=True)
with (app / 'Contents' / 'Info.plist').open('wb') as f: plistlib.dump(info, f)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
print(app)
