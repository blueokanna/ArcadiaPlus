"""Record provenance for the complete README preview matrix after rendering."""

import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    'android': (412, 915), 'ios': (390, 844),
    'windows': (1440, 960), 'macos': (1440, 960),
    'linux': (1440, 960), 'tablet': (1024, 1366),
}


def main():
    images = []
    for target, expected in TARGETS.items():
        for language in ('en', 'zh'):
            for theme in ('light', 'dark'):
                path = ROOT / 'docs/images' / f'{target}-{language}-{theme}.png'
                data = path.read_bytes()
                if data[:8] != b'\x89PNG\r\n\x1a\n':
                    raise ValueError(f'Not a PNG: {path.name}')
                dimensions = struct.unpack('>II', data[16:24])
                if dimensions != expected:
                    raise ValueError(f'Unexpected dimensions: {path.name}: {dimensions}')
                images.append({'file': path.name, 'width': dimensions[0],
                               'height': dimensions[1],
                               'sha256': hashlib.sha256(data).hexdigest()})
    sources = sorted({
        *ROOT.glob('lib/**/*.dart'), *ROOT.glob('packages/**/*.dart'),
        *ROOT.glob('assets/fonts/*'),
        ROOT / 'pubspec.yaml', ROOT / 'pubspec.lock',
        ROOT / 'test/readme_showcase_test.dart',
        ROOT / 'test/support/test_fonts.dart',
    })
    digest = hashlib.sha256()
    for path in sources:
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    revision = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    manifest = {
        'kind': 'Flutter widget render; not native device screenshots',
        'state': 'Offline, stopped service, no active profile, zero traffic',
        'base_revision': revision,
        'render_sources_sha256': digest.hexdigest(),
        'source_files': len(sources),
        'images': images,
    }
    (ROOT / 'docs/images/manifest.json').write_text(
        json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Validated and recorded {len(images)} README images.')


if __name__ == '__main__':
    main()
