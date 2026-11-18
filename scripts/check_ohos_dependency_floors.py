#!/usr/bin/env python3
"""Hold the declared dependencies to the Flutter OHOS line's SDK floor.

The HAP build runs on the Flutter OHOS fork — Dart 3.11.5, Flutter 3.41.9 — and
`prepare_ohos_pubspec.py` rewrites only the root `environment` bounds, so every
dependency has to resolve against those versions too. When one does not, pub
reports `version solving failed` inside the HAP job, minutes after that job has
downloaded the HarmonyOS toolchain and the Flutter fork.

The question has an offline answer on the stable line. Pub ignores the *upper*
bound of a dependency's `environment.sdk` — an old footgun, and the reason
`provider`'s `nested 1.0.0`, which asks for `<3.0.0`, still resolves on Dart 3 —
and enforces the *lower* bound. A dependency whose floor is above 3.11.5 can
therefore never be used there. That is what this checks, on the constraints this
repository declares: a bump that raises a floor fails here in a second instead of
in the HAP job in an hour.

Transitive packages are deliberately out of scope. Pub downgrades them inside
their parents' ranges when it has to, and only the fork's own resolver knows
whether it can. That boundary has a price, and it was paid once: `ffigen` 23
demands `code_assets` 2, whose `hooks` asks for a `meta` the fork's own
`flutter_test` contradicts. That is a version conflict, not a floor, so this
check stayed green while the HAP job's `pub get` died. Reproduce that class of
failure offline rather than in CI, with the pinned fork's own tool:

    python scripts/prepare_ohos_pubspec.py --root <copy of the checkout> \\
        --dart-version 3.11.5 --flutter-version 3.41.9
    <fork>/bin/flutter pub get
    <fork>/bin/flutter analyze --no-pub lib test && <fork>/bin/flutter test --no-pub
"""

import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlparse

# The floors live next to the profile selector rather than here, so the file that
# rewrites the root bounds and the check that holds the dependencies to them
# cannot disagree.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from prepare_ohos_pubspec import OHOS_DART_FLOOR, OHOS_FLUTTER_FLOOR  # noqa: E402


def parse_version(text: str) -> tuple[int, int, int]:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    if match is None:
        raise ValueError(f"No version in {text!r}")
    return tuple(int(part) for part in match.groups())


def floor_of(constraint: str) -> tuple[tuple[int, int, int], bool] | None:
    """The lowest version a constraint allows, and whether it excludes it.

    `^x.y.z` and a bare `x.y.z` both floor at `x.y.z`, `>=x.y.z` includes it, and
    `>x.y.z` does not. `any`, and anything without a version, has no floor.
    """
    text = constraint.strip().strip("'\"")
    match = re.match(r"(\^|>=|>)?\s*(\d+\.\d+\.\d+)", text)
    if match is None:
        return None
    operator, raw = match.groups()
    return parse_version(raw), operator == ">"


def accepts_floor(constraint: str | None, floor: tuple[int, int, int]) -> bool:
    """Whether a constraint admits `floor` at all, `any` and absence included."""
    if constraint is None:
        return True
    bound = floor_of(constraint)
    if bound is None:
        return True
    lowest, excluded = bound
    return floor > lowest if excluded else floor >= lowest


def declared(pubspec: str) -> list[tuple[str, str, str]]:
    """Hosted dependencies as `(section, name, constraint)`.

    Only inline constraints are returned: `name:` followed by a `path:` or
    `sdk:` block is a first-party or SDK package, which `prepare_ohos_pubspec.py`
    owns and whose bounds are not a release constraint.
    """
    found = []
    section = None
    for line in pubspec.splitlines():
        header = re.match(r"^(dependencies|dev_dependencies):\s*$", line)
        if header is not None:
            section = header.group(1)
            continue
        if line and not line.startswith((" ", "#")):
            section = None
            continue
        if section is None:
            continue
        entry = re.match(r"^  ([a-z0-9_]+):\s*(\S.*?)\s*$", line)
        if entry is not None:
            found.append((section, entry.group(1), entry.group(2).strip("'\"")))
    return found


