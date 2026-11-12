"""Check out explicitly pinned engine revisions beside the application in CI."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = {'RecurseX': 'recurse-x', 'Corduit': 'corduit'}
PATCHES = {'Corduit': ROOT / 'scripts' / 'patches' / 'corduit-network.patch'}


def engine_patches(parent, *, apply=False):
    """Apply reviewed fixes atomically per repo; never reset developer changes."""
    for repo, patch_file in PATCHES.items():
        command = ['git', '-C', str(parent / repo), 'apply', '--whitespace=error']
        reverse = subprocess.run(command + ['--reverse', '--check', str(patch_file)],
                                 capture_output=True, text=True)
        if reverse.returncode == 0:
            continue
        if not apply:
            raise ValueError(f'{repo}: required network fixes missing; run '
                             'python scripts/checkout_engines.py --apply-patches')
        subprocess.run(command + ['--check', str(patch_file)], check=True)
        subprocess.run(command + [str(patch_file)], check=True)


def revisions(file=ROOT / 'scripts' / 'engine_revisions.json'):
    pins = json.loads(file.read_text(encoding='utf-8'))
    if not isinstance(pins, dict) or set(pins) != set(PACKAGES):
        raise ValueError(f'{file}: expected exactly RecurseX and Corduit revisions')
    result = {}
    for repo in PACKAGES:
        revision = pins[repo]
        if not isinstance(revision, str) or not re.fullmatch(r'[0-9a-fA-F]{40}', revision):
            raise ValueError(f'{file}: {repo} must be a full 40-character pushed commit; '
                             'branches and implicit HEAD are refused')
        result[repo] = revision.lower()
    return result


def locked_versions(file=ROOT / 'rust' / 'Cargo.lock'):
    with file.open('rb') as stream:
        lock = tomllib.load(stream)
    result = {}
    for repo, package in PACKAGES.items():
        entries = [p for p in lock.get('package', []) if p['name'] == package]
        if len(entries) != 1 or entries[0].get('source') is not None:
            raise ValueError(f'{package}: expected one sibling package in {file}')
        result[repo] = entries[0]['version']
    return result


def validate_package(directory, repo, version):
    with (directory / 'Cargo.toml').open('rb') as stream:
        package = tomllib.load(stream).get('package', {})
    validate_package_data(package, repo, version)


def validate_package_data(package, repo, version):
    if package.get('name') != PACKAGES[repo] or package.get('version') != version:
        raise ValueError(f'{repo}: fetched package must be {PACKAGES[repo]} {version}, '
                         'matching rust/Cargo.lock')


def verify_local(parent, pins, versions):
    """Check CI pins without resetting, fetching or editing developer checkouts."""
    for repo, revision in pins.items():
        manifest = subprocess.check_output(
            ['git', '-C', str(parent / repo), 'show', f'{revision}:Cargo.toml'],
            text=True, encoding='utf-8', stderr=subprocess.PIPE, timeout=30)
        validate_package_data(tomllib.loads(manifest).get('package', {}), repo, versions[repo])
        print(f'{repo}: pinned source matches {versions[repo]}', flush=True)


def checkout(parent, pins, versions):
    # Validate all destinations before changing any checkout. Never replace a local repo.
    destinations = {repo: parent / repo for repo in pins}
    for destination in destinations.values():
        if destination.exists():
            raise ValueError(f'Refusing to replace existing checkout: {destination}')
    for repo, revision in pins.items():
        destination = destinations[repo]
        subprocess.run(['git', 'init', str(destination)], check=True)
        subprocess.run(['git', '-C', str(destination), 'remote', 'add', 'origin',
                        f'https://github.com/blueokanna/{repo}.git'], check=True)
        subprocess.run(['git', '-C', str(destination), 'fetch', '--depth=1', '--no-tags',
                        'origin', revision], check=True, timeout=180)
        subprocess.run(['git', '-C', str(destination), 'checkout', '--detach', revision], check=True)
        actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'],
                                         text=True).strip()
        if actual != revision:
            raise ValueError(f'{repo}: fetched commit does not match the pin')
        validate_package(destination, repo, versions[repo])
        print(f'{repo}: {actual}', flush=True)
    engine_patches(parent, apply=True)


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument('--verify-local', action='store_true',
                            help='Verify pinned manifests using existing Git objects; do not change checkouts')
        mode.add_argument('--apply-patches', action='store_true',
                          help='Apply the tracked engine fixes to existing sibling checkouts')
        options = parser.parse_args()
        if options.apply_patches:
            verify_local(ROOT.parent, revisions(), locked_versions())
            engine_patches(ROOT.parent, apply=True)
        elif options.verify_local:
            verify_local(ROOT.parent, revisions(), locked_versions())
            engine_patches(ROOT.parent)
        else:
            checkout(ROOT.parent, revisions(), locked_versions())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f'Engine checkout failed: {error}')
