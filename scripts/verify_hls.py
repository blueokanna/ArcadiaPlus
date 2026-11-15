"""Download a public HLS manifest, variant and segment through an explicit proxy.

This checks HTTP delivery through the local inbound. Confirm the selected remote
outbound in ArcadiaPlus connection diagnostics; a successful download alone does
not establish whether the engine selected DIRECT or a proxy node.
"""

import argparse
import hashlib
import json
from urllib.parse import urljoin, urlsplit
from urllib.request import ProxyHandler, Request, build_opener


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--proxy', required=True, help='ArcadiaPlus HTTP/mixed inbound URL')
    args = parser.parse_args()
    proxy = urlsplit(args.proxy)
    if proxy.scheme != 'http' or not proxy.hostname or not proxy.port:
        parser.error('--proxy must be an HTTP proxy URL with an explicit port')
    opener = build_opener(ProxyHandler({'https': args.proxy}))

    def fetch(url, limit):
        if urlsplit(url).scheme != 'https':
            raise ValueError('Only HTTPS HLS resources are accepted')
        request = Request(url, headers={'User-Agent': 'ArcadiaPlus-HLS-Validation/1.0'})
        with opener.open(request, timeout=20) as response:
            if response.status != 200 or urlsplit(response.url).scheme != 'https':
                raise ValueError('Unexpected HLS response or HTTPS downgrade')
            data = response.read(limit + 1)
            if not data or len(data) > limit:
                raise ValueError('Empty response or resource exceeds validation limit')
            print(json.dumps({'url': response.url, 'bytes': len(data),
                              'sha256': hashlib.sha256(data).hexdigest()}))
            return response.url, data

    url = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'
    for _ in range(4):
        url, data = fetch(url, 1024 * 1024)
        manifest = data.decode('utf-8-sig')
        if not manifest.startswith('#EXTM3U'):
            raise ValueError('Expected an HLS manifest')
        resources = [line.strip() for line in manifest.splitlines()
                     if line.strip() and not line.startswith('#')]
        if not resources:
            raise ValueError('Manifest has no media resources')
        url = urljoin(url, resources[0])
        if '#EXT-X-STREAM-INF:' not in manifest:
            fetch(url, 16 * 1024 * 1024)
            return
    raise ValueError('Too many nested playlists')


if __name__ == '__main__':
    main()
