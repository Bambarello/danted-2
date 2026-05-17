# Dante SOCKS5 Proxy — Hardened Alpine Docker Setup

A minimal, hardened Docker setup for [Dante](https://www.inet.no/dante/) SOCKS5 proxy. Built on Alpine Linux, runs Dante 1.4.4 (current upstream, patches CVE-2024-54662), and is compatible with browser SOCKS5 clients such as FoxyProxy and SwitchyOmega for Firefox.

The image installs `dante-server` from Alpine `edge/community` so patch revisions (`-r0`, `-r1`, ...) flow in automatically on rebuild. Final image size is ~12 MB. Tested on Ubuntu 24.04 LTS with Docker Engine 27+ and Compose v2.

## Requirements

- Docker Engine 20.10+ (24+ recommended)
- Docker Compose **v2** (`docker compose`, not the legacy `docker-compose` hyphenated v1 — v1 has known event-watcher bugs that produce noisy but harmless `KeyError: 'id'` tracebacks)

## Layout

```
.
├── Dockerfile
├── docker-compose.yml
├── entrypoint.sh
├── sockd.conf
├── secrets/
│   └── proxy_password         # not committed
└── .env                        # optional, not committed
```

## `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7
ARG ALPINE_VERSION=3.21
FROM alpine:${ALPINE_VERSION}

# dante-server lives in Alpine edge/community. We pull just this one
# package from edge using --repository so the edge repo is NOT persisted
# into /etc/apk/repositories — all other apk operations continue to use
# the pinned stable base.
#
# Version pin policy: lock upstream major.minor.patch (1.4.4), let Alpine
# revisions (-r0, -r1, ...) float so maintainer rebuilds/patches flow in
# automatically. Bump the constraints below when upstream releases 1.4.5+.
#
# The dante-server package's pre-install script creates the 'sockd'
# system user and group itself, so we do NOT create them manually here.
RUN apk add --no-cache tini ca-certificates \
 && apk add --no-cache \
      --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
      "dante-server>=1.4.4" "dante-server<1.4.5"

COPY sockd.conf    /etc/sockd.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 55555

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD nc -z 127.0.0.1 55555 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["sockd", "-f", "/etc/sockd.conf", "-N", "2"]
```

## `entrypoint.sh`

Creates the proxy auth user at runtime from environment variables — never from build args, so credentials never end up baked into image layers or visible in `docker history`. Supports the Docker `*_FILE` secrets convention.

```sh
#!/bin/sh
set -eu

: "${PROXY_USER:=${PROXY_USER_FILE:+$(cat "$PROXY_USER_FILE")}}"
: "${PROXY_PASSWORD:=${PROXY_PASSWORD_FILE:+$(cat "$PROXY_PASSWORD_FILE")}}"

if [ -z "${PROXY_USER:-}" ] || [ -z "${PROXY_PASSWORD:-}" ]; then
  echo "ERROR: PROXY_USER and PROXY_PASSWORD (or _FILE variants) must be set" >&2
  exit 1
fi

if ! id -u "$PROXY_USER" >/dev/null 2>&1; then
  adduser -S -D -H -s /sbin/nologin "$PROXY_USER"
fi
echo "${PROXY_USER}:${PROXY_PASSWORD}" | chpasswd 2>/dev/null

unset PROXY_PASSWORD PROXY_PASSWORD_FILE

exec "$@"
```

## `sockd.conf`

Username/password auth only, TCP `CONNECT` only (no UDP ASSOCIATE, no BIND), and explicit blocks for RFC1918/link-local/loopback destinations to prevent SSRF-style abuse via the proxy.

```
logoutput: stderr

internal: 0.0.0.0 port = 55555
external: eth0

socksmethod: username
user.privileged: root
user.unprivileged: sockd

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks block { from: 0.0.0.0/0 to: 10.0.0.0/8       log: connect error }
socks block { from: 0.0.0.0/0 to: 172.16.0.0/12    log: connect error }
socks block { from: 0.0.0.0/0 to: 192.168.0.0/16   log: connect error }
socks block { from: 0.0.0.0/0 to: 169.254.0.0/16   log: connect error }
socks block { from: 0.0.0.0/0 to: 127.0.0.0/8      log: connect error }

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    log: error
}
```

Add `100.64.0.0/10` to the block list if you're on a CGNAT network. Add a second `internal: :: port = 55555` line and a v6 `external:` if you need IPv6 client/destination support.

## `docker-compose.yml`

Two configurations shown — simple `.env` and Docker secrets. Use Docker secrets if the host is shared, if credentials must not appear in `docker inspect`, or for any production-grade deployment.

### Simple (`.env` file)

```yaml
services:
  dante:
    build: .
    container_name: dante
    restart: unless-stopped
    ports:
      - "55555:55555"
    environment:
      PROXY_USER: ${PROXY_USER}
      PROXY_PASSWORD: ${PROXY_PASSWORD}
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - CHOWN
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
```

With `.env` alongside:

```
PROXY_USER=your_user
PROXY_PASSWORD=long_random_password_here
```

### Production (Docker secrets)

```yaml
services:
  dante:
    build: .
    container_name: dante
    restart: unless-stopped
    ports:
      - "55555:55555"
    environment:
      PROXY_USER: your_user
      PROXY_PASSWORD_FILE: /run/secrets/proxy_password
    secrets:
      - proxy_password
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - CHOWN
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

