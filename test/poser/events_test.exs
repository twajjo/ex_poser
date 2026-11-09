defmodule Poser.EventsTest do
  use ExUnit.Case, async: true

  test "subscribers receive dispatched events" do
    :ok = Poser.Events.subscribe(:test_event)
    :ok = Poser.Events.dispatch(:test_event, 42)
    assert_receive {:poser_event, :test_event, 42}
    :ok = Poser.Events.unsubscribe(:test_event)
    :ok = Poser.Events.dispatch(:test_event, 43)
    refute_receive {:poser_event, :test_event, 43}, 50
  end
end
