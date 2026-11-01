defmodule Poser.Session do
  @moduledoc """
  The session file the add-on writes at startup: port, token, protocol and the
  addresses it listens on. Re-read on every connect, since the token changes
  whenever Poser restarts.
  """

  @type t :: %{
          port: pos_integer(),
          token: String.t(),
          protocol: pos_integer(),
          hosts: [String.t()]
        }

  @spec read(Path.t()) :: {:ok, t()} | {:error, {:session, atom()}}
  def read(path) do
    with {:ok, body} <- read_file(path),
         {:ok, data} <- decode(body) do
      parse(data)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:session, reason}}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, {:session, :invalid}}
    end
  end

  defp parse(%{"port" => port, "token" => token, "protocol" => protocol, "hosts" => hosts})
       when is_integer(port) and is_binary(token) and is_integer(protocol) and is_list(hosts),
       do: {:ok, %{port: port, token: token, protocol: protocol, hosts: hosts}}

  defp parse(_), do: {:error, {:session, :invalid}}

  @doc """
  Where to find the session file: `POSERX_SESSION`, else `%APPDATA%\\PoserBridge`
  (through `/mnt/c` when running in WSL), else `~/.config/PoserBridge`.
  """
  @spec default_path() :: Path.t()
  def default_path do
    System.get_env("POSERX_SESSION") || Path.join([appdata(), "PoserBridge", "session.json"])
  end

  defp appdata do
    cond do
      wsl?() -> wsl_appdata() || Path.expand("~/.config")
      appdata = System.get_env("APPDATA") -> appdata
      true -> Path.expand("~/.config")
    end
  end

  defp wsl? do
    case File.read("/proc/version") do
      {:ok, v} -> String.contains?(String.downcase(v), "microsoft")
      {:error, _} -> false
    end
  end

  defp wsl_appdata do
    with {out, 0} <-
           System.cmd("cmd.exe", ["/c", "echo %APPDATA%"], cd: "/mnt/c", stderr_to_stdout: true),
         {path, 0} <- System.cmd("wslpath", ["-u", String.trim(out)], stderr_to_stdout: true) do
      String.trim(path)
    else
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc "The address to connect to: the WSL adapter when listed, else loopback."
  @spec pick_host([String.t()]) :: String.t()
  def pick_host(hosts), do: Enum.find(hosts, "127.0.0.1", &(&1 != "127.0.0.1"))
end
