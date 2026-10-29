FROM debian:trixie-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        freeradius freeradius-utils openssl iproute2 iputils-ping procps && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i -E 's/^([[:space:]]*auth[[:space:]]*=[[:space:]]*)no/\1yes/' /etc/freeradius/3.0/radiusd.conf

COPY bin/aaa-entrypoint bin/radius-user /usr/local/bin/
RUN chmod 755 /usr/local/bin/aaa-entrypoint /usr/local/bin/radius-user

ENV RADIUS_CLIENTS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
    AGENT_IDLE_TIMEOUT="300" \
    AGENT_SESSION_TIMEOUT="3600"

EXPOSE 1812/udp 1813/udp

ENTRYPOINT ["/usr/local/bin/aaa-entrypoint"]
