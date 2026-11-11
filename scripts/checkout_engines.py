"""Check out explicitly pinned engine revisions beside the application in CI."""

import os
from pathlib import Path
import re
import subprocess
import sys


def revisions(environment):
    result = {}
    for repo, variable in [('RecurseX', 'RECURSEX_REVISION'), ('Corduit', 'CORDUIT_REVISION')]:
        revision = environment.get(variable, '')
        if not re.fullmatch(r'[0-9a-fA-F]{40}', revision):
            raise ValueError(f'{variable} must be the full 40-character commit of the reviewed '
                             f'and pushed {repo} changes; branches and implicit HEAD are refused')
        result[repo] = revision.lower()
    return result


def checkout(parent, pins):
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
        subprocess.run(['git', '-C', str(destination), 'fetch', '--depth=1', 'origin', revision], check=True)
        subprocess.run(['git', '-C', str(destination), 'checkout', '--detach', 'FETCH_HEAD'], check=True)
        actual = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'],
                                         text=True).strip()
        if actual != revision:
            raise ValueError(f'{repo}: fetched commit does not match the pin')
        print(f'{repo}: {actual}', flush=True)


if __name__ == '__main__':
    try:
        checkout(Path(__file__).resolve().parents[2], revisions(os.environ))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'Engine checkout failed: {error}')
