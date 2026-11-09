defmodule Poser.CodecTest do
  use ExUnit.Case, async: true

  alias Poser.{Codec, Handle, NDArray}

  @h %Handle{class: "ActorType", id: 4, generation: 2, label: "hip"}

  test "handle round-trips through the wire" do
    assert Codec.to_wire(@h) == {:poser_obj, "ActorType", 4, 2, "hip"}
    assert Codec.from_wire(Codec.to_wire(@h), 3) == %{@h | epoch: 3}
  end

  test "atoms other than nil/true/false become strings" do
    assert Codec.to_wire([:x, nil, true, false]) == ["x", nil, true, false]
    assert Codec.to_wire(%{a: :b}) == %{"a" => "b"}
  end

  test "result references and raw bytes pass through" do
    assert Codec.to_wire([{:result, 0}, {:bytes, <<1, 2>>}]) == [{:result, 0}, {:bytes, <<1, 2>>}]
  end

  test "ndarray tuples become NDArray structs" do
    assert Codec.from_wire({:ndarray, "<f4", {2, 3}, "xx"}, 1) ==
             %NDArray{dtype: "<f4", shape: {2, 3}, data: "xx"}
  end

  test "from_wire walks lists, tuples and maps" do
    wire = Codec.to_wire(@h)

    assert Codec.from_wire(%{"a" => [wire, {wire}]}, 7) == %{
             "a" => [%{@h | epoch: 7}, {%{@h | epoch: 7}}]
           }
  end

  test "encode/decode round trip" do
    assert {:ok, {:r, 1, [1, "x"]}} = Codec.decode(Codec.encode({:r, 1, [1, "x"]}))
  end

  test "decode rejects unknown atoms" do
    name = "never_seen_#{System.unique_integer([:positive])}"
    bin = <<131, 119, byte_size(name), name::binary>>
    assert Codec.decode(bin) == {:error, :undecodable}
  end

  test "decode rejects garbage" do
    assert Codec.decode(<<1, 2, 3>>) == {:error, :undecodable}
  end

  test "known atoms exist and cover the protocol" do
    atoms = Codec.known_atoms()
    assert Enum.all?(atoms, &is_atom/1)

    for a <- [:poser_obj, :generation_changed, :api_hash, :neg_infinity, :batch_failed],
        do: assert(a in atoms)
  end

  test "handles_in finds nested handles" do
    h2 = %{@h | id: 5}

    assert Codec.handles_in(%{"x" => [@h, {1, h2}], "y" => "s"}) |> Enum.sort_by(& &1.id) == [
             @h,
             h2
           ]
  end

  test "to_wire rejects values Python cannot receive" do
    for bad <- [self(), make_ref(), fn -> :ok end, ~D[2020-01-01], <<255, 254>>, [<<255>>]] do
      assert_raise ArgumentError, fn -> Codec.to_wire(bad) end
    end

    assert Codec.to_wire({:bytes, <<255, 254>>}) == {:bytes, <<255, 254>>}
  end
end
