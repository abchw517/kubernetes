#!/usr/bin/env bash
# ==============================================================================
# pod-start-time-check.sh
# Kubernetes Pod 启动耗时巡检工具
#
# 启动耗时口径：Pod Ready condition.lastTransitionTime -
#               PodScheduled condition.lastTransitionTime
#
# 功能：
#   1. 默认扫描全集群所有命名空间；-n/--namespace 指定单命名空间
#   2. Pod 启动耗时按降序输出
#   3. 输出 Namespace / Deployment / Pod / 启动耗时
#   4. >120s 黄色，>180s 红色（阈值可配置）
#   5. >120s 的记录生成 HTML 报告并通过企业微信群机器人发送
#   6. 日志、互斥锁、dry-run、异常清理、依赖检查
#   7. RBAC 最小权限预检、kubectl API/命令双层超时
#
# 依赖：bash 4.0+、kubectl、jq、GNU date、GNU timeout、sort、flock
#       启用企业微信发送时额外依赖 curl
# ==============================================================================

set -Eeuo pipefail
umask 077
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.1.0"

# ------------------------------- 默认配置 -------------------------------------
NAMESPACE=""
DRY_RUN=false
WARN_SECONDS="${WARN_SECONDS:-120}"
CRITICAL_SECONDS="${CRITICAL_SECONDS:-180}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-30s}"
KUBECTL_COMMAND_TIMEOUT="${KUBECTL_COMMAND_TIMEOUT:-45s}"

LOG_DIR="${LOG_DIR:-/data/logs/pod-start-time-check}"
REPORT_DIR="${REPORT_DIR:-${LOG_DIR}/reports}"
LOCK_FILE="${LOCK_FILE:-/tmp/pod-start-time-check.lock}"
WECHAT_WEBHOOK_URL="${WECHAT_WEBHOOK_URL:-}"

LOG_FILE=""
TMP_DIR=""
RESULT_TSV=""
SLOW_TSV=""
REPORT_FILE=""

# 统计信息
TOTAL_PODS=0
VALID_DEPLOYMENT_PODS=0
SKIPPED_NO_READY=0
SKIPPED_NO_DEPLOYMENT=0
WARN_COUNT=0
CRITICAL_COUNT=0

# 颜色
readonly COLOR_RED=$'\033[31m'
readonly COLOR_YELLOW=$'\033[33m'
readonly COLOR_GREEN=$'\033[32m'
readonly COLOR_CYAN=$'\033[36m'
readonly COLOR_RESET=$'\033[0m'

usage() {
    cat <<'USAGE'
Usage:
  pod-start-time-check.sh [options]

Options:
  -n, --namespace <ns>       只扫描指定命名空间；默认扫描全集群
      --dry-run              只扫描和输出，不生成 HTML、不发送企业微信
      --warn-seconds <sec>   黄色告警阈值，默认 120
      --critical-seconds <s> 红色告警阈值，默认 180
      --request-timeout <t>  Kubernetes API 单次请求超时，默认 30s
      --command-timeout <t>  kubectl 整体命令超时，默认 45s
      --webhook-url <url>    企业微信群机器人 Webhook；建议使用环境变量 WECHAT_WEBHOOK_URL
      --log-dir <dir>        日志目录，默认 /data/logs/pod-start-time-check
      --report-dir <dir>     HTML 报告目录，默认 <log-dir>/reports
      --lock-file <path>     锁文件，默认 /tmp/pod-start-time-check.lock
  -h, --help                 显示帮助
  -v, --version              显示版本

Examples:
  # 扫描全集群
  ./pod-start-time-check.sh

  # 只扫描 pro-yunfan
  ./pod-start-time-check.sh -n pro-yunfan

  # Dry-run：只检查，不生成报告、不通知
  ./pod-start-time-check.sh --dry-run

  # 自定义阈值
  ./pod-start-time-check.sh --warn-seconds 90 --critical-seconds 150

  # 使用企业微信机器人
  export WECHAT_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REDACTED'
  ./pod-start-time-check.sh
USAGE
}

