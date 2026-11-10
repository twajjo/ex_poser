defmodule ExPoser.Gen.Overrides do
  @moduledoc """
  Hand corrections for the generator, kept in `priv/poser_api_overrides.json`:

    * `"signatures"`: `"Class.Method"` or `"poser.Function"` → a corrected
      signature line, parsed like a docstring line;
    * `"skip"`: name → reason it isn't generated;
    * `"smoke_skip"`: name → reason `mix poser.smoke` doesn't call it;
    * `"smoke_no_follow"`: name → reason `mix poser.smoke` calls it but
      doesn't explore the handles it returns;
    * `"constant_groups"`: constant name prefixes, used by `ExPoser.Const`.
  """

  @default_path "priv/poser_api_overrides.json"
  @keys %{
    "signatures" => %{},
    "skip" => %{},
    "smoke_skip" => %{},
    "smoke_no_follow" => %{},
    "constant_groups" => []
  }

  @spec load(Path.t()) :: map()
  def load(path \\ @default_path) do
    Map.merge(@keys, path |> File.read!() |> JSON.decode!())
  end
end
