defmodule EabWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :eab

  @session [
    store: :cookie,
    key: "_eab",
    signing_salt: "local-benchmark",
    same_site: "Lax",
    http_only: true
  ]
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session]],
    longpoll: false
  )

  plug(Plug.Static, at: "/", from: :eab, only: ~w(assets))
  plug(Plug.RequestId)

  # Solver transcripts arrive as JSON from the loopback Claude Code hook.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 64_000_000
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session)
  plug(EabWeb.Router)
end
