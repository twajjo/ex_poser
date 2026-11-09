defmodule PoserTest.ApiDump do
  @moduledoc "Reads the committed introspection dump for generator tests."

  @path "priv/poser_api.json"

  def dump, do: @path |> File.read!() |> JSON.decode!()

  @doc "The docstring of `poser.Name` (class \"poser\") or `Class.Name`, verbatim."
  def doc(dump \\ dump(), class, name) do
    entries = if class == "poser", do: dump["functions"], else: dump["classes"][class]["methods"]
    Enum.find_value(entries, fn e -> e["name"] == name && e["doc"] end)
  end
end
