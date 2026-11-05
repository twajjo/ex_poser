defmodule Poser.Gen.Signature do
  @moduledoc """
  Parses the typed signature line in a PoserPython docstring, for example
  `<NoneType> CloseDocument({<IntType> discardChanges = 0})`.

  Parameters inside `{ … }` are optional. Anything the parser can't read
  completely is an error; a corrected line then goes in
  `priv/poser_api_overrides.json`.
  """

  @type type :: String.t() | {:tuple, [type]} | {:union, [type]}
  @type param :: %{
          name: String.t(),
          type: type,
          optional: boolean(),
          default: {:default, term()} | :none
        }
  @type t :: %{returns: type, params: [param]}

  @doc """
  Parses the signature of `name` from `doc`. `constants` resolves
  `poser.kName` defaults.
  """
  @spec parse(String.t(), String.t() | nil, %{String.t() => term()}) ::
          {:ok, t} | {:error, String.t()}
  def parse(_name, nil, _constants), do: {:error, "no docstring"}

  def parse(name, doc, constants) when is_binary(doc) do
    re = Regex.compile!("^(.*?)(?<![\\w.])" <> Regex.escape(name) <> "\\s*(\\(.*)$")

    case doc
         |> String.split("\n")
         |> Enum.filter(&String.contains?(&1, "<"))
         |> Enum.flat_map(&split_line(re, &1)) do
      [] -> {:error, "no signature line"}
      lines -> lines |> Enum.map(&parse_line(&1, constants)) |> combine()
    end
  end

  @doc """
  The signature for one dump entry: a skip from the overrides, an
  override line, or the docstring, in that order. `key` is
  `"Class.Method"` or `"poser.Function"`.
  """
  @spec for_entry(String.t(), String.t(), String.t() | nil, map(), map()) ::
          {:ok, t, :docstring | :override} | {:skip, String.t()} | {:error, String.t()}
  def for_entry(key, name, doc, overrides, constants) do
    cond do
      reason = overrides["skip"][key] ->
        {:skip, reason}

      line = overrides["signatures"][key] ->
        case parse(name, line, constants) do
          {:ok, sig} -> {:ok, sig, :override}
          {:error, reason} -> {:error, "override for #{key}: #{reason}"}
        end

      true ->
        with {:ok, sig} <- parse(name, doc, constants), do: {:ok, sig, :docstring}
    end
  end

  defp split_line(re, line) do
    case Regex.run(re, line, capture: :all_but_first) do
      [before, rest] -> [{before, rest}]
      nil -> []
    end
  end

  defp combine(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, _} = e ->
        e

      nil ->
        sigs = Enum.map(results, fn {:ok, s} -> s end)

        case sigs |> Enum.map(& &1.params) |> Enum.uniq() do
          [params] ->
            returns = sigs |> Enum.map(& &1.returns) |> Enum.uniq()

            {:ok,
             %{
               params: params,
               returns: if(match?([_], returns), do: hd(returns), else: {:union, returns})
             }}

          _ ->
            {:error, "signature lines disagree on parameters"}
        end
    end
  end

  defp parse_line({before, after_name}, constants) do
    with {:ok, ret_tokens} <- tokenize(String.trim(before)),
         {:ok, returns} <- parse_return(ret_tokens),
         {:ok, tokens} <- tokenize(after_name),
         {:ok, params} <- parse_params(tokens, constants) do
      {:ok, %{returns: returns, params: params}}
    end
  end

  # --- tokenizer ---

  defp tokenize(s), do: tokenize(s, [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r], do: tokenize(rest, acc)

  defp tokenize("<" <> rest, acc) do
    case String.split(rest, ">", parts: 2) do
      [text, rest] ->
        if text == "" or String.match?(text, ~r/[<(){}]/),
          do: {:error, "bad type <#{text}>"},
          else: tokenize(rest, [{:type, String.trim(text)} | acc])

      [_] ->
        {:error, "unclosed <"}
    end
  end

  defp tokenize(<<c, rest::binary>>, acc) when c in ~c"(){},=.",
    do: tokenize(rest, [<<c>> | acc])

  defp tokenize(<<q, _::binary>> = s, acc) when q in [?', ?"] do
    case Regex.run(~r/^#{<<q>>}([^#{<<q>>}]*)#{<<q>>}(.*)$/s, s) do
      [_, str, rest] -> tokenize(rest, [{:lit, str} | acc])
      nil -> {:error, "unclosed string"}
    end
  end

  defp tokenize(s, acc) do
    cond do
      m = Regex.run(~r/^(-?\d+\.\d+)(.*)$/s, s) ->
        [_, n, rest] = m
        tokenize(rest, [{:lit, String.to_float(n)} | acc])

      m = Regex.run(~r/^(-?\d+)(.*)$/s, s) ->
        [_, n, rest] = m
        tokenize(rest, [{:lit, String.to_integer(n)} | acc])

      m = Regex.run(~r/^([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*)(.*)$/s, s) ->
        [_, id, rest] = m
        tokenize(rest, [{:ident, id} | acc])

      true ->
        {:error, "unexpected #{inspect(String.first(s))}"}
    end
  end

  # --- return types ---

  defp parse_return([]), do: {:ok, "object"}

  defp parse_return(tokens) do
    case parse_type_expr(tokens) do
      {:ok, t, []} -> {:ok, t}
      {:ok, _, rest} -> {:error, "unexpected #{inspect(hd(rest))} in return type"}
      e -> e
    end
  end

  defp parse_type_expr([{:type, t} | rest]), do: {:ok, t, rest}
  defp parse_type_expr(["(" | rest]), do: tuple_items(rest, [])
  defp parse_type_expr([tok | _]), do: {:error, "unexpected #{inspect(tok)} in type"}
  defp parse_type_expr([]), do: {:error, "missing type"}

  defp tuple_items(tokens, acc) do
    with {:ok, t, rest} <- parse_type_expr(tokens) do
      rest = drop_ident(rest)

      case rest do
        ["," | rest] -> tuple_items(rest, [t | acc])
        [")" | rest] -> {:ok, {:tuple, Enum.reverse([t | acc])}, rest}
        _ -> {:error, "bad tuple type"}
      end
    end
  end

  defp drop_ident([{:ident, _} | rest]), do: rest
  defp drop_ident(rest), do: rest

  # --- parameters ---

  defp parse_params(["(" | rest], constants), do: params(rest, 0, true, [], constants)

  defp params([")" | rest], 0, _sep_ok, acc, _c) do
    case rest do
      [] -> {:ok, Enum.reverse(acc)}
      ["."] -> {:ok, Enum.reverse(acc)}
      _ -> {:error, "text after the closing parenthesis"}
    end
  end

  defp params([")" | _], _depth, _, _, _), do: {:error, "unbalanced {"}
  defp params(["{" | rest], d, _, acc, c), do: params(rest, d + 1, true, acc, c)
  defp params(["}" | _], 0, _, _, _), do: {:error, "unbalanced }"}
  defp params(["}" | rest], d, _, acc, c), do: params(rest, d - 1, true, acc, c)
  defp params(["," | rest], d, _, acc, c), do: params(rest, d, true, acc, c)

  defp params([{:type, t}, {:ident, name} | rest], d, true, acc, c) do
    {default, rest} =
      case rest do
        ["=", lit | rest] -> {literal(lit, c), rest}
        rest -> {{:ok, :none}, rest}
      end

    case default do
      {:ok, default} ->
        p = %{name: name, type: t, optional: d > 0, default: default}
        params(rest, d, false, [p | acc], c)

      e ->
        e
    end
  end

  defp params([], _, _, _, _), do: {:error, "missing )"}
  defp params([tok | _], _, _, _, _), do: {:error, "unexpected #{inspect(tok)} in parameters"}

  defp literal({:lit, v}, _c), do: {:ok, {:default, v}}
  defp literal({:ident, b}, _c) when b in ["true", "True"], do: {:ok, {:default, true}}
  defp literal({:ident, b}, _c) when b in ["false", "False"], do: {:ok, {:default, false}}
  defp literal({:ident, "None"}, _c), do: {:ok, {:default, nil}}

  defp literal({:ident, "poser." <> k}, c) do
    case Map.fetch(c, k) do
      {:ok, v} -> {:ok, {:default, v}}
      :error -> {:error, "unknown constant poser.#{k}"}
    end
  end

  defp literal(tok, _c), do: {:error, "bad default #{inspect(tok)}"}
end
