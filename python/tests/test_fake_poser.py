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
        self.assertEqual(names, ["hip", "chest", u"Ünïcode 頭", "head", "Ball",
                                 "Key", "Fill", "Fill", "Main Camera", "Aux Camera"])

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

    def test_lights_and_cameras_seeded(self):
        self.assertEqual([l.Name() for l in self.scene.Lights()], ["Key", "Fill", "Fill"])
        self.assertEqual([l.InternalName() for l in self.scene.Lights()],
                         ["light 1", "light 2", "light 3"])
        self.assertEqual([c.InternalName() for c in self.scene.Cameras()],
                         ["MAIN_CAMERA", "AUX_CAMERA"])
        self.assertEqual(self.scene.CurrentCamera().InternalName(), "MAIN_CAMERA")
        key = self.scene.ActorByInternalName("light 1")
        self.assertEqual(key.IsLight(), 1)
        self.assertEqual(key.IsCamera(), 0)
        self.assertEqual(key.IsBodyPart(), 0)
        self.assertEqual(key.LightType(), 1)
        self.assertEqual(self.scene.ActorByInternalName("light 2").LightType(), 0)
        self.assertEqual(self.scene.ActorByInternalName("light 3").LightType(), 2)
        cam = self.scene.ActorByInternalName("AUX_CAMERA")
        self.assertEqual(cam.IsCamera(), 1)
        self.assertEqual(cam.ParameterByCode(12).InternalName(), "focal")
        self.assertEqual(self.scene.Actor("Ball").IsLight(), 0)

    def test_light_properties_round_trip(self):
        light = self.scene.Lights()[0]
        light.SetLightType(4)
        self.assertEqual(light.LightType(), 4)
        light.SetShadowSamples(8)
        self.assertEqual(light.ShadowSamples(), 8)
        self.assertEqual(light.LightOn(), 1)
        self.assertEqual(light.ShadowBlurRadius(), 0.0)
        light.SetLightIntensity(0.5)
        self.assertEqual(light.GetLightIntensity(), 0.5)

    def test_parameter_by_code(self):
        light = self.scene.Lights()[0]
        self.assertEqual(light.ParameterByCode(23).InternalName(), "kdred")
        self.assertIsNone(light.ParameterByCode(999))

    def test_create_and_delete_light(self):
        light = self.scene.CreateLight()
        self.assertEqual(light.LightType(), 1)
        self.assertEqual(light.Name(), "Light 4")
        self.assertEqual(light.InternalName(), "light 4")
        self.assertIs(self.scene.ActorByInternalName("light 4"), light)
        light.Delete()
        self.assertNotIn(light, self.scene.Lights())
        self.assertNotIn(light, self.scene.Actors())

    def test_set_name_changes_name_but_not_internal_name(self):
        light = self.scene.CreateLight()
        light.SetName("Rim")
        self.assertEqual(light.Name(), "Rim")
        self.assertEqual(light.InternalName(), "light 4")

    def test_set_current_camera(self):
        aux = self.scene.ActorByInternalName("AUX_CAMERA")
        self.scene.SetCurrentCamera(aux)
        self.assertEqual(self.scene.CurrentCamera().InternalName(), "AUX_CAMERA")

    def test_point_at(self):
        light = self.scene.Lights()[0]
        ball = self.scene.Actor("Ball")
        light.PointAt(ball)
        self.assertIs(light.PointAtTarget(), ball)


if __name__ == "__main__":
    unittest.main()
