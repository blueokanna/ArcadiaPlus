#!/usr/bin/env python3
"""Build an Android debug APK against sibling engine sources without vendoring.

Requires Python 3.11+, Flutter, Cargo and the Android toolchain. Temporary Cargo
overrides are restored after the build; registry dependencies remain the release
contract. Do not run another Cargo operation in rust/ during this command.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corduit", type=Path, default=ROOT.parent / "Corduit")
    parser.add_argument("--courierust", type=Path, default=ROOT.parent / "Courierust")
    parser.add_argument("--flutter", default=shutil.which("flutter") or shutil.which("flutter.bat"))
    args = parser.parse_args()
    if not args.flutter:
        parser.error("Flutter not found; pass --flutter with its executable path")
    for name in ("corduit", "courierust"):
        directory = getattr(args, name).resolve(strict=True)
        package = tomllib.loads((directory / "Cargo.toml").read_text(encoding="utf-8"))["package"]
        if package["name"] != name:
            parser.error(f"--{name} does not point to the expected crate")
        setattr(args, name, directory)

    manifest_path = ROOT / "rust/Cargo.toml"
    lock_path = ROOT / "rust/Cargo.lock"
    manifest = manifest_path.read_bytes()
    lock = lock_path.read_bytes()
    source = manifest.decode("utf-8")
    parsed = tomllib.loads(source)
    if "patch" in parsed or "replace" in parsed:
        parser.error("Existing Cargo source overrides need review before a local build")
    dependency = re.search(r"(?m)^corduit\s*=\s*\{[^}]*\}", source)
    if not dependency:
        parser.error("Expected an inline Corduit dependency in rust/Cargo.toml")
    text = re.sub(r'\bpath\s*=\s*"[^"\n]*"\s*,?\s*', "", dependency.group())
    local_path = json.dumps(os.path.relpath(args.corduit, manifest_path.parent).replace(os.sep, "/"))
    text = text.replace("{", "{ path = " + local_path + ",", 1)
    source = source[:dependency.start()] + text + source[dependency.end():]
    tls_path = json.dumps(os.path.relpath(args.courierust, manifest_path.parent).replace(os.sep, "/"))
    source += '\n[patch.crates-io]\ncourierust = { path = ' + tls_path + ' }\n'
    temporary = source.encode("utf-8")
    # Refuse concurrent invocations of this helper. The release manifest is never
    # intentionally left pointing at temporary source overrides.
    guard = ROOT / ".build/android-local-build.lock"
    guard.parent.mkdir(parents=True, exist_ok=True)
    with guard.open("x"):
        pass
    try:
        manifest_path.write_bytes(temporary)
        tls_version = tomllib.loads((args.courierust / "Cargo.toml").read_text(encoding="utf-8"))["package"]["version"]
        subprocess.run(["cargo", "update", "--offline", "--manifest-path", str(manifest_path),
                        "-p", "courierust", "--precise", tls_version], cwd=ROOT, check=True)
        metadata = subprocess.run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1",
                                   "--manifest-path", str(manifest_path)], cwd=ROOT, check=True,
                                  capture_output=True, text=True, encoding="utf-8")
        packages = json.loads(metadata.stdout)["packages"]
        for name in ("corduit", "courierust"):
            matches = [package for package in packages if package["name"] == name]
            if len(matches) != 1 or matches[0]["source"] is not None or Path(matches[0]["manifest_path"]).resolve().parent != getattr(args, name):
                raise RuntimeError(f"Cargo did not resolve {name} to the requested local source")
        subprocess.run([args.flutter, "build", "apk", "--debug", "--target-platform", "android-arm64"],
                       cwd=ROOT, check=True)
    finally:
        if manifest_path.read_bytes() != temporary:
            # Preserve both snapshots if another editor changed the manifest.
            (guard.parent / "Cargo.toml.before-local-build").write_bytes(manifest)
            (guard.parent / "Cargo.lock.before-local-build").write_bytes(lock)
            raise RuntimeError("Cargo.toml changed concurrently; original files saved under .build/")
        manifest_path.write_bytes(manifest)
        lock_path.write_bytes(lock)
        guard.unlink()


if __name__ == "__main__":
    main()
