"""Verify locked registry dependencies and shared DNS/JNI identities."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

PACKAGES = ('corduit', 'recurse-x', 'courierust')
REGISTRY = 'registry+https://github.com/rust-lang/crates.io-index'


def read_toml(file):
    with file.open('rb') as stream:
        return tomllib.load(stream)


def validate_manifest(manifest):
    dependencies = manifest.get('dependencies', {})
    for name in ('corduit', 'recurse-x'):
        value = dependencies.get(name)
        if isinstance(value, str):
            value = {'version': value}
        if (not isinstance(value, dict) or not value.get('version')
                or any(key in value for key in ('path', 'git', 'registry', 'workspace'))):
            raise ValueError(f'{name} must use a crates.io version dependency')


def validate_lock(lock):
    expected = {}
    for name in PACKAGES:
        entries = [entry for entry in lock.get('package', []) if entry['name'] == name]
        if len(entries) != 1:
            raise ValueError(f'{name}: expected one locked package, found {len(entries)}')
        entry = entries[0]
        if (entry.get('source') != REGISTRY
                or not re.fullmatch(r'[0-9a-f]{64}', entry.get('checksum', ''))):
            raise ValueError(f'{name}: expected a checksummed crates.io release')
        expected[name] = entry['version']
    return expected


def validate_graph(metadata, expected):
    resolve = metadata.get('resolve')
    if not resolve or not resolve.get('root'):
        raise ValueError('Cargo metadata must include the resolved bridge graph')
    nodes = {node['id']: node for node in resolve['nodes']}
    identities = {}
    for name, version in expected.items():
        packages = [package for package in metadata['packages']
                    if package['id'] in nodes and package['name'] == name]
        if len(packages) != 1:
            raise ValueError(f'{name}: expected one shared package, found {len(packages)}')
        package = packages[0]
        if package['source'] != REGISTRY or package['version'] != version:
            raise ValueError(f'{name}: Cargo resolved an unexpected source: {package["id"]}')
        identities[name] = package['id']

    def edge(owner, name):
        dependencies = [item['pkg'] for item in nodes[owner]['deps'] if item['name'] == name]
        if len(dependencies) != 1:
            raise ValueError(f'{owner}: expected exactly one {name} dependency')
        return dependencies[0]

    bridge = resolve['root']
    core = identities['corduit']
    resolver = identities['recurse-x']
    if edge(bridge, 'corduit') != core:
        raise ValueError('Bridge is not using the locked Corduit release')
    if edge(bridge, 'recurse_x') != resolver or edge(core, 'recurse_x') != resolver:
        raise ValueError('Bridge and Corduit must share RecurseX')
    if (edge(core, 'courierust') != identities['courierust']
            or edge(resolver, 'courierust') != identities['courierust']):
        raise ValueError('Corduit and RecurseX must share the Courierust socket factory')
    # Metadata is deliberately not filtered by the host platform. This checks
    # Android FFI types even when CI runs on a desktop host.
    if edge(bridge, 'jni') != edge(core, 'jni'):
        raise ValueError('Bridge and Corduit must share the Android JNI crate')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    options = parser.parse_args()
    rust = Path(__file__).resolve().parents[1] / 'rust'
    validate_manifest(read_toml(rust / 'Cargo.toml'))
    expected = validate_lock(read_toml(rust / 'Cargo.lock'))
    command = ['cargo', 'metadata', '--manifest-path', str(rust / 'Cargo.toml'),
               '--format-version=1', '--locked', '--all-features']
    if options.offline:
        command.append('--offline')
    result = subprocess.run(command, check=True, capture_output=True, text=True, encoding='utf-8')
    validate_graph(json.loads(result.stdout), expected)
    for name, version in expected.items():
        print(f'{name} {version}: one checksummed crates.io package')
    print('Shared RecurseX, Courierust and Android JNI identities verified')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Engine dependency check failed: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
