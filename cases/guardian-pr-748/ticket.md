# Per-request token secrets for verifying and issuing tokens

## Goal

A multi-tenant application keeps one signing secret per tenant and only knows which tenant a request belongs to once an earlier plug has handled the request (for example by assigning the tenant's key to `conn.assigns`). Guardian's plug options are fixed when the pipeline is built, so today the `:secret` option cannot depend on the request.

Let the `:secret` option be chosen per request from the connection, everywhere Guardian's Plug integration verifies or issues tokens. A tenant's tokens must be signed and verified with that tenant's secret from start to finish. When no secret can be found for a request, Guardian must refuse to verify or issue a token. It must never quietly use the implementation module's configured `:secret_key` instead.

## The `:secret` option

`:secret` accepts these forms:

| Form | Meaning |
| --- | --- |
| Omitted | Use the implementation module's `:secret_key`, as today. |
| A static value (string, JWK map or `%JOSE.JWK{}`) | Use it, as today. |
| `{module, function, args}` | Call it without the connection, as today. |
| A one-argument function | Call it with the current `Plug.Conn`. Its return value is the secret for that operation. |

A `:secret` function of any other arity is a configuration error. It raises `ArgumentError` where a one-argument function would be called (see Resolution timing). It is not reported to the error handler as an authentication failure.

Exceptions raised inside a `:secret` function propagate to the caller. They are not turned into authentication errors and never cause a fallback.

The function form must work when the plug is declared in a compiled pipeline (`Plug.Builder`, Phoenix router pipelines) with a remote capture, for example `plug Guardian.Plug.VerifyHeader, secret: &MyApp.Secrets.for_conn/1`. Anonymous functions cannot be escaped into a compiled pipeline. They only need to work when the plug's `call/2` (or the function) is invoked directly.

## Where it applies

Verifying:

- `Guardian.Plug.VerifyHeader`, `Guardian.Plug.VerifySession` and `Guardian.Plug.VerifyCookie`. For `VerifyCookie`, the resolved secret is used both to verify the refresh cookie and to sign the access token it is exchanged for.
- The `:refresh_from_cookie` option of `VerifyHeader` and `VerifySession` keeps its own option list. A `:secret` given to the plug is **not** inherited by the refresh. To refresh with a per-request secret, set it in both places: `secret: &f/1, refresh_from_cookie: [secret: &f/1]`.

Issuing:

- `Guardian.Plug.sign_in/5`, `Guardian.Plug.remember_me/5` and `Guardian.Plug.remember_me_from_token/5`, and the matching functions on an implementation module's generated `MyApp.Guardian.Plug` module (`sign_in/4`, `remember_me/4`, `remember_me_from_token/4`). `remember_me_from_token` uses the resolved secret both to verify the token it is given and to sign the new cookie.
- `Guardian.Plug.SlidingCookie` uses the resolved secret both to verify the current cookie and to sign its replacement.

Resolution timing:

- The verify plugs call the function only after they have found a token, and exactly once per plug call. A request with no token never calls it. A configured `:refresh_from_cookie` `:secret` is resolved separately when the refresh runs.
- `SlidingCookie` never calls the function when the request has no cookie token.
- Otherwise the function may be called more than once in a request. It should be a cheap read from the connection.

`Guardian.Plug.resolve_secret(conn, opts)` is public, so custom plugs can offer the same option. It returns `opts` with a one-argument `:secret` function replaced by its result for `conn`, keeping the other options. If that result is `nil`, `:secret` stays in `opts` with the value `nil`; it is not removed. Options without `:secret`, or with a static or `{m, f, a}` secret, are returned unchanged. A function of any other arity raises `ArgumentError`.

## Fail closed

A `:secret` that is given explicitly but is `nil`, or that resolves to `nil` (from a function or from `{m, f, a}`), means "no secret found". It never falls back to `:secret_key`. Only an omitted `:secret` uses `:secret_key`. A custom `secret_fetcher` instead receives under `:secret` the explicit `nil`, the `nil` returned by a one-argument function, or the unresolved `{m, f, a}` tuple, and decides the outcome; the outcomes below are those of the default fetcher.

| Where | Outcome when the secret is not found |
| --- | --- |
| `VerifyHeader`, `VerifySession`, `VerifyCookie` | The error handler receives `{:invalid_token, :secret_not_found}` and the connection is halted (subject to `:halt`). No token or claims are put on the connection. |
| `sign_in`, `remember_me`, `remember_me_from_token` | Nothing is issued: no token, claims or resource on the connection, no session token, no response cookie. The failure is reported the way these functions already report token errors: the pipeline's error handler receives `{:unauthenticated, {:error, :secret_not_found}}` and the connection is halted. Without an error handler, `Guardian.Plug.UnauthenticatedError` is raised. |
| `SlidingCookie` | The request continues unchanged: no replacement cookie, no error handler call, not halted. This matches how `SlidingCookie` already ignores cookies it cannot verify. |
| `Guardian` API with `secret: nil` or an `{m, f, a}` resolving to `nil` (`encode_and_sign`, `decode_and_verify`, `resource_from_token`, `exchange`, `refresh`, `revoke`) using `Guardian.Token.Jwt` | `{:error, :secret_not_found}`. |
| `Guardian.Token.Jwt.decode_token/3` | `{:error, :secret_not_found}`, no longer collapsed into `{:error, :invalid_token}`. A bad signature is still `{:error, :invalid_token}`. |

A secret that is found but is wrong is an ordinary verification failure. A token signed for another tenant is rejected with `{:invalid_token, :invalid_token}`.

With `:refresh_from_cookie`, `VerifyHeader` and `VerifySession` hand either failure to the cookie refresh, as they do every other verification failure, and the refresh decides the outcome: with no refresh cookie the request continues without a token and the error handler is not called.

## Examples

```elixir
defmodule MyApp.Secrets do
  def for_conn(conn), do: conn.assigns[:tenant_secret]
end

# Verify
plug MyAppWeb.LoadTenant
plug Guardian.Plug.VerifyHeader,
  secret: &MyApp.Secrets.for_conn/1,
  refresh_from_cookie: [secret: &MyApp.Secrets.for_conn/1]

# Issue
conn
|> MyApp.Guardian.Plug.sign_in(user, %{}, secret: &MyApp.Secrets.for_conn/1)
|> MyApp.Guardian.Plug.remember_me(user, %{}, secret: &MyApp.Secrets.for_conn/1)

plug Guardian.Plug.SlidingCookie, secret: &MyApp.Secrets.for_conn/1
```

- The tenant is assigned with key `"k-a"`. A token signed with `"k-a"` is accepted, and its claims are put on the connection. `sign_in` produces a token that verifies with `"k-a"` but not with `:secret_key`.
- No tenant is assigned, so `for_conn/1` returns `nil`. A token signed with the application's `:secret_key` is rejected with `{:invalid_token, :secret_not_found}`. `sign_in` issues nothing, and the error handler receives `{:unauthenticated, {:error, :secret_not_found}}`. `SlidingCookie` leaves the cookie alone and does not re-sign it with `:secret_key`.
- The assigned tenant uses `"k-b"`, but the token was signed with `"k-a"`. The token is rejected with `{:invalid_token, :invalid_token}`.
- Because this pipeline sets `refresh_from_cookie`, `VerifyHeader` hands the rejected header tokens above to the cookie refresh, which verifies the refresh cookie with its own `:secret`. With no refresh cookie the request continues unauthenticated and the error handler is not called.

## Compatibility

- Applications that omit `:secret`, or that pass a static or `{m, f, a}` secret, behave exactly as before for both verifying and issuing.
- Existing error tuples are kept: a bad signature is still `:invalid_token`, an expired token is still handled as before, and the issuing functions keep their existing error reporting.
- Custom `secret_fetcher` modules keep working. They receive `:secret` as before, except that a one-argument function is replaced by its result.
- The one intended behaviour change: an explicit `nil` secret, or an `{m, f, a}` resolving to `nil`, used to fall back to `:secret_key` and now fails with `:secret_not_found`.

## Non-goals

- Connection-aware forms of options other than `:secret` (`:allowed_algos`, `:ttl`, `:issuer` and so on).
- Passing a function as `:secret` to the core `Guardian` functions or to `Guardian.Token.Jwt` directly. They have no connection.
- The one-argument function form in `Guardian.Plug.sign_out/3`, which revokes tokens. It is out of scope and need not be supported there. Revocation with a static, `{m, f, a}` or `nil` secret behaves as described above: a `nil` secret gives `{:error, :secret_not_found}`.
- Choosing the secret from token headers (`kid`, JWKS). The existing `secret_fetcher` mechanism already covers that.
- Making `:refresh_from_cookie` inherit the plug's `:secret`.
- Documentation updates are welcome but optional.
