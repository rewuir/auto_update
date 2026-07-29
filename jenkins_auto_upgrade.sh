#!/bin/bash
###############################################################################
# Jenkins 自动升级脚本（日志与 PID 存放在 /data/jenkins）
# 兼容性与改进（Version5 -> Version6）:
#  - 兼容较旧 bash（不使用 local -n、关联数组、mapfile）
#  - 在所有对外 HTTP 请求处使用 curl_with_resolve：解析目标 host 的多个 A 记录并逐个尝试（curl --resolve）
#  - 显式初始化数组/变量以配合 set -u（避免 unbound variable）
#  - 在数组展开处使用安全形式 "${arr[@]:-}"
#  - 增加下载进度显示，进度同时写入主日志与诊断文件
#
# 使用建议：
#  - 通过 Jenkins Credentials 将 JENKINS_API_TOKEN 注入环境，不要硬编码
#  - 用 /bin/bash 运行（避免 /bin/sh）
###############################################################################

set -uo pipefail

# ====== 配置区（按需修改） ======
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

# DEBUG=1 会在后台以 bash -x 启动并记录详细 trace
DEBUG="${DEBUG:-0}"

# ===== 路径与文件 =====
mkdir -p /data/jenkins 2>/dev/null || true
LOG_FILE="${LOG_FILE:-/data/jenkins/jenkins_upgrade.log}"
BG_LOG="${BG_LOG:-$LOG_FILE}"
PIDFILE="${PIDFILE:-/data/jenkins/jenkins_auto_upgrade.pid}"
BUILD_ENV_FILE="${BUILD_ENV_FILE:-/data/jenkins/jenkins_auto_upgrade_build_env.${BUILD_ID:-$$}.env}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ====== 日志函数 ======
log() {
    local msg="[$(date '+%F %T')] $1"
    echo "$msg" >&2
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}
warn() { log "WARN: $1"; }
error_exit() {
    log "ERROR: $1"
    publish_results_to_build "FAILURE" || true
    [[ -n "${JENKINS_AUTO_UPGRADE_DAEMONIZED:-}" ]] && [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
}

trap '[[ -n "${JENKINS_AUTO_UPGRADE_DAEMONIZED:-}" ]] && [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE" 2>/dev/null || true' EXIT

# ====== 后台化（保持原逻辑） ======
is_pidfile_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 && return 0 || return 1
}

if [[ -n "${BUILD_ID:-}" && -z "${JENKINS_AUTO_UPGRADE_DAEMONIZED:-}" ]]; then
  if is_pidfile_running; then
    echo "Background upgrade already running (pid $(cat "$PIDFILE")) -- exiting foreground." >&2
    exit 0
  fi

  {
    printf '%s\n' "export BUILD_ID='${BUILD_ID:-}'"
    printf '%s\n' "export BUILD_NUMBER='${BUILD_NUMBER:-}'"
    printf '%s\n' "export JOB_NAME='${JOB_NAME:-}'"
    printf '%s\n' "export BUILD_URL='${BUILD_URL:-}'"
  } > "$BUILD_ENV_FILE"
  chmod 0600 "$BUILD_ENV_FILE" 2>/dev/null || true

  echo "Detected Jenkins build environment (BUILD_ID=${BUILD_ID}), launching detached background process..." >&2
  export JENKINS_AUTO_UPGRADE_DAEMONIZED=1

  if [[ "$DEBUG" == "1" ]]; then
    setsid nohup /bin/bash -x "$0" "$@" > "$BG_LOG" 2>&1 < /dev/null &
  else
    setsid nohup /bin/bash "$0" "$@" > "$BG_LOG" 2>&1 < /dev/null &
  fi

  sleep 0.2
  echo $! > "$PIDFILE"
  chmod 0644 "$PIDFILE" 2>/dev/null || true

  echo "Launched background process pid=$! (log: ${BG_LOG}). Exiting foreground build." >&2
  exit 0
