#!/usr/bin/env bash
set -euo pipefail

: "${MOSDNS_WORKDIR:=/etc/mosdns}"
: "${MOSDNS_CONFIG:=config.yaml}"
: "${MOSDNS_DATA_DIR:=/var/lib/easymosdns-bootstrap}"
: "${MOSDNS_X_REPO:=pmkol/mosdns-x}"
: "${EASYMOSDNS_REPO:=pmkol/easymosdns}"
: "${MOSDNS_X_REF:=latest}"
: "${EASYMOSDNS_REF:=latest}"
: "${AUTO_UPDATE:=true}"
: "${RULES_AUTO_UPDATE:=true}"
: "${RULES_UPDATE_INTERVAL:=86400}"
: "${RULES_UPDATE_TIME:=}"
: "${RULES_UPDATE_CRON:=}"
: "${RULES_UPDATE_MODE:=cdn}"
: "${BOOTSTRAP_DOWNLOAD_MODE:=cdn}"
: "${BOOTSTRAP_CDN_PREFIX:=https://ghproxy.net/}"
: "${RULES_UPDATE_ON_START:=true}"
: "${FORCE_PERSISTENT_WORKDIR:=true}"
: "${INIT_MARKER_FILE:=.easymosdns-initialized}"
: "${FORCE_REINIT:=false}"
: "${BACKUP_ON_REINIT:=true}"
: "${GITHUB_API:=https://api.github.com}"
: "${GITHUB_TOKEN:=}"

