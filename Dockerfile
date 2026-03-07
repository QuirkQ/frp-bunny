ARG FRP_VERSION=0.61.1

FROM ghcr.io/fatedier/frps:v${FRP_VERSION}

# Non-root user with no home dir or login shell
RUN addgroup -S frps \
    && adduser -S -G frps -H -s /sbin/nologin frps \
    && mkdir -p /etc/frp \
    && chown frps:frps /etc/frp

COPY --chmod=555 entrypoint.sh /entrypoint.sh

EXPOSE 7000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD pgrep frps > /dev/null || exit 1

USER frps

ENTRYPOINT ["/entrypoint.sh"]

ARG FRP_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="frp-bunny" \
    org.opencontainers.image.description="Hardened frp server for Bunny Magic Containers tunneling" \
    org.opencontainers.image.version="${FRP_VERSION}" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.revision="${VCS_REF}" \
    org.opencontainers.image.vendor="QuirkQ" \
    org.opencontainers.image.licenses="Apache-2.0" \
    org.opencontainers.image.base.name="ghcr.io/fatedier/frps:v${FRP_VERSION}"