fi

# 后台进程启动时恢复构建环境（若存在）
if [[ -n "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE:-}" && -f "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE}"
  rm -f "${JENKINS_AUTO_UPGRADE_BUILD_ENV_FILE}" 2>/dev/null || true
elif [[ -f "${BUILD_ENV_FILE:-}" ]]; then
  # shellcheck disable=SC1090
  source "${BUILD_ENV_FILE}"
  rm -f "${BUILD_ENV_FILE}" 2>/dev/null || true
fi

# 后台进程写 pidfile
if [[ -n "${JENKINS_AUTO_UPGRADE_DAEMONIZED:-}" ]]; then
  echo $$ > "$PIDFILE"
  chmod 0644 "$PIDFILE" 2>/dev/null || true
  log "Background process started, pid=$(cat "$PIDFILE") (BG_LOG=${BG_LOG})"
fi

# ====== 依赖检查 ======
check_dependencies() {
  local missing=()
  for cmd in curl unzip java; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error_exit "缺少依赖: ${missing[*]}"
  fi
  log "依赖检查通过"
}

get_auth_params() {
  if [[ -n "${JENKINS_API_TOKEN:-}" ]]; then
    # 以便后续未加引号的展开可以被 curl 识别为两个参数：-u user:token
    echo "-u" "${JENKINS_USER}:${JENKINS_API_TOKEN}"
  else
    error_exit "未配置 JENKINS_API_TOKEN（请通过 Jenkins Credentials 注入）"
  fi
}

# ====== 兼容且安全的：解析主机并返回 IP 列表（不使用 nameref / 关联数组） ======
# 用法：
#   resolve_host_ips <host> <out_var_name>
# 例如：
#   resolve_host_ips "updates.jenkins.io" ips
#   for ip in "${ips[@]}"; do ...
resolve_host_ips() {
  local host="$1"
  local out_var="${2:-}"
  local ips_list=""   # 用空格分隔的唯一 IP 列表
  local line ip

  # 优先 dig -> getent -> host
  if command -v dig >/dev/null 2>&1; then
    while IFS= read -r line; do
      line="${line%%$'\r'}"
      if [[ -n "$line" && "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ " ${ips_list} " != *" ${line} "* ]]; then
          ips_list="${ips_list:+$ips_list }${line}"
        fi
      fi
    done < <(dig +short "$host" 2>/dev/null || true)

  elif command -v getent >/dev/null 2>&1 && getent hosts "$host" >/dev/null 2>&1; then
    while IFS= read -r line; do
      ip=$(printf '%s' "$line" | awk '{print $1}')
      if [[ -n "$ip" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ " ${ips_list} " != *" ${ip} "* ]]; then
          ips_list="${ips_list:+$ips_list }${ip}"
        fi
      fi
    done < <(getent hosts "$host" 2>/dev/null || true)

  elif command -v host >/dev/null 2>&1; then
    while IFS= read -r line; do
      ip=$(printf '%s' "$line" | awk '/has address/ {print $4}')
      if [[ -n "$ip" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if [[ " ${ips_list} " != *" ${ip} "* ]]; then
          ips_list="${ips_list:+$ips_list }${ip}"
        fi
      fi
    done < <(host "$host" 2>/dev/null || true)
  fi

  if [[ -z "${out_var}" ]]; then
    return 1
  fi

  # 初始化目标数组为空（避免 set -u 报错）
  eval "$out_var=()"

  # 将空格分隔的 ips_list 分割并逐项追加到目标数组
  local ip_item
  for ip_item in ${ips_list}; do
    [[ -z "$ip_item" ]] && continue
    eval "$out_var+=(\"$ip_item\")"
  done

  return 0
}

# ====== 通用 curl wrapper：针对 URL 解析所有 A 记录并按 IP 逐个尝试（使用 --resolve） ======
# 用法：
#   curl_with_resolve <url> <curl-opts...>
# 返回：curl 的退出码，STDOUT/STDERR 与直接调用 curl 保持一致。
# 说明：该函数会先尝试系统默认解析（不加 --resolve），如失败则按解析到的 IP 逐个加 --resolve 重试。
curl_with_resolve() {
  local url="$1"
  shift || true
  local opts=("$@")

  # 解析 scheme/host/port
  local scheme rest hostport host port
  scheme="${url%%:*}"
  rest="${url#*://}"
  hostport="${rest%%/*}"
  if [[ "$hostport" == *:* ]]; then
    host="${hostport%%:*}"
    port="${hostport##*:}"
  else
    host="$hostport"
    if [[ "$scheme" == "https" ]]; then port=443; else port=80; fi
  fi

  local ips=()
  resolve_host_ips "$host" ips || true

  local tries=()
  tries+=("")
  local ip
  for ip in "${ips[@]:-}"; do
    tries+=("$ip")
  done

  local attempt=0 rc=0
  for ip in "${tries[@]:-}"; do
    attempt=$((attempt+1))
    local curl_cmd=(curl "${opts[@]}")
    if [[ -n "$ip" ]]; then
      curl_cmd+=(--resolve "${host}:${port}:${ip}")
      log "curl_with_resolve: 尝试 ${url} -> IP ${ip} (尝试 ${attempt}/${#tries[@]})"
    else
      log "curl_with_resolve: 尝试 ${url} -> 使用系统解析 (尝试 ${attempt}/${#tries[@]})"
    fi

    # 直接执行，让 stdout/stderr 行为与 curl 一致
    "${curl_cmd[@]}"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0
    fi

    log "curl_with_resolve: 请求返回非 0（${rc}），将尝试下一个 IP（若有）"
    # 小间隔，避免短时间连续失败
    sleep 1
  done

  return $rc
}

# ====== 获取当前 Jenkins 版本（使用 X-Jenkins header） ======
get_current_version() {
  local auth_params
  auth_params=$(get_auth_params || true)
  local version tmpf
  tmpf=$(mktemp) || { printf ''; return 0; }
  trap 'rm -f "$tmpf"' RETURN

  # 先尝试带鉴权请求（部分实例需要登录页面 header）
  if curl_with_resolve "${JENKINS_URL}" -sI --connect-timeout 10 --max-time 30 ${auth_params} -o "$tmpf" 2>/dev/null; then
    version=$(grep -i "^X-Jenkins:" "$tmpf" | awk '{print $2}' | tr -d '\r\n' || true)
  fi

  # 若无版本信息，再尝试不带鉴权的请求
  if [[ -z "${version}" ]]; then
    if curl_with_resolve "${JENKINS_URL}" -sI --connect-timeout 10 --max-time 30 -o "$tmpf" 2>/dev/null; then
      version=$(grep -i "^X-Jenkins:" "$tmpf" | awk '{print $2}' | tr -d '\r\n' || true)
    fi
  fi

  if [[ -z "$version" ]]; then
    error_exit "无法获取 Jenkins 当前版本"
  fi
  echo "$version"
}

# ====== 解析 update-center（仅返回版本字符串） ======
get_latest_version() {
  local current="$1"
  local tmpf; tmpf=$(mktemp) || { printf ''; return 0; }
  trap 'rm -f "$tmpf"' RETURN

  # 使用 curl_with_resolve 下载 update center
  curl_with_resolve "${UPDATE_CENTER_URL}" -sL --connect-timeout "$CURL_TIMEOUT" --max-time 120 --insecure -o "$tmpf" || true
  if [[ ! -s "$tmpf" ]]; then
    log "WARN: update-center 返回空"
    printf ''
    return 0
  fi

  # 去掉 JSONP 包装（若存在）
  if grep -q '^updateCenter' "$tmpf" 2>/dev/null; then
    sed -n '1,$p' "$tmpf" | sed '1s/^updateCenter(//' | sed -e '$s/);$//' > "${tmpf}.json" 2>/dev/null || true
    mv -f "${tmpf}.json" "$tmpf" 2>/dev/null || true
  fi

  local latest=""
  if command -v jq >/dev/null 2>&1; then
    latest=$(jq -r '.core.version // empty' "$tmpf" 2>/dev/null || true)
  fi
  if [[ -z "$latest" ]]; then
    latest=$(grep -Po '"core"\s*:\s*\{[^}]*"version"\s*:\s*"\K[^"]+' "$tmpf" 2>/dev/null | head -n1 || true)
  fi
  if [[ -z "$latest" ]]; then
    latest=$(grep -Po '"version"\s*:\s*"\K[0-9][^"]+' "$tmpf" 2>/dev/null | head -n1 || true)
  fi

  printf '%s' "${latest:-}"
  return 0
}

# ====== 下载/校验 WAR（支持逐 IP 下载尝试 via curl --resolve，带进度显示） ======
download_war_by_version() {
  local version="$1" out="$2"
  local url="https://updates.jenkins.io/download/war/${version}/jenkins.war"
  local tmp="${out}.part.$$"
  local attempt=0 max_attempts=6

  # per-attempt 超时（秒）与速率阈值（bytes/sec）
  local per_attempt_max=120         # 每次尝试的最大总时长（s）
  local per_connect_timeout=10      # connect 阶段超时（s）
  local speed_limit=1024            # bytes/sec（1 KB/s）
  local speed_time=30               # 若低于 speed_limit 持续秒数则中断

  # 解析 scheme/host/port
  local scheme rest hostport host port
  scheme="${url%%:*}"
  rest="${url#*://}"
  hostport="${rest%%/*}"
  if [[ "$hostport" == *:* ]]; then
    host="${hostport%%:*}"
    port="${hostport##*:}"
  else
    host="$hostport"
    if [[ "$scheme" == "https" ]]; then port=443; else port=80; fi
  fi

  # 获取 IP 列表（若有）
  local ips=()
  resolve_host_ips "$host" ips || true

  # 构建尝试序列：系统解析一次，然后按解析到的 IP 逐个尝试
  local tries=()
  tries+=("")  # 先试系统解析
  local ip
  for ip in "${ips[@]:-}"; do
    tries+=("$ip")
  done

  # curl 公共选项（强制 IPv4 可按需移除）
  local base_curl_opts=( -fSL --create-dirs --retry 3 --retry-delay 5 --retry-connrefused -4 \
    --connect-timeout "$per_connect_timeout" --max-time "$per_attempt_max" \
    --speed-limit "$speed_limit" --speed-time "$speed_time" --no-keepalive )

  # 如果有 timeout 工具，使用它包裹 curl（作为额外保险）
  local use_timeout=0
  if command -v timeout >/dev/null 2>&1; then
    use_timeout=1
  fi

  # 检测是否有 stdbuf，用于让 tee 行缓冲，减少进度延迟
  local has_stdbuf=0
  if command -v stdbuf >/dev/null 2>&1; then
    has_stdbuf=1
  fi

  for ip in "${tries[@]:-}"; do
    attempt=$((attempt+1))
    if (( attempt > max_attempts )); then
      log "达到最大尝试次数 ${max_attempts}，停止重试"
      break
    fi

    local curl_opts=( "${base_curl_opts[@]:-}" )
    if [[ -n "$ip" ]]; then
      log "下载尝试 ${attempt}/${max_attempts} -> ${url} (尝试 IP: ${ip})"
      curl_opts+=( --resolve "${host}:${port}:${ip}" )
    else
      log "下载尝试 ${attempt}/${max_attempts} -> ${url} (使用系统解析器)"
    fi

    # 清理残留 tmp
    rm -f "${tmp}" 2>/dev/null || true

    # 执行 curl（带进度条），把 stderr 实时 tee 到诊断文件和主日志
    if [[ "$use_timeout" -eq 1 ]]; then
      if [[ $has_stdbuf -eq 1 ]]; then
        timeout "${per_attempt_max}s" curl "${curl_opts[@]:-}" --progress-bar -o "${tmp}" "${url}" 2> >(stdbuf -oL tee -a /tmp/jenkins_war_download.err >> "$LOG_FILE")
      else
        timeout "${per_attempt_max}s" curl "${curl_opts[@]:-}" --progress-bar -o "${tmp}" "${url}" 2> >(tee -a /tmp/jenkins_war_download.err >> "$LOG_FILE")
      fi
    else
      if [[ $has_stdbuf -eq 1 ]]; then
        curl "${curl_opts[@]:-}" --progress-bar -o "${tmp}" "${url}" 2> >(stdbuf -oL tee -a /tmp/jenkins_war_download.err >> "$LOG_FILE")
      else
        curl "${curl_opts[@]:-}" --progress-bar -o "${tmp}" "${url}" 2> >(tee -a /tmp/jenkins_war_download.err >> "$LOG_FILE")
      fi
    fi

    local rc=$?
    if [[ $rc -ne 0 ]]; then
      log "curl 下载失败 (exit=${rc}), 详情见 /tmp/jenkins_war_download.err"
      tail -n 200 /tmp/jenkins_war_download.err 2>/dev/null | sed -n '1,200p' >> "$LOG_FILE" 2>/dev/null || true
      rm -f "${tmp}" 2>/dev/null || true
      sleep 2
      continue
    fi

    if [[ ! -s "${tmp}" ]]; then
      log "下载文件为空，继续尝试..."
      rm -f "${tmp}" 2>/dev/null || true
      sleep 1
      continue
    fi

    if unzip -t "${tmp}" >/dev/null 2>&1; then
      mv -f "${tmp}" "${out}"
      log "WAR 下载并校验通过: ${out}"
      rm -f /tmp/jenkins_war_download.err 2>/dev/null || true
      return 0
    else
      log "下载文件非有效 ZIP/WAR，可能在代理/中间人处被替换，继续尝试..."
      tail -n 200 /tmp/jenkins_war_download.err 2>/dev/null | sed -n '1,200p' >> "$LOG_FILE" 2>/dev/null || true
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
  rm -rf "$dest"
  mkdir -p "$dest"
  unzip -q "$war" -d "$dest" || return 1
  [[ -d "${dest}/WEB-INF" ]] || return 1
  return 0
}

backup_old_version() {
  local dir="$1"
  local bak="${dir}_$(date +%Y%m%d_%H%M%S)"
  if [[ -d "$dir" ]]; then
    log "备份 ${dir} -> ${bak}"
    mv "$dir" "$bak"
  fi
  echo "$bak"
}

deploy_new_version() {
  local src="$1" dst="$2"
  rm -rf "$dst" || true
  mkdir -p "$dst"
  cp -a "${src}/." "$dst/" || return 1
  [[ -d "${dst}/WEB-INF" ]] || return 1
  if id -u "${JENKINS_USER}" >/dev/null 2>&1; then
    chown -R "${JENKINS_USER}:${JENKINS_USER}" "$dst" 2>/dev/null || true
  fi
  return 0
}

# ====== Crumb 与 safeRestart ======
get_crumb_header() {
  local json
  json=$(curl_with_resolve "${JENKINS_URL}crumbIssuer/api/json" -s --connect-timeout 10 --max-time 30 -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" 2>/dev/null || true)
  [[ -n "$json" ]] || { printf ''; return 0; }
  local field val
  field=$(echo "$json" | grep -oP '"crumbRequestField"\s*:\s*"\K[^"]+' 2>/dev/null || true)
  val=$(echo "$json" | grep -oP '"crumb"\s*:\s*"\K[^"]+' 2>/dev/null || true)
  if [[ -n "$field" && -n "$val" ]]; then
    printf '%s' "${field}:${val}"
  else
    printf ''
  fi
}

safe_restart_jenkins() {
  log "调用 /safeRestart..."
  local crumb; crumb=$(get_crumb_header || true)
  local header_opts=()
  if [[ -n "$crumb" ]]; then
    header_opts+=(-H "${crumb%%:*}: ${crumb#*:}")
  fi
  local code
  code=$(curl_with_resolve "${JENKINS_URL}/safeRestart" -s -o /data/jenkins/jenkins_safe_restart_resp.txt -w "%{http_code}" --user "${JENKINS_USER}:${JENKINS_API_TOKEN}" -X POST "${header_opts[@]:-}" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|201|302)$ ]]; then
    log "/safeRestart 调用成功 (HTTP $code)"
    rm -f /data/jenkins/jenkins_safe_restart_resp.txt 2>/dev/null || true
    return 0
  elif [[ "$code" == "401" ]]; then
    log "/safeRestart 返回 401，鉴权失败"
    cat /data/jenkins/jenkins_safe_restart_resp.txt 2>/dev/null || true
    rm -f /data/jenkins/jenkins_safe_restart_resp.txt 2>/dev/null || true
    return 2
  else
    log "/safeRestart 调用失败 HTTP $code"
    cat /data/jenkins/jenkins_safe_restart_resp.txt 2>/dev/null || true
    rm -f /data/jenkins/jenkins_safe_restart_resp.txt 2>/dev/null || true
    return 1
  fi
}

wait_for_restart() {
  log "等待 Jenkins 恢复（最多 ${RESTART_WAIT_MAX}s）..."
  sleep 15
  local waited=0 interval=10
  while [[ $waited -lt $RESTART_WAIT_MAX ]]; do
    local code
    code=$(curl_with_resolve "${JENKINS_URL}/login" -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    if [[ "$code" == "200" || "$code" == "403" ]]; then
      log "Jenkins 恢复 (HTTP ${code})"
      return 0
    fi
    log "等待中... ${waited}s (HTTP ${code})"
    sleep $interval
    waited=$((waited + interval))
  done
  warn "等待超时"
  return 1
}

# ====== 写回构建描述 ======
publish_results_to_build() {
  local status="${1:-SUCCESS}"
  local build_url="${BUILD_URL:-}"
  if [[ -z "$build_url" && -n "${JOB_NAME:-}" && -n "${BUILD_NUMBER:-}" && -n "${JENKINS_URL:-}" ]]; then
    IFS='/' read -ra parts <<< "$JOB_NAME"
    local path=""
    for seg in "${parts[@]}"; do path="${path}/job/${seg}"; done
    build_url="${JENKINS_URL%/}${path}/${BUILD_NUMBER}/"
  fi
  if [[ -z "$build_url" ]]; then
    log "无法写回构建：BUILD_URL 或 JOB_NAME/BUILD_NUMBER 不可用"
    return 0
  fi

  local tail_lines=500
  local excerpt
  if [[ -f "$LOG_FILE" ]]; then
    excerpt=$(tail -n ${tail_lines} "$LOG_FILE" 2>/dev/null || echo "(读取日志失败)")
  else
    excerpt="(未找到日志文件)"
  fi

  local desc
  desc="Jenkins 自动升级任务已完成。状态: ${status}
时间: $(date '+%F %T')

日志摘要（最后 ${tail_lines} 行）:
<pre>$(echo "$excerpt" | sed 's/<\//\\u003C\//g; s/</\\u003C/g')</pre>

完整日志请查看主机上的 ${LOG_FILE}（如可访问）。"

  local crumb; crumb=$(get_crumb_header || true)
  local extra=()
  if [[ -n "$crumb" ]]; then
    extra+=(-H "${crumb%%:*}: ${crumb#*:}")
  fi

  log "写回构建描述到 ${build_url}submitDescription"
  curl_with_resolve "${build_url}submitDescription" -s --user "${JENKINS_USER}:${JENKINS_API_TOKEN}" "${extra[@]:-}" --data-urlencode "description=${desc}" >/dev/null 2>&1 || {
    log "写回构建描述失败（可能无权限或 crumb 问题）"
    return 1
  }
  log "已写回构建描述"
  return 0
}

# ====== 主升级流程 ======
perform_upgrade() {
  log "========== Jenkins 自动升级开始 =========="
  check_dependencies

  local current
  current=$(get_current_version)
  log "当前 Jenkins 版本: ${current}"

  local latest
  latest=$(get_latest_version "$current" || true)
  if [[ -z "$latest" ]]; then
    log "未能解析到最新版本（update-center 返回空），脚本将退出以避免盲目覆盖"
    publish_results_to_build "NO_INFO" || true
    return 0
  fi
  log "Update Center 最新版本: ${latest}"

  if [[ "$current" == "$latest" ]]; then
    log "当前已为最新版本：${current}，无需升级"
    publish_results_to_build "NO_CHANGE" || true
    return 0
  fi

  log "开始升级：${current} -> ${latest}"

  mkdir -p "$TMP_DIR"
  local war_path="${TMP_DIR}/${WAR_FILE}"
  if ! download_war_by_version "$latest" "$war_path"; then
    log "WAR 下载失败，退出"
    publish_results_to_build "DOWNLOAD_FAILED" || true
    return 1
  fi

  local extract_dir="${TMP_DIR}/extracted"
  if ! extract_war "$war_path" "$extract_dir"; then
    log "解压失败，退出"
    publish_results_to_build "EXTRACT_FAILED" || true
    return 1
  fi

  backup_old_version "$APP_DIR"
  if ! deploy_new_version "$extract_dir" "$APP_DIR"; then
    log "部署失败，退出"
    publish_results_to_build "DEPLOY_FAILED" || true
    return 1
  fi

  safe_restart_jenkins
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    publish_results_to_build "AUTH_FAILURE" || true
    error_exit "safeRestart 需要鉴权（401），停止"
  elif [[ $rc -ne 0 ]]; then
    publish_results_to_build "RESTART_FAILED" || true
    error_exit "safeRestart 调用失败"
  fi

  wait_for_restart || warn "等待重启超时"

  local newv; newv=$(get_current_version || true)
  log "升级后 Jenkins 版本: ${newv:-unknown}"
  if [[ -n "$newv" && "$newv" == "$latest" ]]; then
    log "升级成功：${current} -> ${newv}"
    publish_results_to_build "SUCCESS" || true
  else
    warn "版本未按预期更新（期望 ${latest}，实际 ${newv:-unknown}）"
    publish_results_to_build "MISMATCH" || true
  fi

  rm -rf "${TMP_DIR}" 2>/dev/null || true
  log "临时文件清理完成"
  return 0
}

# ====== 入口：循环检测并升级（最多若干轮） ======
main() {
  log "脚本启动（日志: ${LOG_FILE}）"

  local max_cycles=5
  local i=0
  while [[ $i -lt $max_cycles ]]; do
    i=$((i+1))
    log "第 ${i} 轮检测..."
    if ! perform_upgrade; then
      log "本轮升级流程返回非 0，退出主循环"
      exit 1
    fi
    log "等待 30 秒后再次检测..."
    sleep 30
    local cur; cur=$(get_current_version || true)
    local lat; lat=$(get_latest_version "$cur" || true)
    if [[ -z "$lat" || "$cur" == "$lat" ]]; then
      log "无新版本或无法解析到新版本，退出循环"
      break
    fi
    log "检测到新版本 ${lat}，继续下一轮..."
  done

  log "脚本执行完毕"
  publish_results_to_build "FINISHED" || true
}

main "$@"
