defmodule Eab.ClaudeCodeDockerTest do
  use ExUnit.Case, async: false
  @moduletag :docker
  alias Eab.{ClaudeCode, Command, Sandbox, Store}

  test "workspace tools run Pi's own read, bash, edit and write in an offline container" do
    name = "eab-claude-tools-#{System.unique_integer([:positive])}"
    prefix = "runs/#{name}/case"
    image = System.get_env("EAB_TOOLING_IMAGE", "eab-tooling:dev")

    on_exit(fn ->
      Command.run("docker", ["rm", "-f", "-v", name])
      File.rm_rf!(Store.path("runs/#{name}"))
    end)

    Command.run!("docker", [
      "run",
      "-d",
      "--name",
      name,
      "--network=none",
      "--user=65534:65534",
      "--cpus=1",
      "--memory=512m",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--tmpfs=/workspace:rw,uid=65534,gid=65534",
      "--tmpfs=/tmp:rw",
      "-e",
      "HOME=/tmp",
      "-w",
      "/workspace",
      image,
      "sleep",
      "infinity"
    ])

    box = %{name: name, id: "case", run_id: name}

    Command.run!("docker", [
      "exec",
      name,
      "sh",
      "-c",
      "git init -q && git config user.name Test && git config user.email test@localhost && git commit -q --allow-empty -m initial"
    ])

    Sandbox.copy_file(
      box,
      ClaudeCode.path("workspace-tools.mjs"),
      "/opt/eab-attempt/workspace-tools.mjs"
    )

    state = %{box: box, prefix: prefix, key: "", tools: 1}
    text = fn result -> Enum.map_join(result["content"], "", & &1["text"]) end
    call = &ClaudeCode.Attempt.tool(state, &1, &2)

    assert text.(call.("write", %{"path" => "lib/a.ex", "content" => "alpha\n"})) =~
             "Successfully wrote"

    assert call.("read", %{"path" => "lib/a.ex"}) == %{
             "content" => [%{"type" => "text", "text" => "alpha\n"}],
             "isError" => false
           }

    edit = %{"path" => "lib/a.ex", "edits" => [%{"oldText" => "alpha", "newText" => "beta"}]}
    assert text.(call.("edit", edit)) =~ "Successfully replaced 1 block(s)"
    assert File.read!(Store.path("#{prefix}/model.patch")) =~ "+beta"

    missing = call.("edit", Map.put(edit, "edits", [%{"oldText" => "zzz", "newText" => "q"}]))
    assert missing["isError"] and text.(missing) =~ "Could not find the exact text"

    failed = call.("bash", %{"command" => "cat lib/a.ex; exit 3"})
    assert failed["isError"] and text.(failed) =~ "beta\n\n\nCommand exited with code 3"

    timed = call.("bash", %{"command" => "sleep 5", "timeout" => 1})
    assert timed["isError"] and text.(timed) =~ "Command timed out after 1 seconds"

    invalid = call.("read", %{})
    assert invalid["isError"] and text.(invalid) =~ ~s(Validation failed for tool "read")

    offline = call.("bash", %{"command" => "curl -sS -m 2 https://example.com"})
    assert offline["isError"]

    # tools.json is exactly what Pi 1.2.0 declares for these tools.
    listed =
      Command.run!(
        "docker",
        ["exec", "-i", name, "/opt/pi/node", "/opt/eab-attempt/workspace-tools.mjs"],
        input: ~s({"list":true}\n)
      )

    assert Jason.decode!(listed |> String.split("\n", trim: true) |> List.last()) ==
             ClaudeCode.tools()
  end
end
