import os
import unittest

import fake_poser
from poser_bridge.policy import NotAllowed, Policy

MINI = os.path.join(os.path.dirname(__file__), "fixtures", "mini_api.json")


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.poser = fake_poser.install()
        self.scene = self.poser.Scene()
        self.actor = self.scene.Actor("hip")
        self.strict = Policy.load("strict", MINI)

    def test_dev_allows_public_rejects_underscore(self):
        dev = Policy.dev()
        self.assertEqual(dev.mode, "dev")
        dev.check_call("Scene")
        dev.check_method(self.scene, "SetFrame")
        dev.check_attr(self.actor, "anything")
        dev.check_raw("math", "sqrt")
        with self.assertRaises(NotAllowed) as cm:
            dev.check_method(self.actor, "__class__")
        self.assertEqual(cm.exception.kind, "invoke")
        with self.assertRaises(NotAllowed):
            dev.check_call("_private")
        with self.assertRaises(NotAllowed) as cm:
            dev.check_attr(self.actor, "__dict__")
        self.assertEqual(cm.exception.kind, "get_attr")

    def test_strict_allows_listed_function(self):
        self.assertEqual(self.strict.mode, "strict")
        self.strict.check_call("Scene")
        with self.assertRaises(NotAllowed) as cm:
            self.strict.check_call("Sleep")
        self.assertEqual((cm.exception.kind, cm.exception.name), ("call", "Sleep"))

    def test_strict_rejects_unlisted_method(self):
        self.strict.check_method(self.scene, "Frame")
        with self.assertRaises(NotAllowed) as cm:
            self.strict.check_method(self.scene, "SetFrame")
        self.assertEqual((cm.exception.kind, cm.exception.name), ("invoke", "SetFrame"))

    def test_strict_inherits_through_bases(self):
        self.strict.check_method(self.actor, "Name")
        self.strict.check_method(self.actor, "Parameter")

    def test_strict_rejects_unknown_class(self):
        with self.assertRaises(NotAllowed):
            self.strict.check_method(self.scene.Figures()[0], "Name")

    def test_strict_rejects_attr_not_listed(self):
        with self.assertRaises(NotAllowed):
            self.strict.check_attr(self.actor, "Name")

    def test_strict_rejects_raw(self):
        with self.assertRaises(NotAllowed) as cm:
            self.strict.check_raw("math", "sqrt")
        self.assertEqual(cm.exception.kind, "raw")

    def test_strict_missing_file_raises(self):
        with self.assertRaises((OSError, ValueError)):
            Policy.load("strict", MINI + ".missing")

    def test_dev_load_without_file_is_ok(self):
        p = Policy.load("dev", MINI + ".missing")
        self.assertEqual((p.mode, p.api_hash), ("dev", None))

    def test_dev_load_with_corrupt_file_is_ok(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not json")
        self.addCleanup(os.remove, f.name)
        self.assertEqual(Policy.load("dev", f.name).mode, "dev")
        with self.assertRaises(ValueError):
            Policy.load("strict", f.name)

    def test_api_hash_loaded(self):
        self.assertEqual(self.strict.api_hash, "mini")
        self.assertEqual(Policy.load("dev", MINI).api_hash, "mini")

    def test_unknown_mode_raises(self):
        with self.assertRaises(ValueError):
            Policy.load("loose", MINI)


if __name__ == "__main__":
    unittest.main()
