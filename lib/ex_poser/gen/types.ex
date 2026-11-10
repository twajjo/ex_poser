defmodule ExPoser.Gen.Types do
  @moduledoc "Maps PoserPython docstring types to Elixir typespecs."

  @integer ~w(IntType LongType EnumType)
  @float ~w(FloatType FloatValue)
  @string ["StringType", "String", "StringValue", "String Type"]
  @bool ~w(BoolType boolType)
  # Types that are deliberately term(): not reported as unknown.
  @any ~w(object ObjectType PointerType FunctionType)

  # Exact type names and the kind each one classifies as.
  @names Map.merge(
           for(
             {kind, names} <- [
               integer: @integer,
               float: @float,
               string: @string,
               bool: @bool,
               any: @any
             ],
             name <- names,
             into: %{},
             do: {name, kind}
           ),
           %{
             "NoneType" => nil,
             "DictType" => :map,
             "ListType" => :list_any,
             "TupleType" => :tuple_any
           }
         )

  @doc "The typespec AST for `type` as an argument (`:arg`) or a return value (`:return`)."
  @spec spec(ExPoser.Gen.Signature.type(), :arg | :return, Enumerable.t()) :: Macro.t()
  def spec(type, dir, classes), do: type |> classify(classes) |> to_ast(dir)

  @doc "Base type names in `type` that map to nothing and fall back to `term()`."
  @spec unknowns(ExPoser.Gen.Signature.type(), Enumerable.t()) :: [String.t()]
  def unknowns(type, classes),
    do: type |> classify(classes) |> collect_unknown([]) |> Enum.reverse()

  defp base(t, c) do
    case Map.fetch(@names, t) do
      {:ok, kind} -> kind
      :error -> if t in c, do: :handle, else: {:unknown, t}
    end
  end

  defp classify({:tuple, ts}, c), do: {:tuple, Enum.map(ts, &classify(&1, c))}
  defp classify({:union, ts}, c), do: {:union, Enum.map(ts, &classify(&1, c))}

  defp classify(t, c) when is_binary(t) do
    t = String.trim(t)

    cond do
      element = list_element(t) -> {:list, classify(element, c)}
      String.ends_with?(t, "Numeric.Array") -> :ndarray
      String.ends_with?(t, "Tuple") -> :tuple_any
      true -> base(t, c)
    end
  end

  defp collect_unknown({:unknown, t}, acc), do: [t | acc]
  defp collect_unknown({:list, t}, acc), do: collect_unknown(t, acc)

  defp collect_unknown({k, ts}, acc) when k in [:tuple, :union],
    do: Enum.reduce(ts, acc, &collect_unknown/2)

  defp collect_unknown(_, acc), do: acc

  # The element type of a list type ("List of X", "X list", "list X"), or nil.
  defp list_element(t) do
    Enum.find_value([~r/^List of (.+)$/, ~r/^(.+?)\s+[Ll]ists?$/, ~r/^list\s+(.+)$/], fn re ->
      case Regex.run(re, t, capture: :all_but_first) do
        [element] -> element
        nil -> nil
      end
    end)
  end

  defp to_ast(:integer, _), do: quote(do: integer())
  defp to_ast(:float, :arg), do: quote(do: number())
  defp to_ast(:float, :return), do: quote(do: float())
  defp to_ast(:string, _), do: quote(do: String.t())
  defp to_ast(:bool, :arg), do: quote(do: boolean())
  defp to_ast(:bool, :return), do: quote(do: boolean() | integer())
  defp to_ast(nil, _), do: nil
  defp to_ast(:map, _), do: quote(do: map())
  defp to_ast(:list_any, _), do: quote(do: list())
  defp to_ast(:tuple_any, _), do: quote(do: tuple())
  defp to_ast(:ndarray, _), do: quote(do: ExPoser.NDArray.t())
  defp to_ast(:handle, _), do: quote(do: ExPoser.Handle.t())
  defp to_ast(:any, _), do: quote(do: term())
  defp to_ast({:unknown, _}, _), do: quote(do: term())
  defp to_ast({:list, t}, d), do: [to_ast(t, d)]
  defp to_ast({:tuple, ts}, d), do: {:{}, [], Enum.map(ts, &to_ast(&1, d))}

  defp to_ast({:union, ts}, d) do
    ts |> Enum.map(&to_ast(&1, d)) |> Enum.reduce(fn t, acc -> {:|, [], [acc, t]} end)
  end
end
