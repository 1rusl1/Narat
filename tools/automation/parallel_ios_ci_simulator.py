#!/usr/bin/env python3
"""Select a compatible iPhone 17 Pro from actual CoreSimulator inventory.

Selection is read-only by default. An ephemeral CI runner may explicitly allow
creation when its compatible device type and runtime exist but no device does.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

PHONE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
RUNTIME_PREFIX = 'com.apple.CoreSimulator.SimRuntime.iOS-'


def command(*args):
    result = subprocess.run(list(args), capture_output=True, text=True, check=True, timeout=60)
    return result.stdout.strip()


def version(value):
    return tuple(int(part) for part in re.findall(r'\d+', value))


def select(create_if_needed=False):
    sdk = command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version')
    major = version(sdk)[0]
    runtime_prefix = RUNTIME_PREFIX + str(major) + '-'
    inventory = json.loads(command('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))
    choices = []
    for runtime, devices in inventory['devices'].items():
        if not runtime.startswith(runtime_prefix):
            continue
        for device in devices:
            kind = device.get('deviceTypeIdentifier')
            matching = kind == PHONE or (kind is None and device.get('name') == 'iPhone 17 Pro')
            if device.get('isAvailable') and matching:
                choices.append((device.get('state') == 'Booted', version(runtime[len(RUNTIME_PREFIX):]), runtime, device))
    if choices:
        _, _, runtime, device = max(choices, key=lambda item: (item[0], item[1], item[3]['udid']))
        return {'simulator': str(uuid.UUID(device['udid'])).upper(), 'runtime': runtime, 'sdk': sdk, 'created': False}
    if not create_if_needed:
        raise RuntimeError(f'No available iPhone 17 Pro simulator for the iOS {major} SDK')
    types = json.loads(command('xcrun', 'simctl', 'list', 'devicetypes', '--json'))
    if not any(item['identifier'] == PHONE for item in types['devicetypes']):
        raise RuntimeError('The selected Xcode has no iPhone 17 Pro device type')
    available = json.loads(command('xcrun', 'simctl', 'list', 'runtimes', '--json'))
    runtimes = [item for item in available['runtimes']
                if item.get('isAvailable') and item['identifier'].startswith(runtime_prefix)]
    if not runtimes:
        raise RuntimeError(f'No available iOS {major} runtime for the selected Xcode')
    runtime = max(runtimes, key=lambda item: version(item['version']))['identifier']
    selected = command('xcrun', 'simctl', 'create', 'Narat CI', PHONE, runtime)
    return {'simulator': str(uuid.UUID(selected)).upper(), 'runtime': runtime, 'sdk': sdk, 'created': True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--create-if-needed', action='store_true')
    parser.add_argument('--env-output', type=Path, help='Append the selected UUID to a GitHub environment file')
    args = parser.parse_args(argv)
    try:
        result = select(args.create_if_needed)
        if args.env_output is not None:
            with args.env_output.open('a') as output:
                output.write('NARAT_CI_SIMULATOR=' + result['simulator'] + '\n')
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
