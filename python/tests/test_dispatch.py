import os
import unittest

import fake_poser
from ex_poser_bridge.codec import atom
from ex_poser_bridge.dispatch import Dispatcher
from ex_poser_bridge.handles import POSER_OBJ, RESULT, HandleTable
from ex_poser_bridge.policy import Policy

MINI = os.path.join(os.path.dirname(__file__), "fixtures", "mini_api.json")
C, I, G, B, R, S, X = (atom(t) for t in "CIGBRSX")
A_R, A_E = atom("r"), atom("e")
UNI = u"Ünïcode 頭"


class DispatchTest(unittest.TestCase):
    def setUp(self):
        self.poser = fake_poser.install()
        self.gen = [0]
        self.d = self.make(Policy.dev())

    def make(self, policy):
        return Dispatcher(self.poser, HandleTable(lambda: self.gen[0]), policy)

    def ok(self, msg, d=None):
        r = (d or self.d).run(msg)
        self.assertEqual(r[0], A_R, r)
        self.assertEqual(r[1], msg[1])
        return r[2]

    def err(self, msg, d=None):
        r = (d or self.d).run(msg)
        self.assertEqual(r[0], A_E, r)
        self.assertEqual(r[1], msg[1])
        return r[2]

    def scene(self, d=None):
        return self.ok((C, 1, "Scene", [], {}), d)

    def test_call_returns_handle(self):
        h = self.scene()
        self.assertEqual(h[0], POSER_OBJ)
        self.assertEqual(h[1], "SceneType")

    def test_invoke_on_handle(self):
        h = self.scene()
        self.assertEqual(self.ok((I, 2, h, "Frame", [], {})), 0)
        self.assertIsNone(self.ok((I, 3, h, "SetFrame", [5], {})))
        self.assertEqual(self.ok((I, 4, h, "Frame", [], {})), 5)

    def test_kwargs_passed(self):
        h = self.scene()
        self.ok((I, 2, h, "SetFrame", [], {"n": 3}))
        self.assertEqual(self.poser.Scene().Frame(), 3)

    def test_unicode_actor_name_round_trip(self):
        a = self.ok((I, 2, self.scene(), "Actor", [UNI], {}))
        self.assertEqual(a[4], UNI)
        self.assertEqual(self.ok((I, 3, a, "Name", [], {})), UNI)

    def test_handle_argument_is_resolved(self):
        a = self.ok((I, 2, self.scene(), "Actor", ["hip"], {}))
        self.assertEqual(self.ok((X, 3, "builtins", "id", [a])), id(self.poser.Scene().Actor("hip")))

    def test_python_error_shape(self):
        reason = self.err((I, 2, self.scene(), "SetFrame", [99], {}))
        self.assertEqual(reason[:3], (atom("python"), "ValueError", "frame out of range"))
        self.assertTrue(len(reason[3]) > 0)

    def test_get_attr(self):
        a = self.ok((I, 2, self.scene(), "Actor", ["hip"], {}))
        self.assertIs(self.ok((G, 3, a, "visible")), True)

    def test_stale_handle_error(self):
        h = self.scene()
        self.gen[0] = 1
        self.assertEqual(self.err((I, 2, h, "Frame", [], {})), (atom("stale_handle"), h[2], 0))

    def test_not_allowed_in_strict(self):
        strict = self.make(Policy.load("strict", MINI))
        h = self.scene(strict)
        self.assertEqual(self.err((I, 2, h, "SetFrame", [1], {}), strict),
                         (atom("not_allowed"), atom("invoke"), "SetFrame"))

    def test_raw_rejected_in_strict(self):
        strict = self.make(Policy.load("strict", MINI))
        self.assertEqual(self.err((X, 1, "math", "sqrt", [4]), strict),
                         (atom("not_allowed"), atom("raw"), "math.sqrt"))

    def test_raw_allowed_in_dev(self):
        self.assertEqual(self.ok((X, 1, "math", "sqrt", [4])), 2.0)

    def test_batch_with_result_refs(self):
        res = self.ok((B, 1, [(C, "Scene", [], {}), (I, (RESULT, 0), "Frame", [], {})]))
        self.assertEqual(res[0][1], "SceneType")
        self.assertEqual(res[1], 0)

    def test_batch_failure_partial(self):
        reason = self.err((B, 1, [(C, "Scene", [], {}), (I, (RESULT, 0), "SetFrame", [99], {})]))
        self.assertEqual(reason[0], atom("batch_failed"))
        self.assertEqual(reason[1], 1)
        self.assertEqual(reason[2][1], "ValueError")
        self.assertEqual(len(reason[3]), 1)
        self.assertEqual(reason[3][0][1], "SceneType")

    def test_batch_bad_reference(self):
        reason = self.err((B, 1, [(I, (RESULT, 0), "Frame", [], {})]))
        self.assertEqual(reason[0], atom("batch_failed"))
        self.assertEqual(reason[2][0], atom("bad_request"))

    def test_release_and_stats(self):
        h = self.scene()
        self.assertEqual(self.d.stats(), {"handles": 1, "generation": 0})
        self.assertEqual(self.ok((R, 2, [h])), 1)
        self.assertEqual(self.ok((S, 3)), {"handles": 0, "generation": 0})

    def test_malformed_is_bad_request(self):
        self.assertEqual(self.err((C, 1))[0], atom("bad_request"))
        self.assertEqual(self.err((I, 1, "nope", "Frame", [], {}))[0], atom("bad_request"))
        self.assertEqual(self.err((C, 1, "Scene", "notalist", {}))[0], atom("bad_request"))

    def test_unknown_function_is_python_error(self):
        self.assertEqual(self.err((C, 1, "NoSuchThing", [], {}))[1], "AttributeError")

    def test_cyclic_result_is_python_error(self):
        self.assertEqual(self.err((C, 1, "Cyclic", [], {}))[1], "ValueError")


if __name__ == "__main__":
    unittest.main()


try:
    import numpy as np
except ImportError:
    np = None


@unittest.skipUnless(np, "numpy not installed")
class DispatchNumpyTest(unittest.TestCase):
    def setUp(self):
        self.poser = fake_poser.install()
        self.d = Dispatcher(self.poser, HandleTable(lambda: 0), Policy.dev())

    def test_dispatch_numpy_arg(self):
        r = self.d.run((C, 1, "Scene", [], {}))
        scene = r[2]
        actor = self.d.run((I, 2, scene, "Actor", ["hip"], {}))[2]
        geom = self.d.run((I, 3, actor, "Geometry", [], {}))[2]
        a = np.arange(6, dtype="<f8").reshape(2, 3)
        sent = (atom("ndarray"), "<f8", (2, 3), a.tobytes())
        r = self.d.run((I, 4, geom, "SetVertexPositions", [sent], {}))
        self.assertEqual(r[0], A_R, r)
        r = self.d.run((I, 5, geom, "VertexPositions", [], {}))
        self.assertEqual(r[2], sent)
