# Dante SOCKS5 Proxy — Hardened Alpine Docker Setup

A minimal, hardened Docker setup for [Dante](https://www.inet.no/dante/) SOCKS5 proxy. Built on Alpine Linux, runs Dante 1.4.4 (current upstream, patches CVE-2024-54662), and is designed to be compatible with browser SOCKS5 clients such as FoxyProxy and SwitchyOmega for Firefox.

Two variants are provided depending on how you want patches to flow:

| | Alpine package variant | Source-build variant |
|---|---|---|
| Build time | ~10 s | ~60 s |
| Final image size | ~12 MB | ~10 MB |
| Reproducibility | Version-pinned, but edge content can shift | Pinned tarball + SHA256, bit-for-bit |
| Patch flow | `apk` picks up new `-rN` revisions on rebuild | Manual `DANTE_VERSION` bump |
| Upstream trust | Alpine maintainer + apk signing | `inet.no` tarball + your hash check |

Pick the source-build variant if you want full control and reproducibility. Pick the Alpine-package variant if you want shorter builds and automatic patch flow from a weekly rebuild.

## Layout

```
.
├── Dockerfile             # source-build OR Alpine-package variant
├── docker-compose.yml
├── entrypoint.sh
├── sockd.conf
└── .env                   # not committed — see Configuration
```

## Variant A — Source build (recommended for reproducibility)

```dockerfile
# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.21

FROM alpine:${ALPINE_VERSION} AS builder

ARG DANTE_VERSION=1.4.4
# Verify the hash yourself first:
#   curl -fsSL https://www.inet.no/dante/files/dante-1.4.4.tar.gz | sha256sum
ARG DANTE_SHA256=PUT_VERIFIED_SHA256_HERE

RUN apk add --no-cache build-base curl tar

WORKDIR /build
RUN curl -fsSL "https://www.inet.no/dante/files/dante-${DANTE_VERSION}.tar.gz" -o dante.tar.gz \
 && echo "${DANTE_SHA256}  dante.tar.gz" | sha256sum -c - \
 && tar xzf dante.tar.gz \
 && cd "dante-${DANTE_VERSION}" \
 && ac_cv_func_sched_setscheduler=no ./configure \
      --prefix=/usr/local --sysconfdir=/etc \
      --without-libwrap --without-bsdauth \
      --without-gssapi --without-krb5 \
      --without-upnp --without-pam \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache tini ca-certificates \
 && addgroup -S sockd \
 && adduser -S -D -H -G sockd -s /sbin/nologin sockd

COPY --from=builder /out/ /
COPY sockd.conf       /etc/sockd.conf
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 55555

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD nc -z 127.0.0.1 55555 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/local/sbin/sockd", "-f", "/etc/sockd.conf", "-N", "2"]
```

## Variant B — Alpine package (faster builds, auto-patches)

```dockerfile
# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.21
FROM alpine:${ALPINE_VERSION}

# dante-server 1.4.4 lives in edge/community (not testing).
# We use --repository so edge is NOT persisted into /etc/apk/repositories.
ARG DANTE_PKG_VERSION=1.4.4-r0
RUN apk add --no-cache tini ca-certificates \
 && apk add --no-cache \
      --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
      dante-server=${DANTE_PKG_VERSION} \
 && addgroup -S sockd \
 && adduser -S -D -H -G sockd -s /sbin/nologin sockd

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

`ulimits.nofile` is mandatory: modern Docker/systemd hands containers a `RLIMIT_NOFILE` in the millions, which Dante does not handle (it segfaults at `mother_util.c:232` with exit 139). Capping at 65536 fixes it.

Add `NET_BIND_SERVICE` to `cap_add` only if you bind to a privileged port (<1024).

## Configuration

Create a `.env` file next to `docker-compose.yml`:

```
PROXY_USER=your_user
PROXY_PASSWORD=long_random_password_here
```

Add `.env` to `.gitignore`. For production, use Docker secrets instead and switch to the `_FILE` variants in `entrypoint.sh`:

```yaml
secrets:
  proxy_password:
    file: ./secrets/proxy_password
services:
  dante:
    secrets:
      - proxy_password
    environment:
      PROXY_USER: your_user
      PROXY_PASSWORD_FILE: /run/secrets/proxy_password
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

`socks5h` (note the `h`) tells curl to resolve hostnames through the proxy, mirroring browser behaviour with remote DNS enabled.

## Firefox / SwitchyOmega / FoxyProxy

Create a SOCKS5 profile pointing at `your.host:55555` with the proxy username and password. Enable "Proxy DNS when using SOCKS5" (this sets Firefox's `network.proxy.socks_remote_dns = true`) to prevent DNS leaks — the server already supports remote DNS resolution natively.

Note that SOCKS5 authentication travels in plaintext over the wire. If the proxy is publicly reachable, front it with WireGuard, Tailscale, or an SSH tunnel — or accept the risk and use long, unique credentials with rate-limiting at the firewall layer.

## Updates

**Source-build variant.** Watch [inet.no/dante](https://www.inet.no/dante/) for new releases. When one ships:

1. Update `DANTE_VERSION` in the Dockerfile.
2. Download the tarball, run `sha256sum`, paste the result into `DANTE_SHA256`.
3. `docker compose build --no-cache && docker compose up -d`.

**Alpine-package variant.** Watch [pkgs.alpinelinux.org/package/edge/community/x86_64/dante-server](https://pkgs.alpinelinux.org/package/edge/community/x86_64/dante-server). Update `DANTE_PKG_VERSION` and rebuild. A weekly `docker compose build --no-cache` via cron or GitHub Actions is the standard pattern to pull in base-image patches automatically.

## Security notes

- Image runs as the dedicated `sockd` user; root is used only briefly by sockd's own privilege separation logic.
- All Linux capabilities dropped except the three needed for runtime user creation and Dante's privsep.
- `no-new-privileges` prevents any setuid binary inside the container from escalating.
- `tini` reaps zombies and forwards signals, so `docker stop` shuts down cleanly.
- Credentials are never present at build time — they exist only in the running container's `/etc/shadow`, populated from env or secrets at startup.
- The `socks block` rules prevent the proxy being used to reach cloud metadata endpoints (`169.254.169.254`) or scan internal networks.

## CVE history

- **CVE-2024-54662** (CVSS 9.1, Critical): incorrect access control for `sockd.conf` configurations with `socksmethod` in client/hostid rules. Affects 1.4.0 through 1.4.3. Fixed in 1.4.4. This setup uses `socksmethod` at the global level only, but you should still run 1.4.4 or later.

## Troubleshooting

**`exit 139` / `mother_util.c:232` warning at startup** — `RLIMIT_NOFILE` too high. Verify `ulimits.nofile` is set in compose (`docker exec dante sh -c 'ulimit -n'` should show 65536, not 1048576). If the compose limit isn't taking effect, check `systemctl show docker | grep LimitNOFILE` for a dockerd-level override.

**Auth fails from browser but works from `curl`** — make sure SwitchyOmega/FoxyProxy is configured for `SOCKS5`, not `SOCKS4`, and that "Proxy DNS when using SOCKS5" is enabled.

**`Connection refused`** — check the host firewall (`ufw`, `iptables`, cloud security group) and that the container is actually listening: `docker exec dante nc -z 127.0.0.1 55555 && echo ok`.
