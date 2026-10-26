ExUnit.start(
  exclude:
    if(System.get_env("EAB_DOCKER_TESTS") == "1", do: [], else: [:docker]) ++
      if(System.find_executable("python3"), do: [], else: [:python])
)

# Functional tests use synthetic time; individual timing tests advance this clock explicitly.
Application.put_env(:eab, :measurement_clock, fn -> 0 end)
Code.require_file("support/chatgpt_fixture_helper.exs", __DIR__)
