#!/usr/bin/env python3
"""Select the tested OHOS SDK profile in a build checkout (no vendored code)."""

import argparse
from pathlib import Path
import re


def version(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+ ][\w.+ -]+)?", value)
    if not match:
        raise ValueError(f"Invalid SDK version: {value!r}")
    return tuple(int(part) for part in match.groups())


def prepare(text: str, dart: str, flutter: str) -> str:
    """Change only environment bounds and the first-party component path."""
    dart_version, flutter_version = version(dart), version(flutter)
    if not (3, 11, 5) <= dart_version < (3, 12, 0):
        raise ValueError(f"OHOS profile requires Dart 3.11.5+ on 3.11.x, got {dart}")
    if not (3, 41, 9) <= flutter_version < (3, 42, 0):
        raise ValueError(f"OHOS profile requires Flutter 3.41.9+ on 3.41.x, got {flutter}")

    def replace_once(pattern: str, replacement: str, label: str) -> None:
        nonlocal text
        text, count = re.subn(pattern, replacement, text, flags=re.M)
        if count != 1:
            raise ValueError(f"Expected exactly one {label}, found {count}")

    environment = re.search(r"^environment:\s*\n((?:[ \t]+[^\n]*\n|\n)+)", text, re.M)
    if environment is None:
        raise ValueError("Missing environment section in pubspec.yaml")
    bounds = environment.group(1)
    for name, constraint in (
        ("sdk", ">=3.11.5 <3.12.0"),
        ("flutter", ">=3.41.9 <3.42.0"),
    ):
        bounds, count = re.subn(
            rf"^  {name}:.*$", f"  {name}: '{constraint}'", bounds, flags=re.M
        )
        if count != 1:
            raise ValueError(f"Expected exactly one environment.{name}, found {count}")
    text = text[: environment.start(1)] + bounds + text[environment.end(1) :]
    replace_once(
        r"^(  arcadia_expressive:\s*\n)    path: (?:packages|ohos/compat)/arcadia_expressive\s*$",
        r"\g<1>    path: ohos/compat/arcadia_expressive",
        "arcadia_expressive path dependency",
    )
    return text


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--dart-version", required=True)
    parser.add_argument("--flutter-version", required=True)
    args = parser.parse_args()
    manifest = args.root / "pubspec.yaml"
    adapter = args.root / "ohos/compat/arcadia_expressive/pubspec.yaml"
    if not adapter.is_file():
        parser.error(f"Missing first-party OHOS component package: {adapter}")
    try:
        prepared = prepare(
            manifest.read_text(encoding="utf-8"), args.dart_version, args.flutter_version
        )
    except ValueError as error:
        parser.error(str(error))
    manifest.write_text(prepared, encoding="utf-8", newline="\n")
    print("Selected OHOS Flutter 3.41 / Dart 3.11 and the OHOS Expressive adapter")


if __name__ == "__main__":
    main()
