"""Fake Poser materials, layers, shader trees, nodes, inputs and outputs.

Class names match Poser's so the handle table and the strict policy see the
same names they would inside Poser.
"""



def _error(message):
    # Imported late: fake_poser imports this module, and owns the error class.
    import fake_poser
    return fake_poser.error(message)


# Poser's kNodeInputCode* values (ShaderNodeInputType.Type()).
kNodeInputCodeNONE, kNodeInputCodeFLOAT, kNodeInputCodeCOLOR = -1, 0, 1
kNodeInputCodeVECTOR, kNodeInputCodeSTRING, kNodeInputCodeBOOLEAN = 2, 3, 4
kNodeInputCodeINTEGER, kNodeInputCodeMENU = 5, 6


class ShaderNodeOutputType(object):
    def __init__(self, node, internal):
        self._node = node
        self._internal = internal

    def InternalName(self):
        return self._internal

    def Name(self):
        return self._internal

    def ConnectToInput(self, node_input):
        node_input._source = self


class ShaderNodeInputType(object):
    def __init__(self, node, internal, kind, value):
        self._node = node
        self._internal = internal
        self._kind = kind
        self._value = value
        self._source = None

    def InternalName(self):
        return self._internal

    def Name(self):
        return self._internal

    def Type(self):
        return self._kind

    def Value(self):
        return self._value

    def SetFloat(self, v):
        self._expect(kNodeInputCodeFLOAT)
        self._value = float(v)

    def SetColor(self, r, g, b):
        self._expect(kNodeInputCodeCOLOR)
        self._value = (float(r), float(g), float(b))

    def SetString(self, v):
        self._expect(kNodeInputCodeSTRING)
        self._value = v

    def InNode(self):
        return None if self._source is None else self._source._node

    def InOutput(self):
        return self._source

    def Disconnect(self):
        self._source = None

    def _expect(self, kind):
        if self._kind != kind:
            raise _error("input %s has type code %d, not %d" % (self._internal, self._kind, kind))


# type -> (inputs [(internal, kind, default)], outputs [internal], is_root)
NODE_TYPES = {
    "PoserSurface": ([("Diffuse_Color", kNodeInputCodeCOLOR, (0.0, 0.0, 0.0)),
                      ("Diffuse_Value", kNodeInputCodeFLOAT, 0.0),
                      ("Bump", kNodeInputCodeFLOAT, 0.0)], ["out"], True),
    "image_map": ([("Image_Source", kNodeInputCodeSTRING, ""), ("U_Offset", kNodeInputCodeFLOAT, 0.0)],
                  ["Color"], False),
    "atmosphere": ([("Fog_Color", kNodeInputCodeCOLOR, (0.0, 0.0, 0.0))], [], True),
    "background": ([("Color", kNodeInputCodeCOLOR, (0.0, 0.0, 0.0))], [], True),
}


class ShaderNodeType(object):
    def __init__(self, tree, internal, node_type):
        inputs, outputs, root = NODE_TYPES[node_type]
        self._tree = tree
        self._internal = internal
        self._name = internal
        self._type = node_type
        self._root = root
        self._location = (0, 0)
        self._inputs = [ShaderNodeInputType(self, n, k, v) for n, k, v in inputs]
        self._outputs = [ShaderNodeOutputType(self, n) for n in outputs]

    def InternalName(self):
        return self._internal

    def Name(self):
        return self._name

    def SetName(self, name):
        self._name = name

    def Type(self):
        return self._type

    def Location(self):
        return self._location

    def SetLocation(self, x, y):
        self._location = (x, y)

    def IsRoot(self):
        return 1 if self._root else 0

    def Inputs(self):
        return list(self._inputs)

    def Outputs(self):
        return list(self._outputs)

    def InputByInternalName(self, name):
        for i in self._inputs:
            if i.InternalName() == name:
                return i
        raise _error("node has no input named %s" % name)

    def OutputByInternalName(self, name):
        for o in self._outputs:
            if o.InternalName() == name:
                return o
        raise _error("node has no output named %s" % name)

    def ConnectToInput(self, node_input):
        self._outputs[0].ConnectToInput(node_input)

    def Delete(self):
        self._tree._remove(self)


class ShaderTreeType(object):
    def __init__(self):
        self._nodes = []
        self._roots = {}
        self._previews = 0

    def Nodes(self):
        return list(self._nodes)

    def NumNodes(self):
        return len(self._nodes)

    def NodeByInternalName(self, name):
        for n in self._nodes:
            if n.InternalName() == name:
                return n
        raise _error("tree has no node named %s" % name)

    def CreateNode(self, node_type):
        if node_type not in NODE_TYPES:
            raise _error("unknown node type %s" % node_type)
        taken = set(n.InternalName() for n in self._nodes)
        internal, k = node_type, 1
        while internal in taken:
            k += 1
            internal = "%s_%d" % (node_type, k)
        return self._add(internal, node_type)

    def RendererRootNode(self, code):
        return self._roots.get(code)

    # Poser takes the renderer code first, though its docstring says
    # SetRendererRootNode(node, renderer); the documented order is a parse error.
    def SetRendererRootNode(self, code, node):
        if not isinstance(code, int) or not isinstance(node, ShaderNodeType):
            raise _error("Error parsing SetRendererRootNode()")
        self._roots[code] = node

    def UpdatePreview(self):
        self._previews += 1

    def PreviewCount(self):
        """Fake only: how many times UpdatePreview ran."""
        return self._previews

    def _add(self, internal, node_type):
        node = ShaderNodeType(self, internal, node_type)
        self._nodes.append(node)
        return node

    def _remove(self, node):
        self._nodes.remove(node)
        for n in self._nodes:
            for i in n._inputs:
                if i.InNode() is node:
                    i.Disconnect()
        for code in [c for c, r in self._roots.items() if r is node]:
            del self._roots[code]


