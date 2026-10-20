#!/usr/bin/env python3
"""Launch the development preview using the existing local configuration, no auto-send."""
import argparse
import os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--data-dir', type=Path, help='optional isolated development data root')
args = parser.parse_args()
app = ROOT / 'dist/VoiceOS.app/Contents/MacOS/VoiceOS'
if not app.exists():
    parser.error('Build the app first with scripts/app/build.py')
env = dict(os.environ)
config = ROOT / '.env'
if config.exists():
    env['VOICEOS_MODEL_CONFIG_FILE'] = str(config)
if args.data_dir:
    env['VOICEOS_DATA_DIR'] = str(args.data_dir.resolve())
os.execve(str(app), [str(app)], env)
