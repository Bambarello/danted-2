# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.21
FROM alpine:${ALPINE_VERSION}

# dante-server 1.4.4 currently lives in Alpine edge/community
# (it was promoted out of edge/testing). We pull just this one
# package from edge using --repository so the edge repo is NOT
# persisted into /etc/apk/repositories — all other apk operations
# continue to use the pinned stable base.
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
