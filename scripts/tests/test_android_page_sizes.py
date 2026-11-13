import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location(
    "page_sizes", Path(__file__).resolve().parents[1] / "check_android_page_sizes.py"
)
page_sizes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(page_sizes)


def elf(alignment=16384, relro_end=None, offset=0):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<Q", header, 32, 64)
    struct.pack_into("<HH", header, 54, 56, 1 + (relro_end is not None))
    data = header + struct.pack("<IIQQQQQQ", 1, 6, offset, 0, 0, 128, 32768, alignment)
    if relro_end is not None:
        data += struct.pack("<IIQQQQQQ", 0x6474E552, 4, 0, 0, 0, 128, relro_end, 1)
    return data


class PageSizesTest(unittest.TestCase):
    def test_accepts_16k_and_64k(self):
        for size in [16384, 65536]:
            page_sizes.check_elf(io.BytesIO(elf(size, 16384)))

    def test_rejects_4k_and_misaligned_relro_and_offset(self):
        for data in [elf(4096), elf(relro_end=4096), elf(offset=4096), b"bad"]:
            with self.assertRaises(ValueError):
                page_sizes.check_elf(io.BytesIO(data))

    def test_checks_zip_alignment_and_compression(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.apk"
            for aligned, compressed in [(True, False), (False, False), (True, True)]:
                entry = zipfile.ZipInfo("lib/arm64-v8a/libtest.so")
                entry.compress_type = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
                if aligned:
                    padding = 16384 - 30 - len(entry.filename)
                    entry.extra = struct.pack("<HH", 0xD935, padding - 4) + bytes(padding - 4)
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(entry, elf())
                if aligned and not compressed:
                    self.assertEqual(page_sizes.check_apk(path), 1)
                else:
                    with self.assertRaises(ValueError):
                        page_sizes.check_apk(path)

    def test_rejects_archive_without_64bit_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.apk"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("assets/readme", "test")
            with self.assertRaises(ValueError):
                page_sizes.check_apk(path)
