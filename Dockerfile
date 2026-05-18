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

#
#HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
#  CMD printf '\x05\x01\x00' | nc -w 2 127.0.0.1 55555 | head -c 2 | grep -q $'\x05\xff' || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["sockd", "-f", "/etc/sockd.conf", "-N", "2"]
