#!/usr/bin/env python3
"""Launch the development preview using the existing local configuration, no auto-send."""
import argparse
import os
import math
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--data-dir', type=Path, help='optional isolated development data root')
parser.add_argument('--capture-limit-seconds', type=float, help='explicit device-side timed capture; requires isolated --data-dir, does not start recording')
args = parser.parse_args()
if args.capture_limit_seconds is not None and (not args.data_dir or not math.isfinite(args.capture_limit_seconds) or not 0 < args.capture_limit_seconds <= 60):
    parser.error('Capture limit requires --data-dir and a finite duration between 0 and 60 seconds')
app = ROOT / 'dist/VoiceOS.app/Contents/MacOS/VoiceOS'
if not app.exists():
    parser.error('Build the app first with scripts/app/build.py')
env = dict(os.environ)
env.pop('VOICEOS_TEST_CAPTURE_SECONDS', None)
if args.capture_limit_seconds is not None:
    env['VOICEOS_TEST_CAPTURE_SECONDS'] = str(args.capture_limit_seconds)
config = ROOT / '.env'
if config.exists():
    env['VOICEOS_MODEL_CONFIG_FILE'] = str(config)
if args.data_dir:
    env['VOICEOS_DATA_DIR'] = str(args.data_dir.resolve())
os.execve(str(app), [str(app)], env)
