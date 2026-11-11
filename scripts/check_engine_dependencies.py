"""Verify sibling engine sources and shared DNS, socket-factory and JNI identities."""

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


def workspace_sources(rust, manifest):
    sources = {'corduit': rust.parent.parent / 'Corduit',
               'recurse-x': rust.parent.parent / 'RecurseX'}
    patches = manifest.get('patch', {}).get('crates-io', {})
    for name, directory in sources.items():
        patch = patches.get(name, {})
        if (set(patch) != {'path'} or
                (rust / patch['path']).resolve() != directory.resolve()):
            raise ValueError(f'{name}: expected the sibling repository patch')
        package = read_toml(directory / 'Cargo.toml')['package']
        if package['name'] != name:
            raise ValueError(f'{name}: sibling repository package mismatch')
    return sources


def validate_lock(lock, local_versions=None):
    expected = {}
    for name in PACKAGES:
        entries = [entry for entry in lock.get('package', []) if entry['name'] == name]
        if len(entries) != 1:
            raise ValueError(f'{name}: expected one locked package, found {len(entries)}')
        entry = entries[0]
        if name in (local_versions or {}):
            if entry.get('source') is not None or entry['version'] != local_versions[name]:
                raise ValueError(f'{name}: expected the sibling repository version')
            expected[name] = entry['version']
            continue
        if (entry.get('source') != REGISTRY
                or not re.fullmatch(r'[0-9a-f]{64}', entry.get('checksum', ''))):
            raise ValueError(f'{name}: expected a checksummed crates.io release')
        expected[name] = entry['version']
    return expected


def validate_graph(metadata, expected, local_paths=None):
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
        source_matches = package['source'] == REGISTRY
        if name in (local_paths or {}):
            source_matches = (package['source'] is None and
                              Path(package['manifest_path']).resolve() ==
                              (local_paths[name] / 'Cargo.toml').resolve())
        if not source_matches or package['version'] != version:
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
    manifest = read_toml(rust / 'Cargo.toml')
    validate_manifest(manifest)
    sources = workspace_sources(rust, manifest)
    versions = {name: read_toml(path / 'Cargo.toml')['package']['version']
                for name, path in sources.items()}
    expected = validate_lock(read_toml(rust / 'Cargo.lock'), versions)
    subprocess.run([sys.executable, str(rust.parent / 'scripts' / 'checkout_engines.py'),
                    '--verify-local'], check=True)
    command = ['cargo', 'metadata', '--manifest-path', str(rust / 'Cargo.toml'),
               '--format-version=1', '--locked', '--all-features']
    if options.offline:
        command.append('--offline')
    result = subprocess.run(command, check=True, capture_output=True, text=True, encoding='utf-8')
    validate_graph(json.loads(result.stdout), expected, sources)
    for name, version in expected.items():
        source = str(sources[name]) if name in sources else 'checksummed crates.io package'
        print(f'{name} {version}: one {source}')
    print('Shared RecurseX, Courierust and Android JNI identities verified')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Engine dependency check failed: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
