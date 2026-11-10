defmodule ExPoser.EventsTest do
  use ExUnit.Case, async: true

  test "subscribers receive dispatched events" do
    :ok = ExPoser.Events.subscribe(:test_event)
    :ok = ExPoser.Events.dispatch(:test_event, 42)
    assert_receive {:poser_event, :test_event, 42}
    :ok = ExPoser.Events.unsubscribe(:test_event)
    :ok = ExPoser.Events.dispatch(:test_event, 43)
    refute_receive {:poser_event, :test_event, 43}, 50
  end
end
