# Deploying congiuntura-agent

> **The authoritative runbook is [`DEPLOY.md`](DEPLOY.md)** — one Compose stack
> (the congiuntura-live `docker-compose.yml`), fronted by Nginx Proxy Manager.
> This file only keeps the maintainer notes: how the image is built, and the
> "Otari later" switch.

## Building the image

The bundle ships as `paluigi/congiuntura-agent:<version>` on Docker Hub,
multi-arch (`linux/amd64` + `linux/arm64`). The `Dockerfile` at the repo root is
nginx + `site/` + `deploy/nginx-default.conf`; `site/tests/` and the rest of
`deploy/` are kept out of the image by `.dockerignore`.

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t paluigi/congiuntura-agent:<version> -t paluigi/congiuntura-agent:latest --push .
```

Then point the `congiuntura-agent` service in the congiuntura-live
`docker-compose.yml` at the new tag — there is nothing to build on the host.

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
- No network/runtime/dashboard change needed — only `agent-manifest.json`
  changes. The manifest is read at runtime; to ship the change, rebuild the
  image (it is baked in — see "Building the image" above)

Keep `llm_config.model_name` in the HOCON in sync with the router's models.
