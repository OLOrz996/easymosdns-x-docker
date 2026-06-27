#!/usr/bin/env bash
set -euo pipefail

: "${MOSDNS_WORKDIR:=/etc/mosdns}"
: "${MOSDNS_CONFIG:=config.yaml}"
: "${MOSDNS_DATA_DIR:=/var/lib/easymosdns-bootstrap}"
: "${EASYMOSDNS_TEMPLATE_DIR:=/opt/easymosdns-template}"
: "${AUTO_UPDATE:=true}"
: "${RULES_AUTO_UPDATE:=true}"
: "${RULES_UPDATE_INTERVAL:=86400}"
: "${RULES_UPDATE_TIME:=}"
: "${RULES_UPDATE_CRON:=}"
: "${RULES_UPDATE_MODE:=cdn}"
: "${RULES_UPDATE_ON_START:=true}"
: "${FORCE_PERSISTENT_WORKDIR:=true}"
: "${INIT_MARKER_FILE:=.easymosdns-initialized}"
: "${FORCE_REINIT:=false}"
: "${BACKUP_ON_REINIT:=true}"

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

read_json_tag_name() {
  local file_path=$1
  sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "${file_path}" | head -n1
}

sync_bundled_easymosdns() {
  local bundled_tag
  if [[ ! -d "${EASYMOSDNS_TEMPLATE_DIR}" ]]; then
    log "bundled easymosdns template not found: ${EASYMOSDNS_TEMPLATE_DIR}"
    exit 1
  fi

  mkdir -p "${MOSDNS_WORKDIR}/rules"
  cp -f "${EASYMOSDNS_TEMPLATE_DIR}/config.yaml" "${MOSDNS_WORKDIR}/config.yaml"
  cp -f "${EASYMOSDNS_TEMPLATE_DIR}/hosts.txt" "${MOSDNS_WORKDIR}/hosts.txt"
  cp -f "${EASYMOSDNS_TEMPLATE_DIR}/ecs_cn_domain.txt" "${MOSDNS_WORKDIR}/ecs_cn_domain.txt"
  cp -f "${EASYMOSDNS_TEMPLATE_DIR}/ecs_noncn_domain.txt" "${MOSDNS_WORKDIR}/ecs_noncn_domain.txt"
  cp -rf "${EASYMOSDNS_TEMPLATE_DIR}/rules/." "${MOSDNS_WORKDIR}/rules/"

  bundled_tag="$(read_json_tag_name /usr/local/share/easymosdns-release.json)"
  printf 'initialized_at=%s\n' "$(date -Iseconds)" > "$(marker_path)"
  printf 'source=bundled-template\n' >> "$(marker_path)"
  printf 'tag=%s\n' "${bundled_tag:-unknown}" >> "$(marker_path)"
}

log_bundled_versions() {
  local mosdns_x_tag easymosdns_tag
  mosdns_x_tag="$(read_json_tag_name /usr/local/share/mosdns-x-release.json)"
  easymosdns_tag="$(read_json_tag_name /usr/local/share/easymosdns-release.json)"
  log "bundled mosdns-x: ${mosdns_x_tag:-unknown}"
  log "bundled easymosdns: ${easymosdns_tag:-unknown}"
}

bootstrap() {
  mkdir -p "${MOSDNS_WORKDIR}" "${MOSDNS_DATA_DIR}"
  if is_true "${FORCE_REINIT}"; then
    if is_true "${BACKUP_ON_REINIT}"; then
      backup_current_config
    fi
    log "FORCE_REINIT is enabled, restoring bundled easymosdns template"
    sync_bundled_easymosdns
  elif [[ -f "$(marker_path)" ]]; then
    log "found init marker, skipping template bootstrap to avoid overwriting user config"
  else
    log "initializing config from bundled easymosdns template"
    sync_bundled_easymosdns
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
      log_bundled_versions
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
      log_bundled_versions
      bootstrap
      ;;
    *)
      exec "$@"
      ;;
  esac
}

main "$@"
