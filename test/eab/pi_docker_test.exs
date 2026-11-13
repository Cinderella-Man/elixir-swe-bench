defmodule Eab.PiDockerTest do
  use ExUnit.Case, async: false
  @moduletag :docker
  alias Eab.{Command, Model, Pi, Sandbox, Store}

  test "production launcher runs Pi as an unprivileged user in an offline problem container" do
    name = "eab-pi-check-#{System.unique_integer([:positive])}"
    prefix = "runs/#{name}/case"

    endpoint = %{
      "backend" => "llama_cpp",
      "model" => "synthetic",
      "context" => 32768,
      "url" => "http://synthetic"
    }

    settings = Model.settings(endpoint)
    box = %{name: name, spec: %{"test_timeout" => 5}}

    on_exit(fn ->
      Command.run("docker", ["rm", "-f", "-v", name])
      Application.delete_env(:eab, :http_request)
      File.rm_rf!(Store.path("runs/#{name}"))
    end)

    Command.run!("docker", [
      "run",
      "-d",
      "--name",
      name,
      "--network=none",
      "--user=65534:65534",
      "--cpus=2",
      "--memory=512m",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--tmpfs=/workspace:rw,uid=65534,gid=65534",
      "--tmpfs=/tmp:rw",
      "-e",
      "HOME=/tmp",
      "-w",
      "/workspace",
      "eab-tooling:dev",
      "sleep",
      "infinity"
    ])

    Command.run!("docker", [
      "exec",
      name,
      "sh",
      "-c",
      "git init -q && git config user.name Test && git config user.email test@localhost && git commit -q --allow-empty -m initial"
    ])

    Application.put_env(:eab, :http_request, fn opts ->
      body =
        if String.ends_with?(opts[:url], "tokens") do
          %{"input_tokens" => 42}
        else
          done = Enum.any?(opts[:json]["messages"], &(&1["role"] == "tool"))

          delta =
            if done,
              do: %{"content" => "Done."},
              else: %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{
                      "name" => "write",
                      "arguments" =>
                        Jason.encode!(%{"path" => "repair.txt", "content" => "fixed"})
                    }
                  }
                ]
              }

          events = [
            %{
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => Map.put(delta, "role", "assistant"),
                  "finish_reason" => nil
                }
              ]
            },
            %{
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{},
                  "finish_reason" => if(done, do: "stop", else: "tool_calls")
                }
              ],
              "usage" => %{"prompt_tokens" => 42, "completion_tokens" => 5}
            }
          ]

          Enum.map_join(events, &("data: " <> Jason.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"
        end

      {:ok, %{status: 200, body: body}}
    end)

    result =
      Pi.run(
        box,
        endpoint,
        "not-in-container",
        settings,
        prefix,
        "Repair the file.",
        "Use write.",
        fn _ -> :ok end
      )

    assert result["calls"] == 2
    assert result["stop_reason"] == "agent_completed"
    assert File.read!(Store.path("#{prefix}/model.patch")) =~ "+fixed"
    config = Command.run!("docker", ["exec", name, "cat", "/opt/eab-attempt/pi.json"])

    assert Command.run!("docker", [
             "exec",
             name,
             "stat",
             "-c",
             "%u:%g:%a",
             "/opt/eab-attempt/pi.json"
           ]) == "0:0:444\n"

    refute config =~ "not-in-container"
    refute config =~ "http://synthetic"
    assert Store.read("#{prefix}/pi-config.json")["agent"] == Pi.identity()

    Sandbox.apply_patch(
      box,
      "diff --git a/extra.txt b/extra.txt\nnew file mode 100644\n--- /dev/null\n+++ b/extra.txt\n@@ -0,0 +1 @@\n+patch-copy\n"
    )

    assert Sandbox.command!(box, "cat extra.txt") == "patch-copy\n"

    # The saved submission covers the case's edit area and top-level notes; whatever else
    # the agent left in the workspace stays out of it.
    Sandbox.command!(
      box,
      "mkdir -p lib logs && echo a > lib/a.ex && echo n > notes.md && " <>
        "echo l > logs/out.log && echo b > stray.bin"
    )

    scoped = Sandbox.patch(Map.put(box, :spec, %{"allowed_edit_prefixes" => ["lib/", "none/"]}))
    for kept <- ~w(b/lib/a.ex b/notes.md b/repair.txt), do: assert(scoped =~ kept)
    for stray <- ~w(out.log stray.bin), do: refute(scoped =~ stray)
    assert Sandbox.patch(box) =~ "b/logs/out.log"
  end
end
