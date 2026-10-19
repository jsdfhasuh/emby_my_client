import struct
import unittest
from verify_artifact import check_elf


def elf(bits, machine, alignment):
    data = bytearray(256)
    data[:6] = b'\x7fELF' + bytes([bits, 1])
    struct.pack_into('<HH', data, 16, 3, machine)
    if bits == 1:
        struct.pack_into('<I', data, 28, 64)
        struct.pack_into('<HH', data, 42, 32, 1)
        struct.pack_into('<IIIIIIII', data, 64, 1, 0, 0, 0, 256, 256, 5, alignment)
    else:
        struct.pack_into('<Q', data, 32, 64)
        struct.pack_into('<HH', data, 54, 56, 1)
        struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 256, 256, alignment)
    return bytes(data)


class ArtifactTest(unittest.TestCase):
    def test_all_three_abis_accept_16kb(self):
        for abi, bits, machine in [('armeabi-v7a', 1, 40), ('arm64-v8a', 2, 183), ('x86_64', 2, 62)]:
            check_elf(elf(bits, machine, 16384), abi)

    def test_reject_4kb(self):
        with self.assertRaisesRegex(ValueError, '16 KB'):
            check_elf(elf(2, 183, 4096), 'arm64-v8a')

    def test_reject_mismatched_arch(self):
        with self.assertRaisesRegex(ValueError, 'ABI'):
            check_elf(elf(2, 62, 16384), 'arm64-v8a')

    def test_reject_truncated(self):
        with self.assertRaises(ValueError):
            check_elf(b'not ELF', 'arm64-v8a')


if __name__ == '__main__':
    unittest.main()
