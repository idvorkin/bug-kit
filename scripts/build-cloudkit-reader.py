#!/usr/bin/env python3
"""Build the provisioned headless Mac app; signing values stay in a local JSON config."""
import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home() / '.config/bug-kit/cloudkit.json')
    parser.add_argument('--unsigned', action='store_true', help='Compile only; this build cannot access CloudKit')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    derived = root / 'DerivedData/CloudKitReader'
    command = ['xcodebuild', '-project', str(root / 'Tools/CloudKitReader/BugKitCloudReader.xcodeproj'),
               '-scheme', 'BugKitCloudReader', '-destination', 'platform=macOS',
               '-derivedDataPath', str(derived), '-jobs', '2']
    config = None
    if args.unsigned:
        command += ['CODE_SIGNING_ALLOWED=NO']
    else:
        config = json.loads(args.config.expanduser().read_text())
        for key, pattern in [('team', r'[A-Z0-9]{10}'), ('bundle', r'[A-Za-z0-9][A-Za-z0-9.-]+'),
                             ('container', r'iCloud\.[A-Za-z0-9][A-Za-z0-9.-]+')]:
            if not isinstance(config.get(key), str) or not re.fullmatch(pattern, config[key]):
                parser.error(f'local config needs a valid {key}')
        if not isinstance(config.get('app'), str) or not Path(config['app']).expanduser().is_absolute() or not config['app'].endswith('.app'):
            parser.error('app must be an absolute .app destination path (leading ~ is accepted)')
        if config.get('environment') != 'Development':
            parser.error('this build uses Apple Development signing; environment must be Development. '
                         'Production requires a separately provisioned distribution reader')
        derived.mkdir(parents=True, exist_ok=True)
        local = derived / 'signing.xcconfig'
        local.write_text('\n'.join(f'{setting} = {config[key]}' for key, setting in [
            ('team', 'BUGKIT_SIGNING_TEAM'), ('bundle', 'BUGKIT_READER_BUNDLE_ID'),
            ('container', 'BUGKIT_CLOUD_CONTAINER')]) + '\n')
        local.chmod(0o600)
        command += ['-xcconfig', str(local), '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration']
        lock = Path.home() / 'tmp/agent/locks/xcode-signing.lock'
        lock.parent.mkdir(parents=True, exist_ok=True)
        command = ['lockf', '-k', '-t', '900', str(lock), str(root / 'scripts/signing-guard.sh')] + command
    subprocess.run(['xcodegen', 'generate', '--spec', str(root / 'Tools/CloudKitReader/project.yml')], check=True)
    # Logs can contain local identifiers. Keep them outside version control, and show a sanitized result.
    derived.mkdir(parents=True, exist_ok=True)
    with (derived / 'build.log').open('w') as log:
        result = subprocess.run(command + ['build'], stdout=log, stderr=subprocess.STDOUT)
    print(f'Build exit: {result.returncode}; local details: {derived / "build.log"}')
    if result.returncode:
        return result.returncode
    built = derived / 'Build/Products/Debug/BugKitCloudReader.app'
    if config:
        if not (built / 'Contents/embedded.provisionprofile').is_file():
            print('Signing did not embed a provisioning profile; do not use this app for CloudKit.')
            return 1
        subprocess.run(['codesign', '--verify', '--strict', str(built)], check=True)
        destination = Path(config['app']).expanduser()
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(built, destination)
        print(f'Installed headless app: {destination}')
    else:
        print(f'Unsigned app: {built}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
