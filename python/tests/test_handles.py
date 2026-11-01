import unittest

import fake_poser
from poser_bridge.handles import (BadRequest, HandleTable, NDARRAY, POSER_OBJ,
                                  RESULT, StaleHandle)


class _DType(object):
    str = "<f4"


class ndarray(object):  # duck-typed numpy array; the class name matters
    dtype = _DType()
    shape = [2, 3]

    def tobytes(self):
        return b"x" * 24


class _NoName(object):
    def Name(self):
        raise RuntimeError("no name")


class HandleTableTest(unittest.TestCase):
    def setUp(self):
        self.poser = fake_poser.install()
        self.gen = [0]
        self.table = HandleTable(lambda: self.gen[0])

    def test_plain_values_pass_through(self):
        v = [1, 2.5, "a", None, True, {"k": (1,)}]
        self.assertEqual(self.table.wrap(v), v)
        self.assertEqual(len(self.table), 0)

    def test_object_becomes_handle_and_resolves(self):
        actor = self.poser.Scene().Actor("hip")
        h = self.table.wrap(actor)
        self.assertEqual(h, (POSER_OBJ, "ActorType", 1, 0, "hip"))
        self.assertIs(self.table.resolve([h])[0], actor)

    def test_label_none_when_name_raises(self):
        self.assertIsNone(self.table.wrap(_NoName())[4])

    def test_ndarray_duck_type(self):
        self.assertEqual(self.table.wrap(ndarray()), (NDARRAY, "<f4", (2, 3), b"x" * 24))

    def test_stale_after_generation_change(self):
        h = self.table.wrap(self.poser.Scene())
        self.gen[0] = 1
        with self.assertRaises(StaleHandle) as cm:
            self.table.resolve(h)
        self.assertEqual(cm.exception.id, h[2])
        self.assertEqual(cm.exception.generation, 0)

    def test_release_counts_and_forgets(self):
        h = self.table.wrap(self.poser.Scene())
        self.assertEqual(self.table.release([h, h]), 1)
        self.assertEqual(len(self.table), 0)
        with self.assertRaises(StaleHandle):
            self.table.resolve(h)

    def test_lru_evicts_oldest(self):
        t = HandleTable(lambda: 0, cap=2)
        a, b, c = self.poser.Scene().Actors()
        ha = t.wrap(a)
        t.wrap(b)
        t.wrap(c)
        with self.assertRaises(StaleHandle):
            t.resolve(ha)

    def test_lru_lookup_refreshes(self):
        t = HandleTable(lambda: 0, cap=2)
        a, b, c = self.poser.Scene().Actors()
        ha, hb = t.wrap(a), t.wrap(b)
        t.resolve(ha)
        t.wrap(c)
        self.assertIs(t.resolve(ha), a)
        with self.assertRaises(StaleHandle):
            t.resolve(hb)

    def test_clear_forgets_everything(self):
        h = self.table.wrap(self.poser.Scene())
        self.table.clear()
        with self.assertRaises(StaleHandle):
            self.table.resolve(h)

    def test_result_ref(self):
        self.assertEqual(self.table.resolve([(RESULT, 0)], refs=["x"]), ["x"])
        with self.assertRaises(BadRequest):
            self.table.resolve([(RESULT, 0)])
        with self.assertRaises(BadRequest):
            self.table.resolve([(RESULT, 1)], refs=["x"])

    def test_cyclic_value_raises(self):
        with self.assertRaises(ValueError):
            self.table.wrap(self.poser.Cyclic())


if __name__ == "__main__":
    unittest.main()
