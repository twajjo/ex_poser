defmodule Poser.Gen.Model do
  @moduledoc """
  Turns an introspection dump plus overrides into what `Poser.Gen.Render`
  writes: one module per Poser class, the module-level functions, and a
  coverage manifest.
  """

  alias Poser.Gen.{Signature, Types}

  # Getters are called by `mix poser.smoke`, so anything that may change
  # the scene or the UI is excluded by its verb.
  @not_getter ~w(Set Add Create Delete Remove Load Save Import Export Render Make Run
                 Process Open Close New Copy Apply Reset Clear Update Drop Spawn Bake
                 Convert Weld Zero Memorize Restore Undo Redo Exec Quit Calculate Select
                 Mark Begin End Show Hide Lock Unlock Register Unregister Swap Reload
                 Recalculate Simulate Install Uninstall Start Stop Play Pause Dialog Wx)
  @not_getter_re Regex.compile!("^(#{Enum.join(@not_getter, "|")})([A-Z0-9_]|$)")

  @reserved ~w(do end fn nil true false when and or not in catch rescue after else)
  @special_forms Kernel.SpecialForms.__info__(:macros)
                 |> Keyword.keys()
                 |> Enum.map(&Atom.to_string/1)
  @kernel Kernel.__info__(:functions) ++ Kernel.__info__(:macros)

  @doc "Builds the model. `namespace` is the module that holds the module-level functions."
  @spec build(map(), map(), module()) :: map()
  def build(dump, overrides, namespace) do
    classes = dump["classes"]

    ctx = %{
      class_names: MapSet.new(Map.keys(classes)),
      constants: dump["constants"] || %{},
      overrides: overrides
    }

    {functions, fn_entries} =
      build_module(namespace, "poser", dump["functions"], :function, ctx)

    {modules, class_entries} =
      classes
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_reduce(%{}, fn {class, spec}, acc ->
        if exception?(classes, class) do
          skipped =
            for m <- spec["methods"],
                into: %{},
                do: {"#{class}.#{m["name"]}", skip_entry("exception class, not a Poser object")}

          {nil, Map.merge(acc, skipped)}
        else
          {mod, entries} =
            build_module(Module.concat(namespace, class), class, spec["methods"], :method, ctx)

          mod =
            Map.merge(mod, %{
              accepts: accepts(classes, class),
              class_doc: spec["doc"],
              constructor: constructor(class, spec["doc"], ctx)
            })

          {mod, Map.merge(acc, entries)}
        end
      end)

    modules = Enum.reject(modules, &is_nil/1)
    entries = Map.merge(fn_entries, class_entries)

    %{
      functions: functions,
      modules: modules,
      constants: ctx.constants,
      const: const_model(ctx.constants, overrides["constant_groups"] || [], namespace),
      meta: dump["meta"] || %{},
      manifest: manifest(dump, namespace, functions, modules, entries)
    }
  end

  @doc "Kernel functions and macros named `name` with an arity in `arities`."
  @spec kernel_clashes(atom(), Range.t()) :: keyword()
  def kernel_clashes(name, arities),
    do: for({^name, a} <- @kernel, a in arities, uniq: true, do: {name, a})

  # --- modules ---

  defp build_module(module, prefix, entries, kind, ctx) do
    {funs, manifest} =
      Enum.reduce(entries, {[], %{}}, fn m, {funs, man} ->
        key = "#{prefix}.#{m["name"]}"

        case build_fun(key, m["name"], m["doc"], kind, ctx) do
          {:skip, reason} -> {funs, Map.put(man, key, skip_entry(reason))}
          {:ok, fun} -> {[Map.put(fun, :key, key) | funs], man}
        end
      end)

    {funs, skipped} = resolve_collisions(Enum.reverse(funs))
    manifest = Map.merge(manifest, skipped)
    manifest = Enum.reduce(funs, manifest, &Map.put(&2, &1.key, fun_entry(module, &1, ctx)))

    kernel_except = funs |> Enum.flat_map(&kernel_clashes(&1.name, arities(&1))) |> Enum.uniq()

    {%{
       module: module,
       py_class: prefix,
       funs: Enum.sort_by(funs, & &1.name),
       kernel_except: kernel_except
     }, manifest}
  end

  defp resolve_collisions(funs) do
    funs
    |> Enum.group_by(& &1.name)
    |> Enum.reduce({[], %{}}, fn {_name, group}, {keep, skipped} ->
      [winner | losers] = Enum.sort_by(group, &{not upper?(&1.py_name), &1.py_name})

      skipped =
        Enum.reduce(losers, skipped, fn l, acc ->
          reason =
            if String.downcase(l.py_name) == String.downcase(winner.py_name),
              do: "alias of #{winner.py_name}",
              else: "snake_case name collides with #{winner.py_name}"

          Map.put(acc, l.key, skip_entry(reason))
        end)

      {[winner | keep], skipped}
    end)
  end

  defp upper?(<<c, _::binary>>), do: c in ?A..?Z

  # --- functions ---

  defp build_fun(key, py_name, doc, kind, ctx) do
    base = %{py_name: py_name, kind: kind, name: fun_name(py_name), doc: doc || "", note: nil}

    case Signature.for_entry(key, py_name, doc, ctx.overrides, ctx.constants) do
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:ok, variadic(base, reason, ctx)}
      {:ok, sig, source} -> with_signature(base, sig, source, key, ctx)
    end
  end

  defp with_signature(base, sig, source, key, ctx) do
    {params, note} =
      case Enum.find_index(sig.params, &String.contains?(type_text(&1.type), "FunctionType")) do
        nil ->
          {sig.params, nil}

        i ->
          if Enum.at(sig.params, i).optional,
            do: {Enum.take(sig.params, i), "callback parameters dropped: Phase 4"},
            else: {:callback, nil}
      end

    case params do
      :callback ->
        {:skip, "callback: Phase 4"}

      params ->
        {required, optional} = Enum.split_while(params, &(not &1.optional))

        if Enum.any?(optional, &(not &1.optional)) do
          {:ok, variadic(base, "required parameter after an optional one", ctx)}
        else
          fun =
            Map.merge(base, %{
              required: required_params(required),
              optional: Enum.map(optional, &{String.to_atom(snake(&1.name)), &1.default}),
              params: params,
              returns: sig.returns,
              source: source,
              note: note
            })

          {:ok,
           fun
           |> Map.put(:spec, spec(fun, ctx))
           |> Map.put(:getter?, getter?(fun, key, ctx))
           |> Map.put(:follow?, not Map.has_key?(ctx.overrides["smoke_no_follow"] || %{}, key))}
        end
    end
  end

  defp variadic(base, reason, ctx) do
    fun =
      Map.merge(base, %{
        required: [],
        optional: [],
        params: [],
        returns: "object",
        source: :variadic,
        note: "signature not parsed (#{reason}); takes an argument list",
        getter?: false
      })

    Map.put(fun, :spec, spec(fun, ctx))
  end

  defp required_params(params) do
    {vars, _} =
      Enum.map_reduce(params, MapSet.new(), fn p, seen ->
        v = snake(p.name)
        v = if v in @reserved or v in ["handle", "opts", "args"], do: v <> "_arg", else: v
        v = unique(v, seen, 2)
        {Map.merge(p, %{var: String.to_atom(v)}), MapSet.put(seen, v)}
      end)

    vars
  end

  defp unique(v, seen, n) do
    cond do
      not MapSet.member?(seen, v) -> v
      not MapSet.member?(seen, "#{v}#{n}") -> "#{v}#{n}"
      true -> unique(v, seen, n + 1)
    end
  end

  defp fun_name(py_name) do
    n = snake(py_name)
    String.to_atom(if n in @reserved or n in @special_forms, do: n <> "_", else: n)
  end

  defp getter?(fun, key, ctx) do
    fun.required == [] and fun.returns != "NoneType" and
      not Regex.match?(@not_getter_re, fun.py_name) and
      not Map.has_key?(ctx.overrides["smoke_skip"] || %{}, key)
  end

  defp arities(%{source: :variadic, kind: :method}), do: 1..3
  defp arities(%{source: :variadic}), do: 0..2

  defp arities(%{kind: kind, required: r}) do
    base = length(r) + if(kind == :method, do: 1, else: 0)
    base..(base + 1)
  end

  defp spec(fun, ctx) do
    self_arg = if fun.kind == :method, do: [quote(do: Poser.Handle.t())], else: []

    args =
      case fun.source do
        :variadic -> [quote(do: list())]
        _ -> Enum.map(fun.required, &Types.spec(&1.type, :arg, ctx.class_names))
      end

    ret = Types.spec(fun.returns, :return, ctx.class_names)
    head = {fun.name, [], self_arg ++ args ++ [quote(do: keyword())]}

    quote do
      unquote(head) :: {:ok, unquote(ret)} | {:error, Poser.Error.t()}
    end
  end

  defp constructor(class, doc, ctx) when is_binary(doc) do
    # e.g. "To create one pass 1 argument: <ImageType> poser.ImageType(<StringType> path)"
    re = Regex.compile!("<[^<>]*>\\s*poser\\." <> Regex.escape(class) <> "\\(.*$", "m")

    with [line | _] <- Regex.run(re, doc),
         line = String.replace(line, "poser." <> class <> "(", class <> "("),
         {:ok, sig} <- Signature.parse(class, line, ctx.constants),
         base = %{
           py_name: class,
           kind: :function,
           name: :new,
           doc: doc,
           note: nil,
           key: "#{class}.new"
         },
         {:ok, fun} <- with_signature(base, sig, :docstring, "#{class}.new", ctx) do
      %{fun | getter?: false}
    else
      _ -> nil
    end
  end

  defp constructor(_class, _doc, _ctx), do: nil

  # --- classes ---

  defp ancestors(classes, class, seen \\ []) do
    if class in seen do
      []
    else
      bases = get_in(classes, [class, "bases"]) || []
      bases ++ Enum.flat_map(bases, &ancestors(classes, &1, [class | seen]))
    end
  end

  defp exception?(classes, class), do: "BaseException" in ancestors(classes, class)

  defp accepts(classes, class) do
    descendants = for {c, _} <- classes, class in ancestors(classes, c), do: c
    Enum.sort([class | descendants])
  end

  # --- constants ---

  # kParmCodeXSCALE with group ParmCode -> parm_code(:xscale); the longest
  # matching group prefix wins, and ungrouped constants are fetch/1 only.
  defp const_model(constants, groups, namespace) do
    module =
      namespace |> Module.split() |> Enum.drop(-1) |> Kernel.++(["Const"]) |> Module.concat()

    groups = Enum.sort_by(groups, &{-String.length(&1), &1})

    grouped =
      for {"k" <> rest = py_name, value} <- constants,
          group = Enum.find(groups, &String.starts_with?(rest, &1)),
          key = rest |> String.replace_prefix(group, "") |> snake() |> String.trim("_"),
          key != "" do
        {group, key, py_name, value}
      end

    group_list =
      grouped
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map(fn {group, items} ->
        # Same key and same value (kSkinTypePOSER, kSkinTypePoser) is an
        # alias and becomes one key; different values are a real conflict.
        keys =
          items
          |> Enum.group_by(&elem(&1, 1))
          |> Enum.map(fn {key, dups} ->
            case dups |> Enum.map(&elem(&1, 3)) |> Enum.uniq() do
              [value] ->
                {String.to_atom(key), value,
                 dups |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.join(", ")}

              _ ->
                raise ArgumentError,
                      "constants #{dups |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.join(" and ")} " <>
                        "both map to #{group} key :#{key} with different values"
            end
          end)

        %{name: String.to_atom(group |> snake() |> String.trim("_")), keys: Enum.sort(keys)}
      end)

    %{module: module, groups: group_list, all: constants}
  end

  # --- manifest ---

  defp skip_entry(reason), do: %{"status" => "skipped", "reason" => reason}

  defp fun_entry(module, fun, ctx) do
    types = [fun.returns | Enum.map(fun.params, & &1.type)]

    %{
      "status" => "generated",
      "module" => inspect(module),
      "function" => Atom.to_string(fun.name),
      "arity" => Enum.max(arities(fun)),
      "source" => Atom.to_string(fun.source),
      "getter" => fun.getter?,
      "returns" => type_text(fun.returns),
      "unknown_types" =>
        types |> Enum.flat_map(&Types.unknowns(&1, ctx.class_names)) |> Enum.uniq()
    }
    |> then(fn e -> if fun.note, do: Map.put(e, "note", fun.note), else: e end)
  end

  defp manifest(dump, namespace, functions, modules, entries) do
    generated = for {_, %{"status" => "generated"} = e} <- entries, do: e
    constructors = for m <- modules, m.constructor, do: "#{m.py_class}.new"

    %{
      "api_hash" => get_in(dump, ["meta", "api_hash"]),
      "poser_version" => get_in(dump, ["meta", "poser_version"]),
      "namespace" => inspect(namespace),
      "summary" => %{
        "total" => map_size(entries),
        "generated" => length(generated),
        "skipped" => map_size(entries) - length(generated),
        "docstring" => Enum.count(generated, &(&1["source"] == "docstring")),
        "override" => Enum.count(generated, &(&1["source"] == "override")),
        "variadic" => Enum.count(generated, &(&1["source"] == "variadic")),
        "getters" => Enum.count(generated, & &1["getter"]),
        "constructors" => Enum.sort(constructors),
        "unknown_types" =>
          generated |> Enum.flat_map(& &1["unknown_types"]) |> Enum.uniq() |> Enum.sort()
      },
      "entries" => entries,
      "module_getters" => getters(functions),
      "classes" =>
        Map.new(modules, fn m ->
          {m.py_class,
           %{"module" => inspect(m.module), "accepts" => m.accepts, "getters" => getters(m)}}
        end)
    }
  end

  defp getters(mod) do
    for f <- mod.funs, f.getter? do
      %{
        "function" => Atom.to_string(f.name),
        "py_name" => f.py_name,
        "returns" => type_text(f.returns),
        "follow" => Map.get(f, :follow?, true)
      }
    end
  end

  @doc false
  def type_text(t) when is_binary(t), do: t
  def type_text({:tuple, ts}), do: "(" <> Enum.map_join(ts, ", ", &type_text/1) <> ")"
  def type_text({:union, ts}), do: Enum.map_join(ts, " | ", &type_text/1)

  @doc "snake_case for a Python name: `AlignmentRotationXYZ` → `alignment_rotation_xyz`."
  @spec snake(String.t()) :: String.t()
  def snake(name) do
    name
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
  end
end
