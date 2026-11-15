"""Validate the current release notes before setup or packaging starts."""

import argparse
from pathlib import Path
import re
import sys


def release_section(pubspec: str, changelog: str) -> tuple[str, str]:
    versions = re.findall(
        r'^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?[ \t]*\r?$',
        pubspec, re.MULTILINE,
    )
    if len(versions) != 1:
        raise ValueError('pubspec.yaml must declare one stable MAJOR.MINOR.PATCH[+BUILD] version')
    version, build = versions[0]
    build = build or '1'
    lines = changelog.splitlines()
    heading = f'## {version}+{build}'
    if build == '1' and heading not in lines:
        heading = f'## {version}'
    if lines.count(heading) != 1:
        raise ValueError(f'CHANGELOG.md must contain exactly one {heading!r} heading')
    section = []
    for line in lines[lines.index(heading) + 1:]:
        if line.startswith('## '):
            break
        section.append(line)
    if not any(re.match(r'^-\s+\S', line) for line in section):
        raise ValueError(f'CHANGELOG.md has no entries under {heading!r}; write notes before tagging')
    return heading[3:], '\n'.join(section).strip() + '\n'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Write this version section for release packaging')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        version, notes = release_section(
            (root / 'pubspec.yaml').read_text(encoding='utf-8'),
            (root / 'CHANGELOG.md').read_text(encoding='utf-8'),
        )
        if args.output:
            args.output.write_text(notes, encoding='utf-8')
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f'Release notes verified: {version}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
