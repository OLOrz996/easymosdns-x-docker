FROM alpine:3.20 AS fetcher

ARG TARGETARCH
ARG MOSDNS_X_REF=latest
ARG EASYMOSDNS_REF=latest

RUN apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    curl \
    tar \
    unzip

RUN mkdir -p /out/bin /out/easymosdns /out/meta

RUN set -euo pipefail; \
    case "${TARGETARCH}" in \
      amd64) asset_name="mosdns-linux-amd64.zip" ;; \
      arm64) asset_name="mosdns-linux-arm64.zip" ;; \
      arm) asset_name="mosdns-linux-arm-7.zip" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${MOSDNS_X_REF}" = "latest" ]; then \
      asset_url="https://github.com/pmkol/mosdns-x/releases/latest/download/${asset_name}"; \
      version_url="https://github.com/pmkol/mosdns-x/releases/latest"; \
    else \
      asset_url="https://github.com/pmkol/mosdns-x/releases/download/${MOSDNS_X_REF}/${asset_name}"; \
      version_url="https://github.com/pmkol/mosdns-x/releases/tag/${MOSDNS_X_REF}"; \
    fi; \
    tmp_dir="$(mktemp -d)"; \
    curl -fsSL -o "${tmp_dir}/mosdns.zip" "${asset_url}"; \
    unzip -q "${tmp_dir}/mosdns.zip" -d "${tmp_dir}/extract"; \
    install -m 0755 "${tmp_dir}/extract/mosdns" /out/bin/mosdns; \
    version_effective="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "${version_url}")"; \
    version_tag="${version_effective##*/}"; \
    printf '{\n  "tag_name": "%s"\n}\n' "${version_tag}" > /out/meta/mosdns-x-release.json; \
    rm -rf "${tmp_dir}"

RUN set -euo pipefail; \
    if [ "${EASYMOSDNS_REF}" = "latest" ]; then \
      version_url="https://github.com/pmkol/easymosdns/releases/latest"; \
      version_effective="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "${version_url}")"; \
      version_tag="${version_effective##*/}"; \
    else \
      version_tag="${EASYMOSDNS_REF}"; \
    fi; \
    tarball_url="https://github.com/pmkol/easymosdns/archive/refs/tags/${version_tag}.tar.gz"; \
    tmp_dir="$(mktemp -d)"; \
    curl -fsSL -o "${tmp_dir}/easymosdns.tar.gz" "${tarball_url}"; \
    tar -xzf "${tmp_dir}/easymosdns.tar.gz" -C "${tmp_dir}"; \
    extracted_root="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -n1)"; \
    cp -f "${extracted_root}/config.yaml" /out/easymosdns/config.yaml; \
    cp -f "${extracted_root}/hosts.txt" /out/easymosdns/hosts.txt; \
    cp -f "${extracted_root}/ecs_cn_domain.txt" /out/easymosdns/ecs_cn_domain.txt; \
    cp -f "${extracted_root}/ecs_noncn_domain.txt" /out/easymosdns/ecs_noncn_domain.txt; \
    cp -rf "${extracted_root}/rules" /out/easymosdns/rules; \
    printf '{\n  "tag_name": "%s"\n}\n' "${version_tag}" > /out/meta/easymosdns-release.json; \
    rm -rf "${tmp_dir}"

FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    bind-tools \
    ca-certificates \
    coreutils \
    curl \
    tar \
    tzdata

COPY --from=fetcher /out/bin/mosdns /usr/local/bin/mosdns
COPY --from=fetcher /out/easymosdns /opt/easymosdns-template
COPY --from=fetcher /out/meta/mosdns-x-release.json /usr/local/share/mosdns-x-release.json
COPY --from=fetcher /out/meta/easymosdns-release.json /usr/local/share/easymosdns-release.json
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/mosdns /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh && \
    mkdir -p /etc/mosdns /var/lib/easymosdns-bootstrap

VOLUME ["/etc/mosdns"]

EXPOSE 53/udp 53/tcp 853/tcp 9080/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]
