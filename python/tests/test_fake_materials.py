import unittest

import fake_poser


class FakeMaterialsTest(unittest.TestCase):
    def setUp(self):
        self.poser = fake_poser.install()
        self.scene = self.poser.Scene()
        self.hip = self.scene.ActorByInternalName("hip")
        self.skin = self.hip.Material("Skin")

    def test_seed(self):
        figure = self.scene.FigureByInternalName("figure 1")
        self.assertEqual([m.Name() for m in figure.Materials()], ["Skin", "Hair"])
        self.assertEqual([m.Name() for m in self.hip.Materials()], ["Skin"])
        self.assertEqual(self.scene.ActorByInternalName("ball").Material("Preview").Name(), "Preview")
        tree = self.skin.ShaderTree()
        self.assertEqual([n.InternalName() for n in tree.Nodes()], ["PoserSurface", "Image_Map"])
        surface = tree.NodeByInternalName("PoserSurface")
        self.assertIs(tree.RendererRootNode(1), surface)
        self.assertIsNone(tree.RendererRootNode(4))
        image = tree.NodeByInternalName("Image_Map")
        self.assertEqual(image.Type(), "image_map")
        diffuse = surface.InputByInternalName("Diffuse_Color")
        self.assertIs(diffuse.InNode(), image)
        self.assertEqual(diffuse.Type(), 1)
        self.assertEqual(image.InputByInternalName("Image_Source").Type(), 3)
        self.assertEqual(self.poser.kNodeInputCodeCOLOR, 1)
        self.assertEqual(self.poser.kRenderEngineCodeSUPERFLY, 4)
        self.assertEqual(diffuse.InOutput().InternalName(), "Color")
        self.assertEqual([l.Name() for l in self.skin.Layers()], ["Layer_1"])
        layer_tree = self.skin.LayerByName("Layer_1").ShaderTree()
        self.assertEqual([n.Type() for n in layer_tree.Nodes()], ["PoserSurface"])
        hair = figure.Material("Hair").ShaderTree()
        self.assertEqual([n.Type() for n in hair.Nodes()], ["PoserSurface"])
        atmo = self.scene.AtmosphereShaderTree()
        self.assertEqual(atmo.NumNodes(), 1)
        self.assertEqual(atmo.Nodes()[0].Type(), "atmosphere")
        self.assertEqual(self.scene.BackgroundShaderTree().Nodes()[0].IsRoot(), 1)

    def test_missing_lookups_raise(self):
        with self.assertRaises(self.poser.error):
            self.hip.Material("Nope")
        with self.assertRaises(self.poser.error):
            self.skin.LayerByName("Nope")
        with self.assertRaises(self.poser.error):
            self.skin.ShaderTree().NodeByInternalName("Nope")

    def test_flat_settings(self):
        self.skin.SetDiffuseColor(0.1, 0.2, 0.3)
        self.assertEqual(self.skin.DiffuseColor(), (0.1, 0.2, 0.3))
        self.skin.SetBumpMapFileName("bump.png")
        self.assertEqual(self.skin.BumpMapFileName(), "bump.png")
        self.skin.SetNs(12.0)
        self.assertEqual(self.skin.Ns(), 12.0)
        self.skin.SetSelected(1)
        self.assertEqual(self.skin.Selected(), 1)

    def test_create_node_naming(self):
        tree = self.skin.ShaderTree()
        first = tree.CreateNode("image_map")
        # Image_Map (seed) has a different internal name, so the first is plain.
        self.assertEqual(first.InternalName(), "image_map")
        self.assertEqual(first.Name(), "image_map")
        self.assertEqual(tree.CreateNode("image_map").InternalName(), "image_map_2")
        self.assertEqual(tree.CreateNode("image_map").InternalName(), "image_map_3")
        self.assertEqual(tree.CreateNode("PoserSurface").InternalName(), "PoserSurface_2")
        with self.assertRaises(self.poser.error):
            tree.CreateNode("nope")
        self.assertEqual([i.InternalName() for i in first.Inputs()], ["Image_Source", "U_Offset"])
        self.assertEqual(first.Inputs()[0].Value(), "")

    def test_link_and_disconnect(self):
        tree = self.skin.ShaderTree()
        surface = tree.NodeByInternalName("PoserSurface")
        node = tree.CreateNode("image_map")
        bump = surface.InputByInternalName("Bump")
        node.ConnectToInput(bump)
        self.assertIs(bump.InNode(), node)
        bump.Disconnect()
        self.assertIsNone(bump.InNode())
        self.assertIsNone(bump.InOutput())
        node.OutputByInternalName("Color").ConnectToInput(bump)
        self.assertIs(bump.InNode(), node)

    def test_setters_check_kind(self):
        surface = self.skin.ShaderTree().NodeByInternalName("PoserSurface")
        color = surface.InputByInternalName("Diffuse_Color")
        color.SetColor(1, 0, 0)
        self.assertEqual(color.Value(), (1.0, 0.0, 0.0))
        with self.assertRaises(self.poser.error):
            color.SetFloat(1.0)
        with self.assertRaises(self.poser.error):
            color.SetString("x")
        with self.assertRaises(self.poser.error):
            surface.InputByInternalName("Bump").SetColor(0, 0, 0)

    def test_node_name_and_location(self):
        node = self.skin.ShaderTree().NodeByInternalName("Image_Map")
        node.SetName("Pretty")
        node.SetLocation(10, 20)
        self.assertEqual(node.Name(), "Pretty")
        self.assertEqual(node.InternalName(), "Image_Map")
        self.assertEqual(node.Location(), (10, 20))

    def test_delete_node_disconnects_fed_inputs(self):
        tree = self.skin.ShaderTree()
        surface = tree.NodeByInternalName("PoserSurface")
        diffuse = surface.InputByInternalName("Diffuse_Color")
        tree.NodeByInternalName("Image_Map").Delete()
        self.assertIsNone(diffuse.InNode())
        self.assertEqual(tree.NumNodes(), 1)

    def test_layers(self):
        self.skin.CreateLayer("Dup")
        self.skin.CreateLayer("Dup")
        self.assertEqual(self.skin.NumLayers(), 3)
        self.assertIs(self.skin.LayerByName("Dup"), self.skin.Layers()[1])
        self.skin.DeleteLayer(0)
        self.assertEqual([l.Name() for l in self.skin.Layers()], ["Dup", "Dup"])
        with self.assertRaises(self.poser.error):
            self.skin.DeleteLayer(5)

    def test_root_node(self):
        tree = self.skin.ShaderTree()
        image = tree.NodeByInternalName("Image_Map")
        tree.SetRendererRootNode(image, 4)
        self.assertIs(tree.RendererRootNode(4), image)

    def test_preview_count(self):
        tree = self.skin.ShaderTree()
        self.assertEqual(tree.PreviewCount(), 0)
        tree.UpdatePreview()
        tree.UpdatePreview()
        self.assertEqual(tree.PreviewCount(), 2)

    def test_class_names_match_poser(self):
        tree = self.skin.ShaderTree()
        names = [type(x).__name__ for x in (
            self.skin, self.skin.Layers()[0], tree, tree.Nodes()[0],
            tree.Nodes()[0].Inputs()[0], tree.Nodes()[0].Outputs()[0])]
        self.assertEqual(names, ["MaterialType", "MaterialLayerType", "ShaderTreeType",
                                 "ShaderNodeType", "ShaderNodeInputType", "ShaderNodeOutputType"])


if __name__ == "__main__":
    unittest.main()
