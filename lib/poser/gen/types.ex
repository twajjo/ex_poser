defmodule Poser.Gen.Types do
  @moduledoc "Maps PoserPython docstring types to Elixir typespecs."

  @integer ~w(IntType LongType EnumType)
  @float ~w(FloatType FloatValue)
  @string ["StringType", "String", "StringValue", "String Type"]
  @bool ~w(BoolType boolType)
  # Types that are deliberately term(): not reported as unknown.
  @any ~w(object ObjectType PointerType FunctionType)

  @doc "The typespec AST for `type` as an argument (`:arg`) or a return value (`:return`)."
  @spec spec(Poser.Gen.Signature.type(), :arg | :return, Enumerable.t()) :: Macro.t()
  def spec(type, dir, classes), do: type |> classify(classes) |> to_ast(dir)

  @doc "Base type names in `type` that map to nothing and fall back to `term()`."
  @spec unknowns(Poser.Gen.Signature.type(), Enumerable.t()) :: [String.t()]
  def unknowns(type, classes),
    do: type |> classify(classes) |> collect_unknown([]) |> Enum.reverse()

  defp classify({:tuple, ts}, c), do: {:tuple, Enum.map(ts, &classify(&1, c))}
  defp classify({:union, ts}, c), do: {:union, Enum.map(ts, &classify(&1, c))}

  defp classify(t, c) when is_binary(t) do
    t = String.trim(t)

    cond do
      m = Regex.run(~r/^List of (.+)$/, t) -> {:list, classify(Enum.at(m, 1), c)}
      m = Regex.run(~r/^(.+?)\s+[Ll]ists?$/, t) -> {:list, classify(Enum.at(m, 1), c)}
      m = Regex.run(~r/^list\s+(.+)$/, t) -> {:list, classify(Enum.at(m, 1), c)}
      String.ends_with?(t, "Numeric.Array") -> :ndarray
      String.ends_with?(t, "Tuple") or t == "TupleType" -> :tuple_any
      t in @integer -> :integer
      t in @float -> :float
      t in @string -> :string
      t in @bool -> :bool
      t == "NoneType" -> nil
      t == "DictType" -> :map
      t == "ListType" -> :list_any
      t in @any -> :any
      t in c -> :handle
      true -> {:unknown, t}
    end
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
  defp to_ast(:ndarray, _), do: quote(do: Poser.NDArray.t())
  defp to_ast(:handle, _), do: quote(do: Poser.Handle.t())
  defp to_ast(:any, _), do: quote(do: term())
  defp to_ast({:unknown, _}, _), do: quote(do: term())
  defp to_ast({:list, t}, d), do: [to_ast(t, d)]
  defp to_ast({:tuple, ts}, d), do: {:{}, [], Enum.map(ts, &to_ast(&1, d))}

  defp to_ast({:union, ts}, d) do
    ts |> Enum.map(&to_ast(&1, d)) |> Enum.reduce(fn t, acc -> {:|, [], [acc, t]} end)
  end

  defp collect_unknown({:unknown, t}, acc), do: [t | acc]
  defp collect_unknown({:list, t}, acc), do: collect_unknown(t, acc)

  defp collect_unknown({k, ts}, acc) when k in [:tuple, :union],
    do: Enum.reduce(ts, acc, &collect_unknown/2)

  defp collect_unknown(_, acc), do: acc
end
