defmodule Eab.SandboxTest do
  use ExUnit.Case, async: false
  alias Eab.{Activity, Sandbox, Store}

  @limit_error "The workspace diff is over the 1048576-byte patch limit"

  setup do
    old = Application.get_env(:eab, :data_dir)
    dir = Path.join(System.tmp_dir!(), "eab-sandbox-#{System.unique_integer([:positive])}")
    Application.put_env(:eab, :data_dir, dir)

    on_exit(fn ->
      Application.put_env(:eab, :data_dir, old)
      File.rm_rf!(dir)
    end)
  end

  defp output(returncode, output, truncated),
    do: %{"returncode" => returncode, "output" => output, "output_truncated" => truncated}

  test "the patch is the diff; a diff over the limit or a failed command is an error" do
    assert Sandbox.patch_output(output(0, "diff --git a/lib/a.ex b/lib/a.ex\n", false)) ==
             "diff --git a/lib/a.ex b/lib/a.ex\n"

    # The cut-down diff of an oversized patch stays out of the error.
    assert_raise RuntimeError, @limit_error, fn ->
      Sandbox.patch_output(output(0, "diff --git a/lib/a.ex b/lib/a.ex\n-old\n", true))
    end

    assert_raise RuntimeError, "Workspace command failed: fatal: bad revision 'HEAD'", fn ->
      Sandbox.patch_output(output(128, "fatal: bad revision 'HEAD'", false))
    end
  end

  test "a snapshot that cannot be taken keeps the previous one and the attempt goes on" do
    path = "runs/run-x/case-x/model.patch"
    saved = "diff --git a/lib/a.ex b/lib/a.ex\n"
    # The workspace without lib/: every deleted line makes the diff too large to save.
    oversized = output(0, "diff --git a/lib/a.ex b/lib/a.ex\ndeleted file mode 100644\n", true)

    Activity.with_case("run-x", "case-x", "", fn ->
      assert Sandbox.snapshot(path, "", fn -> saved end) == :ok
      assert Sandbox.snapshot(path, "", fn -> Sandbox.patch_output(oversized) end) == :ok
    end)

    assert File.read!(Store.path(path)) == saved
    log = File.read!(Store.path("runs/run-x/case-x/activity.log"))
    assert log =~ "Patch snapshot skipped, the previous one is kept: " <> @limit_error
    refute log =~ "deleted file mode"
  end
end