secrets:
  proxy_password:
    file: ./secrets/proxy_password
```

Create the secret file before first build:

```bash
mkdir -p secrets && chmod 700 secrets
openssl rand -base64 32 | tr -d '\n' > secrets/proxy_password
chmod 600 secrets/proxy_password
```

The `tr -d '\n'` matters — a trailing newline in the secret file becomes part of the password and breaks auth.

### Why `ulimits.nofile` is mandatory

Modern Docker/systemd hands containers a `RLIMIT_NOFILE` in the millions. Dante does not handle this — it segfaults at `mother_util.c:232` with exit code 139. Capping at 65536 in compose fixes the container side. Also cap at the daemon level:

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/limits.conf >/dev/null <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

## `.gitignore`

```
.env
secrets/
```

## Build and run

```bash
docker compose build
docker compose up -d
docker compose logs -f dante
```

Verify:

```bash
curl -x socks5h://your_user:your_password@127.0.0.1:55555 https://ifconfig.me
```

`socks5h` (note the `h`) tells curl to resolve hostnames through the proxy, mirroring browser behaviour with remote DNS enabled. If using Docker secrets, substitute `$(cat secrets/proxy_password)` for the password.

Confirm privsep is working:

```bash
docker exec dante ps -ef
```

Expect one `root` process (sockd's privileged "mother") and worker processes running as `sockd`.

## Firefox / SwitchyOmega / FoxyProxy

Create a SOCKS5 profile pointing at `your.host:55555` with the proxy username and password. Enable "Proxy DNS when using SOCKS5" (sets Firefox's `network.proxy.socks_remote_dns = true`) to prevent DNS leaks — the server supports remote DNS resolution natively.

SOCKS5 authentication travels in plaintext over the wire. If the proxy is publicly reachable, front it with WireGuard, Tailscale, or an SSH tunnel — or accept the risk and use long, unique credentials with rate-limiting at the firewall layer.

## Updates

Alpine periodically rebuilds the `dante-server` package (`-r0` → `-r1` → ...) to pull in dependency patches and packaging fixes. Because the Dockerfile uses a version range (`>=1.4.4 <1.4.5`), these revisions are picked up automatically on rebuild — no Dockerfile change needed:

```bash
docker compose build --no-cache
docker compose up -d
```

A weekly cron or GitHub Actions job running the two commands above is the standard pattern.

When upstream releases **1.4.5 or later**, the build fails on the version constraint. At that point, bump both numbers in the Dockerfile:

```dockerfile
"dante-server>=1.4.5" "dante-server<1.4.6"
```

Check current available versions at: [pkgs.alpinelinux.org/package/edge/community/x86_64/dante-server](https://pkgs.alpinelinux.org/package/edge/community/x86_64/dante-server)

## Security notes

The image runs sockd as the dedicated `sockd` user (created by the Alpine package); root is used only briefly by sockd's own privilege separation logic. All Linux capabilities are dropped except the three needed for runtime user creation and Dante's privsep. `no-new-privileges` prevents any setuid binary inside the container from escalating. `tini` reaps zombies and forwards signals so `docker stop` shuts down cleanly. Credentials are never present at build time — they exist only in the running container's `/etc/shadow`, populated from env or secrets at startup. The `socks block` rules prevent the proxy being used to reach cloud metadata endpoints (`169.254.169.254`) or scan internal networks.

## CVE history

**CVE-2024-54662** (CVSS 9.1, Critical): incorrect access control for `sockd.conf` configurations with `socksmethod` in client/hostid rules. Affects Dante 1.4.0 through 1.4.3. Fixed in 1.4.4. This setup uses `socksmethod` at the global level only, but you should still run 1.4.4 or later.

## Troubleshooting

**`exit 139` / `mother_util.c:232` warning at startup**
`RLIMIT_NOFILE` too high. Verify `ulimits.nofile` is set in compose with `docker exec dante sh -c 'ulimit -n'` (should show 65536, not 1048576). If the compose limit isn't taking effect, check `systemctl show docker | grep LimitNOFILE` for a dockerd-level override — see the "ulimits" section above for the systemd drop-in.

**`addgroup: group 'sockd' in use` during build**
You're using a Dockerfile that manually creates the `sockd` user/group. The Alpine `dante-server` package creates them via a `pre-install` script, so the manual `addgroup`/`adduser` calls must be removed. The Dockerfile above already does this — make sure you're using it as-is.

**`breaks: world[dante-server=X.Y.Z-rN]` during build**
You pinned an exact `-rN` revision that Alpine has since superseded. Either bump the pin or use the range syntax in the Dockerfile above (`"dante-server>=1.4.4" "dante-server<1.4.5"`), which accepts any revision of 1.4.4.

**`KeyError: 'id'` traceback when running `docker-compose up`**
You're on Compose v1 (Python-based, EOL since June 2023). Switch to Compose v2 — install `docker-compose-plugin` from Docker's official APT repo and invoke as `docker compose` (space, not hyphen). The proxy itself is unaffected; this is purely a compose-side bug.

**Auth fails from browser but works from `curl`**
Make sure SwitchyOmega/FoxyProxy is configured for `SOCKS5`, not `SOCKS4`, and that "Proxy DNS when using SOCKS5" is enabled.

**`Connection refused`**
Check the host firewall (`ufw`, `iptables`, cloud security group) and that the container is actually listening: `docker exec dante nc -z 127.0.0.1 55555 && echo ok`.
