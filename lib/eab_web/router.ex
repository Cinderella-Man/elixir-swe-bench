defmodule EabWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  @security_headers %{
    "content-security-policy" =>
      "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws://localhost:* ws://127.0.0.1:*; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
  }

  pipeline :public_results do
    plug(:put_secure_browser_headers, @security_headers)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, @security_headers)

    plug(:put_root_layout, html: {EabWeb.Layouts, :root})
  end

  pipeline :claude_code do
    plug(:accepts, ["json"])
  end

  # Loopback-only solver kit endpoints; no session or CSRF token is involved.
  scope "/claude-code", EabWeb do
    pipe_through(:claude_code)
    post("/mcp", ClaudeCodeController, :mcp)
    get("/mcp", ClaudeCodeController, :mcp)
    delete("/mcp", ClaudeCodeController, :mcp)
    post("/hook", ClaudeCodeController, :hook)
  end

  scope "/", EabWeb do
    pipe_through(:browser)
    get("/auth/chatgpt", ChatGPTController, :start)
    get("/auth/chatgpt/callback", ChatGPTController, :callback)
    live("/", DashboardLive)
    get("/artifacts/:id/*path", ArtifactController, :show)
  end

  # Public static assets use ordinary script requests, without the session pipeline's JS guard.
  scope "/", EabWeb do
    pipe_through(:public_results)
    get("/results/*path", ResultsController, :show)
  end
end