log() {
    local level="$1"
    shift
    local now line
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    line="${now} ${SCRIPT_NAME} [${level}] $*"

    # 日志文件初始化前，仅输出 stderr；初始化后同时落盘。
    if [[ -n "${LOG_FILE}" ]]; then
        printf '%s\n' "${line}" | tee -a "${LOG_FILE}" >&2
    else
        printf '%s\n' "${line}" >&2
    fi
}

fatal() {
    log "ERROR" "$*"
    exit 1
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            -n|--namespace)
                (($# >= 2)) || fatal "$1 缺少命名空间参数"
                NAMESPACE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --warn-seconds)
                (($# >= 2)) || fatal "$1 缺少秒数参数"
                WARN_SECONDS="$2"
                shift 2
                ;;
            --critical-seconds)
                (($# >= 2)) || fatal "$1 缺少秒数参数"
                CRITICAL_SECONDS="$2"
                shift 2
                ;;
            --request-timeout)
                (($# >= 2)) || fatal "$1 缺少超时时间"
                KUBECTL_REQUEST_TIMEOUT="$2"
                shift 2
                ;;
            --command-timeout)
                (($# >= 2)) || fatal "$1 缺少超时时间"
                KUBECTL_COMMAND_TIMEOUT="$2"
                shift 2
                ;;
            --webhook-url)
                (($# >= 2)) || fatal "$1 缺少 URL 参数"
                WECHAT_WEBHOOK_URL="$2"
                log "WARN" "--webhook-url 可能暴露在 shell history/进程参数中，生产环境建议使用 WECHAT_WEBHOOK_URL 环境变量"
                shift 2
                ;;
            --log-dir)
                (($# >= 2)) || fatal "$1 缺少目录参数"
                LOG_DIR="$2"
                shift 2
                ;;
            --report-dir)
                (($# >= 2)) || fatal "$1 缺少目录参数"
                REPORT_DIR="$2"
                shift 2
                ;;
            --lock-file)
                (($# >= 2)) || fatal "$1 缺少路径参数"
                LOCK_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
                exit 0
                ;;
            *)
                fatal "未知参数: $1"
                ;;
        esac
    done
}

validate_config() {
    is_positive_integer "${WARN_SECONDS}" || fatal "--warn-seconds 必须是非负整数"
    is_positive_integer "${CRITICAL_SECONDS}" || fatal "--critical-seconds 必须是非负整数"

    (( CRITICAL_SECONDS > WARN_SECONDS )) || \
        fatal "critical 阈值必须大于 warn 阈值: warn=${WARN_SECONDS}, critical=${CRITICAL_SECONDS}"

    [[ -n "${KUBECTL_REQUEST_TIMEOUT}" ]] || fatal "--request-timeout 不能为空"
    [[ -n "${KUBECTL_COMMAND_TIMEOUT}" ]] || fatal "--command-timeout 不能为空"
}

init_runtime() {
    mkdir -p "${LOG_DIR}" || fatal "无法创建日志目录: ${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/pod-start-time-check-$(date '+%Y%m%d').log"
    touch "${LOG_FILE}" || fatal "无法写入日志文件: ${LOG_FILE}"

    TMP_DIR="$(mktemp -d /tmp/pod-start-time-check.XXXXXX)"
    RESULT_TSV="${TMP_DIR}/results.tsv"
    SLOW_TSV="${TMP_DIR}/slow.tsv"
    : > "${RESULT_TSV}"
    : > "${SLOW_TSV}"
}

cleanup() {
    local rc=$?
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
    exit "${rc}"
}

on_error() {
    local rc=$?
    local line_no="$1"
    log "ERROR" "脚本异常退出: rc=${rc}, line=${line_no}"
    exit "${rc}"
}

acquire_lock() {
    local lock_dir
    lock_dir="$(dirname "${LOCK_FILE}")"
    mkdir -p "${lock_dir}" || fatal "无法创建锁目录: ${lock_dir}"

    exec {LOCK_FD}>"${LOCK_FILE}"
    if ! flock -n "${LOCK_FD}"; then
        fatal "已有实例正在运行，锁文件: ${LOCK_FILE}"
    fi

    printf '%s\n' "$$" 1>&"${LOCK_FD}"
    log "INFO" "获取运行锁成功: ${LOCK_FILE}, pid=$$"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "缺少依赖命令: $1"
}

# 所有访问 Kubernetes API 的 kubectl 命令统一经过双层超时保护。
# 第一层：kubectl --request-timeout，限制单次 API Server 请求。
# 第二层：GNU timeout，限制整个 kubectl 进程的最大执行时间。
kubectl_safe() {
    local rc=0
    local action="${1:-unknown}"

    timeout \
        --signal=TERM \
        --kill-after=5s \
        "${KUBECTL_COMMAND_TIMEOUT}" \
        kubectl \
        --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" \
        "$@" || rc=$?

    if (( rc == 124 || rc == 137 )); then
        log "ERROR" "kubectl 命令整体执行超时: action=${action}, command_timeout=${KUBECTL_COMMAND_TIMEOUT}"
    fi

    return "${rc}"
}

# RBAC 最小权限预检。
# 脚本只需要：pods:list、replicasets.apps:list。
# 不读取 Namespace 对象，不需要 namespaces:get。
check_rbac_permissions() {
    local -a auth_scope=()
    local pods_can_i rs_can_i

    if [[ -n "${NAMESPACE}" ]]; then
        auth_scope=(-n "${NAMESPACE}")
    else
        auth_scope=(--all-namespaces)
    fi

    if ! pods_can_i="$(kubectl_safe auth can-i list pods "${auth_scope[@]}" 2>/dev/null)"; then
        fatal "RBAC 检查失败：无法验证 pods:list 权限，范围=${NAMESPACE:-ALL_NAMESPACES}"
    fi
    [[ "${pods_can_i}" == "yes" ]] || \
        fatal "RBAC 权限不足：需要 pods:list，范围=${NAMESPACE:-ALL_NAMESPACES}"

    if ! rs_can_i="$(kubectl_safe auth can-i list replicasets.apps "${auth_scope[@]}" 2>/dev/null)"; then
        fatal "RBAC 检查失败：无法验证 replicasets.apps:list 权限，范围=${NAMESPACE:-ALL_NAMESPACES}"
    fi
    [[ "${rs_can_i}" == "yes" ]] || \
        fatal "RBAC 权限不足：需要 replicasets.apps:list，范围=${NAMESPACE:-ALL_NAMESPACES}"

    log "INFO" "RBAC 最小权限检查通过: pods:list, replicasets.apps:list, scope=${NAMESPACE:-ALL_NAMESPACES}"
}

preflight() {
    local cmd
    for cmd in kubectl jq date sort flock awk sed mktemp timeout; do
        require_cmd "${cmd}"
    done

    # date -d 是 GNU date 能力，必须验证。
    date -d '2026-01-01T00:00:00Z' '+%s' >/dev/null 2>&1 || \
        fatal "当前 date 不支持 -d RFC3339 时间解析，需要 GNU coreutils date"

    if [[ "${DRY_RUN}" == false && -n "${WECHAT_WEBHOOK_URL}" ]]; then
        require_cmd curl
    fi

    timeout "${KUBECTL_COMMAND_TIMEOUT}" true >/dev/null 2>&1 || \
        fatal "--command-timeout 格式无效: ${KUBECTL_COMMAND_TIMEOUT}"

    kubectl --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" version --client >/dev/null 2>&1 || \
        fatal "kubectl client 不可用，或 --request-timeout 格式无效: ${KUBECTL_REQUEST_TIMEOUT}"

    check_rbac_permissions

    log "INFO" "预检查通过: request_timeout=${KUBECTL_REQUEST_TIMEOUT}, command_timeout=${KUBECTL_COMMAND_TIMEOUT}"
}

kubectl_scope_args() {
    if [[ -n "${NAMESPACE}" ]]; then
        printf '%s\0' '-n' "${NAMESPACE}"
    else
        printf '%s\0' '-A'
    fi
}

fetch_cluster_data() {
    local -a scope_args=()
    local pod_json="${TMP_DIR}/pods.json"
    local rs_json="${TMP_DIR}/replicasets.json"

    while IFS= read -r -d '' arg; do
        scope_args+=("${arg}")
    done < <(kubectl_scope_args)

    log "INFO" "开始拉取 Pod 与 ReplicaSet 数据，范围: ${NAMESPACE:-ALL_NAMESPACES}"

    kubectl_safe get pods "${scope_args[@]}" -o json > "${pod_json}" || \
        fatal "获取 Pod 数据失败（可能是 RBAC、Namespace 不存在、API 请求超时或集群连接异常）"

    kubectl_safe get replicasets.apps "${scope_args[@]}" -o json > "${rs_json}" || \
        fatal "获取 ReplicaSet 数据失败（可能是 RBAC、Namespace 不存在、API 请求超时或集群连接异常）"

    TOTAL_PODS="$(jq '.items | length' "${pod_json}")"
    log "INFO" "集群数据拉取完成: pods=${TOTAL_PODS}, replicasets=$(jq '.items | length' "${rs_json}")"
}

build_deployment_map() {
    local rs_json="${TMP_DIR}/replicasets.json"
    local map_file="${TMP_DIR}/rs-deployment.tsv"

    jq -r '
      .items[]
      | .metadata.namespace as $ns
      | .metadata.name as $rs
      | ((.metadata.ownerReferences // [])
          | map(select(.kind == "Deployment" and (.controller // false) == true))
          | .[0].name // "-") as $deploy
      | [$ns, $rs, $deploy]
      | @tsv
    ' "${rs_json}" > "${map_file}"

    declare -gA RS_TO_DEPLOYMENT=()

    local ns rs deployment
    while IFS=$'\t' read -r ns rs deployment; do
        [[ -n "${ns}" && -n "${rs}" ]] || continue
        RS_TO_DEPLOYMENT["${ns}/${rs}"]="${deployment}"
    done < "${map_file}"
}

extract_pod_records() {
    local pod_json="${TMP_DIR}/pods.json"
    local pods_tsv="${TMP_DIR}/pods.tsv"

    jq -r '
      .items[]
      | .metadata.namespace as $ns
      | .metadata.name as $pod
      | ((.metadata.ownerReferences // [])
          | map(select((.controller // false) == true))
          | .[0]) as $owner
      | ((.status.conditions // [])
          | map(select(.type == "PodScheduled"))
          | .[0].lastTransitionTime // "") as $scheduled
      | ((.status.conditions // [])
          | map(select(.type == "Ready" and .status == "True"))
          | .[0].lastTransitionTime // "") as $ready
      | [$ns, $pod, ($owner.kind // ""), ($owner.name // ""), $scheduled, $ready]
      | @tsv
    ' "${pod_json}" > "${pods_tsv}"

    local ns pod owner_kind owner_name scheduled ready deployment
    local scheduled_epoch ready_epoch load_seconds

    while IFS=$'\t' read -r ns pod owner_kind owner_name scheduled ready; do
        deployment=""

        case "${owner_kind}" in
            ReplicaSet)
                deployment="${RS_TO_DEPLOYMENT["${ns}/${owner_name}"]:-}"
                ;;
            Deployment)
                # 理论上 Pod 通常由 ReplicaSet 控制，这里兼容直接 Deployment owner 的异常/特殊场景。
                deployment="${owner_name}"
                ;;
            *)
                deployment=""
                ;;
        esac

        if [[ -z "${deployment}" || "${deployment}" == "-" ]]; then
            ((SKIPPED_NO_DEPLOYMENT+=1))
            continue
        fi

        ((VALID_DEPLOYMENT_PODS+=1))

        if [[ -z "${scheduled}" || -z "${ready}" ]]; then
            ((SKIPPED_NO_READY+=1))
            continue
        fi

        if ! scheduled_epoch="$(date -d "${scheduled}" '+%s' 2>/dev/null)"; then
            log "WARN" "无法解析 PodScheduled 时间，跳过: ${ns}/${pod}, value=${scheduled}"
            ((SKIPPED_NO_READY+=1))
            continue
        fi

        if ! ready_epoch="$(date -d "${ready}" '+%s' 2>/dev/null)"; then
            log "WARN" "无法解析 Ready 时间，跳过: ${ns}/${pod}, value=${ready}"
            ((SKIPPED_NO_READY+=1))
            continue
        fi

        load_seconds=$((ready_epoch - scheduled_epoch))
        if (( load_seconds < 0 )); then
            log "WARN" "启动耗时为负数，跳过: ${ns}/${pod}, scheduled=${scheduled}, ready=${ready}"
            continue
        fi

        printf '%s\t%s\t%s\t%d\n' \
            "${ns}" "${deployment}" "${pod}" "${load_seconds}" >> "${RESULT_TSV}"
    done < "${pods_tsv}"

    sort -t $'\t' -k4,4nr -k1,1 -k2,2 -k3,3 "${RESULT_TSV}" -o "${RESULT_TSV}"

    awk -F '\t' -v warn="${WARN_SECONDS}" '$4 > warn' "${RESULT_TSV}" > "${SLOW_TSV}"

    WARN_COUNT="$(awk -F '\t' -v warn="${WARN_SECONDS}" -v critical="${CRITICAL_SECONDS}" \
        '$4 > warn && $4 <= critical {count++} END {print count+0}' "${RESULT_TSV}")"
    CRITICAL_COUNT="$(awk -F '\t' -v critical="${CRITICAL_SECONDS}" \
        '$4 > critical {count++} END {print count+0}' "${RESULT_TSV}")"
}

print_results() {
    local ns deployment pod seconds color

    printf '\n%sPod 启动耗时巡检结果%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%-28s %-48s %-70s %12s\n' "NAMESPACE" "DEPLOYMENT" "POD" "STARTUP(s)"
    printf '%-28s %-48s %-70s %12s\n' \
        '----------------------------' \
        '------------------------------------------------' \
        '----------------------------------------------------------------------' \
        '------------'

    if [[ ! -s "${RESULT_TSV}" ]]; then
        printf '%s未发现可计算启动耗时的 Deployment Pod%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
        return 0
    fi

    while IFS=$'\t' read -r ns deployment pod seconds; do
        color=""
        if (( seconds > CRITICAL_SECONDS )); then
            color="${COLOR_RED}"
        elif (( seconds > WARN_SECONDS )); then
            color="${COLOR_YELLOW}"
        fi

        if [[ -n "${color}" ]]; then
            printf '%b%-28s %-48s %-70s %12ss%b\n' \
                "${color}" "${ns}" "${deployment}" "${pod}" "${seconds}" "${COLOR_RESET}"
        else
            printf '%-28s %-48s %-70s %12ss\n' \
                "${ns}" "${deployment}" "${pod}" "${seconds}"
        fi
    done < "${RESULT_TSV}"

    printf '\n统计: total_pods=%s, deployment_pods=%s, no_ready=%s, non_deployment=%s, >%ss=%s, >%ss=%s\n' \
        "${TOTAL_PODS}" "${VALID_DEPLOYMENT_PODS}" "${SKIPPED_NO_READY}" \
        "${SKIPPED_NO_DEPLOYMENT}" "${WARN_SECONDS}" "$((WARN_COUNT + CRITICAL_COUNT))" \
        "${CRITICAL_SECONDS}" "${CRITICAL_COUNT}"
}

html_escape() {
    local s="$1"
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    s=${s//\'/&#39;}
    printf '%s' "${s}"
}

generate_html_report() {
    local slow_total
    slow_total=$((WARN_COUNT + CRITICAL_COUNT))

    (( slow_total > 0 )) || {
        log "INFO" "没有超过 ${WARN_SECONDS}s 的 Pod，不生成 HTML 报告"
        return 0
    }

    mkdir -p "${REPORT_DIR}" || fatal "无法创建报告目录: ${REPORT_DIR}"
    REPORT_FILE="${REPORT_DIR}/pod-start-time-report-$(date '+%Y%m%d-%H%M%S').html"

    local scope generated_at
    scope="${NAMESPACE:-ALL_NAMESPACES}"
    generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"

    cat > "${REPORT_FILE}" <<EOF_HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kubernetes Pod 启动耗时巡检报告</title>
<style>
body { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif; margin: 24px; color: #222; }
h1 { margin-bottom: 8px; }
.meta { color: #666; margin-bottom: 18px; line-height: 1.7; }
.summary { margin: 16px 0; padding: 12px 16px; background: #f5f7fa; border-radius: 6px; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
th, td { border: 1px solid #ddd; padding: 8px 10px; text-align: left; }
th { background: #f0f2f5; }
.warn { background: #fff7d6; }
.critical { background: #ffe1e1; color: #a8071a; font-weight: 600; }
.num { text-align: right; white-space: nowrap; }
.footer { color: #888; margin-top: 18px; font-size: 12px; }
</style>
</head>
<body>
<h1>Kubernetes Pod 启动耗时巡检报告</h1>
<div class="meta">
  <div><strong>扫描范围：</strong>$(html_escape "${scope}")</div>
  <div><strong>生成时间：</strong>$(html_escape "${generated_at}")</div>
  <div><strong>计算口径：</strong>Ready.lastTransitionTime - PodScheduled.lastTransitionTime</div>
  <div><strong>阈值：</strong>&gt; ${WARN_SECONDS}s 警告，&gt; ${CRITICAL_SECONDS}s 严重</div>
</div>
<div class="summary">
  超过 ${WARN_SECONDS}s：<strong>${slow_total}</strong> 个 Pod；
  其中超过 ${CRITICAL_SECONDS}s：<strong>${CRITICAL_COUNT}</strong> 个 Pod。
</div>
<table>
<thead>
<tr><th>Namespace</th><th>Deployment</th><th>Pod</th><th>启动耗时</th><th>级别</th></tr>
</thead>
<tbody>
EOF_HTML

    local ns deployment pod seconds row_class level
    while IFS=$'\t' read -r ns deployment pod seconds; do
        if (( seconds > CRITICAL_SECONDS )); then
            row_class="critical"
            level="CRITICAL"
        else
            row_class="warn"
            level="WARN"
        fi

        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td><td class="num">%ss</td><td>%s</td></tr>\n' \
            "${row_class}" \
            "$(html_escape "${ns}")" \
            "$(html_escape "${deployment}")" \
            "$(html_escape "${pod}")" \
            "${seconds}" \
            "${level}" >> "${REPORT_FILE}"
    done < "${SLOW_TSV}"

    cat >> "${REPORT_FILE}" <<'EOF_HTML'
</tbody>
</table>
<div class="footer">Generated by pod-start-time-check.sh v2.1.0</div>
</body>
</html>
EOF_HTML

    log "INFO" "HTML 报告已生成: ${REPORT_FILE}"
}

extract_webhook_key() {
    local url="$1"
    local key

    key="$(printf '%s' "${url}" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')"
    [[ -n "${key}" ]] || return 1
    printf '%s' "${key}"
}

wechat_post_json() {
    local payload="$1"
    local response errcode errmsg

    response="$(curl --silent --show-error --fail-with-body \
        --connect-timeout 5 --max-time 15 \
        -H 'Content-Type: application/json' \
        -d "${payload}" \
        "${WECHAT_WEBHOOK_URL}")" || return 1

    errcode="$(jq -r '.errcode // -1' <<< "${response}")"
    errmsg="$(jq -r '.errmsg // "unknown"' <<< "${response}")"

    if [[ "${errcode}" != "0" ]]; then
        log "ERROR" "企业微信发送失败: errcode=${errcode}, errmsg=${errmsg}"
        return 1
    fi

    return 0
}

wechat_send_markdown_summary() {
    local slow_total payload scope
    slow_total=$((WARN_COUNT + CRITICAL_COUNT))
    scope="${NAMESPACE:-ALL_NAMESPACES}"

    payload="$(jq -nc \
        --arg scope "${scope}" \
        --argjson warn_seconds "${WARN_SECONDS}" \
        --argjson critical_seconds "${CRITICAL_SECONDS}" \
        --argjson slow_total "${slow_total}" \
        --argjson critical_total "${CRITICAL_COUNT}" \
        '{
          msgtype: "markdown",
          markdown: {
            content: (
              "### Kubernetes Pod 启动耗时巡检\\n" +
              "> 扫描范围：`" + $scope + "`\\n" +
              "> 超过 " + ($warn_seconds|tostring) + "s：<font color=\"warning\">" + ($slow_total|tostring) + "</font>\\n" +
              "> 超过 " + ($critical_seconds|tostring) + "s：<font color=\"warning\">" + ($critical_total|tostring) + "</font>\\n" +
              "> 详细数据见随后的 HTML 报告文件。"
            )
          }
        }')"

    wechat_post_json "${payload}"
}

wechat_upload_file() {
    local file="$1"
    local key upload_url response errcode errmsg media_id

    key="$(extract_webhook_key "${WECHAT_WEBHOOK_URL}")" || {
        log "ERROR" "无法从企业微信 Webhook URL 提取 key"
        return 1
    }

    upload_url="https://qyapi.weixin.qq.com/cgi-bin/webhook/upload_media?key=${key}&type=file"

    response="$(curl --silent --show-error --fail-with-body \
        --connect-timeout 5 --max-time 30 \
        -F "media=@${file};type=text/html" \
        "${upload_url}")" || return 1

    errcode="$(jq -r '.errcode // -1' <<< "${response}")"
    errmsg="$(jq -r '.errmsg // "unknown"' <<< "${response}")"
    media_id="$(jq -r '.media_id // empty' <<< "${response}")"

    if [[ "${errcode}" != "0" || -z "${media_id}" ]]; then
        log "ERROR" "企业微信文件上传失败: errcode=${errcode}, errmsg=${errmsg}"
        return 1
    fi

    printf '%s' "${media_id}"
}

wechat_send_file() {
    local file="$1"
    local media_id payload

    media_id="$(wechat_upload_file "${file}")" || return 1
    payload="$(jq -nc --arg media_id "${media_id}" \
        '{msgtype:"file", file:{media_id:$media_id}}')"

    wechat_post_json "${payload}"
}

send_wechat_report() {
    local slow_total
    slow_total=$((WARN_COUNT + CRITICAL_COUNT))

    (( slow_total > 0 )) || return 0

    if [[ -z "${WECHAT_WEBHOOK_URL}" ]]; then
        log "WARN" "检测到 ${slow_total} 个慢启动 Pod，但未配置 WECHAT_WEBHOOK_URL；仅保留 HTML 报告"
        return 0
    fi

    if ! wechat_send_markdown_summary; then
        log "WARN" "企业微信摘要发送失败，继续尝试发送 HTML 文件"
    fi

    if wechat_send_file "${REPORT_FILE}"; then
        log "INFO" "企业微信 HTML 报告发送成功"
    else
        log "ERROR" "企业微信 HTML 报告发送失败，报告仍保留在: ${REPORT_FILE}"
        return 1
    fi
}

main() {
    parse_args "$@"
    validate_config
    init_runtime

    trap cleanup EXIT
    trap 'on_error ${LINENO}' ERR
    trap 'log "WARN" "收到终止信号"; exit 130' INT TERM

    acquire_lock
    preflight

    log "INFO" "开始巡检: namespace=${NAMESPACE:-ALL_NAMESPACES}, warn=${WARN_SECONDS}s, critical=${CRITICAL_SECONDS}s, request_timeout=${KUBECTL_REQUEST_TIMEOUT}, command_timeout=${KUBECTL_COMMAND_TIMEOUT}, dry_run=${DRY_RUN}"

    fetch_cluster_data
    build_deployment_map
    extract_pod_records
    print_results

    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "dry-run 模式：跳过 HTML 持久化与企业微信发送"
    else
        generate_html_report
        if [[ -n "${REPORT_FILE}" ]]; then
            send_wechat_report || true
        fi
    fi

    log "INFO" "巡检完成"
}

main "$@"
