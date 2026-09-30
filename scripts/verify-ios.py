"""Verify the exported app and keyboard against their distribution profiles."""
import datetime
import pathlib
import plistlib
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(root, team, method):
    apps = list(pathlib.Path(root).glob('Payload/*.app'))
    require(len(apps) == 1, 'Expected one exported app')
    extensions = list(apps[0].glob('PlugIns/*.appex'))
    require(len(extensions) == 1, 'Expected the keyboard extension')
    ids = ['sh.arpan.omil.ios', 'sh.arpan.omil.ios.keyboard']
    versions = []
    devices = []
    for bundle, bundle_id in zip([apps[0], *extensions], ids):
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
        signing = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(bundle)],
            stderr=subprocess.STDOUT, text=True)
        require('Authority=Apple Distribution:' in signing, 'Expected Apple Distribution signature')
        require(f'TeamIdentifier={team}' in signing, 'Wrong certificate team')
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        require(info['CFBundleIdentifier'] == bundle_id, 'Unexpected bundle ID')
        versions.append((info['CFBundleShortVersionString'], info['CFBundleVersion']))
        profile = plistlib.loads(subprocess.check_output([
            'security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')]))
        ent = plistlib.loads(subprocess.check_output([
            'codesign', '-d', '--entitlements', '-', str(bundle)], stderr=subprocess.DEVNULL))
        require(team in profile['TeamIdentifier'], 'Wrong provisioning team')
        require(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile')
        require(ent['com.apple.developer.team-identifier'] == team, 'Wrong signing team')
        app_id = team + '.' + bundle_id
        require(ent['application-identifier'] == app_id, 'Wrong signing application ID')
        require(profile['Entitlements']['application-identifier'] == app_id, 'Wrong profile application ID')
        require(not ent.get('get-task-allow', False), 'Development-signed export')
        group = 'group.sh.arpan.omil.shared'
        require(group in ent.get('com.apple.security.application-groups', []), 'Missing signed App Group')
        require(group in profile['Entitlements'].get('com.apple.security.application-groups', []), 'Profile missing App Group')
        if method == 'release-testing':
            require(profile.get('ProvisionedDevices'), 'No registered devices in ad hoc profile')
            devices.append(set(profile['ProvisionedDevices']))
        else:
            require(not profile.get('ProvisionedDevices'), 'Unexpected device profile for App Store export')
            require(not profile.get('ProvisionsAllDevices'), 'Enterprise profile in App Store export')
    require(versions[0] == versions[1], 'App and keyboard versions differ')
    if devices:
        require(devices[0] == devices[1], 'App and keyboard device lists differ')
    print('Verified iOS app and keyboard signatures, profiles, App Groups, and versions.')


if __name__ == '__main__':
    verify(*sys.argv[1:])
