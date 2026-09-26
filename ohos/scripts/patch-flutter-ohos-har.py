#!/usr/bin/env python3
"""Patch the Flutter OHOS embedding har for the pinned HarmonyOS SDK.

`flutter.har` and `flutter_embedding_release.har` ship
`src/main/ets/embedding/ohos/KeyEventHandler.ets`, which gates CapsLock and
NumLock handling on the `KeyEvent` properties `isCapsLockOn` / `isNumLockOn`.
The pinned HarmonyOS SDK (5.1.0 / API 18) declares neither property -- it has
the older `capsLock` / `numLock` booleans -- so ArkTS rejects the file while
compiling the har and the whole HAP build dies in `CompileArkTS`. The
`!== undefined` guards in the file cannot help: the failure is a compile-time
type error, not a runtime miss.

Both expressions fall back to a constant when the property is absent, and on
this SDK it always is. Rewriting them to those constants therefore preserves
the code's own stated behaviour exactly while removing the type error.

The script rewrites the har archives in place, streaming each member and
rebuilding the archive so order and attributes survive. It prints what it
patched and exits non-zero when nothing matched -- an unpatched tree fails the
HAP build in CompileArkTS, so silence would be worse than an error.
"""

import io
import sys
import tarfile
from pathlib import Path

REPLACEMENTS = (
    ("event.isCapsLockOn !== undefined ? event.isCapsLockOn : false", "false"),
    ("event.isNumLockOn !== undefined ? event.isNumLockOn : true", "true"),
)

MARKERS = (b"isCapsLockOn", b"isNumLockOn")


def patch_payload(payload: bytes) -> tuple[bytes, int]:
    text = payload.decode("utf-8")
    hits = 0
    for old, new in REPLACEMENTS:
        if old in text:
            hits += text.count(old)
            text = text.replace(old, new)
    return text.encode("utf-8"), hits


def patch_har(path: Path) -> int:
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        payloads = {}
        for member in members:
            if member.isfile():
                payloads[member.name] = archive.extractfile(member).read()

    hits = 0
    for name, payload in payloads.items():
        if not any(marker in payload for marker in MARKERS):
            continue
        patched, member_hits = patch_payload(payload)
        if member_hits:
            payloads[name] = patched
            hits += member_hits

    if not hits:
        return 0

    with tarfile.open(path, "w:gz") as archive:
        for member in members:
            if member.isfile():
                member.size = len(payloads[member.name])
                archive.addfile(member, io.BytesIO(payloads[member.name]))
            else:
                archive.addfile(member)
    return hits


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: patch-flutter-ohos-har.py <directory-or-har> [<har> ...]",
            file=sys.stderr,
        )
        return 2

    targets: list[Path] = []
    for argument in sys.argv[1:]:
        candidate = Path(argument)
        if candidate.is_dir():
            targets.extend(sorted(candidate.rglob("*.har")))
        else:
            targets.append(candidate)

    patched_files = 0
    total_hits = 0
    for har in targets:
        hits = patch_har(har)
        if hits:
            patched_files += 1
            total_hits += hits
            print(f"patched {hits} expression(s) in {har}")

    print(f"patched {total_hits} expression(s) across {patched_files} file(s)")
    if total_hits == 0:
        print(
            "error: no KeyEventHandler expression matched; the har layout moved "
            "and CompileArkTS will fail on KeyEvent.isCapsLockOn",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
