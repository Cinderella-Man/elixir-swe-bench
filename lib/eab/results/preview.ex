defmodule Eab.Results.Preview do
  @moduledoc "Loopback-only preview of the generated public files."
  @behaviour Plug
  import Plug.Conn

  def init(directory),
    do:
      Plug.Static.init(
        at: "/",
        from: directory,
        only: ~w(index.html app.js theme.js styles.css results.js results.json),
        cache_control_for_etags: "no-cache"
      )

  def call(conn, opts) do
    conn = if conn.path_info == [], do: %{conn | path_info: ["index.html"]}, else: conn
    conn = Plug.Static.call(conn, opts)
    if conn.halted, do: conn, else: send_resp(conn, 404, "Not found")
  end
end
