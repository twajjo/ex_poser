defmodule Poser.Gen.Overrides do
  @moduledoc """
  Hand corrections for the generator, kept in `priv/poser_api_overrides.json`:

    * `"signatures"`: `"Class.Method"` or `"poser.Function"` → a corrected
      signature line, parsed like a docstring line;
    * `"skip"`: name → reason it isn't generated;
    * `"smoke_skip"`: name → reason `mix poser.smoke` doesn't call it;
    * `"constant_groups"`: constant name prefixes, used by `Poser.Const`.
  """

  @default_path "priv/poser_api_overrides.json"
  @keys %{"signatures" => %{}, "skip" => %{}, "smoke_skip" => %{}, "constant_groups" => []}

  @spec load(Path.t()) :: map()
  def load(path \\ @default_path) do
    Map.merge(@keys, path |> File.read!() |> JSON.decode!())
  end
end
