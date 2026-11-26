# DEPLOY — congiuntura-agent on the congiuntura-live Compose stack

Copy-paste runbook for the production host (Docker Compose, **Nginx Proxy
Manager** (NPM) as the front door). One Compose stack runs everything, from the
`docker-compose.yml` in **congiuntura-live**:

| Container | Image | Role |
|---|---|---|
| `mongo` | `mongo:7` | MongoDB — the data behind the site and the MCP tools |
| `congiuntura-app` | `paluigi/congiuntura-live:0.8.0` | The live site + the read-only MCP endpoint `/mcp` the agent calls |
| `congiuntura-agent` | `paluigi/congiuntura-agent:0.1.0` | This repo's `site/` bundle behind nginx, which sets the special headers |

Both images are prebuilt for `linux/amd64` and `linux/arm64`: nothing is
compiled on the host and no files are copied to it. The bundle's own nginx
serves the files and sets the CORS/CSP headers; NPM only forwards.

**How the agent container is reached.** It publishes no port. It joins the
Docker network NPM already uses to reach `congiuntura-app`, and NPM forwards to
`http://congiuntura-agent:80`. It sits behind a Compose *profile* (`agent`), so
a plain `docker compose up -d` without that profile keeps running the
two-container stack unchanged.

**Fixed hostnames.** The bundle hard-codes the MCP URL
(`https://congiuntura.by.gg8.eu/mcp`), and the MCP server accepts cross-origin
calls from exactly `https://congiuntura-agent.by.gg8.eu`. The agent therefore
has to be served at that domain — changing it is a code change in both repos,
not a deploy setting.

---

## 1. Update the congiuntura-live checkout

On the host, in the congiuntura-live deployment folder (the one holding
`docker-compose.yml` and `.env`):

```bash
git pull
```

This needs `main` at or past the commit *"chore: release 0.8.0 — compose pin +
congiuntura-agent service (agent profile)"*. Check:

```bash
grep -n 'image:\|congiuntura-agent:\|profiles:\|- agent' docker-compose.yml
#   → "image: paluigi/congiuntura-live:0.8.0", a "congiuntura-agent:" service, "- agent"
```

Fresh host only: run `docker compose up -d` once now, so MongoDB is running
before step 2. On an existing deployment the stack is already up.

## 2. Create the read-only MongoDB user

The MCP endpoint (`/mcp`) connects with its own credential, `agent_ro`, holding
the built-in `read` role on the `congiuntura` database. `mongosh` runs inside
the `mongo` container, so nothing needs to be installed on the host.

```bash
# 1. A password: hex, so it is safe inside a connection string. It is exported
#    because the next commands pass it by environment — it never appears on a
#    command line.
export AGENT_RO_PASSWORD=$(openssl rand -hex 16)

# 2. Create the user. The compose mongo service runs without authorization,
#    so no admin login is needed.
docker exec -e AGENT_RO_PASSWORD mongo mongosh --quiet --eval '
  db.getSiblingDB("congiuntura").createUser({
    user: "agent_ro",
    pwd: process.env.AGENT_RO_PASSWORD,
    roles: [{ role: "read", db: "congiuntura" }]
  })'

# 3. Check: exactly one role, read on congiuntura
docker exec mongo mongosh --quiet --eval \
  'printjson(db.getSiblingDB("congiuntura").getUser("agent_ro").roles)'
#   → [ { role: 'read', db: 'congiuntura' } ]

# 4. Sanity check — sign in as agent_ro and attempt one write. It targets a
#    scratch collection, so nothing real is touched either way.
docker exec -e AGENT_RO_PASSWORD mongo mongosh --quiet --eval '
  const d = connect("mongodb://agent_ro:" + process.env.AGENT_RO_PASSWORD +
                    "@127.0.0.1:27017/congiuntura?authSource=congiuntura");
  const probe = d.getCollection("tmp_agent_ro_probe");
  try {
    probe.insertOne({ probe: 1 });
    probe.drop();
    print("login ok; write NOT blocked (authorization is off on this stack)");
  } catch (e) {
    print("login ok; write blocked:", e.codeName);
  }'
#   → login ok; write NOT blocked (authorization is off on this stack)
#     (on a mongod started with --auth the same command prints:
#      "login ok; write blocked: Unauthorized")

# 5. The app's connection string — append it to .env, then forget the password
printf '\nAGENT_MONGODB_URL=mongodb://agent_ro:%s@mongo:27017/congiuntura?authSource=congiuntura\n' \
  "$AGENT_RO_PASSWORD" >> .env
unset AGENT_RO_PASSWORD
```

