defmodule Poser.ErrorTest do
  use ExUnit.Case, async: true

  alias Poser.Error

  test "python errors" do
    e = Error.from_wire({:python, "ValueError", "bad", ["tb\n"]})
    assert %Error{kind: :python, class: "ValueError", message: "bad", traceback: ["tb\n"]} = e
    assert Exception.message(e) == "python: ValueError: bad"
  end

  test "stale handle" do
    assert %Error{kind: :stale_handle, details: %{id: 3, generation: 1}} =
             Error.from_wire({:stale_handle, 3, 1})
  end

  test "not allowed" do
    assert %Error{kind: :not_allowed, message: "SetFrame", details: %{op: :invoke}} =
             Error.from_wire({:not_allowed, :invoke, "SetFrame"})
  end

  test "batch_failed error nests its cause" do
    e = Error.from_wire({:batch_failed, 1, {:python, "ValueError", "x", []}, [7]})

    assert %Error{
             kind: :batch_failed,
             details: %{index: 1, partial: [7], cause: %Error{kind: :python}}
           } = e
  end

  test "bad request and protocol mismatch" do
    assert %Error{kind: :bad_request, message: "nope"} = Error.from_wire({:bad_request, "nope"})

    assert %Error{kind: :protocol_mismatch, details: %{ours: 1, theirs: 2}} =
             Error.from_wire({:protocol_mismatch, 1, 2})
  end

  test "message omits nil parts" do
    assert Exception.message(%Error{kind: :timeout}) == "timeout"
  end

  test "not_found message renders the path" do
    e = %Error{
      kind: :not_found,
      details: %{
        path: [{:figure, "figure 1"}, {:actor, "lforearm"}, {:parm, "bend"}],
        index: nil,
        cause: nil
      }
    }

    assert Exception.message(e) == "not_found: figure 1/lforearm/bend"
  end

  test "ambiguous message" do
    assert Exception.message(%Error{kind: :ambiguous, details: %{matches: []}}) == "ambiguous"
  end
end
