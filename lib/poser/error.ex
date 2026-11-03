defmodule Poser.Error do
  @moduledoc """
  An error from the bridge or from Poser.

  `kind` is one of `:python`, `:stale_handle`, `:not_allowed`, `:bad_request`,
  `:batch_failed`, `:timeout`, `:disconnected`, `:protocol_mismatch`,
  `:handshake_failed`, `:not_found`, `:ambiguous`.

  `:not_found` details: `%{path: [step], index: non_neg_integer() | nil, cause: t() | nil}`
  (`index` is the caller's op in a `Poser.Batch`).
  `:ambiguous` details: `%{matches: [struct]}`.
  """

  defexception [:kind, :class, :message, :traceback, :details]

  @type kind ::
          :python
          | :stale_handle
          | :not_allowed
          | :bad_request
          | :batch_failed
          | :timeout
          | :disconnected
          | :protocol_mismatch
          | :handshake_failed
          | :not_found
          | :ambiguous

  @type t :: %__MODULE__{
          kind: kind(),
          class: String.t() | nil,
          message: String.t() | nil,
          traceback: [String.t()] | nil,
          details: map() | nil
        }

  @doc "Builds an error from a wire-level `{:e, id, reason}` reason term."
  @spec from_wire(term()) :: t()
  def from_wire({:python, class, message, traceback}),
    do: %__MODULE__{kind: :python, class: class, message: message, traceback: traceback}

  def from_wire({:stale_handle, id, generation}),
    do: %__MODULE__{kind: :stale_handle, details: %{id: id, generation: generation}}

  def from_wire({:not_allowed, op, name}),
    do: %__MODULE__{kind: :not_allowed, message: name, details: %{op: op}}

  def from_wire({:bad_request, message}), do: %__MODULE__{kind: :bad_request, message: message}

  def from_wire({:batch_failed, index, cause, partial}),
    do: %__MODULE__{
      kind: :batch_failed,
      details: %{index: index, cause: from_wire(cause), partial: partial}
    }

  def from_wire({:protocol_mismatch, ours, theirs}),
    do: %__MODULE__{kind: :protocol_mismatch, details: %{ours: ours, theirs: theirs}}

  def from_wire(other), do: %__MODULE__{kind: :bad_request, message: inspect(other)}

  @impl true
  def message(%__MODULE__{kind: :not_found, details: %{path: path}}) do
    "not_found: " <> Enum.map_join(path, "/", &elem(&1, 1))
  end

  def message(%__MODULE__{kind: kind, class: class, message: message}) do
    [kind, class, message] |> Enum.reject(&is_nil/1) |> Enum.join(": ")
  end
end
