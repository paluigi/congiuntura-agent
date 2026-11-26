# congiuntura-agent — the static bundle (site/) served by nginx.
#
# Multi-arch (linux/amd64 + linux/arm64): no build stage, and the single RUN
# below is instant even emulated. Build and publish from the repo root:
#
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t paluigi/congiuntura-agent:<version> -t paluigi/congiuntura-agent:latest --push .
#
# The bundle's own nginx sets the headers the agent needs (CORS on the public
# artifacts, CSP on the sandbox worker, no X-Frame-Options on the bridge), so a
# reverse proxy in front only forwards. Runbook: deploy/DEPLOY.md.
FROM nginx:alpine

# Drop the base image's stock pages, so the web root holds exactly the bundle.
RUN rm -rf /usr/share/nginx/html/*

# Site config — replaces the default server block.
COPY deploy/nginx-default.conf /etc/nginx/conf.d/default.conf

# The bundle is the repo's site/ folder, served as-is.
COPY site/ /usr/share/nginx/html

EXPOSE 80
