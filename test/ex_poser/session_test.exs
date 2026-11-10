defmodule ExPoser.SessionTest do
  use ExUnit.Case, async: true

  alias ExPoser.Session

  describe "read/1" do
    @tag :tmp_dir
    test "parses the session file", %{tmp_dir: dir} do
      path = Path.join(dir, "session.json")

      File.write!(
        path,
        ~s({"port": 47800, "token": "abc", "protocol": 1, "hosts": ["127.0.0.1", "172.22.192.1"]})
      )

      assert Session.read(path) ==
               {:ok,
                %{port: 47_800, token: "abc", protocol: 1, hosts: ["127.0.0.1", "172.22.192.1"]}}
    end

    test "reports a missing file" do
      assert {:error, {:session, :enoent}} = Session.read("/nonexistent/session.json")
    end

    @tag :tmp_dir
    test "reports a malformed file", %{tmp_dir: dir} do
      path = Path.join(dir, "session.json")
      File.write!(path, ~s({"port": "x"}))
      assert {:error, {:session, :invalid}} = Session.read(path)
    end
  end

  describe "pick_host/1" do
    test "prefers the WSL adapter" do
      assert Session.pick_host(["127.0.0.1", "172.22.192.1"]) == "172.22.192.1"
      assert Session.pick_host(["127.0.0.1"]) == "127.0.0.1"
    end
  end

  describe "default_path/0" do
    test "POSERX_SESSION overrides" do
      old = System.get_env("POSERX_SESSION")
      System.put_env("POSERX_SESSION", "/tmp/x/session.json")

      on_exit(fn ->
        if old,
          do: System.put_env("POSERX_SESSION", old),
          else: System.delete_env("POSERX_SESSION")
      end)

      assert Session.default_path() == "/tmp/x/session.json"
    end
  end
end
