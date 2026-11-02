defmodule Poser.Codec do
  @moduledoc """
  Term conversion between Elixir and the bridge wire format (ETF, decoded with `:safe`).

  Outbound: `%Poser.Handle{}` becomes the handle tuple; atoms other than
  `nil`/`true`/`false` become strings; `{:result, n}` and `{:bytes, bin}` pass
  through. Inbound: handle tuples become `%Poser.Handle{}` stamped with the
  connection epoch, ndarray tuples become `%Poser.NDArray{}`.
  """

  alias Poser.{Handle, NDArray}

  # Every atom the add-on can send. binary_to_term(.., [:safe]) only accepts
  # atoms that already exist, so they are listed here.
  @known_atoms [
    # message tags
    :r,
    :e,
    :M,
    # values
    :pong,
    :poser_obj,
    :ndarray,
    :result,
    nil,
    true,
    false,
    :nan,
    :infinity,
    :neg_infinity,
    :obj,
    :bytes,
    # error kinds
    :python,
    :stale_handle,
    :not_allowed,
    :bad_request,
    :batch_failed,
    :protocol_mismatch,
    # not_allowed sub-kinds
    :call,
    :invoke,
    :get_attr,
    :raw,
    # events
    :frame_changed,
    :generation_changed,
    # modes
    :dev,
    :strict,
    # hello reply keys
    :protocol,
    :mode,
    :poser_version,
    :python_version,
    :api_hash
  ]

  @spec known_atoms() :: [atom()]
  def known_atoms, do: @known_atoms

  @doc """
  Serializes a frame as is. Request tags and hello keys must stay atoms, so
  callers apply `to_wire/1` to user-supplied parts (args, kwargs, handles) only.
  """
  @spec encode(term()) :: binary()
  def encode(frame), do: :erlang.term_to_binary(frame)

  @spec decode(binary()) :: {:ok, term()} | {:error, :undecodable}
  def decode(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError -> {:error, :undecodable}
  end

  @doc """
  Converts an outbound value. Raises `ArgumentError` for values Python cannot
  receive: pids, refs, funs, ports, structs other than `%Poser.Handle{}` and
  `%Poser.NDArray{}`, and
  binaries that are not valid UTF-8 (send raw bytes as `{:bytes, bin}`).
  """
  @spec to_wire(term()) :: term()
  def to_wire(%Handle{} = h), do: {:poser_obj, h.class, h.id, h.generation, h.label}

  def to_wire(%NDArray{dtype: dtype, shape: shape, data: data})
      when is_binary(dtype) and is_tuple(shape) and is_binary(data),
      do: {:ndarray, dtype, shape, {:bytes, data}}

  def to_wire(%_{} = v),
    do: raise(ArgumentError, "cannot send #{inspect(v)} to Poser (structs are not supported)")

  def to_wire(v) when v in [nil, true, false], do: v
  def to_wire(v) when is_atom(v), do: Atom.to_string(v)
  def to_wire(v) when is_number(v), do: v
  def to_wire({:result, n} = ref) when is_integer(n), do: ref
  def to_wire({:bytes, bin} = b) when is_binary(bin), do: b

  def to_wire(v) when is_binary(v) do
    if String.valid?(v),
      do: v,
      else: raise(ArgumentError, "binary is not valid UTF-8; send raw bytes as {:bytes, bin}")
  end

  def to_wire(v) when is_list(v), do: Enum.map(v, &to_wire/1)

  def to_wire(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&to_wire/1) |> List.to_tuple()

  def to_wire(v) when is_map(v), do: Map.new(v, fn {k, x} -> {to_wire(k), to_wire(x)} end)
  def to_wire(v), do: raise(ArgumentError, "cannot send #{inspect(v)} to Poser")

  @spec from_wire(term(), non_neg_integer() | nil) :: term()
  def from_wire({:poser_obj, class, id, generation, label}, epoch),
    do: %Handle{class: class, id: id, generation: generation, label: label, epoch: epoch}

  def from_wire({:ndarray, dtype, shape, data}, _epoch),
    do: %NDArray{dtype: dtype, shape: shape, data: data}

  def from_wire(v, epoch) when is_list(v), do: Enum.map(v, &from_wire(&1, epoch))

  def from_wire(v, epoch) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&from_wire(&1, epoch)) |> List.to_tuple()

  def from_wire(v, epoch) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, x} -> {k, from_wire(x, epoch)} end)

  def from_wire(v, _epoch), do: v

  @doc "Every `%Poser.Handle{}` inside a term."
  @spec handles_in(term()) :: [Handle.t()]
  def handles_in(term), do: term |> collect([]) |> Enum.reverse()

  defp collect(%Handle{} = h, acc), do: [h | acc]
  defp collect(v, acc) when is_list(v), do: Enum.reduce(v, acc, &collect/2)
  defp collect(v, acc) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.reduce(acc, &collect/2)

  defp collect(v, acc) when is_map(v) and not is_struct(v),
    do: Enum.reduce(v, acc, fn {_k, x}, a -> collect(x, a) end)

  defp collect(_v, acc), do: acc
end
