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

FROM alpine:${ALPINE_VERSION}

RUN apk upgrade --no-cache \
    && apk add --no-cache su-exec busybox-extras \
    && addgroup -S -g 1000 frps \
    && adduser -S -G frps -H -s /sbin/nologin -u 1000 frps \
    && mkdir -p /etc/frp \
    && chmod 777 /etc/frp

COPY --from=builder /usr/bin/frps /usr/bin/frps
COPY --chmod=555 entrypoint.sh /entrypoint.sh

EXPOSE 80 443 7000 8080

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
