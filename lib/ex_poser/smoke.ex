defmodule ExPoser.Smoke do
  @moduledoc """
  Calls every generated getter against a live scene and records what
  happens, to find signature and encoding problems across the whole API.

  The walk starts from the module-level getters (such as `ExPoser.Api.scene/1`),
  then explores up to `:per_class` objects of each class through the
  handles the getters return. Handles that aren't explored are released at
  once, so the walk never fills the add-on's handle table, and everything is
  released at the end.

  A Python error is an outcome, not a failure: many getters raise on an
  object of the wrong kind (a light-only getter on a prop, say).
  """

  alias ExPoser.{Client, Codec, Error, Handle}

  @heavy ~r/^(TexVertex|Vertex|TexPolygon|Polygon)Type [Ll]ist$|^[Ll]ist of (TexVertex|Vertex|TexPolygon|Polygon)Type/
  @heavy_reason "one handle per element; would flush the 10,000-handle table"

  @doc """
  Runs the walk. Options: `:server`, `:per_class` (default 3), `:timeout`
  per call (default 30 000 ms), `:include_heavy` (default false).
  """
  @spec run(map(), keyword()) :: map()
  def run(manifest, opts \\ []) do
    st = %{
      manifest: manifest,
      per_class: Keyword.get(opts, :per_class, 3),
      include_heavy: Keyword.get(opts, :include_heavy, false),
      client: Keyword.take(opts, [:server]) ++ [timeout: Keyword.get(opts, :timeout, 30_000)],
      getters: %{},
      explored: %{},
      queued: %{},
      queue: :queue.new(),
      kept: [],
      unknown_classes: MapSet.new()
    }

    namespace = Module.concat([manifest["namespace"]])

    st =
      Enum.reduce(manifest["module_getters"], st, fn g, st ->
        call(st, "poser.#{g["py_name"]}", namespace, g, [])
      end)

    st = drain(st)
    release(st.kept, st)
    report(st)
  end

  defp call(st, key, module, g, receiver) do
    entry =
      Map.get(st.getters, key, %{
        "module" => inspect(module),
        "function" => g["function"],
        "py_name" => g["py_name"],
        "returns" => g["returns"],
        "calls" => 0,
        "outcomes" => %{},
        "max_ms" => 0
      })

    if Regex.match?(@heavy, g["returns"]) and not st.include_heavy do
      put_entry(st, key, Map.put(entry, "skipped", @heavy_reason))
    else
      t0 = System.monotonic_time(:millisecond)
      result = invoke(module, g["function"], receiver ++ [st.client])
      ms = System.monotonic_time(:millisecond) - t0

      entry = %{
        entry
        | "calls" => entry["calls"] + 1,
          "max_ms" => max(entry["max_ms"], ms),
          "outcomes" => count(entry["outcomes"], result)
      }

      entry =
        case result do
          {:ok, v} ->
            Map.put_new(entry, "sample", inspect(v, limit: 5, printable_limit: 80))

          {:error, %Error{kind: :python, class: class, message: msg}} ->
            Map.put_new(entry, "python_example", String.slice("#{class}: #{msg}", 0, 200))

          _ ->
            entry
        end

      st = put_entry(st, key, entry)

      case {result, g["follow"]} do
        {{:ok, v}, false} ->
          release(Codec.handles_in(v), st)
          st

        {{:ok, v}, _} ->
          keep_or_release(st, Codec.handles_in(v))

        _ ->
          st
      end
    end
  end

  defp count(outcomes, {:ok, _}), do: Map.update(outcomes, "ok", 1, &(&1 + 1))

  defp count(outcomes, {:error, %Error{kind: :python, class: class}}),
    do:
      Map.update(outcomes, "python", %{class => 1}, &Map.update(&1, class, 1, fn n -> n + 1 end))

  defp count(outcomes, {:error, %Error{kind: kind}})
       when kind in [:timeout, :stale_handle, :bad_request],
       do: Map.update(outcomes, Atom.to_string(kind), 1, &(&1 + 1))

  defp count(outcomes, other) do
    outcomes
    |> Map.update("other", 1, &(&1 + 1))
    |> Map.put_new("other_example", inspect(other, limit: 5, printable_limit: 200))
  end

  defp drain(st) do
    case :queue.out(st.queue) do
      {:empty, _} -> st
      {{:value, h}, queue} -> %{st | queue: queue} |> explore(h) |> drain()
    end
  end

  defp explore(st, %Handle{class: class} = h) do
    st = %{st | explored: Map.update(st.explored, class, 1, &(&1 + 1))}
    info = st.manifest["classes"][class]
    module = Module.concat([info["module"]])

    Enum.reduce(info["getters"], st, fn g, st ->
      call(st, "#{class}.#{g["py_name"]}", module, g, [h])
    end)
  end

  defp invoke(module, function, args) do
    # load first: the function-name atoms exist only once the module is loaded
    Code.ensure_loaded!(module)
    apply(module, String.to_existing_atom(function), args)
  rescue
    e -> {:raised, Exception.message(e)}
  end

  # Enqueue handles whose class still has room; release the rest now.
  # `queued` counts every handle ever enqueued for a class (explored ones
  # included), so it alone bounds the class at per_class.
  defp keep_or_release(st, handles) do
    {st, drop} =
      Enum.reduce(handles, {st, []}, fn %Handle{class: class} = h, {st, drop} ->
        cond do
          not Map.has_key?(st.manifest["classes"], class) ->
            {%{st | unknown_classes: MapSet.put(st.unknown_classes, class)}, [h | drop]}

          Map.get(st.queued, class, 0) < st.per_class ->
            {%{
               st
               | queue: :queue.in(h, st.queue),
                 queued: Map.update(st.queued, class, 1, &(&1 + 1)),
                 kept: [h | st.kept]
             }, drop}

          true ->
            {st, [h | drop]}
        end
      end)

    release(drop, st)
    st
  end

  defp outcome_total(nil), do: 0
  defp outcome_total(n) when is_integer(n), do: n
  defp outcome_total(%{} = by_class), do: by_class |> Map.values() |> Enum.sum()

  defp put_entry(st, key, entry), do: %{st | getters: Map.put(st.getters, key, entry)}

  defp release([], _st), do: :ok
  defp release(handles, st), do: Client.release(handles, st.client)

  defp report(st) do
    entries = Map.values(st.getters)
    sum = fn key -> entries |> Enum.map(&outcome_total(&1["outcomes"][key])) |> Enum.sum() end

    %{
      "getters" => st.getters,
      "explored" => st.explored,
      "unknown_classes" => st.unknown_classes |> MapSet.to_list() |> Enum.sort(),
      "summary" => %{
        "getters" => length(entries),
        "getters_ok" => Enum.count(entries, &Map.has_key?(&1["outcomes"], "ok")),
        "calls" => entries |> Enum.map(& &1["calls"]) |> Enum.sum(),
        "ok" => sum.("ok"),
        "python" => sum.("python"),
        "timeout" => sum.("timeout"),
        "stale_handle" => sum.("stale_handle"),
        "bad_request" => sum.("bad_request"),
        "other" => sum.("other"),
        "skipped" => Enum.count(entries, &Map.has_key?(&1, "skipped"))
      }
    }
  end
end
