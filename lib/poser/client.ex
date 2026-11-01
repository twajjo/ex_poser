defmodule Poser.Client do
  @moduledoc """
  The connection to the Poser bridge add-on.

  Owns one transport connection, matches replies to requests by id, enforces
  per-request timeouts, and reconnects with backoff. Every public function
  takes `opts`:

    * `:server` - the client name or pid (default `Poser.Client`)
    * `:timeout` - ms to wait for this request, or `:infinity`
      (default: the client's `:call_timeout`, 120 000 ms)
    * `:kw` - keyword arguments for the Python call

  Results are `{:ok, value}` or `{:error, %Poser.Error{}}`. Poser objects come
  back as `%Poser.Handle{}`.
  """

  use GenServer

  require Logger

  alias Poser.{Codec, Error, Events, Handle, Session}

  @version Mix.Project.config()[:version]

  @defaults [
    transport: Poser.Transport.TCP,
    call_timeout: 120_000,
    connect_timeout: 5_000,
    heartbeat_interval: 5_000,
    heartbeat_timeout: 15_000,
    backoff_initial: 250,
    backoff_max: 10_000
  ]

  # --- Public API ---

  @doc """
  Starts a client. Options: `:name` (default `Poser.Client`), `:session`
  (session file path, default `Poser.Session.default_path/0`), `:host`,
  `:port`, `:token` (override the session file), `:transport`,
  `:call_timeout`, `:connect_timeout`, `:heartbeat_interval`,
  `:heartbeat_timeout`, `:backoff_initial`, `:backoff_max`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Calls a module-level `poser` function, e.g. `call(\"Scene\")`."
  def call(name, args \\ [], opts \\ []), do: request({:call, name, args, kw(opts)}, opts)

  @doc "Calls a method on a Poser object."
  def invoke(%Handle{} = h, method, args \\ [], opts \\ []),
    do: request({:invoke, h, method, args, kw(opts)}, opts)

  @doc "Reads an attribute of a Poser object."
  def get_attr(%Handle{} = h, attr, opts \\ []), do: request({:get_attr, h, attr}, opts)

  @doc """
  Runs several operations in one main-thread turn. Ops are
  `{:call, name, args}`, `{:call, name, args, kw}`, `{:invoke, target, method, args}`,
  `{:invoke, target, method, args, kw}` and `{:get_attr, target, attr}`, where a
  target or argument may be `{:result, n}` (the result of op `n`, 0-based).
  """
  def batch(ops, opts \\ []) when is_list(ops), do: request({:batch, ops}, opts)

  @doc "Releases handles on the Poser side. Returns how many were still held."
  def release(handles, opts \\ []), do: request({:release, List.wrap(handles)}, opts)

  @doc "Dev mode only: calls `module.function(*args)` in Poser's Python."
  def raw(module, function, args \\ [], opts \\ []),
    do: request({:raw, module, function, args}, opts)

  @doc """
  Round trip answered by the add-on's network thread, never queued behind
  Poser's main thread. Returns the round-trip time in microseconds.
  """
  def ping(opts \\ []), do: request(:ping, opts)

  @doc "Handle-table statistics: `%{\"handles\" => n, \"generation\" => g}`."
  def stats(opts \\ []), do: request(:stats, opts)

  @doc "The add-on's hello reply (mode, versions, api_hash)."
  def info(opts \\ []), do: GenServer.call(server(opts), :info)

  @spec status(keyword()) :: :connected | :disconnected
  def status(opts \\ []), do: GenServer.call(server(opts), :status)

  defp request(req, opts) do
    GenServer.call(server(opts), {:request, req, Keyword.get(opts, :timeout)}, :infinity)
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp kw(opts), do: Keyword.get(opts, :kw, [])

  # --- Callbacks ---

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    state = %{
      opts: opts,
      name: Keyword.get(opts, :name, __MODULE__),
      transport: opts[:transport],
      conn: nil,
      info: nil,
      epoch: 0,
      next_id: 1,
      pending: %{},
      backoff: opts[:backoff_initial],
      reconnect_timer: nil,
      # pid => %{handle_id => %Handle{}} for handles returned to that process
      owners: %{},
      monitors: %{},
      last_inbound: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call(:info, _from, %{conn: nil} = state),
    do: {:reply, {:error, %Error{kind: :disconnected}}, state}

  def handle_call(:info, _from, state), do: {:reply, {:ok, state.info}, state}

  def handle_call(:status, _from, state),
    do: {:reply, if(state.conn, do: :connected, else: :disconnected), state}

  def handle_call({:request, _req, _timeout}, _from, %{conn: nil} = state),
    do: {:reply, {:error, %Error{kind: :disconnected}}, state}

  def handle_call({:request, req, timeout}, from, state) do
    case stale_handle(req, state.epoch) do
      %Handle{} = h ->
        {:reply, {:error, stale_error(h)}, state}

      nil ->
        state = disown(state, req)
        {id, state} = next_id(state)
        timeout = timeout || state.opts[:call_timeout]

        timer =
          if timeout == :infinity,
            do: nil,
            else: Process.send_after(self(), {:request_timeout, id}, timeout)

        entry = %{
          from: from,
          timer: timer,
          kind: kind(req),
          t0: System.monotonic_time(:microsecond)
        }

        send_request(%{state | pending: Map.put(state.pending, id, entry)}, frame(req, id))
    end
  end

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(%{state | reconnect_timer: nil})}

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        GenServer.reply(entry.from, {:error, %Error{kind: :timeout}})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:heartbeat, epoch}, %{epoch: epoch, conn: conn} = state) when conn != nil do
    silent = System.monotonic_time(:millisecond) - state.last_inbound

    if silent > state.opts[:heartbeat_timeout] do
      {:noreply, disconnect(state, :heartbeat_timeout)}
    else
      Process.send_after(self(), {:heartbeat, epoch}, state.opts[:heartbeat_interval])
      send_untracked(state, :ping)
    end
  end

  def handle_info({:heartbeat, _old_epoch}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {owned, owners} = Map.pop(state.owners, pid, %{})
    state = %{state | owners: owners, monitors: Map.delete(state.monitors, pid)}

    case {state.conn, Map.values(owned)} do
      {nil, _} -> {:noreply, state}
      {_, []} -> {:noreply, state}
      {_, handles} -> send_untracked(state, {:release, handles})
    end
  end

  def handle_info(msg, %{conn: conn} = state) when conn != nil do
    case state.transport.handle_message(conn, msg) do
      {:frame, bin} -> {:noreply, handle_frame(bin, state)}
      {:closed, reason} -> {:noreply, disconnect(state, reason)}
      :ignore -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Connecting ---

  defp connect(state) do
    case handshake(state) do
      {:ok, conn, info} ->
        state = %{
          state
          | conn: conn,
            info: info,
            # Unique across every client in this VM, so a handle from another
            # client (or an earlier run of this one) is always caught as stale.
            epoch: :erlang.unique_integer([:positive, :monotonic]),
            backoff: state.opts[:backoff_initial],
            last_inbound: System.monotonic_time(:millisecond)
        }

        Process.send_after(self(), {:heartbeat, state.epoch}, state.opts[:heartbeat_interval])
        Events.dispatch(:connected, %{server: state.name, info: info})
        state

      {:error, reason} ->
        Logger.debug("poserx: connect failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp handshake(state) do
    opts = state.opts
    transport = state.transport

    with {:ok, target} <- target(opts),
         {:ok, conn} <- transport.connect(target.host, target.port, opts[:connect_timeout]) do
      hello = {:hello, %{token: target.token, protocol: 1, client: "poserx #{@version}"}}

      with :ok <- transport.send_frame(conn, Codec.encode(hello)),
           {:ok, bin} <- transport.recv_frame(conn, opts[:connect_timeout]),
           {:ok, info} <- hello_reply(Codec.decode(bin)),
           :ok <- transport.activate(conn) do
        {:ok, conn, info}
      else
        error ->
          transport.close(conn)
          error
      end
    end
  end

  defp target(opts) do
    session =
      case Session.read(opts[:session] || Session.default_path()) do
        {:ok, s} -> s
        {:error, _} = error -> error
      end

    case {session, opts[:host], opts[:port], opts[:token]} do
      {%{} = s, host, port, token} ->
        {:ok,
         %{
           host: host || Session.pick_host(s.hosts),
           port: port || s.port,
           token: token || s.token
         }}

      {_error, host, port, token}
      when is_binary(host) and is_integer(port) and is_binary(token) ->
        {:ok, %{host: host, port: port, token: token}}

      {error, _, _, _} ->
        error
    end
  end

  defp hello_reply({:ok, {:r, 0, info}}) when is_map(info), do: {:ok, info}

  defp hello_reply({:ok, {:e, 0, reason}}),
    do: {:error, Error.from_wire(reason)}

  defp hello_reply(_), do: {:error, %Error{kind: :handshake_failed}}

  defp schedule_reconnect(state) do
    timer = Process.send_after(self(), :connect, state.backoff)
    %{state | reconnect_timer: timer, backoff: min(state.backoff * 2, state.opts[:backoff_max])}
  end

  defp disconnect(state, reason) do
    if state.conn, do: state.transport.close(state.conn)

    for {_id, entry} <- state.pending do
      if entry.timer, do: Process.cancel_timer(entry.timer)

      if entry.from,
        do:
          GenServer.reply(
            entry.from,
            {:error, %Error{kind: :disconnected, details: %{reason: reason}}}
          )
    end

    # Handles died with the connection: the add-on's table was per connection.
    for {_pid, ref} <- state.monitors, do: Process.demonitor(ref, [:flush])

    Events.dispatch(:disconnected, %{server: state.name, reason: reason})

    schedule_reconnect(%{state | conn: nil, info: nil, pending: %{}, owners: %{}, monitors: %{}})
  end

  # --- Requests ---

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp kind(:ping), do: :ping
  defp kind(_), do: :request

  defp frame({:call, name, args, kw}, id), do: {:C, id, name, Codec.to_wire(args), kw_map(kw)}

  defp frame({:invoke, target, method, args, kw}, id),
    do: {:I, id, Codec.to_wire(target), method, Codec.to_wire(args), kw_map(kw)}

  defp frame({:get_attr, target, attr}, id), do: {:G, id, Codec.to_wire(target), attr}
  defp frame({:batch, ops}, id), do: {:B, id, Enum.map(ops, &batch_op/1)}
  defp frame({:release, handles}, id), do: {:R, id, Codec.to_wire(handles)}

  defp frame({:raw, module, function, args}, id),
    do: {:X, id, module, function, Codec.to_wire(args)}

  defp frame(:ping, id), do: {:ping, id}
  defp frame(:stats, id), do: {:S, id}

  defp batch_op({:call, name, args}), do: batch_op({:call, name, args, []})
  defp batch_op({:call, name, args, kw}), do: {:C, name, Codec.to_wire(args), kw_map(kw)}
  defp batch_op({:invoke, t, m, args}), do: batch_op({:invoke, t, m, args, []})

  defp batch_op({:invoke, t, m, args, kw}),
    do: {:I, Codec.to_wire(t), m, Codec.to_wire(args), kw_map(kw)}

  defp batch_op({:get_attr, t, attr}), do: {:G, Codec.to_wire(t), attr}

  defp kw_map(kw), do: Map.new(kw, fn {k, v} -> {to_string(k), Codec.to_wire(v)} end)

  defp stale_handle(req, epoch) do
    req |> request_terms() |> Codec.handles_in() |> Enum.find(&(&1.epoch != epoch))
  end

  defp request_terms({:batch, ops}), do: ops
  defp request_terms(req) when is_tuple(req), do: req
  defp request_terms(_), do: []

  defp stale_error(h),
    do: %Error{kind: :stale_handle, details: %{id: h.id, generation: h.generation}}

  # Fire-and-forget request: the reply is matched and dropped.
  defp send_untracked(state, req) do
    {id, state} = next_id(state)
    entry = %{from: nil, timer: nil, kind: :request, t0: 0}
    send_request(%{state | pending: Map.put(state.pending, id, entry)}, frame(req, id))
  end

  defp send_request(state, frame) do
    case state.transport.send_frame(state.conn, Codec.encode(frame)) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:noreply, disconnect(state, reason)}
    end
  end

  # --- Inbound ---

  defp handle_frame(bin, state) do
    state = %{state | last_inbound: System.monotonic_time(:millisecond)}

    case Codec.decode(bin) do
      {:ok, term} ->
        handle_term(term, state)

      {:error, :undecodable} ->
        Logger.warning("poserx: dropped undecodable frame (#{byte_size(bin)} bytes)")
        state
    end
  end

  defp handle_term({:r, id, value}, state),
    do: reply(state, id, {:ok, Codec.from_wire(value, state.epoch)})

  defp handle_term({:e, id, reason}, state),
    do: reply(state, id, {:error, Error.from_wire(Codec.from_wire(reason, state.epoch))})

  defp handle_term({:M, {event, payload}}, state) when is_atom(event) do
    Events.dispatch(event, Codec.from_wire(payload, state.epoch))
    state
  end

  defp handle_term(other, state) do
    Logger.warning("poserx: unexpected frame #{inspect(other)}")
    state
  end

  defp reply(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        release_late(state, result)

      {entry, pending} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        state = %{state | pending: pending}

        case entry.from do
          nil ->
            state

          {pid, _tag} = from ->
            GenServer.reply(from, shape(entry, result))
            own(state, pid, returned_handles(result))
        end
    end
  end

  defp returned_handles({:ok, value}), do: Codec.handles_in(value)

  defp returned_handles({:error, %Error{kind: :batch_failed, details: %{partial: partial}}}),
    do: Codec.handles_in(partial)

  defp returned_handles(_), do: []

  # Handles returned to a process are released when that process exits.
  defp own(state, _pid, []), do: state

  defp own(state, pid, handles) do
    monitors = Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)
    owned = Map.get(state.owners, pid, %{})
    owned = Enum.reduce(handles, owned, &Map.put(&2, &1.id, &1))
    %{state | owners: Map.put(state.owners, pid, owned), monitors: monitors}
  end

  defp disown(state, {:release, handles}) do
    ids = handles |> Codec.handles_in() |> MapSet.new(& &1.id)

    owners =
      Map.new(state.owners, fn {pid, owned} -> {pid, Map.drop(owned, MapSet.to_list(ids))} end)

    %{state | owners: owners}
  end

  defp disown(state, _req), do: state

  defp shape(%{kind: :ping, t0: t0}, {:ok, :pong}),
    do: {:ok, System.monotonic_time(:microsecond) - t0}

  defp shape(_entry, result), do: result

  # A reply nobody waits for any more (the caller timed out): free its handles.
  defp release_late(state, {:ok, value}) do
    case Codec.handles_in(value) do
      [] ->
        state

      handles ->
        {:noreply, state} = send_untracked(state, {:release, handles})
        state
    end
  end

  defp release_late(state, _error), do: state
end
