defmodule ExPoser.NDArrayTest do
  use ExUnit.Case, async: true

  alias ExPoser.{Codec, NDArray}

  test "an NDArray goes on the wire as an ndarray tuple and comes back" do
    a = %NDArray{dtype: "<f4", shape: {1, 2}, data: <<0::32, 0::32>>}
    # data travels as {:bytes, _}: Python's codec turns bare binaries into str
    assert Codec.to_wire(a) == {:ndarray, "<f4", {1, 2}, {:bytes, <<0::32, 0::32>>}}
    assert Codec.from_wire({:ndarray, "<f4", {1, 2}, <<0::32, 0::32>>}, 1) == a
    assert Codec.to_wire([a]) == [{:ndarray, "<f4", {1, 2}, {:bytes, <<0::32, 0::32>>}}]
  end

  test "from_nx and to_nx round trip" do
    t = Nx.tensor([[1.0, 2.0]], type: :f32)
    a = NDArray.from_nx(t)
    assert %NDArray{dtype: "<f4", shape: {1, 2}} = a
    assert NDArray.to_nx(a) == t
  end

  test "supported dtypes map both ways" do
    for {dtype, type} <- [
          {"<f4", {:f, 32}},
          {"<f8", {:f, 64}},
          {"<i4", {:s, 32}},
          {"<i8", {:s, 64}},
          {"|u1", {:u, 8}}
        ] do
      t = Nx.tensor([1, 2, 3], type: type)
      assert NDArray.from_nx(t).dtype == dtype
      assert NDArray.to_nx(NDArray.from_nx(t)) == t
    end

    bools = %NDArray{dtype: "|b1", shape: {2}, data: <<1, 0>>}
    assert NDArray.to_nx(bools) == Nx.tensor([1, 0], type: :u8)
  end

  test "an unsupported dtype raises naming it" do
    assert_raise ArgumentError, ~r/>f4/, fn ->
      NDArray.to_nx(%NDArray{dtype: ">f4", shape: {1}, data: <<0::32>>})
    end

    assert_raise ArgumentError, ~r/\{:f, 16\}/, fn ->
      NDArray.from_nx(Nx.tensor([1.0], type: :f16))
    end
  end
end
