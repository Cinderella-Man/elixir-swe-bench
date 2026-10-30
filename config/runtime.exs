import Config

if config_env() != :test do
  data = System.get_env("EAB_DATA_DIR", ".local/app") |> Path.expand()
  File.mkdir_p!(data)
  File.chmod!(data, 0o700)
  secret_path = Path.join(data, "session-secret")

  unless File.exists?(secret_path) do
    File.write!(secret_path, Base.encode64(:crypto.strong_rand_bytes(64)), [:exclusive])
    File.chmod!(secret_path, 0o600)
  end

  config :eab,
    data_dir: data,
    offline: System.get_env("EAB_OFFLINE") in ["1", "true"],
    cache_reserve_bytes:
      String.to_integer(System.get_env("EAB_CACHE_MIN_FREE_GB", "5")) * 1024 * 1024 * 1024,
    docker_storage_path: System.get_env("EAB_DOCKER_STORAGE_PATH"),
    root: System.get_env("EAB_ROOT", File.cwd!())

  if target = System.get_env("EAB_MEMORY_SSH_TARGET") |> then(&if(&1 not in [nil, ""], do: &1)) do
    hosts =
      System.fetch_env!("EAB_MEMORY_HOSTS")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    config :eab, :memory_monitor,
      target: target,
      hosts: hosts,
      known_hosts:
        System.get_env("EAB_MEMORY_KNOWN_HOSTS", Path.join(data, "memory/known_hosts")),
      ssh_key: System.get_env("EAB_MEMORY_SSH_KEY") |> then(&if(&1 not in [nil, ""], do: &1)),
      collector:
        System.get_env(
          "EAB_MEMORY_REMOTE_COLLECTOR",
          "/srv/elixir-agent-benchmark/memory-collector/bin/eab_memory_collector"
        ),
      key_file: System.get_env("EAB_MEMORY_REMOTE_KEY_FILE")
  end

  config :eab, :pipeline,
    lookahead: String.to_integer(System.get_env("EAB_PREPARE_AHEAD", "4")),
    preparation_workers: String.to_integer(System.get_env("EAB_PREPARE_WORKERS", "2"))

  config :eab, EabWeb.Endpoint,
    secret_key_base: File.read!(secret_path),
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
    server: true
end
