defmodule Poser do
  @moduledoc """
  Poser's scene as Elixir data: figures, body parts and dials are structs
  that name a path, and every operation on them is a batch.

  | Poser | Elixir |
  |---|---|
  | The open scene and its current frame | `Poser.Scene`, and the `frame:` option |
  | Figure | `%Poser.Figure{}` |
  | Body part, prop, camera or light | `%Poser.Actor{}` |
  | Dial ("parm") | `%Poser.Parameter{}` |
  | Internal name | a step in the struct's path |
  | Python object | `%Poser.Handle{}`, from `handle/2` |

  Start at `Poser.Scene` to find figures, then work down through
  `Poser.Figure`, `Poser.Actor` and `Poser.Parameter`. `batch/2` sends many
  reads and writes, on any dials and at any frames, in one request.

      iex> fig = %Poser.Figure{internal: "figure 1", name: "Andy"}
      iex> hip = %Poser.Actor{figure: fig, internal: "hip", name: "Hip"}
      iex> %Poser.Parameter{actor: hip, internal: "xrot", name: "xRotate"}
      #Poser.Parameter<figure 1/hip/xrot>

  The guides: [Getting started](getting-started.md), [Concepts](concepts.md),
  [Batching](batching.md).
  """

  @doc """
  Builds a batch with `fun` and sends it with `Poser.Batch.run/2`.

  `fun` receives `Poser.Batch.new()` and returns the batch to send. `opts` are
  those of `Poser.Batch.run/2`: `:server`, `:timeout` and `:chunk`.

  > #### No rollback {: .warning}
  >
  > Poser has no transactions. When an op fails, the ops before it stay
  > applied and later chunks don't run. See the [Batching](batching.md) guide.

  ## Examples

      Poser.batch(fn b ->
        b
        |> Poser.Batch.set(bend, 30.0, frame: 4)
        |> Poser.Batch.get(bend, frame: 4)
      end)
      #=> {:ok, [:ok, 30.0]}
  """
  @spec batch((Poser.Batch.t() -> Poser.Batch.t()), keyword()) ::
          {:ok, [term()]} | {:error, Poser.Error.t()}
  def batch(fun, opts \\ []) when is_function(fun, 1) do
    Poser.Batch.new() |> fun.() |> Poser.Batch.run(opts)
  end

  @doc """
  Like `batch/2`, but returns the results and raises `Poser.Error` on failure.

  ## Examples

      Poser.batch!(fn b ->
        b
        |> Poser.Batch.set(bend, 30.0, frame: 4)
        |> Poser.Batch.get(bend, frame: 4)
      end)
      #=> [:ok, 30.0]

      Poser.batch!(&Poser.Batch.get(&1, missing))
      ** (Poser.Error) not_found: figure 1/hip/nope
  """
  @spec batch!((Poser.Batch.t() -> Poser.Batch.t()), keyword()) :: [term()]
  def batch!(fun, opts \\ []) when is_function(fun, 1) do
    fun |> batch(opts) |> Poser.Ref.unwrap!()
  end
end
