#!/usr/bin/env python3
"""Verify the running Android VPN from a separate, ordinary application UID.

Requires Android SDK build-tools 35+ and a JDK on PATH. This does not start,
stop, reinstall, or change ArcadiaPlus. The temporary probe checks Android's
active VPN and DNS address before making requests with platform TLS validation.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = "com.blueokanna.arcadiaplus.validationprobe"
COMPONENT = PROBE + "/org.arcadia.validation.NetworkProbe"


def run(command, timeout=90, check=True):
    result = subprocess.run([str(part) for part in command], capture_output=True,
                            encoding="utf-8", errors="replace", timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{Path(str(command[0])).name} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result


def newest(directory, pattern):
    candidates = [p for p in directory.glob(pattern) if p.is_dir()]
    if not candidates:
        raise RuntimeError(f"No {pattern} found in {directory}")
    return max(candidates, key=lambda p: tuple(int(v) for v in re.findall(r"\d+", p.name)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="ADB serial; required when more than one device is connected")
    parser.add_argument("--sdk", type=Path, help="Android SDK directory")
    parser.add_argument("--rounds", type=int, choices=range(1, 11), default=1)
    parser.add_argument("--delay", type=int, choices=range(601), default=0,
                        help="Seconds before requests, allowing a controlled lock-screen test")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/android-validation/report.json")
    parser.add_argument("--keep-probe", action="store_true", help="Keep a newly installed diagnostic APK for another run")
    args = parser.parse_args()
    sdk = args.sdk or Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") or
                           (Path(os.environ.get("LOCALAPPDATA", "")) / "Android/Sdk"))
    adb_binary = sdk / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb")
    if not adb_binary.is_file():
        raise RuntimeError("ADB not found; pass --sdk or set ANDROID_SDK_ROOT")
    devices = [line.split()[0] for line in run([adb_binary, "devices"]).stdout.splitlines()[1:]
               if len(line.split()) == 2 and line.split()[1] == "device"]
    serial = args.serial or (devices[0] if len(devices) == 1 else None)
    if serial is None or serial not in devices:
        raise RuntimeError("Select one connected, authorized device with --serial")
    adb = [adb_binary, "-s", serial]
    owner_pattern = re.compile(r"VPN CONNECTED[^\r\n]*VPN:com\.blueokanna\.arcadiaplus(?:\}|\s|,)")
    if not owner_pattern.search(run(adb + ["shell", "dumpsys", "connectivity"]).stdout):
        raise RuntimeError("ArcadiaPlus VPN is not connected; start it on the phone first")

    build_tools = newest(sdk / "build-tools", "*")
    android_jar = newest(sdk / "platforms", "android-*") / "android.jar"
    java, javac, keytool = (shutil.which(name) for name in ("java", "javac", "keytool"))
    if not all((java, javac)):
        raise RuntimeError("A JDK with java and javac must be on PATH")
    build = ROOT / ".build/android-validation/probe"
    classes = build / "classes"
    classes.mkdir(parents=True, exist_ok=True)
    sources = ROOT / "scripts/android_probe"
    run([javac, "--release", "8", "-cp", android_jar, "-d", classes, *sorted(sources.glob("*.java"))])
    run([java, "-cp", build_tools / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "24",
         "--lib", android_jar, "--output", build / "dex.jar", *sorted(classes.rglob("*.class"))])
    extension = ".exe" if os.name == "nt" else ""
    run([build_tools / ("aapt" + extension), "package", "-f", "-M", sources / "AndroidManifest.xml",
         "-I", android_jar, "-F", build / "base.apk"])
    with zipfile.ZipFile(build / "dex.jar") as dex, zipfile.ZipFile(build / "base.apk", "a") as apk:
        apk.writestr("classes.dex", dex.read("classes.dex"))
    run([build_tools / ("zipalign" + extension), "-f", "4", build / "base.apk", build / "aligned.apk"])
    # A disposable diagnostic identity, never the application's release key.
    keystore = Path.home() / ".android/debug.keystore"
    if not keystore.exists():
        keystore = build / "probe.keystore"
        if not keystore.exists():
            if not keytool:
                candidate = Path(javac).resolve().parent / ("keytool.exe" if os.name == "nt" else "keytool")
                keytool = str(candidate) if candidate.is_file() else None
            if not keytool:
                raise RuntimeError("keytool is needed to create a disposable diagnostic signing key")
            run([keytool, "-genkeypair", "-keystore", keystore, "-storepass", "android", "-keypass", "android",
                 "-alias", "androiddebugkey", "-keyalg", "RSA", "-keysize", "2048", "-validity", "30",
                 "-dname", "CN=ArcadiaPlus Diagnostic"])
    run([java, "-jar", build_tools / "lib/apksigner.jar", "sign", "--ks", keystore,
         "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", build / "probe.apk", build / "aligned.apk"])
    was_installed = "package:" in run(adb + ["shell", "pm", "path", PROBE], check=False).stdout
    installed_here = False
    try:
        install = run(adb + ["install", "-r", build / "probe.apk"])
        if "Success" not in install.stdout:
            raise RuntimeError("Diagnostic APK installation did not report success")
        installed_here = True
        timed_out = False
        try:
            test = run(adb + ["shell", "am", "instrument", "-w", "-e", "rounds", str(args.rounds),
                              "-e", "delay", str(args.delay), COMPONENT],
                       timeout=args.delay + max(90, args.rounds * 100))
            test_output = test.stdout
        except subprocess.TimeoutExpired as error:
            timed_out = True
            captured = error.stdout or b""
            test_output = captured.decode("utf-8", errors="replace") if isinstance(captured, bytes) else captured
            test_output += "\nFAIL instrumentation exceeded the test deadline\n"
            run(adb + ["shell", "am", "force-stop", PROBE])
        still_owned = bool(owner_pattern.search(run(adb + ["shell", "dumpsys", "connectivity"]).stdout))
        passed = not timed_out and "INSTRUMENTATION_RESULT: failures=0" in test_output and still_owned
        report = {
            "time_utc": datetime.now(timezone.utc).isoformat(),
            "model": run(adb + ["shell", "getprop", "ro.product.model"]).stdout.strip(),
            "sdk": run(adb + ["shell", "getprop", "ro.build.version.sdk"]).stdout.strip(),
            "rounds": args.rounds, "vpn_owner_confirmed": still_owned, "passed": passed,
            "timed_out": timed_out,
            "output": test_output.split("INSTRUMENTATION_RESULT:", 1)[0].strip(),
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(report["output"])
        print(f"Report: {args.output}")
        return 0 if passed else 1
    finally:
        if installed_here and not was_installed and not args.keep_probe:
            run(adb + ["uninstall", PROBE])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        print(f"Device verification failed: {error}", file=sys.stderr)
        sys.exit(1)
