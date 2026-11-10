defmodule PoserTest.GenFixture do
  @moduledoc """
  Generates `test/fixtures/gen_api.json` as `PoserTest.GenApi.*` and compiles
  it once per test run (from `test_helper.exs`), so several test modules can
  use the generated code without redefinition warnings.
  """

  @dump "test/fixtures/gen_api.json"
  @overrides "test/fixtures/gen_overrides.json"

  def model do
    dump = @dump |> File.read!() |> JSON.decode!()
    ExPoser.Gen.Model.build(dump, ExPoser.Gen.Overrides.load(@overrides), PoserTest.GenApi)
  end

  @doc "Generates into a temp dir and compiles; returns the compiler diagnostics."
  def compile! do
    dir = Path.join(System.tmp_dir!(), "ex_poser_gen_#{System.unique_integer([:positive])}")
    files = ExPoser.Gen.Render.files(model())

    paths =
      for {rel, content} <- files do
        path = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        path
      end

    # compiled to .beam files so Code.fetch_docs/1 can read the docs
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)

    {:ok, _modules, %{compile_warnings: warnings, runtime_warnings: runtime}} =
      Kernel.ParallelCompiler.compile_to_path(paths, ebin, return_diagnostics: true)

    diagnostics = warnings ++ runtime
    :persistent_term.put({__MODULE__, :diagnostics}, diagnostics)
    :persistent_term.put({__MODULE__, :ebin}, ebin)
    diagnostics
  end

  def diagnostics, do: :persistent_term.get({__MODULE__, :diagnostics})

  @doc "Path of a compiled fixture module's .beam, for `Code.fetch_docs/1`."
  def beam(module), do: Path.join(:persistent_term.get({__MODULE__, :ebin}), "#{module}.beam")
end
