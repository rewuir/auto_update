#!/bin/bash
###############################################################################
# Jenkins 自动升级脚本（保守版）
# - 适用于较老 Bash / 避免 process-substitution 导致的语法错误
# - 对域名做多 A 记录逐 IP 重试（使用 curl --resolve）
# - 下载时保存 stderr 到临时文件再追加到 LOG_FILE（无 >(...) 用法）
# - 请用 /bin/bash 运行；建议通过 Jenkins Credentials 注入 JENKINS_API_TOKEN
###############################################################################

set -uo pipefail

JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:8081}"
JENKINS_USER="${JENKINS_USER:-appadm}"
JENKINS_API_TOKEN="${JENKINS_API_TOKEN:-}"

TMP_DIR="${TMP_DIR:-/tmp/jenkins}"
APP_DIR="${APP_DIR:-/data/jenkins/apps}"
WAR_FILE="${WAR_FILE:-jenkins.war}"
UPDATE_CENTER_URL="${UPDATE_CENTER_URL:-https://updates.jenkins.io/update-center.json}"

CURL_TIMEOUT=30
DOWNLOAD_TIMEOUT=600
RESTART_WAIT_MAX=300
DEBUG="${DEBUG:-0}"

mkdir -p /data/jenkins 2>/dev/null || true
LOG_FILE="${LOG_FILE:-/data/jenkins/jenkins_upgrade.log}"
PIDFILE="${PIDFILE:-/data/jenkins/jenkins_auto_upgrade.pid}"
BUILD_ENV_FILE="${BUILD_ENV_FILE:-/data/jenkins/jenkins_auto_upgrade_build_env.${BUILD_ID:-$$}.env}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
  local msg="[$(date '+%F %T')] $1"
  echo "$msg" >&2
  printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}
warn() { log "WARN: $1"; }
error_exit() {
  log "ERROR: $1"
  publish_results_to_build "FAILURE" || true
  [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE" 2>/dev/null || true
  exit 1
}

trap '[[ -f "$PIDFILE" ]] && rm -f "$PIDFILE" 2>/dev/null || true' EXIT

# ====== background handling (same as before) ======
is_pidfile_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 && return 0 || return 1
}

if [[ -n "${BUILD_ID:-}" && -z "${JENKINS_AUTO_UPGRADE_DAEMONIZED:-}" ]]; then
  if is_pidfile_running; then
    echo "Background upgrade already running (pid $(cat \"$PIDFILE\")) -- exiting." >&2
    exit 0
  fi
  {
    printf '%s\n' "export BUILD_ID='${BUILD_ID:-}'"
    printf '%s\n' "export BUILD_NUMBER='${BUILD_NUMBER:-}'"
    printf '%s\n' "export JOB_NAME='${JOB_NAME:-}'"
    printf '%s\n' "export BUILD_URL='${BUILD_URL:-}'"
  } > "$BUILD_ENV_FILE"
  chmod 0600 "$BUILD_ENV_FILE" 2>/dev/null || true
  export JENKINS_AUTO_UPGRADE_DAEMONIZED=1
  if [[ "$DEBUG" == "1" ]]; then
    setsid nohup /bin/bash -x "$0" "$@" > "$LOG_FILE" 2>&1 < /dev/null &
  else
    setsid nohup /bin/bash "$0" "$@" > "$LOG_FILE" 2>&1 < /dev/null &
  fi
  sleep 0.2
  echo $! > "$PIDFILE"
  chmod 0644 "$PIDFILE" 2>/dev/null || true
  echo "Launched background process pid=$! (log: ${LOG_FILE}). Exiting." >&2
  exit 0
fi

