defmodule Eab.ModelIdentityTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint EabWeb.Endpoint

  test "discovery records the artifact identity and size while preserving the request alias" do
    Application.put_env(:eab, :http_request, fn opts ->
      body =
        case URI.parse(opts[:url]).path do
          "/health" ->
            %{"status" => "ok"}

          "/v1/models" ->
            %{
              "data" => [
                %{
                  "id" => "volta-a",
                  "meta" => %{"size" => 17_431_404_544, "n_params" => 27_320_697_856}
                }
              ]
            }

          "/props" ->
            %{
              "model_alias" => "volta-a",
              "model_path" => "/models/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf",
              "default_generation_settings" => %{"n_ctx" => 262_144}
            }
        end

      {:ok, %{status: 200, body: body}}
    end)

    on_exit(fn -> Application.delete_env(:eab, :http_request) end)
    endpoint = Eab.Model.discover("http://fixture")
    assert endpoint["model"] == "volta-a"
    assert endpoint["identity"]["name"] == "Swift-1.5-Qwen3.8-27B"
    assert endpoint["identity"]["quantization"] == "Q4_K_M"
    assert endpoint["identity"]["size_bytes"] == 17_431_404_544
    assert Eab.ModelIdentity.size_label(endpoint) == "17.4 GB"
    assert :ok == Eab.Model.unchanged!(endpoint, "")
  end

  test "shard suffixes do not become model names and unknown sizes are not guessed" do
    model = %{
      "model" => "flash-next-uncensored",
      "profile" => %{
        "model_path" => "/models/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S-00001-of-00002.gguf"
      }
    }

    assert Eab.ModelIdentity.label(model) == "Qwen3.8-Flash-Next-GSQ-RCO-abliterated · IQ3_S"
    assert Eab.ModelIdentity.details(model)["size_bytes"] == nil
    assert Eab.ModelIdentity.details(%{"model" => "gpt-6-astra"})["quantization"] == nil
  end

  test "a Strata pack folder is not a model name; the alias stands until weight files name it" do
    endpoint = %{
      "model" => "deepseek-v41-flash-atomic",
      "backend" => "strata",
      "profile" => %{"model_path" => "/srv/hot/deepseek_v41_flash_atomic_iq1_m/pack"}
    }

    identity = Eab.ModelIdentity.details(endpoint)
    assert identity["name"] == "deepseek-v41-flash-atomic"
    assert identity["artifact"] == nil and identity["quantization"] == nil
    assert identity["source"] == "reported_name"
    assert Eab.ModelIdentity.served_artifact(endpoint) == "pack"

    # Runs saved before the fix carry the folder as their artifact, with or without metadata.
    stale = %{"version" => 1, "name" => "pack", "artifact" => "pack", "quantization" => nil}
    assert Eab.ModelIdentity.label(Map.put(endpoint, "identity", stale)) == identity["name"]

    summary = Map.take(endpoint, ~w(model backend)) |> Map.put("identity", stale)
    assert Eab.ModelIdentity.label(summary) == "deepseek-v41-flash-atomic"

    claude = %{"backend" => "anthropic", "identity" => %{"version" => 1, "name" => "Claude"}}
    assert Eab.ModelIdentity.label(claude) == "Claude"

    files = %{
      "size_bytes" => 3,
      "files" => [
        %{"name" => "DeepSeek-V4.1-Flash-1017-UD-IQ1_M-00001-of-00002.gguf", "size_bytes" => 1},
        %{"name" => "DeepSeek-V4.1-Flash-1017-UD-IQ1_M-00002-of-00002.gguf", "size_bytes" => 2}
      ]
    }

    observed = Eab.ModelIdentity.from_files(files)

    assert observed["name"] == "DeepSeek-V4.1-Flash-1017" and
             observed["quantization"] == "UD-IQ1_M"

    assert observed["artifact"] == "DeepSeek-V4.1-Flash-1017-UD-IQ1_M-00001-of-00002.gguf"
    assert observed["source"] == "host_files"
    assert Eab.ModelIdentity.from_files(nil) == nil
  end

  test "connection shows skipped memory collection until the exact endpoint hostname is configured" do
    old_memory = Application.get_env(:eab, :memory_monitor)
    old_http = Application.get_env(:eab, :http_request)

    on_exit(fn ->
      for {key, value} <- [memory_monitor: old_memory, http_request: old_http] do
        if is_nil(value),
          do: Application.delete_env(:eab, key),
          else: Application.put_env(:eab, key, value)
      end
    end)

    for backend <- ["llama_cpp", "strata"] do
      Application.put_env(:eab, :http_request, fn opts ->
        body =
          case URI.parse(opts[:url]).path do
            "/health" ->
              %{"status" => "ok"}

            "/v1/models" ->
              %{"data" => [%{"id" => "fixture"}]}

            "/props" ->
              %{
                "model_alias" => "fixture",
                "model_path" => "/models/fixture-Q4_K_M.gguf",
                "build_info" =>
                  if(backend == "strata", do: "Strata fixture", else: "llama fixture"),
                "default_generation_settings" => %{"n_ctx" => 262_144}
              }
          end

        {:ok, %{status: 200, body: body}}
      end)

      Application.put_env(:eab, :memory_monitor, hosts: ["rig"], target: "rig")
      {:ok, view, _} = live(build_conn(), "/")
      connection = %{"connection" => %{"url" => "http://rig.example.ts.net:8410", "key" => ""}}
      render_submit(view, "connect", connection)
      render_async(view)
      assert has_element?(view, "#memory-collection-status", "RAM/VRAM will not be recorded")
      assert has_element?(view, "#memory-collection-status", "rig.example.ts.net")
      assert has_element?(view, "#memory-collection-status", "EAB_MEMORY_HOSTS")

      Application.put_env(:eab, :memory_monitor,
        hosts: ["rig", "rig.example.ts.net"],
        target: "rig"
      )

      render_submit(view, "connect", connection)
      render_async(view)
      assert has_element?(view, "#memory-collection-status", "RAM/VRAM collection is configured")

      Application.delete_env(:eab, :memory_monitor)
      render_submit(view, "connect", connection)
      render_async(view)
      assert has_element?(view, "#memory-collection-status", "RAM/VRAM will not be recorded")
      assert has_element?(view, "#memory-collection-status", "EAB_MEMORY_SSH_TARGET")
    end
  end

  test "saved runs show the artifact name and quantization rather than their routing alias" do
    id = "identity-display-test"

    run = %{
      "id" => id,
      "created_at" => "9999-01-01T00:00:00Z",
      "status" => "completed",
      "cases" => [],
      "attempts" => %{},
      "settings" => %{},
      "model" => %{
        "model" => "volta-a",
        "backend" => "llama_cpp",
        "profile" => %{
          "model_path" => "/models/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf",
          "model_ftype" => "Q4_K - Medium"
        },
        "metadata" => %{"model" => %{"meta" => %{"size" => 17_431_404_544}}}
      }
    }

    Eab.Store.write("runs/#{id}/run.json", run)
    Eab.Store.index_run(run)
    # Reproduce an already indexed legacy history entry with its metadata stripped.
    Eab.Store.write(
      "runs/#{id}/summary.json",
      Map.take(run, ~w(id created_at status)) |> Map.put("model", %{"model" => "volta-a"})
    )

    on_exit(fn -> File.rm_rf!(Eab.Store.path("runs/#{id}")) end)

    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, ".run-model", "Swift-1.5-Qwen3.8-27B · Q4_K_M")
    assert has_element?(view, ".history-row strong", "Swift-1.5-Qwen3.8-27B · Q4_K_M")
    refute has_element?(view, ".run-model", "volta-a")
    summary = Eab.Store.read("runs/#{id}/summary.json")
    assert summary["model"]["identity"]["quantization"] == "Q4_K_M"
    assert summary["model"]["identity"]["size_bytes"] == 17_431_404_544
    refute Map.has_key?(summary["model"], "metadata")
    assert Eab.Store.read("runs/#{id}/run.json") == run

    Eab.Report.write(run)
    assert File.read!(Eab.Store.path("runs/#{id}/report.md")) =~ "Swift-1.5-Qwen3.8-27B · Q4_K_M"
  end
end
