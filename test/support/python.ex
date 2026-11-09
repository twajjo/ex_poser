defmodule PoserTest.Python do
  @moduledoc false

  @root Path.expand("../..", __DIR__)

  def root, do: @root

  @doc "The Python 3.7 interpreter: POSERX_PYTHON, else mise's python for this project."
  def path do
    case :persistent_term.get({__MODULE__, :path}, nil) do
      nil ->
        p = System.get_env("POSERX_PYTHON") || mise_python()
        :persistent_term.put({__MODULE__, :path}, p)
        p

      p ->
        p
    end
  end

  defp mise_python do
    {out, 0} = System.cmd("mise", ["which", "python"], cd: @root)
    String.trim(out)
  end
end
