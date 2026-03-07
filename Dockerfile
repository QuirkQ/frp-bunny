ARG FRP_VERSION=0.61.1
ARG GO_VERSION=1.24.13
ARG ALPINE_VERSION=3.23

FROM golang:${GO_VERSION}-alpine AS builder

ARG FRP_VERSION

RUN apk add --no-cache git make

RUN git clone --depth 1 --branch v${FRP_VERSION} https://github.com/fatedier/frp.git /src

WORKDIR /src

RUN mkdir -p web/frps/dist && echo '' > web/frps/dist/index.html \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /usr/bin/frps ./cmd/frps

FROM alpine:${ALPINE_VERSION} AS extras

RUN apk add --no-cache busybox-extras

FROM alpine:${ALPINE_VERSION}

COPY --from=extras /bin/busybox-extras /bin/busybox-extras

RUN apk upgrade --no-cache \
    && apk add --no-cache su-exec \
    && addgroup -S -g 1000 frps \
    && adduser -S -G frps -H -s /sbin/nologin -u 1000 frps \
    && mkdir -p /etc/frp \
    && chmod 777 /etc/frp \
    && ln -sf /bin/busybox-extras /usr/sbin/httpd \
    && rm -rf /sbin/apk /lib/apk /etc/apk /var/cache/apk \
    && rm -f /usr/bin/scanelf /usr/sbin/ssl_client /usr/bin/iconv /usr/bin/ldd \
    && rm -rf /usr/lib/libcrypto* /usr/lib/libssl* /usr/lib/libapk* \
              /usr/lib/engines-3 /usr/lib/ossl-modules /etc/ssl1.1 \
    && rm -rf /etc/crontabs /etc/periodic /etc/logrotate.d /etc/modprobe.d \
              /etc/modules-load.d /etc/sysctl.d /etc/sysctl.conf /etc/udhcpc \
              /etc/network /etc/securetty /etc/inittab /etc/motd /etc/fstab \
              /etc/services /etc/protocols /etc/profile /etc/profile.d \
              /etc/busybox-paths.d /etc/secfixes.d /etc/opt /etc/issue \
              /etc/shells /etc/modules \
    && rm -rf /usr/lib/sysctl.d /usr/lib/modules-load.d \
              /usr/share /var/spool /media /mnt /opt /srv \
              /usr/lib/libz* /usr/lib/os-release \
              /lib/firmware /lib/modules-load.d /lib/sysctl.d

COPY --from=builder /usr/bin/frps /usr/bin/frps
COPY --chmod=555 entrypoint.sh /entrypoint.sh

EXPOSE 7000 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/cgi-bin/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]

ARG FRP_VERSION
ARG ALPINE_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="frp-bunny" \
    org.opencontainers.image.description="Hardened frp server for Bunny Magic Containers tunneling" \
    org.opencontainers.image.version="${FRP_VERSION}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.revision="${VCS_REF}" \
    org.opencontainers.image.vendor="QuirkQ" \
    org.opencontainers.image.licenses="Apache-2.0" \
    org.opencontainers.image.base.name="alpine:${ALPINE_VERSION}"
