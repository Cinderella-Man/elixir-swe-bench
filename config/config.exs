import Config
config :eab, data_dir: System.get_env("EAB_DATA_DIR", ".local/app"), root: File.cwd!()

config :eab, EabWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [html: EabWeb.ErrorHTML], layout: false],
  pubsub_server: Eab.PubSub,
  live_view: [signing_salt: "benchmark-live-view"],
  secret_key_base: String.duplicate("development-only-", 5),
  check_origin: ["//localhost", "//127.0.0.1"],
  server: config_env() != :test

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "key",
  "password",
  "secret",
  "code",
  "state",
  "id_token",
  "access_token",
  "refresh_token",
  "code_verifier"
]

config :logger, :console, format: "$level $message\n"
config :logger, level: :info

if config_env() == :test do
  config :eab,
    cache_reserve_bytes: 0,
    data_dir: Path.join(System.tmp_dir!(), "eab-tests-#{System.pid()}"),
    # Never the checkout's verification folder; a test that saves run logs names its own.
    run_logs_root: Path.join(System.tmp_dir!(), "eab-tests-#{System.pid()}-logs/runs")

  config :logger, level: :warning
end
