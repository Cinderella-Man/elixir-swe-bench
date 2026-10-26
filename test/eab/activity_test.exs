defmodule Eab.ActivityTest do
  use ExUnit.Case, async: false
  alias Eab.{Activity, Command, Model, Store}

  setup do
    id = "activity-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:eab, :http_request)
      File.rm_rf!(Store.path("runs/#{id}"))
    end)

    %{id: id, path: Store.path("runs/#{id}/case/activity.log")}
  end

  test "command output is readable while the process is still waiting", %{id: id, path: path} do
    gate = Store.path("runs/#{id}/continue")

    task =
      Task.async(fn ->
        Activity.with_case(id, "case", "", fn ->
          opts = [timeout: 5]

          Command.run(
            "sh",
            [
              "-c",
              "printf 'compiling now\\n'; while [ ! -f #{Command.quote(gate)} ]; do sleep 0.02; done; printf 'finished\\n'"
            ],
            opts
          )
        end)
      end)

    try do
      wait_for_output(path, "compiling now\n", 200)
      assert Process.alive?(task.pid)
      refute File.read!(path) =~ "finished\n"
      File.write!(gate, "continue")
      assert Task.await(task)["returncode"] == 0
      assert File.read!(path) =~ "finished\n"
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "quiet command output stays out of the activity log", %{id: id, path: path} do
    result =
      Activity.with_case(id, "case", "", fn ->
        Command.run("sh", ["-c", "printf 'whole %s\\n' patch"], quiet: true)
      end)

    assert result["output"] == "whole patch\n"
    log = File.read!(path)
    assert log =~ "Process exited with code 0"
    refute log =~ "whole patch"
  end

  test "partial Pi results are shown once and split credentials stay redacted", %{
    id: id,
    path: path
  } do
    Activity.with_case(id, "case", "private-key", fn ->
      Activity.output(:command, "hello private-")
      refute File.read!(path) =~ "private-"
      Activity.output(:command, "key world\n")
      Activity.flush(:command)

      Activity.pi(%{
        "type" => "tool_execution_start",
        "toolName" => "bash",
        "toolCallId" => "1",
        "args" => %{"command" => "mix test"}
      })

      Activity.pi(%{
        "type" => "tool_execution_update",
        "toolCallId" => "1",
        "partialResult" => %{"content" => [%{"text" => "Compiling\n"}]}
      })

      Activity.pi(%{
        "type" => "tool_execution_end",
        "toolCallId" => "1",
        "result" => %{"content" => [%{"text" => "Compiling\nPassed\n"}]}
      })
    end)

    text = File.read!(path)
    assert text =~ "hello [REDACTED] world"
    assert text =~ "$ mix test\nCompiling\nPassed"
    assert length(String.split(text, "Compiling")) == 2
    refute text =~ "private-key"
  end

  test "model stream is visible before completion and its full body is retained", %{
    id: id,
    path: path
  } do
    parent = self()

    first =
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Investigating the source"}}]}) <>
        "\n\n"

    second = "data: [DONE]\n\n"

    Application.put_env(:eab, :http_request, fn opts ->
      # Exercise the same receive callback Req invokes for each HTTP chunk.
      {left, right} = String.split_at(first, 19)
      {:cont, acc} = opts[:into].({:data, left}, {nil, %Req.Response{status: 200}})
      {:cont, acc} = opts[:into].({:data, right}, acc)
      send(parent, {:stream_waiting, self()})

      receive do
        :continue -> :ok
      after
        3000 -> flunk("Stream was never released")
      end

      {:cont, {_, response}} = opts[:into].({:data, second}, acc)
      {:ok, response}
    end)

    task =
      Task.async(fn ->
        Activity.with_case(id, "case", "", fn ->
          Model.stream(%{"url" => "http://synthetic", "backend" => "llama_cpp"}, "", %{})
        end)
      end)

    assert_receive {:stream_waiting, pid}, 3000
    assert File.read!(path) =~ "Investigating the source"
    send(pid, :continue)
    assert Task.await(task) == first <> second
  end

  test "tail reads are bounded and cannot escape artifact paths", %{id: id} do
    Store.write_text("runs/#{id}/case/activity.log", String.duplicate("a", 100) <> "latest")

    assert {:ok, "[Earlier output omitted; download the full log]\nlatest"} =
             Store.tail_artifact(id, "case/activity.log", 6)

    assert :error = Store.tail_artifact(id, "../outside")
  end

  test "real HTTP streaming preserves the response and writes model text", %{id: id, path: path} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    body =
      "data: " <>
        Jason.encode!(%{
          "type" => "content_block_delta",
          "delta" => %{"text" => "Inspecting files"}
        }) <> "\n\n"

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5000)
        read_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
              body
          )

        :gen_tcp.close(socket)
      end)

    try do
      response =
        Activity.with_case(id, "case", "", fn ->
          Model.stream(%{"url" => "http://127.0.0.1:#{port}", "backend" => "strata"}, "", %{})
        end)

      assert response == body
      assert File.read!(path) == "Inspecting files"
      Task.await(server)
    after
      :gen_tcp.close(listener)
      Task.shutdown(server, :brutal_kill)
    end
  end

  defp read_request(socket, data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, size] = Regex.run(~r/content-length: (\d+)/i, headers)
        if byte_size(body) < String.to_integer(size), do: receive_request(socket, data)

      _ ->
        receive_request(socket, data)
    end
  end

  defp receive_request(socket, data) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5000)
    read_request(socket, data <> chunk)
  end

  defp wait_for_output(path, text, tries) do
    cond do
      File.exists?(path) and String.contains?(File.read!(path), text) ->
        :ok

      tries == 0 ->
        flunk("Live command output never appeared")

      true ->
        Process.sleep(10)
        wait_for_output(path, text, tries - 1)
    end
  end
end