To rotate the password later: export a new `AGENT_RO_PASSWORD`, run `updateUser`
instead of `createUser`, replace the `AGENT_MONGODB_URL` line in `.env`, then
`docker compose up -d`. The restart matters: connections that were already open
with the old password stay valid until they close.

```bash
docker exec -e AGENT_RO_PASSWORD mongo mongosh --quiet --eval '
  db.getSiblingDB("congiuntura").updateUser("agent_ro", { pwd: process.env.AGENT_RO_PASSWORD })'
```

Notes:

- **Order matters.** As soon as `AGENT_MONGODB_URL` is set, the app logs in as
  `agent_ro` — and that login fails until the user exists. The symptom is easy
  to miss: `tools/list` on `/mcp` keeps answering normally in that state, while
  every actual tool call returns `"Tool … failed; see server logs"` (the app log
  shows `Authentication failed`). So: create the user first (above), then start
  the app with the variable (step 4). With the variable unset, `/mcp` falls
  back to the app's own read-write `MONGODB_URL`.
- **What "read-only" means here.** The compose `mongo` service is not started
  with `--auth`, so the role is recorded but not enforced: a connection that
  skips authentication can still write. The credential becomes a real guard
  only if MongoDB is started with authorization enabled — and then the app
  itself needs its own database user too, or it loses access.
- `scripts/create_agent_ro_user.js` in congiuntura-live does the same as step 2
  (drop + recreate, so re-running it rotates the password).

## 3. Switch the agent on

Find the Docker network NPM uses to reach the app: the name that appears in
both lists below.

```bash
docker inspect congiuntura-app --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'; echo
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i proxy-manager      # NPM's container name
docker inspect <npm-container> --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'; echo
```

Add two lines to `.env`:

```env
COMPOSE_PROFILES=agent
NPM_NETWORK=<the network name found above>
```

## 4. Start the stack

```bash
docker compose pull
docker compose up -d
docker compose ps
#   → mongo (healthy), congiuntura-app, congiuntura-agent
```

If `docker compose` stops with
`network … declared as external, but could not be found`, `NPM_NETWORK` does
not match an existing Docker network — re-check the name in step 3.

## 5. NPM Proxy Host

In the NPM web UI → Hosts → Proxy Hosts → Add proxy host:

- **Details tab**
  - Domain Names: `congiuntura-agent.by.gg8.eu`
  - Scheme: `http`
  - Forward Hostname / IP: `congiuntura-agent` (the container name)
  - Forward Port: `80`
  - Websockets: off (not needed)
  - ⚠ **Block common exploits: OFF.** NPM's exploit-blocking adds
    `X-Frame-Options: SAMEORIGIN`, which would stop OTHER agent sites from
    loading `bridge/action-bridge.html` in a hidden frame — that framing is a
    core MVP interop feature.
  - ⚠ Do **not** enable **Cache Assets** — the bundle must never be cached.
- **SSL tab:** request a new Let's Encrypt certificate (or pick the existing
  wildcard certificate if you have one) + Force HTTPS + HTTP/2.
- **Advanced tab:** leave empty — all special headers come from the upstream
  container; NPM adds none of its own that would clash.
- Save.

HTTPS is REQUIRED in production: the visitor's API key lives in localStorage
for this origin (MVP spec §4).

## 6. DNS

Add a record: `congiuntura-agent.by.gg8.eu` → the same IP the other
subdomains of the site resolve to.

---

## Verify