log() {
  printf '[entrypoint] %s\n' "$*"
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

api_get() {
  local url=$1
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$url"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "$url"
  fi
}

marker_path() {
  echo "${MOSDNS_WORKDIR}/${INIT_MARKER_FILE}"
}

ensure_persistent_workdir() {
  if ! is_true "${FORCE_PERSISTENT_WORKDIR}"; then
    return 0
  fi
  if ! grep -qsE "[[:space:]]${MOSDNS_WORKDIR}[[:space:]]" /proc/mounts; then
    log "persistent mount required: ${MOSDNS_WORKDIR} is not a mounted volume"
    log "please bind mount or use a named volume for ${MOSDNS_WORKDIR}"
    exit 1
  fi
}

timestamp_utc() {
  date -u +"%Y%m%dT%H%M%SZ"
}

backup_current_config() {
  local backup_dir
  backup_dir="${MOSDNS_WORKDIR}/.backup-$(timestamp_utc)"
  mkdir -p "${backup_dir}"

  for path in config.yaml hosts.txt ecs_cn_domain.txt ecs_noncn_domain.txt rules; do
    if [[ -e "${MOSDNS_WORKDIR}/${path}" ]]; then
      cp -a "${MOSDNS_WORKDIR}/${path}" "${backup_dir}/"
    fi
  done

  if [[ -f "$(marker_path)" ]]; then
    cp -a "$(marker_path)" "${backup_dir}/"
  fi
  printf '%s\n' "${backup_dir}" > "${MOSDNS_DATA_DIR}/last-reinit-backup.txt"
  log "backed up existing config to ${backup_dir}"
}

sleep_until_next_daily_time() {
  local schedule today target_ts now_ts sleep_seconds
  schedule="${RULES_UPDATE_TIME}"
  if [[ ! "${schedule}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$ ]]; then
    log "invalid RULES_UPDATE_TIME=${schedule}, expected HH:MM or HH:MM:SS"
    exit 1
  fi

  today="$(date +%F)"
  target_ts="$(date -d "${today} ${schedule}" +%s)"
  now_ts="$(date +%s)"
  if (( target_ts <= now_ts )); then
    target_ts="$(date -d "${today} ${schedule} +1 day" +%s)"
  fi
  sleep_seconds=$(( target_ts - now_ts ))
  log "next scheduled rules update at ${schedule}, sleeping ${sleep_seconds}s"
  sleep "${sleep_seconds}"
}

cron_field_matches() {
  local field=$1
  local value=$2
  local min=$3
  local max=$4

  awk -v field="${field}" -v value="${value}" -v min="${min}" -v max="${max}" '
    function in_range(v, a, b) { return v >= a && v <= b }
    function check_part(part,    range, step, start, stop, i, parts) {
      step = 1
      split(part, parts, "/")
      range = parts[1]
      if (length(parts) > 1) {
        step = parts[2] + 0
        if (step <= 0) return 0
      }

      if (range == "*") {
        start = min
        stop = max
      } else if (index(range, "-")) {
        split(range, parts, "-")
        start = parts[1] + 0
        stop = parts[2] + 0
      } else {
        start = range + 0
        stop = start
      }

      if (!in_range(start, min, max) || !in_range(stop, min, max) || start > stop) return 0
      for (i = start; i <= stop; i += step) {
        if (i == value) return 1
      }
      return 0
    }

    BEGIN {
      n = split(field, items, ",")
      for (i = 1; i <= n; i++) {
        if (check_part(items[i])) exit 0
      }
      exit 1
    }
  '
}

cron_matches_now() {
  local minute hour dom month dow expr
  local -a parts
  expr="${RULES_UPDATE_CRON}"
  read -r -a parts <<< "${expr}"
  if [[ ${#parts[@]} -ne 5 ]]; then
    log "invalid RULES_UPDATE_CRON=${expr}, expected 5 fields"
    exit 1
  fi

  minute="$(date +%-M)"
  hour="$(date +%-H)"
  dom="$(date +%-d)"
  month="$(date +%-m)"
  dow="$(date +%w)"

  cron_field_matches "${parts[0]}" "${minute}" 0 59 &&
  cron_field_matches "${parts[1]}" "${hour}" 0 23 &&
  cron_field_matches "${parts[2]}" "${dom}" 1 31 &&
  cron_field_matches "${parts[3]}" "${month}" 1 12 &&
  {
    cron_field_matches "${parts[4]}" "${dow}" 0 7 ||
    { [[ "${dow}" == "0" ]] && cron_field_matches "${parts[4]}" 7 0 7; }
  }
}

sleep_until_next_cron_match() {
  local now sleep_seconds
  while true; do
    now="$(date +%s)"
    sleep_seconds=$((60 - (now % 60)))
    sleep "${sleep_seconds}"
    if cron_matches_now; then
      log "cron expression matched: ${RULES_UPDATE_CRON}"
      return 0
    fi
  done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    armv7l)
      echo "arm-7"
      ;;
    armv6l)
      echo "arm-6"
      ;;
    armv5l)
      echo "arm-5"
      ;;
    *)
      log "unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

release_api_url() {
  local repo=$1
  local ref=$2
  if [[ "${ref}" == "latest" ]]; then
    echo "${GITHUB_API}/repos/${repo}/releases/latest"
  else
    echo "${GITHUB_API}/repos/${repo}/releases/tags/${ref}"
  fi
}

bootstrap_download_url() {
  local url=$1
  case "${BOOTSTRAP_DOWNLOAD_MODE}" in
    direct)
      printf '%s\n' "${url}"
      ;;
    cdn)
      case "${url}" in
        https://github.com/*|https://raw.githubusercontent.com/*)
          printf '%s%s\n' "${BOOTSTRAP_CDN_PREFIX}" "${url}"
          ;;
        *)
          printf '%s\n' "${url}"
          ;;
      esac
      ;;
    *)
      log "invalid BOOTSTRAP_DOWNLOAD_MODE=${BOOTSTRAP_DOWNLOAD_MODE}, expected direct/cdn"
      exit 1
      ;;
  esac
}

release_archive_url() {
  local repo=$1
  local tag=$2
  printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz\n' "${repo}" "${tag}"
}

download_file() {
  local url=$1
  local dest=$2
  local final_url
  final_url="$(bootstrap_download_url "${url}")"
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -o "${dest}" \
      "${final_url}"
  else
    curl -fsSL -o "${dest}" "${final_url}"
  fi
}

