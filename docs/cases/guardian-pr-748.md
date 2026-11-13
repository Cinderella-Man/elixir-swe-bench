# Choose token secrets per request when verifying and issuing tokens

**Case** `guardian-pr-748` · **Feature** in [Guardian](https://github.com/ueberauth/guardian)

Guardian is an authentication library that signs and verifies tokens; its Plug options are fixed when a pipeline is built. Multi-tenant apps need a secret chosen per request, so the `:secret` option must also accept a one-argument function that receives the current `Plug.Conn`, wherever the Plug integration verifies or issues tokens. When no secret is found, Guardian must refuse to verify or issue a token, reporting `:secret_not_found` instead of falling back to the configured `:secret_key`.

- [Ticket the agent receives](../../cases/guardian-pr-748/ticket.md)
- [Case files](../../cases/guardian-pr-748/): grading contract, patches and provenance
- [Upstream pull request](https://github.com/ueberauth/guardian/pull/748) the case is based on