class MaterialLayerType(object):
    def __init__(self, name, ext_name=None):
        self._name = name
        self._ext = name if ext_name is None else ext_name
        self._tree = ShaderTreeType()

    def ExtName(self):
        return self._ext

    def Name(self):
        return self._name

    def ShaderTree(self):
        return self._tree


# Flat getter/setter pairs: Poser method stem -> default value.
_COLORS = {"AmbientColor": (0.0, 0.0, 0.0), "DiffuseColor": (1.0, 1.0, 1.0),
           "ReflectionColor": (0.0, 0.0, 0.0), "SpecularColor": (1.0, 1.0, 1.0),
           "TextureColor": (1.0, 1.0, 1.0)}
_MAPS = ["AmbientMapFileName", "BumpMapFileName", "ReflectionMapFileName",
         "SpecularMapFileName", "TextureMapFileName", "TransparencyMapFileName"]
_NUMBERS = {"BumpStrength": 1.0, "ReflectionStrength": 0.0, "TransparencyMin": 0.0,
            "TransparencyMax": 0.0, "TransparencyExpo": 0.0, "Ns": 50.0}


class MaterialType(object):
    def __init__(self, name, ext_name=None):
        self._name = name
        self._ext = name if ext_name is None else ext_name
        self._tree = ShaderTreeType()
        self._layers = []
        self._flat = dict(_COLORS)
        self._flat.update((m, "") for m in _MAPS)
        self._flat.update(_NUMBERS)
        self._flat["Selected"] = 0

    def Name(self):
        return self._name

    def ExtName(self):
        return self._ext

    def ShaderTree(self):
        return self._tree

    def Layers(self):
        return list(self._layers)

    def NumLayers(self):
        return len(self._layers)

    def LayerByName(self, name):
        for layer in self._layers:
            if layer.Name() == name:
                return layer
        raise _error("material has no layer named %s" % name)

    # As in Poser: the name becomes the display name (ExtName), and the layer's
    # Name is Poser's own Layer_<n>.
    def CreateLayer(self, name):
        taken = set(layer.Name() for layer in self._layers)
        n = 1
        while "Layer_%d" % n in taken:
            n += 1
        self._layers.append(MaterialLayerType("Layer_%d" % n, name))

    def DeleteLayer(self, index):
        if not 0 <= index < len(self._layers):
            raise _error("layer index out of range")
        del self._layers[index]


def _flat_getter(key):
    def get(self):
        return self._flat[key]
    get.__name__ = key
    return get


def _flat_setter(key):
    def set_(self, v):
        self._flat[key] = v
    set_.__name__ = "Set" + key
    return set_


def _color_setter(key):
    def set_(self, r, g, b):
        self._flat[key] = (float(r), float(g), float(b))
    set_.__name__ = "Set" + key
    return set_


for _key in list(_COLORS):
    setattr(MaterialType, _key, _flat_getter(_key))
    setattr(MaterialType, "Set" + _key, _color_setter(_key))
for _key in _MAPS + list(_NUMBERS) + ["Selected"]:
    setattr(MaterialType, _key, _flat_getter(_key))
    setattr(MaterialType, "Set" + _key, _flat_setter(_key))


def seed_figure_materials():
    """Skin and Hair for figure 1; Skin is also the hip's material. Hair has two
    layers that share a Name, which CreateLayer can't make, for :ambiguous."""
    skin = MaterialType("Skin")
    surface = skin._tree._add("PoserSurface", "PoserSurface")
    skin._tree.SetRendererRootNode(1, surface)
    image = skin._tree._add("Image_Map", "image_map")
    image.OutputByInternalName("Color").ConnectToInput(surface.InputByInternalName("Diffuse_Color"))
    skin.CreateLayer("Layer_1")
    skin._layers[0]._tree._add("PoserSurface", "PoserSurface")
    hair = MaterialType("Hair")
    hair._tree._add("PoserSurface", "PoserSurface")
    hair._layers = [MaterialLayerType("Dup"), MaterialLayerType("Dup")]
    return skin, hair


def seed_prop_material():
    preview = MaterialType("Preview")
    preview._tree._add("PoserSurface", "PoserSurface")
    return preview


def seed_atmosphere_tree():
    tree = ShaderTreeType()
    tree._add("atmosphere", "atmosphere")
    return tree


def seed_background_tree():
    tree = ShaderTreeType()
    tree._add("background", "background")
    return tree


class MaterialHolder(object):
    """Mixin for FigureType and ActorType: Materials() and Material(name)."""

    def Materials(self):
        return list(self._materials)

    def Material(self, name):
        for m in self._materials:
            if m.Name() == name:
                return m
        raise _error("no material named %s" % name)
