defmodule Poser do
  @moduledoc """
  Idiomatic access to Poser scenes through name-path structs
  (`Poser.Figure`, `Poser.Actor`, `Poser.Parameter`) and batches.
  """

  @doc """
  Builds a batch with `fun` and sends it with `Poser.Batch.run/2`.

  `fun` receives `Poser.Batch.new()` and returns the batch to send. `opts` are
  those of `Poser.Batch.run/2`. Ops before a failure stay applied.

  ## Examples

      Poser.batch(fn b ->
        b
        |> Poser.Batch.set(bend, 30.0, frame: 5)
        |> Poser.Batch.get(bend, frame: 12)
      end)
      #=> {:ok, [:ok, 0.0]}
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
        |> Poser.Batch.set(bend, 30.0, frame: 5)
        |> Poser.Batch.get(bend, frame: 12)
      end)
      #=> [:ok, 0.0]

      Poser.batch!(&Poser.Batch.get(&1, missing))
      ** (Poser.Error) not_found: figure 1/hip/nope
  """
  @spec batch!((Poser.Batch.t() -> Poser.Batch.t()), keyword()) :: [term()]
  def batch!(fun, opts \\ []) when is_function(fun, 1) do
    fun |> batch(opts) |> Poser.Ref.unwrap!()
  end
end
