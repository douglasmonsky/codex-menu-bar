# App Server compatibility

Verified locally on 2026-07-29 with Codex CLI `0.146.0-alpha.3.1`.

The generated schema exposed the stable methods and notifications used by the
MVP:

- `initialize` / `initialized`
- `account/read`
- `account/rateLimits/read`
- `account/updated`
- `account/rateLimits/updated`

The live stdio probe completed the initialization handshake and returned these
fields without persisting the raw response:

- `initialize`: `codexHome`, `platformFamily`, `platformOs`, `userAgent`
- `account/read`: `account`, `requiresOpenaiAuth`
- `account/rateLimits/read`: `rateLimits`, `rateLimitsByLimitId`,
  `rateLimitResetCredits`

The client uses the compact App Server envelope (`method`, `params`, `id`) and
does not add a generic `jsonrpc` field or opt into `experimentalApi`.
