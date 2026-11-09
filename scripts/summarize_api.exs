# Coverage summary of an introspection dump.
#
#   elixir scripts/summarize_api.exs [priv/poser_api.json]

path = List.first(System.argv(), "priv/poser_api.json")
api = path |> File.read!() |> JSON.decode!()
meta = api["meta"]
classes = Map.values(api["classes"])
methods = Enum.flat_map(classes, & &1["methods"])
callables = methods ++ api["functions"]
count = fn list, pred -> Enum.count(list, pred) end

IO.puts("""
#{path} (#{div(File.stat!(path).size, 1024)} KiB)
poser #{meta["poser_version"]}, python #{meta["python_version"] |> String.split() |> hd()}
api_hash #{meta["api_hash"]}

module functions   #{length(api["functions"])}
classes            #{length(classes)} (#{count.(classes, fn c -> Enum.all?(c["via"], &String.starts_with?(&1, "live:")) end)} found only by live discovery)
methods            #{length(methods)}
with signature     #{count.(callables, & &1["signature"])} of #{length(callables)}
with docstring     #{count.(callables, & &1["doc"])} of #{length(callables)}
callback-flagged   #{count.(callables, & &1["callback"])}
constants          #{map_size(api["constants"])}
discovery errors   #{length(meta["discovery_errors"])}
""")

IO.puts("methods per class:")

classes
|> Enum.sort_by(&{-length(&1["methods"]), &1["name"]})
|> Enum.each(fn c -> IO.puts("  #{String.pad_trailing(c["name"], 28)} #{length(c["methods"])}") end)

case Enum.filter(callables, & &1["callback"]) do
  [] -> :ok
  cbs -> IO.puts("\ncallback-flagged: " <> Enum.map_join(cbs, ", ", & &1["name"]))
end

manifest_path = Path.join(Path.dirname(path), "poser_api_manifest.json")

if File.exists?(manifest_path) do
  m = manifest_path |> File.read!() |> JSON.decode!()
  s = m["summary"]

  IO.puts("""

  generated API (#{manifest_path}, #{m["namespace"]})
  generated          #{s["generated"]} of #{s["total"]} (#{s["docstring"]} from docstrings, #{s["override"]} overridden, #{s["variadic"]} variadic)
  skipped            #{s["skipped"]}
  getters            #{s["getters"]}
  constructors       #{Enum.join(s["constructors"], ", ")}
  unknown types      #{Enum.join(s["unknown_types"], "; ")}
  """)

  for {key, %{"status" => "skipped", "reason" => reason}} <- Enum.sort(m["entries"]),
      do: IO.puts("  skipped #{key}: #{reason}")
end
