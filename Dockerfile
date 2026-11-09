FROM debian:trixie-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        freeradius freeradius-utils openssl iproute2 iputils-ping procps tini && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i -E 's/^([[:space:]]*auth[[:space:]]*=[[:space:]]*)no/\1yes/' /etc/freeradius/3.0/radiusd.conf

COPY lib/aaa-common.sh /usr/local/lib/aaa/
COPY bin/aaa-entrypoint bin/aaa-supervise bin/aaa-healthcheck bin/radius-user /usr/local/bin/
RUN chmod 644 /usr/local/lib/aaa/aaa-common.sh && \
    chmod 755 /usr/local/bin/aaa-entrypoint /usr/local/bin/aaa-supervise \
              /usr/local/bin/aaa-healthcheck /usr/local/bin/radius-user

ENV RADIUS_CLIENTS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
    AGENT_IDLE_TIMEOUT="300" \
    AGENT_SESSION_TIMEOUT="3600" \
    AAA_MAX_RESTARTS="5" \
    AAA_RESTART_WINDOW="60"

EXPOSE 1812/udp 1813/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/aaa-healthcheck"]

# tini reaps zombies and forwards docker stop (SIGTERM) to aaa-entrypoint.
# -s keeps it working when GNS3's init script, not tini, is PID 1.
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/usr/local/bin/aaa-entrypoint"]