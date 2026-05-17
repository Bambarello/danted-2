#!/bin/sh
set -eu

# Read credentials from env or _FILE (Docker secrets pattern)
: "${PROXY_USER:=${PROXY_USER_FILE:+$(cat "$PROXY_USER_FILE")}}"
: "${PROXY_PASSWORD:=${PROXY_PASSWORD_FILE:+$(cat "$PROXY_PASSWORD_FILE")}}"

if [ -z "${PROXY_USER:-}" ] || [ -z "${PROXY_PASSWORD:-}" ]; then
  echo "ERROR: PROXY_USER and PROXY_PASSWORD (or _FILE variants) must be set" >&2
  exit 1
fi

# Create the auth user if missing; update password each start (idempotent)
if ! id -u "$PROXY_USER" >/dev/null 2>&1; then
  adduser -S -D -H -s /sbin/nologin "$PROXY_USER"
fi
echo "${PROXY_USER}:${PROXY_PASSWORD}" | chpasswd 2>/dev/null

# Scrub from env so child process can't read them
unset PROXY_PASSWORD PROXY_PASSWORD_FILE

exec "$@"