```bash
# 1. all three containers up, agent on exactly one network (your NPM_NETWORK)
docker compose ps
docker inspect congiuntura-agent --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'; echo

# 2. NPM can reach it (curl from inside the NPM container)
docker exec <npm-container> curl -s -o /dev/null -w '%{http_code}\n' http://congiuntura-agent:80/
#   → 200

# 3. the live app is on 0.8.0 and serves the MCP endpoint
curl -s https://congiuntura.by.gg8.eu/openapi.json | grep -o '"version": *"[^"]*"'
#   → "version": "0.8.0"
curl -s -i -X OPTIONS https://congiuntura.by.gg8.eu/mcp \
  -H 'Origin: https://congiuntura-agent.by.gg8.eu' \
  -H 'Access-Control-Request-Method: POST' | grep -i 'access-control-allow-origin'
#   → access-control-allow-origin: https://congiuntura-agent.by.gg8.eu
curl -s -X POST https://congiuntura.by.gg8.eu/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | grep -o '"name":"[a-z_]*"'
#   → search_releases, get_latest_releases, sentiment_summary,
#     get_upcoming_releases, get_ff_events, get_pipeline_status

# 4. page loads
curl -s -o /dev/null -w '%{http_code}\n' https://congiuntura-agent.by.gg8.eu/          # 200

# 5. public artifacts CORS (exactly ONE Access-Control-Allow-Origin line each)
curl -s -I https://congiuntura-agent.by.gg8.eu/agent-manifest.json \
  -H 'Origin: https://example.org' | grep -ci access-control-allow-origin           # 1
curl -s -I https://congiuntura-agent.by.gg8.eu/agent-manifest.json \
  -H 'Origin: https://example.org' | grep -i access-control-allow-origin            # *
curl -s -I https://congiuntura-agent.by.gg8.eu/congiuntura_outlook.network.json \
  -H 'Origin: https://example.org' | grep -i access-control-allow-origin            # *
curl -s -I https://congiuntura-agent.by.gg8.eu/.well-known/nsdeploy.json \
  -H 'Origin: https://example.org' | grep -i access-control-allow-origin            # *

# 6. sandbox worker CSP
curl -s -I https://congiuntura-agent.by.gg8.eu/runtime/sandbox-worker.js \
  | grep -i content-security-policy

# 7. bridge frameable (NO X-Frame-Options anywhere in the response)
curl -s -I https://congiuntura-agent.by.gg8.eu/bridge/action-bridge.html | head -20
```

Browser check (manual, 5 min):

1. Open `https://congiuntura-agent.by.gg8.eu/` — dashboard renders releases,
   freshness badge shows a recent UTC timestamp.
2. Pick Country=Italy — the list narrows; Clear resets.
3. ⚙ AI model settings → connect OpenRouter/Otari or paste a key → Save and start.
4. Ask "What is the latest signal on inflation?" — the assistant's first MCP
   contact shows a consent card; allow it. The answer cites publisher/date/url.
5. Ask "Show only negative Italy releases on the page" — the page's filters change.
6. Ask "What was Italy's GDP growth in 2019?" — it declines honestly.
7. DevTools console: no errors beyond the harmless ones documented in the skill
   (`<router origin>/agent-manifest.json` noise when using a non-default router).

### NPM gotchas for this bundle

- **Do not add custom locations in NPM** for `/.well-known/`,
  `agent-manifest.json` etc. — the upstream container already sets the CORS
  headers there. Adding them again in NPM would produce duplicate
  `Access-Control-Allow-Origin` headers (browsers reject duplicates with CORS
  errors).
- If you later need an NPM-wide header (e.g. HSTS is already handled by NPM's
  SSL settings), verify with the check curls above that
  `Access-Control-Allow-Origin` still appears exactly once.
- NPM passes the visitor's `Origin` through untouched, which is what the MCP
  CORS check on congiuntura-live needs — no extra config.

## Rollback

All of these are `.env` / checkout edits followed by `docker compose up -d`.

- **Agent bundle off:** remove `COMPOSE_PROFILES=agent` from `.env`. The next
  `up` removes the `congiuntura-agent` container; the NPM proxy host and DNS
  record can stay for later.
- **Previous bundle:** set `image: paluigi/congiuntura-agent:<older tag>` in
  `docker-compose.yml`, then `docker compose up -d`.
- **Previous app version:** `config/` is bind-mounted, so checkout and image
  must move together — `git checkout <previous commit or tag>` and
  `docker compose up -d`.
- **MCP only:** remove `AGENT_MONGODB_URL` from `.env` and recreate the app:
  `/mcp` then falls back to `MONGODB_URL`. v0.8.0 can stay deployed; the
  endpoint is inert without agent traffic.

## MVP §6 interop checklist (for the submission)

- [ ] `/.well-known/nsdeploy.json` reachable, CORS `*`
- [ ] `/.well-known/nsdeploy-agent.json` reachable, CORS `*`
- [ ] `agent-manifest.json` reachable, CORS `*`, from another origin
- [ ] Another agentic site can load the network URL
      `https://congiuntura-agent.by.gg8.eu/congiuntura_outlook` and run it
      (consent card, visitor's key, no `website_*` tools granted to peers)
- [ ] MCP reachable cross-origin from the agent subdomain
