import unittest

import fake_poser


class FakePoserTest(unittest.TestCase):
    def setUp(self):
        self.poser = fake_poser.install()
        self.scene = self.poser.Scene()

    def test_lookup_by_internal_name(self):
        fig = self.scene.FigureByInternalName("figure 2")
        self.assertEqual(fig.InternalName(), "figure 2")
        self.assertEqual(fig.ActorByInternalName("head").Name(), "head")
        self.assertEqual(self.scene.ActorByInternalName("ball").Name(), "Ball")
        self.assertEqual(self.scene.ActorByInternalName("head").Name(), "head")
        with self.assertRaises(self.poser.error) as c:
            self.scene.FigureByInternalName("nope")
        self.assertEqual(str(c.exception), "Unknown/invalid figure name")
        with self.assertRaises(self.poser.error) as c:
            fig.ActorByInternalName("nope")
        self.assertEqual(str(c.exception), "Figure has no actor by that name")
        with self.assertRaises(self.poser.error) as c:
            self.scene.ActorByInternalName("nope")
        self.assertEqual(str(c.exception), "Named actor could not be found")

    def test_scene_actors_order(self):
        names = [a.Name() for a in self.scene.Actors()]
        self.assertEqual(names, ["hip", "chest", u"Ünïcode 頭", "head", "Ball"])

    def test_internal_parameter_missing_returns_none(self):
        actor = self.scene.ActorByInternalName("hip")
        self.assertIsNone(actor.InternalParameter("nope"))
        self.assertEqual(actor.InternalParameter("xtran").Name(), "xTran")

    def test_values_are_per_frame(self):
        p = self.scene.Actor("hip").Parameter("xTran")
        self.scene.SetFrame(5)
        p.SetValue(10)
        self.assertEqual(p.Value(), 10.0)
        self.assertIsInstance(p.Value(), float)
        self.scene.SetFrame(0)
        self.assertEqual(p.Value(), 0.0)
        self.scene.SetFrame(8)
        self.assertEqual(p.Value(), 10.0)

    def test_keyframes_walk(self):
        p = self.scene.Actor("hip").Parameter("xTran")
        self.assertIsNone(p.PrevKeyFrame())
        for f in (3, 7):
            self.scene.SetFrame(f)
            p.AddKeyFrame()
        self.scene.SetFrame(0)
        self.assertEqual(p.NextKeyFrame(), 3)
        self.scene.SetFrame(3)
        self.assertEqual(p.NextKeyFrame(), 7)
        self.assertEqual(p.PrevKeyFrame(), 0)
        self.scene.SetFrame(7)
        self.assertIsNone(p.NextKeyFrame())
        p.DeleteKeyFrame(3)
        self.assertEqual(p.PrevKeyFrame(), 0)
        p.AddKeyFrame(12)
        self.assertEqual(p.NextKeyFrame(), 12)

    def test_min_max_internal_name(self):
        p = self.scene.Actor("hip").Parameter("xTran")
        self.assertEqual((p.MinValue(), p.MaxValue()), (-180.0, 180.0))
        self.assertEqual(p.InternalName(), "xtran")
        self.assertEqual(self.scene.FramesPerSecond(), 30)

    def test_duplicate_display_names(self):
        names = [f.Name() for f in self.scene.Figures()]
        self.assertEqual(names, ["Figure 1", "Figure 1"])

    def test_prop_is_not_a_body_part(self):
        self.assertEqual(self.scene.Actor("Ball").IsBodyPart(), 0)
        self.assertEqual(self.scene.Actor("hip").IsBodyPart(), 1)


if __name__ == "__main__":
    unittest.main()
