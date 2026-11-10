defmodule ExPoser.NDArray do
  @moduledoc """
  A numpy array: raw bytes plus the numpy dtype string and shape.

  Poser returns these for array-valued methods, and methods that take a
  `Numeric.Array` accept one. With the optional `:nx` dependency,
  `to_nx/1` and `from_nx/1` convert to and from `Nx.Tensor`. Data is
  little-endian, as on every machine Poser runs on.
  """

  @enforce_keys [:dtype, :shape, :data]
  defstruct [:dtype, :shape, :data]

  @type t :: %__MODULE__{dtype: String.t(), shape: tuple(), data: binary()}

  if Code.ensure_loaded?(Nx) do
    @to_nx %{
      "<f4" => {:f, 32},
      "<f8" => {:f, 64},
      "<i4" => {:s, 32},
      "<i8" => {:s, 64},
      "|u1" => {:u, 8},
      "|b1" => {:u, 8}
    }
    @from_nx %{
      {:f, 32} => "<f4",
      {:f, 64} => "<f8",
      {:s, 32} => "<i4",
      {:s, 64} => "<i8",
      {:u, 8} => "|u1"
    }

    @doc "Converts to an `Nx.Tensor`. A bool array (`|b1`) becomes `:u8`."
    @spec to_nx(t()) :: Nx.Tensor.t()
    def to_nx(%__MODULE__{dtype: dtype, shape: shape, data: data}) do
      case Map.fetch(@to_nx, dtype) do
        {:ok, type} -> data |> Nx.from_binary(type) |> Nx.reshape(shape)
        :error -> raise ArgumentError, "unsupported numpy dtype #{inspect(dtype)}"
      end
    end

    @doc "Converts an `Nx.Tensor` to an NDArray."
    @spec from_nx(Nx.Tensor.t()) :: t()
    def from_nx(tensor) do
      type = Nx.type(tensor)

      case Map.fetch(@from_nx, type) do
        {:ok, dtype} ->
          %__MODULE__{dtype: dtype, shape: Nx.shape(tensor), data: Nx.to_binary(tensor)}

        :error ->
          raise ArgumentError, "unsupported Nx type #{inspect(type)}"
      end
    end
  end
end
