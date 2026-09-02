#!/usr/bin/env bash
# ==============================================================================
# pod-start-time-check.sh
# Kubernetes Pod Scheduled -> current Ready transition duration checker
# v2.2.1 Production Maintenance
#
# Metric semantics:
#   Ready=True condition.lastTransitionTime - PodScheduled.lastTransitionTime
#
# IMPORTANT:
#   This is a readiness-transition proxy. If readiness flaps after startup,
#   Ready.lastTransitionTime is the latest transition to Ready=True, not the
#   first-ever Ready timestamp.
# ==============================================================================

set -Eeuo pipefail
umask 077
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.2.1"
readonly METRIC_NAME="scheduled_to_current_ready_transition_seconds"

NAMESPACE=""
DRY_RUN=false
WARN_SECONDS="${WARN_SECONDS:-120}"
CRITICAL_SECONDS="${CRITICAL_SECONDS:-180}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-30s}"
KUBECTL_COMMAND_TIMEOUT="${KUBECTL_COMMAND_TIMEOUT:-45s}"

LOG_DIR="${LOG_DIR:-/data/logs/pod-start-time-check}"
REPORT_DIR="${REPORT_DIR:-}"
LOCK_FILE="${LOCK_FILE:-/run/lock/pod-start-time-check/pod-start-time-check.lock}"
WECHAT_WEBHOOK_URL="${WECHAT_WEBHOOK_URL:-}"
REPORT_DIR_EXPLICIT=false
[[ -n "${REPORT_DIR}" ]] && REPORT_DIR_EXPLICIT=true

LOG_FILE=""
TMP_DIR=""
RESULT_TSV=""
SLOW_TSV=""
REPORT_FILE=""

TOTAL_PODS=0
VALID_DEPLOYMENT_PODS=0
SKIPPED_NO_READY=0
SKIPPED_NO_DEPLOYMENT=0
WARN_COUNT=0
CRITICAL_COUNT=0

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
      --request-timeout <t>  Kubernetes API 单次请求超时，默认 30s；禁止 0
      --command-timeout <t>  kubectl 整体命令超时，默认 45s；禁止 0
      --log-dir <dir>        日志目录，默认 /data/logs/pod-start-time-check
      --report-dir <dir>     HTML 报告目录，默认 <log-dir>/reports
      --lock-file <path>     锁文件，默认 /run/lock/pod-start-time-check/pod-start-time-check.lock
  -h, --help                 显示帮助
  -v, --version              显示版本

WeCom:
  仅通过环境变量 WECHAT_WEBHOOK_URL 配置机器人 Webhook，避免 Secret 暴露在
  shell history 和进程参数中。

Metric:
  scheduled_to_current_ready_transition_seconds =
      Ready=True.lastTransitionTime - PodScheduled.lastTransitionTime

  注意：这是当前 Ready transition 代理耗时，不保证等于 Pod 首次 Ready 启动耗时。
USAGE
}