install_mosdns_x() {
  local arch release_json asset_name asset_url tmp_dir tmp_zip tmp_extract
  arch="$(detect_arch)"
  release_json="$(api_get "$(release_api_url "${MOSDNS_X_REPO}" "${MOSDNS_X_REF}")")"

  case "${arch}" in
    amd64)
      asset_name="mosdns-linux-amd64.zip"
      ;;
    arm64)
      asset_name="mosdns-linux-arm64.zip"
      ;;
    arm-7)
      asset_name="mosdns-linux-arm-7.zip"
      ;;
    arm-6)
      asset_name="mosdns-linux-arm-6.zip"
      ;;
    arm-5)
      asset_name="mosdns-linux-arm-5.zip"
      ;;
  esac

  asset_url="$(jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .browser_download_url' <<< "${release_json}" | head -n1)"
  if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
    log "failed to find mosdns-x asset ${asset_name}"
    exit 1
  fi

  tmp_dir="$(mktemp -d)"
  tmp_zip="${tmp_dir}/mosdns.zip"
  tmp_extract="${tmp_dir}/extract"
  mkdir -p "${tmp_extract}"

  log "downloading ${MOSDNS_X_REPO} ${MOSDNS_X_REF} (${asset_name}) via ${BOOTSTRAP_DOWNLOAD_MODE}"
  download_file "${asset_url}" "${tmp_zip}"
  unzip -q "${tmp_zip}" -d "${tmp_extract}"

  install -m 0755 "${tmp_extract}/mosdns" /usr/local/bin/mosdns
  jq -r '{tag_name, published_at}' <<< "${release_json}" > "${MOSDNS_DATA_DIR}/mosdns-x-release.json"
  rm -rf "${tmp_dir}"
}

sync_easymosdns() {
  local release_json tag_name tarball_url tmp_dir src_dir extracted_root
  release_json="$(api_get "$(release_api_url "${EASYMOSDNS_REPO}" "${EASYMOSDNS_REF}")")"
  tag_name="$(jq -r '.tag_name' <<< "${release_json}")"
  if [[ -z "${tag_name}" || "${tag_name}" == "null" ]]; then
    log "failed to resolve easymosdns release tag"
    exit 1
  fi
  tarball_url="$(release_archive_url "${EASYMOSDNS_REPO}" "${tag_name}")"

  tmp_dir="$(mktemp -d)"
  src_dir="${tmp_dir}/src"
  mkdir -p "${src_dir}"

  log "downloading ${EASYMOSDNS_REPO} ${EASYMOSDNS_REF} via ${BOOTSTRAP_DOWNLOAD_MODE}"
  download_file "${tarball_url}" "${tmp_dir}/easymosdns.tar.gz"
  tar -xzf "${tmp_dir}/easymosdns.tar.gz" -C "${src_dir}"
  extracted_root="$(find "${src_dir}" -mindepth 1 -maxdepth 1 -type d | head -n1)"

  mkdir -p "${MOSDNS_WORKDIR}/rules"
  cp -f "${extracted_root}/config.yaml" "${MOSDNS_WORKDIR}/config.yaml"
  cp -f "${extracted_root}/hosts.txt" "${MOSDNS_WORKDIR}/hosts.txt"
  cp -f "${extracted_root}/ecs_cn_domain.txt" "${MOSDNS_WORKDIR}/ecs_cn_domain.txt"
  cp -f "${extracted_root}/ecs_noncn_domain.txt" "${MOSDNS_WORKDIR}/ecs_noncn_domain.txt"
  cp -rf "${extracted_root}/rules/." "${MOSDNS_WORKDIR}/rules/"

  jq -r '{tag_name, published_at}' <<< "${release_json}" > "${MOSDNS_DATA_DIR}/easymosdns-release.json"
  printf 'initialized_at=%s\n' "$(date -Iseconds)" > "$(marker_path)"
  printf 'repo=%s\n' "${EASYMOSDNS_REPO}" >> "$(marker_path)"
  printf 'ref=%s\n' "${EASYMOSDNS_REF}" >> "$(marker_path)"
  printf 'tag=%s\n' "$(jq -r '.tag_name' <<< "${release_json}")" >> "$(marker_path)"
  rm -rf "${tmp_dir}"
}

