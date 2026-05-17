#!/bin/bash
# reinstall-docker.sh
#
# Purges any old/legacy Docker installation (apt packages, snap, pip
# docker-compose v1), then installs the current Docker Engine + Compose v2
# from Docker's official APT repository, configures /etc/docker/daemon.json
# with sane log rotation and live-restore, caps systemd LimitNOFILE for the
# daemon, restarts and enables the service, and verifies the result.
#
# Idempotent: safe to re-run on a converged host (will reinstall packages
# only if upstream has a newer version and reapply config files unchanged).
#
# Preserves /var/lib/docker (containers, images, volumes) across the
# reinstall. Tested on Ubuntu 22.04 (jammy) and 24.04 (noble).

set -euo pipefail

# ---------- helpers ----------

log()   { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# ---------- preflight ----------

need_root

if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release missing — unsupported distro."
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This script supports Ubuntu only (detected: ${ID:-unknown})."
fi
CODENAME="${VERSION_CODENAME:?VERSION_CODENAME not set in /etc/os-release}"
ARCH="$(dpkg --print-architecture)"

log "Ubuntu ${VERSION:-?} (${CODENAME}/${ARCH}) — proceeding."

# ---------- step 1: purge old Docker ----------

log "Removing legacy Docker packages (if installed)..."

# Stop the running daemon if any, so apt remove doesn't moan
systemctl stop docker.service docker.socket 2>/dev/null || true

OLD_PKGS=(
    docker
    docker-engine
    docker.io
    docker-doc
    docker-compose
    docker-compose-v2
    podman-docker
    containerd
    runc
)
# Filter to only those that are actually installed — keeps apt output clean
INSTALLED=()
for pkg in "${OLD_PKGS[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        INSTALLED+=("$pkg")
    fi
done
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "${INSTALLED[@]}"
else
    log "No legacy Docker apt packages found."
fi

# Snap-installed Docker, if present
if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx docker; then
    log "Removing snap-installed Docker..."
    snap remove docker
else
    log "No snap-installed Docker found."
fi

# pip-installed Compose v1 (EOL since 2023)
if command -v pip3 >/dev/null 2>&1 && pip3 show docker-compose >/dev/null 2>&1; then
    log "Removing pip-installed docker-compose v1..."
    pip3 uninstall -y docker-compose || true
elif command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q docker-compose; then
    log "Removing pipx-installed docker-compose..."
    pipx uninstall docker-compose || true
fi

# NOTE: /var/lib/docker is intentionally preserved across the reinstall.
# Containers, images, volumes survive. Remove manually if you actually
# want a fresh slate.

# ---------- step 2: official Docker apt repo ----------

log "Installing prerequisites for the Docker apt repo..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg

log "Adding Docker's GPG key..."
install -m 0755 -d /etc/apt/keyrings
# Atomic key write — temp then mv, so a partial download can't poison the keyring
TMP_KEY="$(mktemp)"
trap 'rm -f "$TMP_KEY"' EXIT
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$TMP_KEY"
[[ -s "$TMP_KEY" ]] || die "Downloaded GPG key is empty."
install -m 0644 "$TMP_KEY" /etc/apt/keyrings/docker.asc
rm -f "$TMP_KEY"
trap - EXIT

log "Adding Docker apt repo for ${CODENAME}..."
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

apt-get update -qq

# ---------- step 3: install Docker CE + Compose v2 ----------

log "Installing docker-ce, docker-ce-cli, containerd.io, buildx, compose plugin..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# ---------- step 4: /etc/docker/daemon.json ----------

log "Writing /etc/docker/daemon.json..."
install -m 0755 -d /etc/docker
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT
cat > "$TMP_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
install -m 0644 "$TMP_JSON" /etc/docker/daemon.json
rm -f "$TMP_JSON"
trap - EXIT

# ---------- step 5: systemd LimitNOFILE drop-in ----------
#
# Recent systemd defaults LimitNOFILE to absurd values (1073741816) which
# crashes some daemons (Dante segfaults at mother_util.c:232). Cap at 1M.

log "Installing systemd LimitNOFILE drop-in for docker.service..."
install -m 0755 -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF

systemctl daemon-reload

# ---------- step 6: start, enable, verify ----------

log "Enabling and (re)starting docker.service..."
systemctl enable --now docker.service
systemctl restart docker.service

# Wait for the daemon socket to be ready before verifying
for _ in $(seq 1 20); do
    if docker info >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

log "Verification:"
docker --version
docker compose version

# Sanity-check that compose is v2 (the entire point of this reinstall)
COMPOSE_VER="$(docker compose version --short 2>/dev/null || true)"
if [[ -z "$COMPOSE_VER" || "${COMPOSE_VER%%.*}" != "2" ]]; then
    die "Expected Docker Compose v2.x but got: '${COMPOSE_VER:-unknown}'"
fi

# Sanity-check that LimitNOFILE took effect
EFFECTIVE_NOFILE="$(systemctl show docker.service -p LimitNOFILE --value 2>/dev/null || echo unknown)"
log "Effective docker.service LimitNOFILE: ${EFFECTIVE_NOFILE}"

log "Done. Containers, images, and volumes from the previous install are preserved."
log "Next step on the host: cd into your compose project and 'docker compose up -d'."