log() {
    local level="$1"
    shift
    local now line
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    line="${now} ${SCRIPT_NAME} [${level}] $*"

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

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_zero_duration() {
    local value="$1"
    local stripped

    stripped="${value//0/}"
    stripped="${stripped//./}"
    stripped="${stripped//ms/}"
    stripped="${stripped//us/}"
    stripped="${stripped//ns/}"
    stripped="${stripped//s/}"
    stripped="${stripped//m/}"
    stripped="${stripped//h/}"

    [[ -z "${stripped}" ]]
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
                fatal "--webhook-url 已移除；请通过 WECHAT_WEBHOOK_URL 环境变量配置，避免 Secret 暴露在命令行"
                ;;
            --log-dir)
                (($# >= 2)) || fatal "$1 缺少目录参数"
                LOG_DIR="$2"
                shift 2
                ;;
            --report-dir)
                (($# >= 2)) || fatal "$1 缺少目录参数"
                REPORT_DIR="$2"
                REPORT_DIR_EXPLICIT=true
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

finalize_paths() {
    if [[ "${REPORT_DIR_EXPLICIT}" == false ]]; then
        REPORT_DIR="${LOG_DIR}/reports"
    fi
}

validate_config() {
    is_nonnegative_integer "${WARN_SECONDS}" || fatal "--warn-seconds 必须是非负整数"
    is_nonnegative_integer "${CRITICAL_SECONDS}" || fatal "--critical-seconds 必须是非负整数"
    (( CRITICAL_SECONDS > WARN_SECONDS )) || \
        fatal "critical 阈值必须大于 warn 阈值: warn=${WARN_SECONDS}, critical=${CRITICAL_SECONDS}"

    [[ -n "${KUBECTL_REQUEST_TIMEOUT}" ]] || fatal "--request-timeout 不能为空"
    [[ -n "${KUBECTL_COMMAND_TIMEOUT}" ]] || fatal "--command-timeout 不能为空"

    is_zero_duration "${KUBECTL_REQUEST_TIMEOUT}" && \
        fatal "--request-timeout 禁止为 0: ${KUBECTL_REQUEST_TIMEOUT}"
    is_zero_duration "${KUBECTL_COMMAND_TIMEOUT}" && \
        fatal "--command-timeout 禁止为 0: ${KUBECTL_COMMAND_TIMEOUT}"

    return 0
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "缺少依赖命令: $1"
}

bootstrap_preflight() {
    local cmd
    for cmd in kubectl jq date sort flock awk sed mktemp timeout stat id mkdir chmod tee; do
        require_cmd "${cmd}"
    done

    timeout "${KUBECTL_COMMAND_TIMEOUT}" true >/dev/null 2>&1 || \
        fatal "--command-timeout 格式无效: ${KUBECTL_COMMAND_TIMEOUT}"

    kubectl --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" version --client >/dev/null 2>&1 || \
        fatal "kubectl client 不可用，或 --request-timeout 格式无效: ${KUBECTL_REQUEST_TIMEOUT}"

    if [[ "${DRY_RUN}" == false && -n "${WECHAT_WEBHOOK_URL}" ]]; then
        require_cmd curl
    fi
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
    return "${rc}"
}

on_error() {
    local rc=$?
    local line_no="$1"
    log "ERROR" "脚本异常退出: rc=${rc}, line=${line_no}"
    exit "${rc}"
}

validate_lock_path() {
    local lock_dir mode owner uid group_digit other_digit

    lock_dir="${LOCK_FILE%/*}"
    [[ "${lock_dir}" != "${LOCK_FILE}" ]] || lock_dir="."

    [[ ! -L "${lock_dir}" ]] || fatal "锁目录不能是符号链接: ${lock_dir}"

    if [[ ! -d "${lock_dir}" ]]; then
        mkdir -p -m 0700 "${lock_dir}" || fatal "无法创建安全锁目录: ${lock_dir}"
    fi

    [[ -d "${lock_dir}" && ! -L "${lock_dir}" ]] || \
        fatal "锁目录不是安全目录: ${lock_dir}"

    uid="$(id -u)"
    owner="$(stat -c '%u' "${lock_dir}")" || fatal "无法读取锁目录 owner: ${lock_dir}"
    [[ "${owner}" == "${uid}" ]] || \
        fatal "锁目录 owner 与当前执行用户不一致: dir=${lock_dir}, owner=${owner}, uid=${uid}"

    mode="$(stat -c '%a' "${lock_dir}")" || fatal "无法读取锁目录权限: ${lock_dir}"
    group_digit="${mode: -2:1}"
    other_digit="${mode: -1}"
    if (( (10#${group_digit} & 2) != 0 || (10#${other_digit} & 2) != 0 )); then
        fatal "锁目录不能 group/world writable: dir=${lock_dir}, mode=${mode}"
    fi

    if [[ -e "${LOCK_FILE}" || -L "${LOCK_FILE}" ]]; then
        [[ -f "${LOCK_FILE}" && ! -L "${LOCK_FILE}" ]] || \
            fatal "锁文件必须是普通文件且不能是符号链接: ${LOCK_FILE}"
        owner="$(stat -c '%u' "${LOCK_FILE}")" || fatal "无法读取锁文件 owner: ${LOCK_FILE}"
        [[ "${owner}" == "${uid}" ]] || \
            fatal "锁文件 owner 与当前执行用户不一致: file=${LOCK_FILE}, owner=${owner}, uid=${uid}"
    fi
}

acquire_lock() {
    validate_lock_path

    exec {LOCK_FD}>"${LOCK_FILE}"
    chmod 0600 "${LOCK_FILE}" || fatal "无法设置锁文件权限: ${LOCK_FILE}"

    if ! flock -n "${LOCK_FD}"; then
        fatal "已有实例正在运行，锁文件: ${LOCK_FILE}"
    fi

    printf '%s\n' "$$" 1>&"${LOCK_FD}"
    log "INFO" "获取运行锁成功: ${LOCK_FILE}, pid=$$"
}

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

can_i_value() {
    local output
    output="$(kubectl_safe auth can-i "$@" 2>/dev/null)" || return 2
    case "${output}" in
        yes|no) printf '%s' "${output}" ;;
        *) return 2 ;;
    esac
}

require_rbac_permission() {
    local description="$1"
    shift
    local answer

    answer="$(can_i_value "$@")" || fatal "RBAC 检查失败：无法验证 ${description}"
    [[ "${answer}" == "yes" ]] || fatal "RBAC 权限不足：需要 ${description}"
}

forbid_rbac_permission() {
    local description="$1"
    shift
    local answer

    answer="$(can_i_value "$@")" || fatal "Strict RBAC 检查失败：无法验证 ${description}"
    [[ "${answer}" == "no" ]] || \
        fatal "Strict RBAC 拒绝高权限身份：检测到 ${description}；请使用 pod-start-time-check 专用最小权限身份"
}

check_rbac_permissions() {
    local -a scope_args=(-A)
    [[ -n "${NAMESPACE}" ]] && scope_args=(-n "${NAMESPACE}")

    require_rbac_permission "pods:list" list pods "${scope_args[@]}"
    require_rbac_permission "replicasets.apps:list" list replicasets.apps "${scope_args[@]}"

    forbid_rbac_permission "wildcard */*" '*' '*' "${scope_args[@]}"
    forbid_rbac_permission "secrets:get" get secrets "${scope_args[@]}"
    forbid_rbac_permission "pods:delete" delete pods "${scope_args[@]}"
    forbid_rbac_permission "deployments.apps:patch" patch deployments.apps "${scope_args[@]}"
    forbid_rbac_permission \
        "clusterrolebindings.rbac.authorization.k8s.io:create" \
        create clusterrolebindings.rbac.authorization.k8s.io

    log "INFO" "Strict RBAC 检查通过: required=pods:list,replicasets:list; dangerous permissions=none"
}

preflight() {
    check_rbac_permissions
    log "INFO" "预检查通过: request_timeout=${KUBECTL_REQUEST_TIMEOUT}, command_timeout=${KUBECTL_COMMAND_TIMEOUT}"
}

fetch_cluster_data() {
    local -a scope_args=(-A)
    local pod_json="${TMP_DIR}/pods.json"
    local rs_json="${TMP_DIR}/replicasets.json"
    [[ -n "${NAMESPACE}" ]] && scope_args=(-n "${NAMESPACE}")

    log "INFO" "开始拉取 Pod 与 ReplicaSet 数据，范围: ${NAMESPACE:-ALL_NAMESPACES}"

    kubectl_safe get pods "${scope_args[@]}" -o json > "${pod_json}" || \
        fatal "获取 Pod 数据失败（可能是 RBAC、Namespace 不存在、API 请求超时或集群连接异常）"

    kubectl_safe get replicasets.apps "${scope_args[@]}" -o json > "${rs_json}" || \
        fatal "获取 ReplicaSet 数据失败（可能是 RBAC、Namespace 不存在、API 请求超时或集群连接异常）"

    jq -e '.items | type == "array"' "${pod_json}" >/dev/null || fatal "Pod API 返回 JSON 结构异常"
    jq -e '.items | type == "array"' "${rs_json}" >/dev/null || fatal "ReplicaSet API 返回 JSON 结构异常"

    TOTAL_PODS="$(jq '.items | length' "${pod_json}")"
    log "INFO" "集群数据拉取完成: pods=${TOTAL_PODS}, replicasets=$(jq '.items | length' "${rs_json}")"
}

build_deployment_map() {
    local rs_json="${TMP_DIR}/replicasets.json"

    declare -gA RS_TO_DEPLOYMENT=()

    local ns rs deployment
    while IFS=$'\t' read -r ns rs deployment; do
        [[ -n "${ns}" && -n "${rs}" ]] || continue
        RS_TO_DEPLOYMENT["${ns}/${rs}"]="${deployment}"
    done < <(
        jq -r '
          .items[]
          | .metadata.namespace as $ns
          | .metadata.name as $rs
          | ((.metadata.ownerReferences // [])
              | map(select(.kind == "Deployment" and (.controller // false) == true))
              | .[0].name // "-") as $deploy
          | [$ns, $rs, $deploy]
          | @tsv
        ' "${rs_json}"
    )
}

extract_pod_records() {
    local pod_json="${TMP_DIR}/pods.json"
    local ns pod owner_kind owner_name scheduled ready duration deployment

    while IFS=$'\t' read -r ns pod owner_kind owner_name scheduled ready duration; do
        deployment=""

        case "${owner_kind}" in
            ReplicaSet)
                deployment="${RS_TO_DEPLOYMENT["${ns}/${owner_name}"]:-}"
                ;;
            Deployment)
                deployment="${owner_name}"
                ;;
        esac

        if [[ -z "${deployment}" || "${deployment}" == "-" ]]; then
            ((SKIPPED_NO_DEPLOYMENT+=1))
            continue
        fi

        ((VALID_DEPLOYMENT_PODS+=1))

        if [[ -z "${duration}" || ! "${duration}" =~ ^-?[0-9]+$ ]]; then
            ((SKIPPED_NO_READY+=1))
            continue
        fi

        if (( duration < 0 )); then
            log "WARN" "Ready transition 代理耗时为负数，跳过: ${ns}/${pod}, scheduled=${scheduled}, ready=${ready}"
            ((SKIPPED_NO_READY+=1))
            continue
        fi

        printf '%s\t%s\t%s\t%d\n' \
            "${ns}" "${deployment}" "${pod}" "${duration}" >> "${RESULT_TSV}"
    done < <(
        jq -r '
          def epoch_or_null:
            if . == "" or . == null then null
            else try fromdateiso8601 catch null
            end;

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
          | ($scheduled | epoch_or_null) as $scheduled_epoch
          | ($ready | epoch_or_null) as $ready_epoch
          | (if ($scheduled_epoch != null and $ready_epoch != null)
               then ($ready_epoch - $scheduled_epoch)
               else null
             end) as $duration
          | [
              $ns,
              $pod,
              ($owner.kind // ""),
              ($owner.name // ""),
              $scheduled,
              $ready,
              (if $duration == null then "" else ($duration | tostring) end)
            ]
          | @tsv
        ' "${pod_json}"
    )

    sort -t $'\t' -k4,4nr -k1,1 -k2,2 -k3,3 "${RESULT_TSV}" -o "${RESULT_TSV}"
    awk -F '\t' -v warn="${WARN_SECONDS}" '$4 > warn' "${RESULT_TSV}" > "${SLOW_TSV}"

    WARN_COUNT="$(awk -F '\t' -v warn="${WARN_SECONDS}" -v critical="${CRITICAL_SECONDS}" \
        '$4 > warn && $4 <= critical {count++} END {print count+0}' "${RESULT_TSV}")"
    CRITICAL_COUNT="$(awk -F '\t' -v critical="${CRITICAL_SECONDS}" \
        '$4 > critical {count++} END {print count+0}' "${RESULT_TSV}")"
}

print_results() {
    local ns deployment pod seconds color

    printf '\n%sPod Scheduled -> 当前 Ready transition 代理耗时%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf '%-28s %-48s %-70s %16s\n' "NAMESPACE" "DEPLOYMENT" "POD" "TRANSITION(s)"
    printf '%-28s %-48s %-70s %16s\n' \
        '----------------------------' \
        '------------------------------------------------' \
        '----------------------------------------------------------------------' \
        '----------------'

    if [[ ! -s "${RESULT_TSV}" ]]; then
        printf '%s未发现可计算代理耗时的 Deployment Pod%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
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
            printf '%b%-28s %-48s %-70s %16ss%b\n' \
                "${color}" "${ns}" "${deployment}" "${pod}" "${seconds}" "${COLOR_RESET}"
        else
            printf '%-28s %-48s %-70s %16ss\n' \
                "${ns}" "${deployment}" "${pod}" "${seconds}"
        fi
    done < "${RESULT_TSV}"

    printf '\n统计: total_pods=%s, deployment_pods=%s, no_ready_or_invalid_time=%s, non_deployment=%s, >%ss=%s, >%ss=%s\n' \
        "${TOTAL_PODS}" "${VALID_DEPLOYMENT_PODS}" "${SKIPPED_NO_READY}" \
        "${SKIPPED_NO_DEPLOYMENT}" "${WARN_SECONDS}" "$((WARN_COUNT + CRITICAL_COUNT))" \
        "${CRITICAL_SECONDS}" "${CRITICAL_COUNT}"
}

html_escape() {
    jq -nr --arg value "$1" '$value | @html'
}

generate_html_report() {
    local slow_total scope generated_at
    slow_total=$((WARN_COUNT + CRITICAL_COUNT))

    (( slow_total > 0 )) || {
        log "INFO" "没有超过 ${WARN_SECONDS}s 的 Pod，不生成 HTML 报告"
        return 0
    }

    mkdir -p "${REPORT_DIR}" || fatal "无法创建报告目录: ${REPORT_DIR}"
    REPORT_FILE="${REPORT_DIR}/pod-start-time-report-$(date '+%Y%m%d-%H%M%S').html"
    scope="${NAMESPACE:-ALL_NAMESPACES}"
    generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"

    cat > "${REPORT_FILE}" <<EOF_HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kubernetes Pod Ready Transition 巡检报告</title>
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
<h1>Kubernetes Pod Ready Transition 巡检报告</h1>
<div class="meta">
  <div><strong>扫描范围：</strong>$(html_escape "${scope}")</div>
  <div><strong>生成时间：</strong>$(html_escape "${generated_at}")</div>
  <div><strong>指标：</strong>$(html_escape "${METRIC_NAME}")</div>
  <div><strong>计算口径：</strong>Ready=True.lastTransitionTime - PodScheduled.lastTransitionTime</div>
  <div><strong>语义说明：</strong>这是当前 Ready transition 的代理耗时；Readiness 后续抖动会刷新该时间，不等价于历史首次 Ready。</div>
  <div><strong>阈值：</strong>&gt; ${WARN_SECONDS}s 警告，&gt; ${CRITICAL_SECONDS}s 严重</div>
</div>
<div class="summary">
  超过 ${WARN_SECONDS}s：<strong>${slow_total}</strong> 个 Pod；
  其中超过 ${CRITICAL_SECONDS}s：<strong>${CRITICAL_COUNT}</strong> 个 Pod。
</div>
<table>
<thead>
<tr><th>Namespace</th><th>Deployment</th><th>Pod</th><th>代理耗时</th><th>级别</th></tr>
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
<div class="footer">Generated by pod-start-time-check.sh v2.2.1</div>
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
}

wechat_send_markdown_summary() {
    local slow_total payload scope
    slow_total=$((WARN_COUNT + CRITICAL_COUNT))
    scope="${NAMESPACE:-ALL_NAMESPACES}"

    payload="$(jq -nc \
        --arg scope "${scope}" \
        --arg metric "${METRIC_NAME}" \
        --argjson warn_seconds "${WARN_SECONDS}" \
        --argjson critical_seconds "${CRITICAL_SECONDS}" \
        --argjson slow_total "${slow_total}" \
        --argjson critical_total "${CRITICAL_COUNT}" \
        '{
          msgtype: "markdown",
          markdown: {
            content: (
              "### Kubernetes Pod Ready Transition 巡检\\n" +
              "> 扫描范围：`" + $scope + "`\\n" +
              "> 指标：`" + $metric + "`\\n" +
              "> 超过 " + ($warn_seconds|tostring) + "s：<font color=\"warning\">" + ($slow_total|tostring) + "</font>\\n" +
              "> 超过 " + ($critical_seconds|tostring) + "s：<font color=\"warning\">" + ($critical_total|tostring) + "</font>\\n" +
              "> 该指标是当前 Ready transition 代理耗时，不保证等于历史首次 Ready。"
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
        log "WARN" "检测到 ${slow_total} 个慢启动代理指标 Pod，但未配置 WECHAT_WEBHOOK_URL；仅保留 HTML 报告"
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
    finalize_paths
    validate_config
    bootstrap_preflight
    init_runtime

    trap cleanup EXIT
    trap 'on_error ${LINENO}' ERR
    trap 'log "WARN" "收到终止信号"; exit 130' INT TERM

    acquire_lock
    preflight

    log "INFO" "开始巡检: metric=${METRIC_NAME}, namespace=${NAMESPACE:-ALL_NAMESPACES}, warn=${WARN_SECONDS}s, critical=${CRITICAL_SECONDS}s, request_timeout=${KUBECTL_REQUEST_TIMEOUT}, command_timeout=${KUBECTL_COMMAND_TIMEOUT}, dry_run=${DRY_RUN}"

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
