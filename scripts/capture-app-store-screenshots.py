"""Capture real Omil UI with fictional data on the two App Store size classes.

Run after building Debug-iphonesimulator. This never targets a physical device.
The fixture preferences replace data only on the explicitly chosen simulators.
"""
import argparse
import json
import pathlib
import plistlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEVICES = {
    'iphone': '57AD0DFC-2665-400B-A21C-AFDC5027DC13',
    'ipad': 'DD0BD851-E87A-4B58-8A86-3E2EE9987A4D',
}


def run(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--iphone', default=DEVICES['iphone'])
    parser.add_argument('--ipad', default=DEVICES['ipad'])
    args = parser.parse_args()
    available = json.loads(run('list', 'devices', 'available', '--json'))
    available_ids = {d['udid'] for ds in available['devices'].values() for d in ds}
    screens = json.loads((ROOT / 'release/app-store/source/screens.json').read_text())
    for kind, device in [('iphone', args.iphone), ('ipad', args.ipad)]:
        if device not in available_ids:
            raise ValueError(f'{device} is not an available simulator')
        subprocess.run(['xcrun', 'simctl', 'boot', device], capture_output=True)
        run('bootstatus', device, '-b')
        run('install', device, str(args.app.resolve()))
        container = pathlib.Path(run('get_app_container', device, 'sh.arpan.omil.ios', 'data'))
        preferences = container / 'Library/Preferences/sh.arpan.omil.ios.plist'
        preferences.parent.mkdir(parents=True, exist_ok=True)
        # Fictional connection details contain no personal credentials; DebugLaunch supplies demo state.
        preferences.write_bytes(plistlib.dumps({
            'omil.ios.onboarded': True,
            'omil.appearance': 'light',
            'omil.themePreset': 'graphite',
            'omil.serverConfig': json.dumps({'host': 'Studio-Mac.local', 'port': 3217,
                                             'token': 'screenshot-fixture', 'language': 'en'}).encode(),
        }))
        run('status_bar', device, 'override', '--time', '9:41', '--dataNetwork', 'wifi',
            '--wifiMode', 'active', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100')
        output = ROOT / 'release/app-store/screenshots/raw' / kind
        output.mkdir(parents=True, exist_ok=True)
        for screen in screens:
            subprocess.run(['xcrun', 'simctl', 'terminate', device, 'sh.arpan.omil.ios'], capture_output=True)
            capture = screen['capture']
            arguments = ['-OmilDemo', 'result']
            if capture == 'changes':
                arguments += ['-OmilTranscriptVersion', 'Changes']
            elif capture not in ('result', 'changes'):
                arguments += ['-OmilScreen', capture]
            # UserDefaults command-line overrides are scoped to this launch.
            arguments += ['-omil.appearance', screen['theme']]
            run('launch', device, 'sh.arpan.omil.ios', *arguments)
            time.sleep(3)
            path = output / f"{screen['id']}.png"
            run('io', device, 'screenshot', '--type=png', str(path))
            print(f'{kind}: {path.relative_to(ROOT)}', flush=True)
        run('status_bar', device, 'clear')
        subprocess.run(['xcrun', 'simctl', 'terminate', device, 'sh.arpan.omil.ios'], capture_output=True)


if __name__ == '__main__':
    main()