bootstrap() {
  mkdir -p "${MOSDNS_WORKDIR}" "${MOSDNS_DATA_DIR}"
  install_mosdns_x
  if is_true "${FORCE_REINIT}"; then
    if is_true "${BACKUP_ON_REINIT}"; then
      backup_current_config
    fi
    log "FORCE_REINIT is enabled, reinitializing easymosdns config"
    sync_easymosdns
  elif [[ -f "$(marker_path)" ]]; then
    log "found init marker, skipping easymosdns bootstrap to avoid overwriting user config"
  else
    sync_easymosdns
  fi
}

rules_update_script() {
  case "${RULES_UPDATE_MODE}" in
    direct)
      echo "${MOSDNS_WORKDIR}/rules/update"
      ;;
    cdn)
      echo "${MOSDNS_WORKDIR}/rules/update-cdn"
      ;;
    none)
      echo ""
      ;;
    *)
      log "invalid RULES_UPDATE_MODE=${RULES_UPDATE_MODE}, expected direct/cdn/none"
      exit 1
      ;;
  esac
}

update_rules_once() {
  local script_path
  script_path="$(rules_update_script)"
  if [[ -z "${script_path}" ]]; then
    log "rules auto update disabled by mode=none"
    return 0
  fi
  if [[ ! -x "${script_path}" ]]; then
    chmod +x "${script_path}" 2>/dev/null || true
  fi
  if [[ ! -f "${script_path}" ]]; then
    log "rules update script not found: ${script_path}"
    return 1
  fi

  log "updating rules via $(basename "${script_path}")"
  "${script_path}"
}

run_rules_updater() {
  while true; do
    if [[ -n "${RULES_UPDATE_CRON}" ]]; then
      sleep_until_next_cron_match
    elif [[ -n "${RULES_UPDATE_TIME}" ]]; then
      sleep_until_next_daily_time
    else
      sleep "${RULES_UPDATE_INTERVAL}"
    fi
    if ! update_rules_once; then
      log "rules update failed; keeping existing rules"
    fi
  done
}

cleanup() {
  if [[ -n "${MOSDNS_PID:-}" ]]; then
    kill "${MOSDNS_PID}" 2>/dev/null || true
  fi
  if [[ -n "${RULES_UPDATER_PID:-}" ]]; then
    kill "${RULES_UPDATER_PID}" 2>/dev/null || true
  fi
}

run_mosdns() {
  trap cleanup EXIT INT TERM

  if is_true "${RULES_AUTO_UPDATE}" && is_true "${RULES_UPDATE_ON_START}"; then
    if ! update_rules_once; then
      log "initial rules update failed; continuing with bundled rules"
    fi
  fi

  if is_true "${RULES_AUTO_UPDATE}"; then
    if [[ -n "${RULES_UPDATE_CRON}" ]]; then
      log "starting background rules updater, cron=${RULES_UPDATE_CRON}"
    elif [[ -n "${RULES_UPDATE_TIME}" ]]; then
      log "starting background rules updater, daily time=${RULES_UPDATE_TIME}"
    else
      log "starting background rules updater, interval=${RULES_UPDATE_INTERVAL}s"
    fi
    run_rules_updater &
    RULES_UPDATER_PID=$!
  fi

  log "starting mosdns with ${MOSDNS_WORKDIR}/${MOSDNS_CONFIG}"
  /usr/local/bin/mosdns start -d "${MOSDNS_WORKDIR}" -c "${MOSDNS_CONFIG}" &
  MOSDNS_PID=$!
  wait "${MOSDNS_PID}"
}

main() {
  local command=${1:-start}
  case "${command}" in
    start)
      ensure_persistent_workdir
      if [[ "${AUTO_UPDATE}" == "true" || "${AUTO_UPDATE}" == "1" ]]; then
        bootstrap
      elif [[ ! -x /usr/local/bin/mosdns || ! -f "${MOSDNS_WORKDIR}/${MOSDNS_CONFIG}" ]]; then
        log "runtime files are missing, forcing bootstrap"
        bootstrap
      fi
      shift || true
      if [[ $# -gt 0 ]]; then
        exec /usr/local/bin/mosdns start "$@"
      fi
      run_mosdns
      ;;
    bootstrap)
      ensure_persistent_workdir
      bootstrap
      ;;
    *)
      exec "$@"
      ;;
  esac
}

main "$@"
