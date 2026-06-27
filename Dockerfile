FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    bind-tools \
    ca-certificates \
    coreutils \
    curl \
    jq \
    tar \
    tzdata \
    unzip

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh && \
    mkdir -p /etc/mosdns /var/lib/easymosdns-bootstrap

VOLUME ["/etc/mosdns"]

EXPOSE 53/udp 53/tcp 853/tcp 9080/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]
