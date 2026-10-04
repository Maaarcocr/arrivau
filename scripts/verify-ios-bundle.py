#!/usr/bin/env python3
"""Check actual unsigned Release bundle contents, not just source files."""
from pathlib import Path
import plistlib
import sys

def verify(path):
    bundle = Path(path)
    info = plistlib.loads((bundle/'Info.plist').read_bytes())
    if 'NSAppTransportSecurity' in info:
        raise ValueError('Release must not contain insecure transport exceptions')
    if info.get('UIDeviceFamily') != [1]:
        raise ValueError('The current supervised pilot must target iPhone only')
    icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
    if icon.get('CFBundleIconName') != 'AppIcon' or not (bundle/'Assets.car').is_file():
        raise ValueError('Compiled AppIcon is missing from the actual application bundle')
    privacy = plistlib.loads((bundle/'PrivacyInfo.xcprivacy').read_bytes())
    if privacy.get('NSPrivacyTracking') is not False:
        raise ValueError('Privacy manifest is missing or inconsistent')
    binary = (bundle/info['CFBundleExecutable']).read_bytes()
    if any(token in binary for token in [b'demo-dispatcher', b'demo-driver-1', b'demo-driver-2']):
        raise ValueError('A public demo bearer token is present in the Release binary')
    if not info.get('CFBundleShortVersionString') or not info.get('CFBundleVersion'):
        raise ValueError('Version/build metadata is missing')
    return True

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: verify-ios-bundle.py PATH/Arrivau.app')
    verify(sys.argv[1])
    print('Release bundle has compiled icon, privacy manifest, iPhone metadata, strict transport and no demo bearer strings')
