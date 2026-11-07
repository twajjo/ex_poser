defmodule Poser.Call do
  @moduledoc """
  Runtime for the generated `Poser.Api` modules.

  Poser's methods are written in C and take arguments by position only, so
  optional Python arguments, given as keyword `opts`, are turned back into
  positional arguments here. `:server` and `:timeout` in `opts` go to
  `Poser.Client`.
  """

  alias Poser.{Client, Handle}

  @client_keys [:server, :timeout]

  @typedoc "Ordered optional Python parameters with their defaults, if known."
  @type optional :: [{atom(), {:default, term()} | :none}]

  @doc false
  # Returns {positional_args, client_opts}. Trailing omitted optionals are
  # dropped so Python applies its own defaults; a gap before a given option
  # is filled with the known default, or raises when there is none.
  @spec build_args(list(), optional(), keyword()) :: {list(), keyword()}
  def build_args(args, optional, opts) when is_list(args) and is_list(opts) do
    {client_opts, py_opts} = Keyword.split(opts, @client_keys)
    names = Keyword.keys(optional)

    case Keyword.keys(py_opts) -- names do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown options #{inspect(unknown)}; expected #{inspect(names ++ @client_keys)}"
    end

    last =
      optional
      |> Enum.with_index()
      |> Enum.filter(fn {{n, _}, _} -> Keyword.has_key?(py_opts, n) end)

    extra =
      case List.last(last) do
        nil ->
          []

        {_, last_index} ->
          optional
          |> Enum.take(last_index + 1)
          |> Enum.map(fn {name, default} ->
            fill(name, default, py_opts, optional, last_index)
          end)
      end

    {args ++ extra, client_opts}
  end

  @doc "Calls the module-level `poser` function `py_name`."
  @spec function(String.t(), list(), optional(), keyword()) ::
          {:ok, term()} | {:error, Poser.Error.t()}
  def function(py_name, args, optional, opts) do
    {args, client_opts} = build_args(args, optional, opts)
    Client.call(py_name, args, client_opts)
  end

  @doc "Calls the method `py_name` on `handle`."
  @spec method(Handle.t(), String.t(), list(), optional(), keyword()) ::
          {:ok, term()} | {:error, Poser.Error.t()}
  def method(%Handle{} = handle, py_name, args, optional, opts) do
    {args, client_opts} = build_args(args, optional, opts)
    Client.invoke(handle, py_name, args, client_opts)
  end

  defp fill(name, default, py_opts, optional, last_index) do
    case {Keyword.fetch(py_opts, name), default} do
      {{:ok, v}, _} ->
        v

      {:error, {:default, v}} ->
        v

      {:error, :none} ->
        {later, _} = Enum.at(optional, last_index)

        raise ArgumentError,
              "option #{inspect(name)} has no known default and must be given when #{inspect(later)} is"
    end
  end
end
