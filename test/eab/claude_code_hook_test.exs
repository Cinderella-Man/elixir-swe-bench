defmodule Eab.ClaudeCodeHookTest do
  use ExUnit.Case, async: true
  # The solver kit's hook runs with the host's python3, outside the controller image.
  @moduletag :python

  test "the hook uploads a transcript only once it is complete and stable" do
    {output, status} =
      System.cmd("python3", ["-I", "test/claude_code/hook_test.py"],
        cd: Eab.Inventory.root(),
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
