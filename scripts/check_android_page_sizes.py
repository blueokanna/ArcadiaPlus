#!/usr/bin/env python3
"""Validate every 64-bit native library's ELF and APK ZIP alignment.

Uses only Python's standard library. Reads ELF headers from the archive without
extracting libraries or buffering their contents. A failure exits nonzero.
"""

import argparse
from pathlib import Path
import struct
import zipfile

PAGE = 16384
PT_LOAD = 1
PT_GNU_RELRO = 0x6474E552


def read_exact(stream, count):
    value = stream.read(count)
    if len(value) != count:
        raise ValueError("Truncated native library or archive header")
    return value


def check_elf(stream):
    header = read_exact(stream, 64)
    if header[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected a little-endian ELF64 library")
    phoff = struct.unpack_from("<Q", header, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", header, 54)
    if phentsize != 56 or not 0 < phnum <= 1024 or phoff > 1024 * 1024:
        raise ValueError("Invalid ELF program header table")
    stream.seek(phoff)
    segments = [struct.unpack("<IIQQQQQQ", read_exact(stream, 56)) for _ in range(phnum)]
    loads = [segment for segment in segments if segment[0] == PT_LOAD]
    if not loads:
        raise ValueError("ELF has no loadable segments")
    for _, _, offset, address, _, _, _, alignment in loads:
        if alignment < PAGE or alignment & (alignment - 1):
            raise ValueError(f"PT_LOAD alignment {alignment} is below 16 KiB or invalid")
        if (address - offset) % PAGE:
            raise ValueError("PT_LOAD offset and address are not congruent modulo 16 KiB")
    for segment in segments:
        if segment[0] != PT_GNU_RELRO:
            continue
        end = segment[3] + segment[6]
        # A partial RELRO page may protect writable data following it in the
        # same LOAD segment. NDK 28 / common-page-size=16384 pads this boundary.
        if end % PAGE and any(
            load[1] & 2 and load[3] <= segment[3] and end < load[3] + load[6]
            for load in loads
        ):
            raise ValueError("GNU_RELRO ends inside a writable 16 KiB page")


def check_apk(path):
    checked = 0
    errors = []
    with zipfile.ZipFile(path) as archive, open(path, "rb") as raw:
        libraries = [
            entry for entry in archive.infolist()
            if entry.filename.startswith(("lib/arm64-v8a/", "lib/x86_64/"))
            and entry.filename.endswith(".so")
        ]
        if not libraries:
            raise ValueError("APK contains no arm64-v8a or x86_64 native libraries")
        for entry in libraries:
            try:
                with archive.open(entry) as library:
                    check_elf(library)
                raw.seek(entry.header_offset)
                local = read_exact(raw, 30)
                if local[:4] != b"PK\x03\x04":
                    raise ValueError("Invalid local ZIP header")
                name_size, extra_size = struct.unpack_from("<HH", local, 26)
                offset = entry.header_offset + 30 + name_size + extra_size
                if entry.compress_type != zipfile.ZIP_STORED:
                    raise ValueError("Native library must be stored uncompressed for mmap loading")
                if offset % PAGE:
                    raise ValueError(f"ZIP data offset {offset} is not 16 KiB aligned")
                checked += 1
                print(f"PASS {path.name}: {entry.filename}")
            except (ValueError, OSError, struct.error) as error:
                errors.append(f"{entry.filename}: {error}")
    if errors:
        raise ValueError("\n".join(errors))
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, nargs="+")
    args = parser.parse_args()
    failures = []
    for path in args.apk:
        try:
            count = check_apk(path)
            print(f"PASS {path}: {count} native libraries verified")
        except (ValueError, OSError, zipfile.BadZipFile) as error:
            failures.append(f"FAIL {path}: {error}")
    if failures:
        parser.exit(1, "\n".join(failures) + "\n")


if __name__ == "__main__":
    main()
