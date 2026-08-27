#!/usr/bin/env bash
# ============================================================
# k8s-gray-scale-zero.sh - Kubernetes 灰度 Deployment 副本归零工具
# v3.1.0 Simplified Production Hardened Edition
#
# 保留：日志 / 全局锁 / 预检查 / 标签保护 / HPA fail-closed / 基线快照
#      人工确认 / 分批执行 / 批次复核 / Formal 健康保护 / 自动回滚
# 删除：Resume / Abort / Pause / Status / Snapshot 状态机
# ============================================================
set -Eeuo pipefail
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="3.1.0"
NAMESPACE="${NAMESPACE:-dev-xxx}"
LANGUAGE_TYPE="${LANGUAGE_TYPE:-java}"
BUSINESS_TYPE="${BUSINESS_TYPE:-all}"
DEPLOYMENT_ARG=""
DRY_RUN=false
BATCH_SIZE="${BATCH_SIZE:-5}"
OBSERVE_SECONDS="${OBSERVE_SECONDS:-60}"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-30s}"
LOG_ROOT="${LOG_ROOT:-/data/logs/k8s-gray-scale-zero}"
LOG_FILE="${LOG_ROOT}/${SCRIPT_NAME%.sh}.log"
SNAPSHOT_DIR="${LOG_ROOT}/snapshot"
LOCK_FILE="${LOG_ROOT}/k8s-gray-scale-zero.lock"
WECHAT_WEBHOOK_URL="${WECHAT_WEBHOOK_URL:-}"
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
CURRENT_CONTEXT=""
SNAPSHOT_FILE=""
SNAPSHOT_CREATED=false
ROLLBACK_RUNNING=false
ROLLBACK_DONE=false
LOCK_FD=200
declare -a DISCOVERED_DEPLOYMENTS=()
declare -a CANDIDATE_DEPLOYMENTS=()
declare -a FINAL_DEPLOYMENTS=()
declare -a SUCCESS_DEPLOYMENTS=()
declare -a SKIPPED_DEPLOYMENTS=()
declare -a MODIFIED_DEPLOYMENTS=()
declare -A GRAY_BASELINE=()
declare -A FORMAL_MAP=()
declare -A FORMAL_BASELINE=()
log(){ local l="$1"; shift; printf '%s [%s] %s\n' "$(date '+%F %T')" "$l" "$*" | tee -a "$LOG_FILE"; }
info(){ log INFO "$@"; }
warn(){ log WARN "$@"; }
err(){ log ERROR "$@" >&2; }
die(){ err "$*"; exit 1; }
usage(){ cat <<EOF_USAGE
用法：${SCRIPT_NAME} [options]
  --namespace NAME
  --language NAME
  --business all|api|service|api,service
  --deployment NAME
  --batch-size N
  --observe-seconds N
  --dry-run
  -h|--help
环境变量：WECHAT_WEBHOOK_URL LOG_ROOT NAMESPACE LANGUAGE_TYPE BUSINESS_TYPE
          BATCH_SIZE OBSERVE_SECONDS KUBECTL_TIMEOUT
EOF_USAGE
}
parse_args(){
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace)       [[ $# -ge 2 ]] || die "--namespace 缺少参数"; NAMESPACE="$2"; shift 2 ;;
            --language)        [[ $# -ge 2 ]] || die "--language 缺少参数"; LANGUAGE_TYPE="$2"; shift 2 ;;
            --business)        [[ $# -ge 2 ]] || die "--business 缺少参数"; BUSINESS_TYPE="$2"; shift 2 ;;
            --deployment)      [[ $# -ge 2 ]] || die "--deployment 缺少参数"; DEPLOYMENT_ARG="$2"; shift 2 ;;
            --batch-size)      [[ $# -ge 2 ]] || die "--batch-size 缺少参数"; BATCH_SIZE="$2"; shift 2 ;;
            --observe-seconds) [[ $# -ge 2 ]] || die "--observe-seconds 缺少参数"; OBSERVE_SECONDS="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数：$1" ;;
        esac
    done
}
init_dirs(){
    mkdir -p "$LOG_ROOT" "$SNAPSHOT_DIR"
    touch "$LOG_FILE"
    chmod 750 "$LOG_ROOT" "$SNAPSHOT_DIR" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
}
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"; }
check_dependencies(){
    local c
    for c in kubectl flock awk sed grep; do require_cmd "$c"; done
    [[ -z "$WECHAT_WEBHOOK_URL" ]] || require_cmd curl
}
check_args(){
    [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] || die "BATCH_SIZE 必须为正整数"
    [[ "$OBSERVE_SECONDS" =~ ^[0-9]+$ ]] || die "OBSERVE_SECONDS 必须为非负整数"
    case "$BUSINESS_TYPE" in
        all|api|service|api,service|service,api) ;;
        *) die "不支持的 BUSINESS_TYPE：$BUSINESS_TYPE" ;;
    esac
    [[ -n "$NAMESPACE" ]] || die "NAMESPACE 不能为空"
    [[ -n "$LANGUAGE_TYPE" ]] || die "LANGUAGE_TYPE 不能为空"
}
acquire_lock(){
    exec {LOCK_FD}>"$LOCK_FILE"
    flock -n "$LOCK_FD" || die "已有其他灰度归零任务运行：$LOCK_FILE"
    info "获取任务锁成功：$LOCK_FILE"
}
kctl(){
    kubectl --context "$CURRENT_CONTEXT" --request-timeout="$KUBECTL_TIMEOUT" "$@"
}
check_k8s(){
    CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
    [[ -n "$CURRENT_CONTEXT" ]] || die "无法获取 kubectl current-context"
    kubectl version --client >/dev/null 2>&1 || die "kubectl 不可用"
    kctl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "Namespace 不存在或不可访问：$NAMESPACE"
    info "Context=$CURRENT_CONTEXT Namespace=$NAMESPACE"
}
get_replicas(){
    kctl -n "$NAMESPACE" get deployment "$1" -o jsonpath='{.spec.replicas}' 2>/dev/null
}
get_label(){
    kctl -n "$NAMESPACE" get deployment "$1" -o "jsonpath={.metadata.labels.$2}" 2>/dev/null
}
get_hpa_info(){
    local deployment="$1" output
    if ! output="$(kctl -n "$NAMESPACE" get hpa \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.scaleTargetRef.kind}{"|"}{.spec.scaleTargetRef.name}{"|"}{.spec.minReplicas}{"|"}{.spec.maxReplicas}{"\n"}{end}' 2>/dev/null)"; then
        return 1
    fi
    awk -F'|' -v d="$deployment" '$2=="Deployment" && $3==d {print $1"|"$4"|"$5}' <<< "$output"
}
get_deployment_health(){
    kctl -n "$NAMESPACE" get deployment "$1" \
        -o jsonpath='{.spec.replicas}{"|"}{.status.readyReplicas}{"|"}{.status.availableReplicas}' 2>/dev/null
}
formal_name(){ printf '%s\n' "${1%-gray}"; }
business_match(){
    case "$BUSINESS_TYPE" in
        all) return 0 ;;
        api) [[ "$1" == *-api-gray ]] ;;
        service) [[ "$1" == *-service-gray ]] ;;
        api,service|service,api) [[ "$1" == *-api-gray || "$1" == *-service-gray ]] ;;
    esac
}
verify_formal_health(){
    local formal="$1" expected="$2" health desired ready available
    health="$(get_deployment_health "$formal" 2>/dev/null || true)"
    IFS='|' read -r desired ready available <<< "$health"
    ready="${ready:-0}"
    available="${available:-0}"
    [[ "$desired" =~ ^[0-9]+$ ]] || {
        err "无法读取 Formal 健康状态：$formal"
        return 1
    }
    [[ "$desired" == "$expected" ]] || {
        err "Formal 副本基线变化：$formal expected=$expected current=$desired"
        return 1
    }
    [[ "$desired" != 0 ]] || {
        err "Formal Deployment replicas=0：$formal"
        return 1
    }
    [[ "$ready" == "$desired" && "$available" == "$desired" ]] || {
        err "Formal 非健康状态：$formal desired=$desired ready=$ready available=$available"
        return 1
    }
    return 0
}
discover_deployments(){
    DISCOVERED_DEPLOYMENTS=()
    if [[ -n "$DEPLOYMENT_ARG" ]]; then
        kctl -n "$NAMESPACE" get deployment "$DEPLOYMENT_ARG" >/dev/null 2>&1 || \
            die "Deployment 不存在或不可访问：$DEPLOYMENT_ARG"
        DISCOVERED_DEPLOYMENTS=("$DEPLOYMENT_ARG")
    else
        mapfile -t DISCOVERED_DEPLOYMENTS < <(
            kctl -n "$NAMESPACE" get deployments.apps \
              -l "module_name=gray,language_type=${LANGUAGE_TYPE}" \
              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
            sed '/^[[:space:]]*$/d' | sort
        )
    fi
    info "发现 Deployment：${#DISCOVERED_DEPLOYMENTS[@]}"
}
filter_deployments(){
    CANDIDATE_DEPLOYMENTS=()
    local d module language replicas
    for d in "${DISCOVERED_DEPLOYMENTS[@]}"; do
        [[ "$d" == *-gray ]] || { SKIPPED_DEPLOYMENTS+=("$d|NOT_GRAY_SUFFIX"); continue; }
        [[ "$d" != *frontend* ]] || { SKIPPED_DEPLOYMENTS+=("$d|FRONTEND"); continue; }
        business_match "$d" || { SKIPPED_DEPLOYMENTS+=("$d|BUSINESS"); continue; }
        module="$(get_label "$d" module_name 2>/dev/null || true)"
        language="$(get_label "$d" language_type 2>/dev/null || true)"
        [[ "$module" == gray && "$language" == "$LANGUAGE_TYPE" ]] || {
            warn "标签保护跳过：$d module_name=$module language_type=$language"
            SKIPPED_DEPLOYMENTS+=("$d|LABEL")
            continue
        }
        replicas="$(get_replicas "$d" 2>/dev/null || true)"
        [[ "$replicas" =~ ^[0-9]+$ ]] || { SKIPPED_DEPLOYMENTS+=("$d|REPLICAS_UNKNOWN"); continue; }
        [[ "$replicas" != 0 ]] || { SKIPPED_DEPLOYMENTS+=("$d|ALREADY_ZERO"); continue; }
        CANDIDATE_DEPLOYMENTS+=("$d")
    done
    info "基础过滤后候选：${#CANDIDATE_DEPLOYMENTS[@]}"
}
collect_baseline(){
    FINAL_DEPLOYMENTS=()
    local d gray formal formal_rep health ready available hpa hpa_name hpa_min hpa_max
    for d in "${CANDIDATE_DEPLOYMENTS[@]}"; do
        if ! hpa="$(get_hpa_info "$d")"; then
            die "无法确认 $d 是否存在 HPA，为安全起见停止执行"
        fi
        if [[ -n "$hpa" ]]; then
            IFS='|' read -r hpa_name hpa_min hpa_max <<< "$hpa"
            warn "HPA 存在，跳过：$d HPA=$hpa_name min=$hpa_min max=$hpa_max"
            SKIPPED_DEPLOYMENTS+=("$d|HPA")
            continue
        fi
        gray="$(get_replicas "$d" 2>/dev/null || true)"
        [[ "$gray" =~ ^[0-9]+$ ]] || die "无法读取 Gray replicas：$d"
        formal="$(formal_name "$d")"
        kctl -n "$NAMESPACE" get deployment "$formal" >/dev/null 2>&1 || \
            die "对应 Formal Deployment 不存在或不可访问：$d -> $formal"
        health="$(get_deployment_health "$formal" 2>/dev/null || true)"
        IFS='|' read -r formal_rep ready available <<< "$health"
        ready="${ready:-0}"; available="${available:-0}"
        [[ "$formal_rep" =~ ^[0-9]+$ ]] || die "无法读取 Formal replicas：$formal"
        [[ "$formal_rep" != 0 ]] || die "Formal Deployment 已为 0，禁止执行：$formal"
        [[ "$ready" == "$formal_rep" && "$available" == "$formal_rep" ]] || \
            die "Formal 非健康状态，禁止执行：$formal desired=$formal_rep ready=$ready available=$available"
        GRAY_BASELINE["$d"]="$gray"
        FORMAL_MAP["$d"]="$formal"
        FORMAL_BASELINE["$d"]="$formal_rep"
        FINAL_DEPLOYMENTS+=("$d")
    done
    info "最终可执行：${#FINAL_DEPLOYMENTS[@]}"
}
send_wechat(){
    local message="$1" level="${2:-INFO}"
    [[ -n "$WECHAT_WEBHOOK_URL" ]] || return 0
    local content payload
    content="$(cat <<EOF_MSG
【K8S灰度应用归零工具】
级别：$level
Context：$CURRENT_CONTEXT
Namespace：$NAMESPACE
Language：$LANGUAGE_TYPE
Business：$BUSINESS_TYPE
RunID：$RUN_ID
$message
Snapshot：${SNAPSHOT_FILE:-N/A}
时间：$(date '+%F %T')
EOF_MSG
)"
    payload="$(printf '%s\n' "$content" | awk '
      BEGIN{printf "{\"msgtype\":\"text\",\"text\":{\"content\":\""}
      {gsub(/\\/,"\\\\");gsub(/\"/,"\\\"");printf "%s\\n",$0}
      END{printf "\"}}"}')"
    curl -fsS --connect-timeout 5 --max-time 10 -H 'Content-Type: application/json' \
      -d "$payload" "$WECHAT_WEBHOOK_URL" >/dev/null 2>&1 || \
      warn "企业微信发送失败（不影响业务）"
    return 0
}
create_snapshot(){
    SNAPSHOT_FILE="${SNAPSHOT_DIR}/gray-scale-zero-${RUN_ID}.snapshot"
    local tmp="${SNAPSHOT_FILE}.tmp" d
    {
        echo "# K8S Gray Scale Zero Snapshot"
        echo "SNAPSHOT_VERSION=$SCRIPT_VERSION"
        echo "RUN_ID=$RUN_ID"
        echo "START_TIME=$(date '+%F %T')"
        echo "EXECUTOR=$(id -un)"
        echo "HOSTNAME=$(hostname)"
        echo "CURRENT_CONTEXT=$CURRENT_CONTEXT"
        echo "NAMESPACE=$NAMESPACE"
        echo "LANGUAGE_TYPE=$LANGUAGE_TYPE"
        echo "BUSINESS_TYPE=$BUSINESS_TYPE"
        echo "DEPLOYMENT_COUNT=${#FINAL_DEPLOYMENTS[@]}"
        echo "# DEPLOYMENT|GRAY_NAME|GRAY_REPLICAS|FORMAL_NAME|FORMAL_REPLICAS"
        for d in "${FINAL_DEPLOYMENTS[@]}"; do
            printf 'DEPLOYMENT|%s|%s|%s|%s\n' "$d" "${GRAY_BASELINE[$d]}" \
              "${FORMAL_MAP[$d]}" "${FORMAL_BASELINE[$d]}"
        done
    } > "$tmp" || die "Snapshot 写入失败：$tmp"
    mv -f "$tmp" "$SNAPSHOT_FILE"
    chmod 640 "$SNAPSHOT_FILE" 2>/dev/null || true
    SNAPSHOT_CREATED=true
    [[ "$(grep -c '^DEPLOYMENT|' "$SNAPSHOT_FILE" || true)" == "${#FINAL_DEPLOYMENTS[@]}" ]] || \
        die "Snapshot 完整性校验失败"
    info "Snapshot：$SNAPSHOT_FILE"
}
snapshot_event(){
    [[ "$SNAPSHOT_CREATED" == true ]] || return 0
    if ! printf 'EVENT|%s|%s|%s|%s\n' "$(date '+%F %T')" "$1" "${2:-}" "${3:-}" >> "$SNAPSHOT_FILE"; then
        warn "Snapshot EVENT 写入失败：event=$1 deployment=${2:-}"
    fi
}
print_plan(){
    local d
    echo "============================================================"
    echo "Kubernetes 灰度应用副本归零执行计划"
    echo "Context=$CURRENT_CONTEXT Namespace=$NAMESPACE Language=$LANGUAGE_TYPE"
    echo "Business=$BUSINESS_TYPE Batch=$BATCH_SIZE Observe=${OBSERVE_SECONDS}s DryRun=$DRY_RUN"
    echo "Snapshot=$SNAPSHOT_FILE"
    echo "------------------------------------------------------------"
    for d in "${FINAL_DEPLOYMENTS[@]}"; do
        printf '%s : Gray=%s -> 0 | Formal=%s replicas=%s\n' \
          "$d" "${GRAY_BASELINE[$d]}" "${FORMAL_MAP[$d]}" "${FORMAL_BASELINE[$d]}"
    done
    echo "============================================================"
}
confirm_start(){
    local answer
    send_wechat "等待人工确认，可执行 Deployment：${#FINAL_DEPLOYMENTS[@]}" WARNING
    read -r -p "确认执行请输入 YES：" answer
    [[ "$answer" == YES ]] || { warn "任务取消"; snapshot_event REJECTED; return 1; }
    snapshot_event APPROVED "" "operator=$(id -un)"
}
rollback(){
    [[ "$ROLLBACK_RUNNING" == true || "$ROLLBACK_DONE" == true ]] && return 0
    ROLLBACK_RUNNING=true
    # Rollback 是保护流程，一旦开始则不允许普通 INT/TERM 中断。
    trap '' INT TERM
    if [[ ${#MODIFIED_DEPLOYMENTS[@]} -eq 0 ]]; then
        warn "无已修改对象，无需 Rollback"
        ROLLBACK_DONE=true
        ROLLBACK_RUNNING=false
        return 0
    fi
    warn "开始 Rollback：${#MODIFIED_DEPLOYMENTS[@]} 个 Deployment"
    send_wechat "开始自动 Rollback：${#MODIFIED_DEPLOYMENTS[@]} 个 Deployment" CRITICAL
    local i d baseline current failed=0
    for ((i=${#MODIFIED_DEPLOYMENTS[@]}-1; i>=0; i--)); do
        d="${MODIFIED_DEPLOYMENTS[$i]}"
        baseline="${GRAY_BASELINE[$d]}"
        current="$(get_replicas "$d" 2>/dev/null || echo UNKNOWN)"
        if [[ "$current" == "$baseline" ]]; then
            snapshot_event ROLLBACK_NOOP "$d" "current=$current"
            continue
        fi
        if [[ "$current" != 0 ]]; then
            err "Rollback 冲突：$d current=$current baseline=$baseline"
            snapshot_event ROLLBACK_CONFLICT "$d" "current=$current,baseline=$baseline"
            ((failed+=1))
            continue
        fi
        if ! kctl -n "$NAMESPACE" scale deployment "$d" \
            --current-replicas=0 --replicas="$baseline"; then
            current="$(get_replicas "$d" 2>/dev/null || echo UNKNOWN)"
            if [[ "$current" != "$baseline" ]]; then
                err "Rollback 失败：$d current=$current expected=$baseline"
                snapshot_event ROLLBACK_FAILED "$d" "current=$current,expected=$baseline"
                ((failed+=1))
                continue
            fi
        fi
        current="$(get_replicas "$d" 2>/dev/null || echo UNKNOWN)"
        if [[ "$current" != "$baseline" ]]; then
            err "Rollback 复核失败：$d current=$current expected=$baseline"
            snapshot_event ROLLBACK_FAILED "$d" "current=$current,expected=$baseline"
            ((failed+=1))
            continue
        fi
        info "Rollback 成功：$d -> $baseline"
        snapshot_event ROLLED_BACK "$d" "replicas=$baseline"
    done
    ROLLBACK_DONE=true
    ROLLBACK_RUNNING=false
    if [[ $failed -eq 0 ]]; then
        snapshot_event ROLLBACK_COMPLETED
        send_wechat "Rollback 完成" WARNING
        return 0
    fi
    snapshot_event ROLLBACK_PARTIAL_FAILED "" "failed=$failed"
    send_wechat "Rollback 存在 $failed 个失败/冲突项，请人工检查" CRITICAL
    return 1
}
scale_one(){
    local d="$1" gray_before="${GRAY_BASELINE[$1]}"
    local formal="${FORMAL_MAP[$1]}" formal_before="${FORMAL_BASELINE[$1]}"
    local gray_now hpa scale_rc=0
    if ! hpa="$(get_hpa_info "$d")"; then
        err "执行前 HPA 查询失败：$d"
        snapshot_event HPA_CHECK_FAILED "$d"
        return 20
    fi
    if [[ -n "$hpa" ]]; then
        warn "执行前发现 HPA，安全跳过：$d $hpa"
        SKIPPED_DEPLOYMENTS+=("$d|HPA_LATE")
        snapshot_event SKIPPED_HPA_LATE "$d" "$hpa"
        return 2
    fi
    gray_now="$(get_replicas "$d" 2>/dev/null || echo UNKNOWN)"
    [[ "$gray_now" == "$gray_before" ]] || {
        err "Gray 基线变化：$d $gray_before -> $gray_now"
        snapshot_event GRAY_BASELINE_CHANGED "$d" "$gray_before->$gray_now"
        return 10
    }
    verify_formal_health "$formal" "$formal_before" || {
        snapshot_event FORMAL_HEALTH_FAILED "$d" "formal=$formal"
        return 11
    }
    # 真正变更前再次检查 HPA，尽量缩小 HPA 创建竞态窗口。
    if ! hpa="$(get_hpa_info "$d")"; then
        err "最终 HPA 门禁查询失败：$d"
        snapshot_event HPA_CHECK_FAILED "$d" "stage=pre-scale"
        return 20
    fi
    if [[ -n "$hpa" ]]; then
        warn "最终门禁发现 HPA，安全跳过：$d $hpa"
        SKIPPED_DEPLOYMENTS+=("$d|HPA_LATE")
        snapshot_event SKIPPED_HPA_LATE "$d" "$hpa"
        return 2
    fi
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] kubectl --context $CURRENT_CONTEXT -n $NAMESPACE scale deployment $d --current-replicas=$gray_before --replicas=0"
        snapshot_event DRY_RUN "$d" "baseline=$gray_before"
        return 0
    fi
    # scale 前加入回滚集合；请求未生效时 Rollback 会识别 baseline 并 NOOP。
    MODIFIED_DEPLOYMENTS+=("$d")
    snapshot_event SCALE_BEGIN "$d" "from=$gray_before,to=0"
    kctl -n "$NAMESPACE" scale deployment "$d" \
        --current-replicas="$gray_before" --replicas=0 || scale_rc=$?
    gray_now="$(get_replicas "$d" 2>/dev/null || echo UNKNOWN)"
    [[ "$gray_now" == 0 ]] || {
        err "Gray 归零失败：$d scale_rc=$scale_rc current=$gray_now"
        snapshot_event SCALE_FAILED "$d" "scale_rc=$scale_rc,current=$gray_now"
        return 12
    }
    [[ $scale_rc -eq 0 ]] || warn "scale rc=$scale_rc，但已确认 $d replicas=0"
    verify_formal_health "$formal" "$formal_before" || {
        snapshot_event FORMAL_HEALTH_FAILED "$d" "formal=$formal,stage=post-scale"
        return 13
    }
    SUCCESS_DEPLOYMENTS+=("$d")
    snapshot_event SUCCESS "$d" "gray=$gray_before->0,formal=$formal:$formal_before"
    info "归零成功：$d $gray_before -> 0"
}
verify_success_deployments(){
    local d formal expected gray_now failed=0
    for d in "${SUCCESS_DEPLOYMENTS[@]}"; do
        gray_now="$(get_replicas "$d" 2>/dev/null || echo UNKNOWN)"
        if [[ "$gray_now" != 0 ]]; then
            err "Gray 复核失败：$d current=$gray_now expected=0"
            snapshot_event VERIFY_GRAY_FAILED "$d" "current=$gray_now"
            ((failed+=1))
        fi
        formal="${FORMAL_MAP[$d]}"
        expected="${FORMAL_BASELINE[$d]}"
        if ! verify_formal_health "$formal" "$expected"; then
            snapshot_event VERIFY_FORMAL_FAILED "$d" "formal=$formal"
            ((failed+=1))
        fi
    done
    [[ $failed -eq 0 ]]
}
batch_observe(){
    local completed="$1"
    if [[ "$OBSERVE_SECONDS" -gt 0 ]]; then
        info "累计成功 $completed 个，观察 ${OBSERVE_SECONDS}s"
        send_wechat "批次完成，累计成功 $completed 个；观察 ${OBSERVE_SECONDS}s" INFO
        sleep "$OBSERVE_SECONDS"
    fi
    info "批次观察结束，开始安全复核"
    if ! verify_success_deployments; then
        err "批次安全复核失败：completed=$completed"
        snapshot_event BATCH_VERIFY_FAILED "" "completed=$completed"
        return 1
    fi
    snapshot_event BATCH_VERIFY_OK "" "completed=$completed"
    info "批次安全复核通过"
}
final_verify(){
    if ! verify_success_deployments; then
        snapshot_event FINAL_VERIFY_FAILED
        return 1
    fi
    snapshot_event FINAL_VERIFY_OK
    return 0
}
summary(){
    echo "============================================================"
    echo "任务摘要"
    echo "RunID      : $RUN_ID"
    echo "Context    : $CURRENT_CONTEXT"
    echo "Namespace  : $NAMESPACE"
    echo "Discovered : ${#DISCOVERED_DEPLOYMENTS[@]}"
    echo "Candidate  : ${#CANDIDATE_DEPLOYMENTS[@]}"
    echo "Executable : ${#FINAL_DEPLOYMENTS[@]}"
    echo "Success    : ${#SUCCESS_DEPLOYMENTS[@]}"
    echo "Skipped    : ${#SKIPPED_DEPLOYMENTS[@]}"
    echo "Snapshot   : ${SNAPSHOT_FILE:-N/A}"
    [[ ${#SKIPPED_DEPLOYMENTS[@]} -eq 0 ]] || printf 'Skipped     : %s\n' "${SKIPPED_DEPLOYMENTS[@]}"
    echo "============================================================"
}
handle_signal(){
    local signal="$1"
    trap - ERR INT TERM
    warn "收到系统信号：$signal"
    snapshot_event SIGNAL "" "$signal"
    [[ "$DRY_RUN" == true ]] || rollback || true
    send_wechat "收到系统信号 $signal，任务终止" CRITICAL
    exit 130
}
handle_error(){
    local rc=$? command="$BASH_COMMAND" line="${BASH_LINENO[0]:-unknown}"
    trap - ERR INT TERM
    err "脚本异常：ExitCode=$rc Line=$line Command=$command"
    snapshot_event SCRIPT_ERROR "" "rc=$rc,line=$line,command=$command"
    send_wechat "脚本异常，开始自动 Rollback。ExitCode=$rc Line=$line" CRITICAL
    [[ "$DRY_RUN" == true ]] || rollback || true
    exit "$rc"
}
preflight(){
    check_dependencies
    check_args
    check_k8s
    discover_deployments
    filter_deployments
    collect_baseline
}
run_main(){
    acquire_lock
    preflight
    [[ ${#FINAL_DEPLOYMENTS[@]} -gt 0 ]] || { warn "没有可执行 Deployment"; summary; return 0; }
    create_snapshot
    print_plan
    if [[ "$DRY_RUN" == true ]]; then
        local d
        for d in "${FINAL_DEPLOYMENTS[@]}"; do scale_one "$d"; done
        snapshot_event DRY_RUN_COMPLETED
        summary
        return 0
    fi
    confirm_start || { summary; return 0; }
    local d rc count=0
    for d in "${FINAL_DEPLOYMENTS[@]}"; do
        rc=0
        scale_one "$d" || rc=$?
        case "$rc" in
            0) ((count+=1)) ;;
            2) continue ;;
            *)
                err "执行失败：$d rc=$rc，开始 Rollback"
                snapshot_event TASK_FAILED "$d" "rc=$rc"
                rollback || true
                summary
                return 1
                ;;
        esac
        if (( count > 0 && count % BATCH_SIZE == 0 )); then
            if ! batch_observe "$count"; then
                err "批次复核失败，开始 Rollback"
                rollback || true
                summary
                return 1
            fi
        fi
    done
    if (( count > 0 && count % BATCH_SIZE != 0 )); then
        if ! batch_observe "$count"; then
            err "最后一批复核失败，开始 Rollback"
            rollback || true
            summary
            return 1
        fi
    fi
    if ! final_verify; then
        err "最终复核失败，开始 Rollback"
        rollback || true
        summary
        return 1
    fi
    snapshot_event COMPLETED "" "success=${#SUCCESS_DEPLOYMENTS[@]},skipped=${#SKIPPED_DEPLOYMENTS[@]}"
    summary
    send_wechat "灰度归零完成。成功=${#SUCCESS_DEPLOYMENTS[@]} 跳过=${#SKIPPED_DEPLOYMENTS[@]}" INFO
    info "任务完成"
}
main(){
    parse_args "$@"
    init_dirs
    trap 'handle_error' ERR
    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM
    run_main
}
main "$@"
