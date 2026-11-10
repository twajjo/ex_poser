import sys
import unittest

import fake_poser
from ex_poser_bridge import codec
from ex_poser_bridge.erlterms import Atom


class CodecTest(unittest.TestCase):
    def test_bool_and_nil_round_trip(self):
        self.assertIs(codec.decode(codec.encode(True)), True)
        self.assertIs(codec.decode(codec.encode(False)), False)
        self.assertIsNone(codec.decode(codec.encode(None)))

    def test_unicode_str_round_trip(self):
        self.assertEqual(codec.decode(codec.encode("Ünïcode 頭")), "Ünïcode 頭")

    def test_non_finite_floats_become_atoms(self):
        self.assertEqual(codec.to_wire(float("nan")), Atom(b"nan"))
        self.assertEqual(codec.to_wire(float("inf")), Atom(b"infinity"))
        self.assertEqual(codec.to_wire(float("-inf")), Atom(b"neg_infinity"))
        self.assertEqual(codec.to_wire([1.5]), [1.5])

    def test_fake_poser_installs_fresh_module(self):
        p = fake_poser.install()
        self.assertIs(sys.modules["poser"], p)
        self.assertEqual(type(p.Scene()).__name__, "SceneType")
        self.assertIsNot(fake_poser.install().Scene(), p.Scene())


if __name__ == "__main__":
    unittest.main()