def environment_of(pubspec: str) -> dict[str, str]:
    """The `sdk` and `flutter` bounds of one package's pubspec."""
    block = re.search(r"^environment:\s*\n((?:[ \t]+[^\n]*\n|\n)+)", pubspec, re.MULTILINE)
    if block is None:
        return {}
    bounds = {}
    for name in ("sdk", "flutter"):
        match = re.search(rf"^\s+{name}:\s*(.+?)\s*$", block.group(1), re.MULTILINE)
        if match is not None:
            bounds[name] = match.group(1).strip().strip("'\"")
    return bounds


def lock_versions(lock: str) -> dict[str, str]:
    """`name -> version` from a `pubspec.lock`."""
    versions = {}
    for block in lock.split("\n\n"):
        name = re.search(r"^  ([a-z0-9_]+):\s*$", block, re.MULTILINE)
        version = re.search(r"^    version:\s*\"?([^\"\n]+?)\"?\s*$", block, re.MULTILINE)
        if name is not None and version is not None:
            versions[name.group(1)] = version.group(1)
    return versions


def root_of(uri: str, base: Path) -> Path | None:
    """The directory a `package_config.json` entry names, `None` for other schemes."""
    parsed = urlparse(uri)
    if parsed.scheme == "file":
        path = unquote(parsed.path)
        # `file:///C:/x` parses as `/C:/x` on Windows, and the drive has to survive.
        if re.match(r"^/[A-Za-z]:", path):
            path = path[1:]
        return Path(path)
    if parsed.scheme:
        return None
    return (base / uri).resolve()


def violations(
    dependencies: list[tuple[str, str, str]],
    locked: dict[str, str],
    manifests: dict[str, str],
) -> list[tuple[str, str, str, str]]:
    """Dependencies the OHOS line cannot take, as `(name, version, sdk, flutter)`."""
    found = []
    for _, name, constraint in dependencies:
        manifest = manifests.get(name)
        if manifest is None:
            continue
        bounds = environment_of(manifest)
        if accepts_floor(bounds.get("sdk"), OHOS_DART_FLOOR) and accepts_floor(
            bounds.get("flutter"), OHOS_FLUTTER_FLOOR
        ):
            continue
        version = locked.get(name, constraint)
        found.append((name, version, bounds.get("sdk", "any"), bounds.get("flutter", "any")))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="Flutter project root")
    args = parser.parse_args()

    manifest = args.root / "pubspec.yaml"
    if not manifest.is_file():
        print(f"{manifest} is missing", file=sys.stderr)
        return 1

    config = args.root / ".dart_tool/package_config.json"
    if not config.is_file():
        print(f"{config} is missing; run `flutter pub get` first", file=sys.stderr)
        return 1

    roots: dict[str, Path] = {}
    for package in json.loads(config.read_text(encoding="utf-8"))["packages"]:
        root = root_of(package["rootUri"], config.parent)
        if root is not None:
            roots[package["name"]] = root

    lockfile = args.root / "pubspec.lock"
    locked = lock_versions(lockfile.read_text(encoding="utf-8")) if lockfile.is_file() else {}

    dependencies = declared(manifest.read_text(encoding="utf-8"))
    manifests = {}
    unresolved = []
    for _, name, _ in dependencies:
        root = roots.get(name)
        candidate = root / "pubspec.yaml" if root is not None else None
        if candidate is not None and candidate.is_file():
            manifests[name] = candidate.read_text(encoding="utf-8")
        else:
            unresolved.append(name)

    # Every declared dependency is hosted here, so an unresolved one means the
    # resolution this gate is supposed to judge never happened.
    if unresolved:
        print(
            f"{', '.join(sorted(unresolved))} cannot be checked: run `flutter pub get` "
            "first",
            file=sys.stderr,
        )
        return 1

    rejected = violations(dependencies, locked, manifests)
    if rejected:
        for name, version, sdk, flutter in rejected:
            print(f"{name} {version} requires sdk {sdk} and flutter {flutter}", file=sys.stderr)
        print(
            f"{len(rejected)} declared dependencies reject the Flutter OHOS line "
            f"(Dart {'.'.join(map(str, OHOS_DART_FLOOR))}, "
            f"Flutter {'.'.join(map(str, OHOS_FLUTTER_FLOOR))}); "
            "lower their constraints or the HAP build cannot resolve",
            file=sys.stderr,
        )
        return 1

    print(
        f"{len(manifests)} declared dependencies accept the Flutter OHOS line "
        f"(Dart {'.'.join(map(str, OHOS_DART_FLOOR))}, "
        f"Flutter {'.'.join(map(str, OHOS_FLUTTER_FLOOR))})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
