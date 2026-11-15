#!/usr/bin/env python3
"""Verify the signed app, including permissions needed by WebRTC UDP."""
import plistlib
import subprocess
import sys
from pathlib import Path

bundle = Path(sys.argv[1] if len(sys.argv) > 1 else 'dist/GPT Live.app')
if not bundle.is_dir():
    sys.exit(f'App bundle not found: {bundle}')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
signed = subprocess.run(
    ['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)],
    check=True, capture_output=True,
)
entitlements = plistlib.loads(signed.stdout)
required = [
    'com.apple.security.app-sandbox',
    'com.apple.security.device.audio-input',
    'com.apple.security.network.client',
    'com.apple.security.network.server',
]
missing = [key for key in required if entitlements.get(key) is not True]
if missing:
    sys.exit('Missing signed release entitlements: ' + ', '.join(missing))
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
if not info.get('NSMicrophoneUsageDescription'):
    sys.exit('Missing microphone permission description')
print('PASS: signature, sandbox, microphone and bidirectional WebRTC UDP permissions.')
