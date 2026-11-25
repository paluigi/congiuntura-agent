# DEPLOY — congiuntura-agent Phase 3 runbook

Copy-paste runbook for the production host **<prod-host IP>** (Ubuntu, Docker
Compose, openresty in front). Two deployments are involved:

- **A. congiuntura-live v0.8.0** (the MCP server the agent bundle calls) — merge
  [paluigi/congiuntura-live#2](https://github.com/paluigi/congiuntura-live/pull/2)
  into `paluigi/main` first, then sync/rebuild on the host.
- **B. congiuntura-agent** (this repo's `site/` static bundle + nginx).

---

## A. congiuntura-live → v0.8.0 (the /mcp endpoint)

The agent bundle hard-codes `https://congiuntura.by.gg8.eu/mcp` (in
`site/script.js` and the HOCON). Production must run v0.8.0 or the chat has no
data tools.

```bash
# on the host, in the congiuntura-live deployment folder
cd /opt/congiuntura-live   # adjust to the actual path
git fetch origin && git checkout <deployed-ref>   # whatever the host tracks

# 1. create the read-only Mongo user (one-time). Generate a password first:
AGENT_RO_PASSWORD=$(openssl rand -hex 16)   # save this for step 3
docker exec -i -e AGENT_RO_PASSWORD "$MONGO_CONTAINER" mongosh --quiet \
  -u "$MONGO_ADMIN_USER" -p "$MONGO_ADMIN_PASS" --authenticationDatabase admin <<EOF
db.getSiblingDB("congiuntura").createUser({
  user: "agent_ro",
  pwd: process.env.AGENT_RO_PASSWORD,
  roles: [{ role: "read", db: "congiuntura" }]
})
EOF

# 2. deploy the new version (v0.8.0 with /mcp)
git pull   # after the PR merge, however the host syncs (git/rsync/compose build)
docker compose up -d --build app

# 3. add to the app's environment (.env next to docker-compose.yml):
#    AGENT_MONGODB_URL=mongodb://agent_ro:<AGENT_RO_PASSWORD>@mongo:27017/congiuntura?authSource=congiuntura
#    (host = the compose service name of mongo; check docker-compose.yml)
docker compose up -d app   # recreate with the new env

# 4. verify
curl -s https://congiuntura.by.gg8.eu/openapi.json | grep -o '"version": *"[^"]*"'
#   → "version": "0.8.0"
curl -s -i -X OPTIONS https://congiuntura.by.gg8.eu/mcp \
  -H 'Origin: https://congiuntura-agent.by.gg8.eu' \
  -H 'Access-Control-Request-Method: POST' | grep -i 'access-control-allow-origin'
#   → access-control-allow-origin: https://congiuntura-agent.by.gg8.eu
curl -s -X POST https://congiuntura.by.gg8.eu/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -c 200
#   → 6 tools listed (search_releases, get_latest_releases, sentiment_summary,
#     get_upcoming_releases, get_ff_events, get_pipeline_status)
```

Write-protection sanity check (must fail):

```bash
docker exec -i -e P=<AGENT_RO_PASSWORD> "$MONGO_CONTAINER" mongosh --quiet \
  -u agent_ro -p "$P" --authenticationDatabase congiuntura \
  "mongodb://127.0.0.1:27017/congiuntura?authSource=congiuntura" \
  --eval 'try { db.processed_releases.insertOne({x:1}); print("BAD: write succeeded") } catch(e) { print("ok:", e.codeName) }'
#   → ok: Unauthorized
```

## B. congiuntura-agent static bundle

```bash
# 1. get the bundle onto the host
sudo mkdir -p /opt/congiuntura-agent
sudo chown <user>:<user> /opt/congiuntura-agent
# Option 1 — rsync from a machine with the repo :
#   rsync -av --delete <repo>/site/ <user>@<prod-host>:/opt/congiuntura-agent/site/
#   rsync -av <repo>/deploy/nginx-default.conf <user>@<prod-host>:/opt/congiuntura-agent/
# Option 2 — git clone on the host:
#   git -C /opt/congiuntura-agent clone https://github.com/paluigi-moltis/congiuntura-agent repo
#   (then symlink site/ and deploy/nginx-default.conf from repo/)

# 2. compose service — append the block from deploy/compose.snippet.yml to the
#    host's main docker-compose.yml, then:
docker compose up -d congiuntura-agent
docker ps --format '{{.Names}} {{.Status}}' | grep congiuntura-agent

# 3. openresty vhost — new server block proxying the subdomain:
#    server {
#      listen 443 ssl http2;
#      server_name congiuntura-agent.by.gg8.eu;
#      ssl_certificate     <same wildcard/cert as congiuntura.by.gg8.eu>;
#      ssl_certificate_key <same>;
#      location / { proxy_pass http://congiuntura-agent:80; }
#    }
#    (nginx -t && systemctl reload openresty)
#    HTTPS is REQUIRED in production: the visitor's API key lives in
#    localStorage for this origin (MVP spec §4).

# 4. DNS — add a record: congiuntura-agent.by.gg8.eu → <prod-host IP>
```

## Post-deploy checks (all must pass)

```bash
# 1. page loads
curl -s -o /dev/null -w '%{http_code}\n' https://congiuntura-agent.by.gg8.eu/          # 200

# 2. public artifacts CORS
curl -s -I https://congiuntura-agent.by.gg8.eu/agent-manifest.json \
  -H 'Origin: https://example.org' | grep -i access-control-allow-origin               # *
curl -s -I https://congiuntura-agent.by.gg8.eu/congiuntura_outlook.network.json \
  -H 'Origin: https://example.org' | grep -i access-control-allow-origin               # *
curl -s -I https://congiuntura-agent.by.gg8.eu/.well-known/nsdeploy.json \
  -H 'Origin: https://example.org' | grep -i access-control-allow-origin               # *

# 3. sandbox worker CSP
curl -s -I https://congiuntura-agent.by.gg8.eu/runtime/sandbox-worker.js \
  | grep -i content-security-policy

# 4. bridge frameable (no X-Frame-Options in the response)
curl -s -I https://congiuntura-agent.by.gg8.eu/bridge/action-bridge.html | head -20

# 5. the bundle can reach the MCP from the agent origin (browser-equivalent)
curl -s -X POST https://congiuntura.by.gg8.eu/mcp -H 'Content-Type: application/json' \
  -H 'Origin: https://congiuntura-agent.by.gg8.eu' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -c 200
```

Browser check (manual, 5 min):

1. Open `https://congiuntura-agent.by.gg8.eu/` — dashboard renders releases,
   freshness badge shows a recent UTC timestamp.
2. Pick Country=Italy — the list narrows; Clear resets.
3. ⚙ AI model settings → connect OpenRouter/Otari or paste a key → Save and start.
4. Ask "What is the latest signal on inflation?" — the first MCP contact shows a
   consent card; allow it. The answer cites publisher/date/url.
5. Ask "Show only negative Italy releases on the page" — the page's filters change.
6. Ask "What was Italy's GDP growth in 2019?" — it declines honestly.
7. DevTools console: no errors beyond the harmless ones documented in the skill
   (`<router origin>/agent-manifest.json` noise when using a non-default router).

## Rollback

- Bundle: `rsync` the previous `site/` back (or `git checkout` the previous tag
  on the host) — no service restart needed, just files.
- MCP: `AGENT_MONGODB_URL` can be emptied in `.env` and the app recreated —
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
