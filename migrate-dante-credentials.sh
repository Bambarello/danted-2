#!/bin/bash
# migrate-dante-credentials.sh
# Extracts user/password build args from old danted compose file
# and writes them to the new danted-2 .env file.

set -euo pipefail

OLD="${HOME}/danted/docker-compose.yml"
NEW_ENV="${HOME}/danted-2/.env"

[[ -r "$OLD" ]] || { echo "ERROR: $OLD not readable" >&2; exit 1; }

# Match lines like "- user=value" / "- password=value" inside build.args.
# Tolerates: leading whitespace; YAML quoting of the whole token
# (- "key=value") or just the value (- key="value"); trailing whitespace.
# Captures whatever follows the first '=', stripping a single matching
# trailing quote if present.
extract() {
    local key="$1"
    sed -nE "s/^[[:space:]]*-[[:space:]]*[\"']?${key}=[\"']?(.*[^[:space:]\"'])[\"']?[[:space:]]*$/\1/p" "$OLD" \
        | head -n1
}

PROXY_USER="$(extract user)"
PROXY_PASSWORD="$(extract password)"

[[ -n "$PROXY_USER" && -n "$PROXY_PASSWORD" ]] \
    || { echo "ERROR: could not parse user/password from $OLD" >&2; exit 1; }

mkdir -p "$(dirname "$NEW_ENV")"

# Atomic write so a partial file can't briefly exist with the wrong perms
umask 077
tmp="$(mktemp "${NEW_ENV}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
PROXY_USER=${PROXY_USER}
PROXY_PASSWORD=${PROXY_PASSWORD}
EOF
mv "$tmp" "$NEW_ENV"
trap - EXIT

echo "Wrote $NEW_ENV (user=${PROXY_USER}, password=***)"
