defmodule ExPoser do
  @moduledoc """
  Poser's scene as Elixir data: figures, body parts and dials are structs
  that name a path, and every operation on them is a batch.

  | Poser | Elixir |
  |---|---|
  | The open scene and its current frame | `ExPoser.Scene`, and the `frame:` option |
  | Figure | `%ExPoser.Figure{}` |
  | Body part, prop, camera or light | `%ExPoser.Actor{}` |
  | Dial ("parm") | `%ExPoser.Parameter{}` |
  | Internal name | a step in the struct's path |
  | Python object | `%ExPoser.Handle{}`, from `handle/2` |

  Start at `ExPoser.Scene` to find figures, then work down through
  `ExPoser.Figure`, `ExPoser.Actor` and `ExPoser.Parameter`. `batch/2` sends many
  reads and writes, on any dials and at any frames, in one request.

      iex> fig = %ExPoser.Figure{internal: "figure 1", name: "Andy"}
      iex> hip = %ExPoser.Actor{figure: fig, internal: "hip", name: "Hip"}
      iex> %ExPoser.Parameter{actor: hip, internal: "xrot", name: "xRotate"}
      #ExPoser.Parameter<figure 1/hip/xrot>

  The guides: [Getting started](getting-started.md), [Concepts](concepts.md),
  [Batching](batching.md).
  """

  @doc """
  Builds a batch with `fun` and sends it with `ExPoser.Batch.run/2`.

  `fun` receives `ExPoser.Batch.new()` and returns the batch to send. `opts` are
  those of `ExPoser.Batch.run/2`: `:server`, `:timeout` and `:chunk`.

  > #### No rollback {: .warning}
  >
  > Poser has no transactions. When an op fails, the ops before it stay
  > applied and later chunks don't run. See the [Batching](batching.md) guide.

  ## Examples

      ExPoser.batch(fn b ->
        b
        |> ExPoser.Batch.set(bend, 30.0, frame: 4)
        |> ExPoser.Batch.get(bend, frame: 4)
      end)
      #=> {:ok, [:ok, 30.0]}
  """
  @spec batch((ExPoser.Batch.t() -> ExPoser.Batch.t()), keyword()) ::
          {:ok, [term()]} | {:error, ExPoser.Error.t()}
  def batch(fun, opts \\ []) when is_function(fun, 1) do
    ExPoser.Batch.new() |> fun.() |> ExPoser.Batch.run(opts)
  end

  @doc """
  Like `batch/2`, but returns the results and raises `ExPoser.Error` on failure.

  ## Examples

      ExPoser.batch!(fn b ->
        b
        |> ExPoser.Batch.set(bend, 30.0, frame: 4)
        |> ExPoser.Batch.get(bend, frame: 4)
      end)
      #=> [:ok, 30.0]

      ExPoser.batch!(&ExPoser.Batch.get(&1, missing))
      ** (ExPoser.Error) not_found: figure 1/hip/nope
  """
  @spec batch!((ExPoser.Batch.t() -> ExPoser.Batch.t()), keyword()) :: [term()]
  def batch!(fun, opts \\ []) when is_function(fun, 1) do
    fun |> batch(opts) |> ExPoser.Ref.unwrap!()
  end
end
