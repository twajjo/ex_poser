defmodule Poser.Error do
  @moduledoc """
  An error from the bridge or from Poser, returned as
  `{:error, %Poser.Error{}}` and raised by the `!` functions.

  `kind` says what went wrong; `details` carries the specifics:

  | Kind | `details` |
  |---|---|
  | `:not_found` | `path` (the steps that didn't resolve), `index`, `cause` |
  | `:ambiguous` | `matches` (every struct a display name matched) |
  | `:python` | `index` in a batch; plus `class`, `message`, `traceback` |
  | `:not_allowed` | `op` (the refused wire op kind, e.g. `:invoke`), `index` in a batch |
  | `:stale_handle` | `id`, `generation` |
  | `:batch_failed` | `index` (wire op), `cause`, `partial` |
  | `:disconnected` | `reason` |
  | `:protocol_mismatch` | `ours`, `theirs` |
  | `:timeout`, `:bad_request`, `:handshake_failed` | none |

  An error from a `Poser.Batch`, which includes every call in the idiomatic
  API, carries `details.index`: the index of the caller's op that failed,
  not counting the batch's own lookups.

      iex> error = Poser.Error.not_found([figure: "figure 1", actor: "nope"], 0)
      iex> error.details.path
      [figure: "figure 1", actor: "nope"]
      iex> Exception.message(error)
      "not_found: figure 1/nope"

  See the [Errors](errors.md) guide.
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

  @doc """
  Builds a `:not_found` error for a path of `Poser.Ref.path/1` steps, with
  the caller's op `index` and the Python error, if any, that caused it.

  ## Examples

      iex> Poser.Error.not_found([actor: "ball"]).details
      %{path: [actor: "ball"], index: nil, cause: nil}
  """
  @spec not_found([tuple()], non_neg_integer() | nil, t() | nil) :: t()
  def not_found(path, index \\ nil, cause \\ nil),
    do: %__MODULE__{kind: :not_found, details: %{path: path, index: index, cause: cause}}

  @doc """
  Builds an error from a wire-level `{:e, id, reason}` reason term.

  ## Examples

      iex> Poser.Error.from_wire({:not_allowed, :invoke, "Delete"})
      %Poser.Error{kind: :not_allowed, message: "Delete", details: %{op: :invoke}}
  """
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

  def message(%__MODULE__{kind: :ambiguous, details: %{matches: [%{name: name} | _] = matches}}) do
    "ambiguous: #{inspect(name)} matches " <>
      Enum.map_join(matches, ", ", &Poser.Ref.path_string/1)
  end

  def message(%__MODULE__{kind: kind, class: class, message: message}) do
    [kind, class, message] |> Enum.reject(&is_nil/1) |> Enum.join(": ")
  end
end
