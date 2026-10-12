"""Validate upload sizes, PNG color format, metadata, manifests, and policy links."""
import json
import pathlib
import plistlib
import struct

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'release/app-store'
screens = json.loads((PACKAGE / 'source/screens.json').read_text())
for platform, dimensions in [('iphone', (1320, 2868)), ('ipad', (2064, 2752))]:
    files = sorted((PACKAGE / 'screenshots' / platform).glob('*.png'))
    assert len(files) == len(screens) == 5, f'Missing {platform} screenshots'
    for path in files:
        data = path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height, depth, color = struct.unpack('>IIBB', data[16:26])
        assert (width, height) == dimensions, path
        assert depth == 8 and color == 2, f'Expected opaque RGB PNG: {path}'

for field, limit in [('name', 30), ('subtitle', 30), ('promotional-text', 170), ('keywords', 100), ('description', 4000), ('release-notes', 4000)]:
    text = (PACKAGE / 'en-US' / (field + '.txt')).read_text().strip()
    assert text and len(text) <= limit, f'{field}: {len(text)} exceeds {limit}'
description = (PACKAGE / 'en-US/description.txt').read_text()
assert 'REQUIRES YOUR OWN MAC' in description and 'English' in description

for bundle in ['iOS', 'Keyboard']:
    manifest = plistlib.loads((ROOT / f'Apps/{bundle}/PrivacyInfo.xcprivacy').read_bytes())
    assert manifest['NSPrivacyTracking'] is False
    assert manifest['NSPrivacyCollectedDataTypes'] == []
    reasons = manifest['NSPrivacyAccessedAPITypes'][0]
    assert reasons['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryUserDefaults'
    assert '1C8F.1' in reasons['NSPrivacyAccessedAPITypeReasons']
info = plistlib.loads((ROOT / 'Apps/iOS/Info.plist').read_bytes())
assert info['ITSAppUsesNonExemptEncryption'] is False
assert not info['NSAppTransportSecurity'].get('NSAllowsArbitraryLoads', False)

for slug in ['privacy', 'security', 'terms', 'support']:
    assert (ROOT / f'marketing/site/src/pages/{slug}.astro').is_file()
    assert f'/{slug}/' in (ROOT / 'marketing/site/src/components/Footer.astro').read_text()
    assert f'https://omil.arpan.sh/{slug}/' in (ROOT / 'Apps/iOS/SettingsView.swift').read_text()
print('PASS: 10 opaque screenshots with accepted dimensions, store field lengths, manifests, and app/site policy links.')
