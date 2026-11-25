import os
import shutil
import tempfile
import unittest

from ex_poser_bridge import net


class ReadBuildTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "build.txt")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_missing_file_is_unknown(self):
        self.assertEqual(net.read_build(self.path), "unknown")

    def test_reads_the_stamp_without_surrounding_space(self):
        with open(self.path, "w") as f:
            f.write("3f9a2c1e 2026-11-24 21:05\n")
        self.assertEqual(net.read_build(self.path), "3f9a2c1e 2026-11-24 21:05")

    def test_empty_file_is_unknown(self):
        open(self.path, "w").close()
        self.assertEqual(net.read_build(self.path), "unknown")


if __name__ == "__main__":
    unittest.main()
