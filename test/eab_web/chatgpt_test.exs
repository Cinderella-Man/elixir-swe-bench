defmodule EabWeb.ChatGPTTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Eab.{ChatGPTAuth, ChatGPTFixture}
  @endpoint EabWeb.Endpoint
  setup do: ChatGPTFixture.start!()

  test "choosing ChatGPT exposes sign-in without requiring an endpoint or credentials" do
    Application.put_env(:eab, :http_request, fn _ ->
      flunk("Choosing an unsigned provider must not send a model request")
    end)

    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#provider-choice input[value=local][checked]")
    view |> form("#provider-choice", provider: "chatgpt") |> render_change()

    assert has_element?(view, "#provider-choice input[value=chatgpt][checked]")
    assert has_element?(view, "#chatgpt-connection a", "Continue with ChatGPT")
    assert has_element?(view, "#run[disabled]")
    refute has_element?(view, "#connection")
    refute has_element?(view, "#chatgpt-account-form")
    refute has_element?(view, "input[name='settings[response_tokens]']")
    assert has_element?(view, "input[name='settings[max_tokens]'][value='262144']")
  end

  test "OpenAI endpoint offers sign-in without probing local server routes" do
    Application.put_env(:eab, :http_request, fn _ ->
      flunk("Unsigned discovery sent a model request")
    end)

    {:ok, view, _} = live(build_conn(), "/")

    view
    |> form("#connection", connection: %{url: "https://api.openai.com/v1", key: ""})
    |> render_change()

    assert has_element?(view, "#chatgpt-connection a", "Continue with ChatGPT")
    assert has_element?(view, "#run[disabled]")
    refute has_element?(view, "input[name='connection[key]']")
    refute has_element?(view, "input[name='settings[response_tokens]']")
    assert has_element?(view, "input[name='settings[max_tokens]'][value='262144']")
  end

  test "switching providers preserves each provider's entered settings" do
    {:ok, view, _} = live(build_conn(), "/")
    # A local run has no generated-token setting (ADR 0016); its seed is one it does have.
    refute has_element?(view, "input[name='settings[max_tokens]']")
    view |> form("#settings", settings: %{seed: "12345"}) |> render_change()

    view |> form("#provider-choice", provider: "chatgpt") |> render_change()

    assert has_element?(view, "input[name='settings[max_tokens]'][value='262144']")
    view |> form("#settings", settings: %{max_tokens: "300000"}) |> render_change()
    view |> form("#provider-choice", provider: "local") |> render_change()
    render_async(view)
    assert has_element?(view, "input[name='settings[seed]'][value='12345']")
    refute has_element?(view, "input[name='settings[max_tokens]']")

    view |> form("#provider-choice", provider: "chatgpt") |> render_change()

    assert has_element?(view, "input[name='settings[max_tokens]'][value='300000']")
  end

  test "switching source cancels pending discovery and preserves the local connection" do
    parent = self()

    Application.put_env(:eab, :http_request, fn opts ->
      send(parent, {:discovering, self(), opts[:url], opts[:headers]})

      receive do
        :release -> {:error, :unavailable}
      end
    end)

    {:ok, view, _} = live(build_conn(), "/")

    view
    |> form("#connection", connection: %{url: "http://fixture", key: "local-secret"})
    |> render_change()

    assert_receive {:discovering, pid, "http://fixture/health", _}
    ref = Process.monitor(pid)
    view |> form("#provider-choice", provider: "chatgpt") |> render_change()
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute render_async(view) =~ "Model discovery stopped"
    assert has_element?(view, "#run[disabled]")
    refute render(view) =~ "local-secret"

    view |> form("#provider-choice", provider: "local") |> render_change()
    assert has_element?(view, "#endpoint[value='http://fixture']")
    assert has_element?(view, "#key[value='local-secret']")
    assert_receive {:discovering, _, "http://fixture/health", headers}
    assert {"authorization", "Bearer local-secret"} in headers
    view |> form("#provider-choice", provider: "chatgpt") |> render_change()
  end

  test "callback is bound to browser session then model selection enables the same Run button",
       f do
    conn = get(build_conn(), "http://127.0.0.1:4000/auth/chatgpt")
    url = redirected_to(conn)
    params = URI.decode_query(URI.parse(url).query)
    assert params["redirect_uri"] == "http://127.0.0.1:4000/auth/chatgpt/callback"
    assert conn.resp_cookies["_eab"][:same_site] == "Lax"
    Agent.update(f.control, &%{&1 | nonce: params["nonce"]})

    callback =
      "/auth/chatgpt/callback?" <>
        URI.encode_query(%{
          "state" => params["state"],
          "code" => "code",
          "client_id" => "oaiapp_test"
        })

    unsolicited = get(build_conn(), callback)
    assert redirected_to(unsolicited) == "/"
    assert ChatGPTAuth.accounts() == []
    signed_in = conn |> recycle() |> get(callback)
    assert redirected_to(signed_in) == "/?chatgpt=oaiapp_test"

    Application.put_env(:eab, :http_request, fn opts ->
      assert opts[:url] == "https://api.openai.com/v1/models"

      {:ok,
       %{
         status: 200,
         body: %{
           "models" => [
             %{
               "slug" => "available-model",
               "display_name" => "Available model",
               "visibility" => "list"
             }
           ]
         }
       }}
    end)

    {:ok, view, _} = live(recycle(signed_in), redirected_to(signed_in))
    render_async(view)
    assert has_element?(view, "#provider-choice input[value=chatgpt][checked]")
    refute has_element?(view, "#connection")
    assert has_element?(view, "#run[disabled]")
    view |> form("form[phx-change=chatgpt_model]", model: "available-model") |> render_change()
    assert has_element?(view, "#run:not([disabled])")
    assert has_element?(view, "#chatgpt-account option", "test@example.test")
    refute render(view) =~ "access-test"
    view |> element("button[phx-click=chatgpt_sign_out]") |> render_click()
    assert has_element?(view, "#run[disabled]")
    assert [%{"signed_in" => false}] = ChatGPTAuth.accounts()
  end
end
