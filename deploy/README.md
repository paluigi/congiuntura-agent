# Deploying congiuntura-agent

> **The authoritative runbook is [`DEPLOY.md`](DEPLOY.md)** — written for the
> production setup (Nginx Proxy Manager fronting the containers on the shared
> docker network). This file only keeps the "Otari later" switch.

## "Otari later" switch (BYOK-first → funded default)

The manifest ships BYOK-first: visitors add their own key (OpenRouter/Otari/OpenAI-compatible).
To fund visitors' calls later with hosted Otari, change ONE file (`agent-manifest.json`):

```json
"llm_router": {
  "base_url": "https://api.otari.ai/api/v1",
  "publisher_funded": true,
  "mock": false,
  "byok_router": "https://api.otari.ai/api/v1"
}
```

- `publisher_funded: true` → the runtime calls Otari with no key (needs a funded Otari
  key behind a small CORS-allowing proxy you control — see the skill's
  `references/bundle_and_hosting.md`, "Paying for visitors' model calls")
- `byok_router` stays a DIFFERENT URL from `base_url` (the build refuses a match):
  point `byok_router` at e.g. your Otari EU endpoint when you do this
- The visitor's own key always takes precedence and is never sent to `base_url`
- No network/runtime/dashboard change needed — rebuild not required (manifest is read at runtime)

Keep `llm_config.model_name` in the HOCON in sync with the router's models.