if [[ -n "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE:-}" && -f "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE}"
  rm -f "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE}" 2>/dev/null || true
elif [[ -f "${BUILD_ENV_FILE:-}" ]]; then
  # shellcheck disable=SC1090
  source "${BUILD_ENV_FILE}"
  rm -f "${BUILD_ENV_FILE}" 2>/dev/null || true
fi

if [[ -n "${JENKINS_AUTO_UPGRADE_DAEMONIZED:-}" ]]; then
  echo $$ > "$PIDFILE"
  chmod 0644 "$PIDFILE" 2>/dev/null || true
  log "Background process started, pid=$(cat \"$PIDFILE\")"
fi

check_dependencies() {
  local missing=()
  for cmd in curl unzip java; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error_exit "Missing dependencies: ${missing[*]}"
  fi
  log "Dependencies OK"
}

get_auth_params() {
  if [[ -n "${JENKINS_API_TOKEN:-}" ]]; then
    echo "-u" "${JENKINS_USER}:${JENKINS_API_TOKEN}"
  else
    error_exit "JENKINS_API_TOKEN not set (use Jenkins Credentials)"
  fi
}

# resolve_host_ips (compatible)
resolve_host_ips() {
  local host="$1"; local out_var="${2:-}"
  local ips_list="" line ip
  if command -v dig >/dev/null 2>&1; then
    while IFS= read -r line; do
      line="${line%%$'\r'}"
      if [[ -n "$line" && "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ " ${ips_list} " != *" ${line} "* ]]; then ips_list="${ips_list:+$ips_list }${line}"; fi
      fi
    done < <(dig +short "$host" 2>/dev/null || true)
  elif command -v getent >/dev/null 2>&1 && getent hosts "$host" >/dev/null 2>&1; then
    while IFS= read -r line; do
      ip=$(printf '%s' "$line" | awk '{print $1}')
      if [[ -n "$ip" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ " ${ips_list} " != *" ${ip} "* ]]; then ips_list="${ips_list:+$ips_list }${ip}"; fi
      fi
    done < <(getent hosts "$host" 2>/dev/null || true)
  elif command -v host >/dev/null 2>&1; then
    while IFS= read -r line; do
      ip=$(printf '%s' "$line" | awk '/has address/ {print $4}')
      if [[ -n "$ip" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ " ${ips_list} " != *" ${ip} "* ]]; then ips_list="${ips_list:+$ips_list }${ip}"; fi
      fi
    done < <(host "$host" 2>/dev/null || true)
  fi

  if [[ -z "${out_var}" ]]; then return 1; fi
  eval "$out_var=()"
  local ip_item
  for ip_item in ${ips_list}; do [[ -z "$ip_item" ]] && continue; eval "$out_var+=(\"$ip_item\")"; done
  return 0
}

# conservative curl_exec: explicit url param
# usage: curl_exec <errfile> <url> -- <curl-args...>
curl_exec() {
  local errfile="$1"; shift
  local url="$1"; shift
  if [[ "${1:-}" != "--" ]]; then log "curl_exec usage error"; return 2; fi
  shift

  local base_opts=( --connect-timeout "${CURL_TIMEOUT}" --max-time "${DOWNLOAD_TIMEOUT}" --retry 2 --retry-delay 2 --retry-connrefused )

  # detect -o option presence
  local has_output=0
  local idx=1
  while [[ $idx -le $# ]]; do
    eval "a=\${$idx}"
    case "$a" in
      -o|--output|-O) has_output=1; break;;
      --output=*) has_output=1; break;;
    esac
    idx=$((idx+1))
  done

  _run_once() {
    if [[ $has_output -eq 0 ]]; then
      local tmpout; tmpout=$(mktemp) || tmpout="/tmp/jenkins_curl_out.$$"
      rm -f "$tmpout" 2>/dev/null || true
      curl "${base_opts[@]}" "$@" -o "$tmpout" 2> "$errfile"
      local rc=$?
      if [[ -s "$errfile" ]]; then cat "$errfile" >> "$LOG_FILE"; fi
      if [[ $rc -eq 0 ]]; then cat "$tmpout"; fi
      rm -f "$tmpout" 2>/dev/null || true
      return $rc
    else
      curl "${base_opts[@]}" "$@" 2> "$errfile"
      local rc=$?
      if [[ -s "$errfile" ]]; then cat "$errfile" >> "$LOG_FILE"; fi
      return $rc
    fi
  }

  # parse host/port from URL
  local scheme rest hostport host port
  scheme="${url%%:*}"
  rest="${url#*://}"
  hostport="${rest%%/*}"
  if [[ "$hostport" == *:* ]]; then host="${hostport%%:*}"; port="${hostport##*:}"; else host="$hostport"; if [[ "$scheme" == "https" ]]; then port=443; else port=80; fi; fi

  # get IP list
  local ips=()
  resolve_host_ips "$host" ips || true

  local tries=()
  tries+=("")
  local ip
  for ip in "${ips[@]:-}"; do tries+=("$ip"); done

  local last_rc=0
  for ip in "${tries[@]}"; do
    if [[ -n "$ip" ]]; then
      log "curl try ${host} -> ${ip}"
      if _run_once --resolve "${host}:${port}:${ip}" "$@" "$url"; then return 0; else last_rc=$?; log "curl (host ${host} -> ${ip}) failed (exit=${last_rc})"; continue; fi
    else
      log "curl try system resolver ${host}"
      if _run_once "$@" "$url"; then return 0; else last_rc=$?; log "curl (system resolver) failed (exit=${last_rc})"; continue; fi
    fi
  done

  return $last_rc
}

# download_war_by_version: conservative, write stderr to tmp file then append
download_war_by_version() {
  local version="$1" out="$2"
  local url="https://updates.jenkins.io/download/war/${version}/jenkins.war"
  local tmp="${out}.part.$$"
  local attempt=0 max_attempts=6
  local per_attempt_max=120 per_connect_timeout=10 speed_limit=1024 speed_time=30

  local scheme rest hostport host port
  scheme="${url%%:*}"; rest="${url#*://}"; hostport="${rest%%/*}"
  if [[ "$hostport" == *:* ]]; then host="${hostport%%:*}"; port="${hostport##*:}"; else host="$hostport"; if [[ "$scheme" == "https" ]]; then port=443; else port=80; fi; fi

  local ips=()
  resolve_host_ips "$host" ips || true

  local tries=(); tries+=("")
  local ip
  for ip in "${ips[@]:-}"; do tries+=("$ip"); done

  for ip in "${tries[@]}"; do
    attempt=$((attempt+1))
    if (( attempt > max_attempts )); then log "Exceeded max attempts ${max_attempts}"; break; fi

    local curl_opts=( -fSL --create-dirs --retry 3 --retry-delay 5 --retry-connrefused -4 --connect-timeout "$per_connect_timeout" --max-time "$per_attempt_max" --speed-limit "$speed_limit" --speed-time "$speed_time" --no-keepalive )
    if [[ -n "$ip" ]]; then
      log "Download attempt ${attempt}/${max_attempts} -> ${url} (IP: ${ip})"
      curl_opts+=( --resolve "${host}:${port}:${ip}" )
    else
      log "Download attempt ${attempt}/${max_attempts} -> ${url} (system resolver)"
    fi

    rm -f "${tmp}" 2>/dev/null || true
    local errf="/tmp/jenkins_war_download.err.$$"
    rm -f "$errf" 2>/dev/null || true

    if command -v timeout >/dev/null 2>&1; then
      local cmd="curl"
      for e in "${curl_opts[@]}"; do cmd+=" $(printf '%q' "$e")"; done
      cmd+=" --progress-bar -o $(printf '%q' "$tmp") $(printf '%q' "$url")"
      timeout "${per_attempt_max}s" bash -lc "$cmd" 2> "$errf"
      local rc=$?
    else
      curl "${curl_opts[@]}" --progress-bar -o "${tmp}" "${url}" 2> "$errf"
      local rc=$?
    fi

    if [[ -s "$errf" ]]; then cat "$errf" >> "$LOG_FILE"; fi
    rm -f "$errf" 2>/dev/null || true

    if [[ $rc -ne 0 ]]; then
      log "curl download failed (exit=${rc})"
      rm -f "${tmp}" 2>/dev/null || true
      sleep 2
      continue
    fi

    if [[ ! -s "${tmp}" ]]; then
      log "Downloaded file empty, trying next"
      rm -f "${tmp}" 2>/dev/null || true
      sleep 1
      continue
    fi

    if unzip -t "${tmp}" >/dev/null 2>&1; then
      mv -f "${tmp}" "${out}"
      log "WAR downloaded and verified: ${out}"
      return 0
    else
      log "Downloaded file not a valid WAR, possible tampering; retrying"
      rm -f "${tmp}" 2>/dev/null || true
      sleep 1
      continue
    fi
  done

  rm -f "${tmp}" 2>/dev/null || true
  return 1
}

extract_war() {
  local war="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  unzip -q "$war" -d "$dest" || return 1
  [[ -d "${dest}/WEB-INF" ]] || return 1
  return 0
}

backup_old_version() {
  local dir="$1"
  local bak="${dir}_$(date +%Y%m%d_%H%M%S)"
  if [[ -d "$dir" ]]; then log "Backup ${dir} -> ${bak}"; mv "$dir" "$bak"; fi
  echo "$bak"
}

deploy_new_version() {
  local src="$1" dst="$2"
  rm -rf "$dst" || true; mkdir -p "$dst"
  cp -a "${src}/." "$dst/" || return 1
  [[ -d "${dst}/WEB-INF" ]] || return 1
  if id -u "${JENKINS_USER}" >/dev/null 2>&1; then chown -R "${JENKINS_USER}:${JENKINS_USER}" "$dst" 2>/dev/null || true; fi
  return 0
}

get_crumb_header() {
  local jsonf; jsonf=$(mktemp) || jsonf="/tmp/jenkins_crumb.json.$$"
  rm -f "$jsonf" 2>/dev/null || true
  if curl_exec /tmp/jenkins_crumb.err "${JENKINS_URL%/}/crumbIssuer/api/json" -- curl -sS --fail --show-error -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" --connect-timeout 10 --max-time 30 -o "$jsonf"; then
    local field val
    field=$(grep -oP '"crumbRequestField"\s*:\s*"\K[^"]+' "$jsonf" 2>/dev/null || true)
    val=$(grep -oP '"crumb"\s*:\s*"\K[^"]+' "$jsonf" 2>/dev/null || true)
    rm -f "$jsonf" 2>/dev/null || true
    if [[ -n "$field" && -n "$val" ]]; then printf '%s' "${field}:${val}"; return 0; fi
  else
    log "WARN: get crumb failed (see /tmp/jenkins_crumb.err)"
  fi
  rm -f "$jsonf" 2>/dev/null || true
  printf ''
  return 0
}

safe_restart_jenkins() {
  log "Calling /safeRestart..."
  local crumb; crumb=$(get_crumb_header || true)
  local header_opts=()
  if [[ -n "$crumb" ]]; then header_opts+=( -H "${crumb%%:*}: ${crumb#*:}" ); fi
  local respfile="/data/jenkins/jenkins_safe_restart_resp.txt"; rm -f "$respfile" 2>/dev/null || true
  local code
  code=$(curl_exec /tmp/jenkins_safe_restart.err "${JENKINS_URL%/}/safeRestart" -- curl -sS -o "$respfile" -w "%{http_code}" --user "${JENKINS_USER}:${JENKINS_API_TOKEN}" -X POST "${header_opts[@]:-}" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|201|302)$ ]]; then log "/safeRestart OK (HTTP $code)"; rm -f "$respfile" 2>/dev/null || true; return 0
  elif [[ "$code" == "401" ]]; then log "/safeRestart returned 401 (auth)"; cat "$respfile" 2>/dev/null || true; rm -f "$respfile" 2>/dev/null || true; return 2
  else log "/safeRestart failed HTTP $code"; cat "$respfile" 2>/dev/null || true; rm -f "$respfile" 2>/dev/null || true; return 1; fi
}

wait_for_restart() {
  log "Waiting for Jenkins to come up (max ${RESTART_WAIT_MAX}s)..."
  sleep 15
  local waited=0 interval=10
  while [[ $waited -lt $RESTART_WAIT_MAX ]]; do
    local code
    code=$(curl_exec /tmp/jenkins_wait.err "${JENKINS_URL%/}/login" -- curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    if [[ "$code" == "200" || "$code" == "403" ]]; then log "Jenkins is up (HTTP ${code})"; return 0; fi
    log "Waiting... ${waited}s (HTTP ${code})"
    sleep $interval
    waited=$((waited + interval))
  done
  warn "Wait timed out"
  return 1
}

publish_results_to_build() {
  local status="${1:-SUCCESS}"
  local build_url="${BUILD_URL:-}"
  if [[ -z "$build_url" && -n "${JOB_NAME:-}" && -n "${BUILD_NUMBER:-}" && -n "${JENKINS_URL:-}" ]]; then
    IFS='/' read -ra parts <<< "$JOB_NAME"
    local path=""
    for seg in "${parts[@]}"; do path="${path}/job/${seg}"; done
    build_url="${JENKINS_URL%/}${path}/${BUILD_NUMBER}/"
  fi
  if [[ -z "$build_url" ]]; then log "Cannot publish build results: BUILD_URL or JOB_NAME/BUILD_NUMBER missing"; return 0; fi
  local tail_lines=500 excerpt
  if [[ -f "$LOG_FILE" ]]; then excerpt=$(tail -n ${tail_lines} "$LOG_FILE" 2>/dev/null || echo "(log read failed)"); else excerpt="(log missing)"; fi
  local desc
  desc="Jenkins auto-upgrade finished. Status: ${status}\nTime: $(date '+%F %T')\n\nLog excerpt (last ${tail_lines} lines):\n<pre>$(echo "$excerpt" | sed 's/<\//\\u003C\//g; s/</\\u003C/g')</pre>\n\nFull logs on host: ${LOG_FILE}."
  local crumb; crumb=$(get_crumb_header || true)
  local extra=()
  if [[ -n "$crumb" ]]; then extra+=( -H "${crumb%%:*}: ${crumb#*:}" ); fi
  log "Publishing build description to ${build_url}submitDescription"
  if ! curl_exec /tmp/jenkins_publish.err "${build_url%/}/submitDescription" -- curl -sS --fail --show-error --user "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${extra[@]:-}" --data-urlencode "description=${desc}"; then
    log "Publish failed (see /tmp/jenkins_publish.err)"
    return 1
  fi
  log "Published build description"
  return 0
}

perform_upgrade() {
  log "===== Jenkins auto-upgrade start ====="
  check_dependencies
  local current
  current=$(get_current_version)
  log "Current Jenkins version: ${current}"
  local latest
  latest=$(get_latest_version "$current" || true)
  if [[ -z "$latest" ]]; then log "No latest version info, aborting"; publish_results_to_build "NO_INFO" || true; return 0; fi
  log "Latest from update-center: ${latest}"
  if [[ "$current" == "$latest" ]]; then log "Already up-to-date: ${current}"; publish_results_to_build "NO_CHANGE" || true; return 0; fi
  log "Upgrading: ${current} -> ${latest}"
  mkdir -p "$TMP_DIR"
  local war_path="${TMP_DIR}/${WAR_FILE}"
  if ! download_war_by_version "$latest" "$war_path"; then log "WAR download failed"; publish_results_to_build "DOWNLOAD_FAILED" || true; return 1; fi
  local extract_dir="${TMP_DIR}/extracted"
  if ! extract_war "$war_path" "$extract_dir"; then log "Extract failed"; publish_results_to_build "EXTRACT_FAILED" || true; return 1; fi
  backup_old_version "$APP_DIR"
  if ! deploy_new_version "$extract_dir" "$APP_DIR"; then log "Deploy failed"; publish_results_to_build "DEPLOY_FAILED" || true; return 1; fi
  safe_restart_jenkins
  local rc=$?
  if [[ $rc -eq 2 ]]; then publish_results_to_build "AUTH_FAILURE" || true; error_exit "safeRestart needs auth (401)"; elif [[ $rc -ne 0 ]]; then publish_results_to_build "RESTART_FAILED" || true; error_exit "safeRestart failed"; fi
  wait_for_restart || warn "Restart wait timed out"
  local newv; newv=$(get_current_version || true)
  log "Post-upgrade Jenkins version: ${newv:-unknown}"
  if [[ -n "$newv" && "$newv" == "$latest" ]]; then log "Upgrade succeeded: ${current} -> ${newv}"; publish_results_to_build "SUCCESS" || true; else warn "Version mismatch: expected ${latest}, got ${newv:-unknown}"; publish_results_to_build "MISMATCH" || true; fi
  rm -rf "${TMP_DIR}" 2>/dev/null || true
  log "Temporary cleanup done"
  return 0
}

main() {
  log "Script started (log: ${LOG_FILE})"
  local max_cycles=5 i=0
  while [[ $i -lt $max_cycles ]]; do
    i=$((i+1))
    log "Checking round ${i}..."
    if ! perform_upgrade; then log "Upgrade run returned non-zero, exiting"; exit 1; fi
    log "Sleeping 30s before next check..."
    sleep 30
    local cur; cur=$(get_current_version || true)
    local lat; lat=$(get_latest_version "$cur" || true)
    if [[ -z "$lat" || "$cur" == "$lat" ]]; then log "No new version or cannot parse, exiting loop"; break; fi
    log "Detected new version ${lat}, continuing..."
  done
  log "Script finished"
  publish_results_to_build "FINISHED" || true
}

main "$@"
