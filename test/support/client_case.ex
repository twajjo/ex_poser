defmodule PoserTest.ClientCase do
  @moduledoc "Starts a standalone server and a connected Poser.Client for a test."

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @doc "Start a client on `session` and wait until it is connected; returns its name."
  def start_client(session, opts \\ []) do
    name = :"poser_client_#{System.unique_integer([:positive])}"
    :ok = Poser.Events.subscribe(:connected)
    start_supervised!({Poser.Client, [name: name, session: session] ++ opts}, id: name)
    assert_receive {:poser_event, :connected, %{server: ^name}}, 5_000
    name
  end

  def start_standalone(opts \\ []) do
    server = PoserTest.Standalone.start!(opts)
    on_exit(fn -> PoserTest.Standalone.stop!(server) end)
    server
  end

  @doc "Poll `fun` every 20 ms until it returns truthy or `timeout` ms pass."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        receive do
        after
          20 -> poll(fun, deadline)
        end
    end
  end
end
