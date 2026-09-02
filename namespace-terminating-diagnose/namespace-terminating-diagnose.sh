#!/usr/bin/env bash
# ==============================================================================
# namespace-terminating-diagnose.sh
#
# Kubernetes Namespace Terminating 只读诊断工具
#
# 目标：
#   1. 自动检查 Namespace Conditions / Finalizers / 删除时长
#   2. 检查异常 APIService 及位于目标 Namespace 的 Aggregated API 后端
#   3. 完整枚举所有 namespaced resources，而不是仅依赖 kubectl get all
#   4. 定位所有 deletionTimestamp / metadata.finalizers
#   5. 专项检查 Pod / PVC / 关联 PV / VolumeAttachment
#   6. 识别 Namespaced CRD 对应的残留 CR
#   7. 检查 Validating/Mutating Webhook 与 ValidatingAdmissionPolicy
#   8. 输出 SAFE / WARNING / DANGEROUS / FORCE-FINALIZE-READY 四级结论
#
# 安全边界：
#   - 本脚本严格只读。
#   - 不执行 delete / patch / replace / finalize。
#   - FORCE-FINALIZE-READY 仅表示“已满足进入人工 Break-Glass 复核的前置条件”，
#     绝不表示脚本建议立即强制删除 Namespace。
#
# Exit Code:
#   0   SAFE
#   10  WARNING
#   20  DANGEROUS
#   30  FORCE-FINALIZE-READY
#   64  参数/依赖/基础访问错误
#
# Requirements:
#   bash >= 4
#   kubectl
#   jq
#   GNU date（用于精确计算 deletionTimestamp 时长；缺失时会降级并阻止 FORCE-READY）
# ==============================================================================

set -uo pipefail

VERSION="1.0.0"

NAMESPACE=""
REQUEST_TIMEOUT="10s"
TERMINATING_THRESHOLD_SECONDS=300
MAX_DETAILS=20
REPORT_FILE=""
NO_COLOR=0

TMP_DIR=""
SCAN_ERRORS=0
REMAINING_TOTAL=0
OBJECT_FINALIZER_TOTAL=0
TERMINATING_OBJECT_TOTAL=0
CUSTOM_RESOURCE_TOTAL=0
NAMESPACE_PHASE=""
NAMESPACE_DELETION_TIMESTAMP=""
NAMESPACE_AGE_SECONDS=-1
NAMESPACE_AGE_KNOWN=0

declare -a WARNINGS=()
declare -a DANGERS=()
declare -a FORCE_BLOCKERS=()
declare -a RELATED_PVS=()

declare -A RESOURCE_COUNTS=()
declare -A RESOURCE_TERM_COUNTS=()
declare -A RESOURCE_FINALIZER_COUNTS=()
declare -A WEBHOOK_SERVICE_STATE=()

if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_CYAN=""
fi

usage() {
  cat <<'EOF'
Usage:
  namespace-terminating-diagnose.sh -n <namespace> [options]

Options:
  -n, --namespace <name>        目标 Namespace（必填）
      --request-timeout <time>  单次 kubectl API 请求超时，默认 10s
      --threshold <seconds>     Terminating 超过多少秒才允许进入 FORCE-READY 评估
                               默认 300
      --max-details <number>    每类详细对象最多输出数量，默认 20
      --report <file>           同时将完整输出写入文件
      --no-color                禁用颜色
  -h, --help                    显示帮助
  -V, --version                 显示版本

Examples:
  ./namespace-terminating-diagnose.sh -n test
  ./namespace-terminating-diagnose.sh -n pro-yunfan --threshold 900
  ./namespace-terminating-diagnose.sh -n test --report /tmp/test-ns-report.log

Verdict:
  SAFE
    当前没有发现高风险删除阻塞；若刚进入 Terminating，优先继续等待控制器正常收敛。

  WARNING
    存在剩余资源、暂时性删除对象或无法完全验证的项；暂不满足强制 finalize 前置条件。

  DANGEROUS
    存在 PVC/PV/VolumeAttachment、残留 CR/Finalizer、异常 APIService、
    删除链路相关 Webhook/VAP 等高风险问题。禁止强制 finalize。

  FORCE-FINALIZE-READY
    Namespace 已 Terminating 超过阈值；完整资源扫描为空；对象 Finalizer 为空；
    API Discovery 未发现异常；没有高风险外部资源证据。
    这只是进入人工 Break-Glass 复核的条件，不会执行任何修改。
EOF
}

die() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 64
}

section() {
  printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"
}

info() {
  printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
}

ok() {
  printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

danger() {
  printf '%s[DANGER]%s %s\n' "$C_RED" "$C_RESET" "$*"
}

add_warning() {
  WARNINGS+=("$*")
}

add_danger() {
  DANGERS+=("$*")
  FORCE_BLOCKERS+=("$*")
}

add_force_blocker() {
  FORCE_BLOCKERS+=("$*")
}

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --request-timeout)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        REQUEST_TIMEOUT="$2"
        shift 2
        ;;
      --threshold)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        TERMINATING_THRESHOLD_SECONDS="$2"
        shift 2
        ;;
      --max-details)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        MAX_DETAILS="$2"
        shift 2
        ;;
      --report)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        REPORT_FILE="$2"
        shift 2
        ;;
      --no-color)
        NO_COLOR=1
        C_RESET=""
        C_BOLD=""
        C_GREEN=""
        C_YELLOW=""
        C_RED=""
        C_CYAN=""
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        echo "namespace-terminating-diagnose.sh ${VERSION}"
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$NAMESPACE" ]] || die "namespace is required: -n <namespace>"
  [[ "$TERMINATING_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] ||
    die "--threshold must be an integer >= 0"
  [[ "$MAX_DETAILS" =~ ^[1-9][0-9]*$ ]] ||
    die "--max-details must be an integer > 0"
}

setup_report() {
  [[ -z "$REPORT_FILE" ]] && return 0

  mkdir -p "$(dirname "$REPORT_FILE")" ||
    die "cannot create report directory: $(dirname "$REPORT_FILE")"

  touch "$REPORT_FILE" || die "cannot write report: $REPORT_FILE"
  exec > >(tee -a "$REPORT_FILE") 2>&1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "required command not found: $1"
}

k() {
  kubectl --request-timeout="$REQUEST_TIMEOUT" "$@"
}

timestamp_age_seconds() {
  local ts="$1"
  local epoch now

  if ! date -d "$ts" +%s >/dev/null 2>&1; then
    return 1
  fi

  epoch=$(date -d "$ts" +%s) || return 1
  now=$(date +%s)
  echo $((now - epoch))
}

human_seconds() {
  local total="$1"
  local days hours mins secs

  if (( total < 0 )); then
    echo "unknown"
    return
  fi

  days=$((total / 86400))
  hours=$(((total % 86400) / 3600))
  mins=$(((total % 3600) / 60))
  secs=$((total % 60))

  if (( days > 0 )); then
    printf '%dd%dh%dm%ds' "$days" "$hours" "$mins" "$secs"
  elif (( hours > 0 )); then
    printf '%dh%dm%ds' "$hours" "$mins" "$secs"
  elif (( mins > 0 )); then
    printf '%dm%ds' "$mins" "$secs"
  else
    printf '%ds' "$secs"
  fi
}

preflight() {
  section "Preflight"

  require_command kubectl
  require_command jq

  if (( BASH_VERSINFO[0] < 4 )); then
    die "bash >= 4 is required; current: ${BASH_VERSION}"
  fi

  TMP_DIR=$(mktemp -d -t ns-terminating-diagnose.XXXXXX) ||
    die "cannot create temporary directory"

  local context server_version client_version
  context=$(k config current-context 2>/dev/null || true)
  client_version=$(kubectl version --client -o json 2>/dev/null |
    jq -r '.clientVersion.gitVersion // .clientVersion.gitVersion // "unknown"' 2>/dev/null || true)
  server_version=$(k version -o json 2>/dev/null |
    jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || true)

  info "tool version        : ${VERSION}"
  info "kubectl context     : ${context:-unknown}"
  info "kubectl client      : ${client_version:-unknown}"
  info "Kubernetes server   : ${server_version:-unknown}"
  info "namespace           : ${NAMESPACE}"
  info "request timeout     : ${REQUEST_TIMEOUT}"
  info "force-ready threshold: ${TERMINATING_THRESHOLD_SECONDS}s"

  if ! k get namespace "$NAMESPACE" >/dev/null 2>"$TMP_DIR/ns-access.err"; then
    cat "$TMP_DIR/ns-access.err" >&2
    die "cannot read namespace '${NAMESPACE}'"
  fi

  ok "Kubernetes API and Namespace are readable"
}

check_namespace() {
  section "1. Namespace State / Conditions"

  local ns_json condition_count
  ns_json=$(k get namespace "$NAMESPACE" -o json) ||
    die "failed to read namespace JSON"

  NAMESPACE_PHASE=$(jq -r '.status.phase // "Unknown"' <<<"$ns_json")
  NAMESPACE_DELETION_TIMESTAMP=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$ns_json")

  info "phase              : ${NAMESPACE_PHASE}"
  info "deletionTimestamp  : ${NAMESPACE_DELETION_TIMESTAMP:-<none>}"

  if [[ -n "$NAMESPACE_DELETION_TIMESTAMP" ]]; then
    if NAMESPACE_AGE_SECONDS=$(timestamp_age_seconds "$NAMESPACE_DELETION_TIMESTAMP"); then
      NAMESPACE_AGE_KNOWN=1
      info "terminating age    : $(human_seconds "$NAMESPACE_AGE_SECONDS") (${NAMESPACE_AGE_SECONDS}s)"
    else
      NAMESPACE_AGE_SECONDS=-1
      NAMESPACE_AGE_KNOWN=0
      add_warning "无法解析 Namespace deletionTimestamp，不能进行 FORCE-READY 判定"
      add_force_blocker "Namespace terminating age is unknown"
      warn "GNU date unavailable or timestamp parse failed; force-ready evaluation disabled"
    fi
  fi

  local ns_finalizers
  ns_finalizers=$(jq -r '(.spec.finalizers // []) | join(",")' <<<"$ns_json")
  info "namespace finalizers: ${ns_finalizers:-<none>}"

  if jq -e '
      (.spec.finalizers // []) |
      map(select(. != "kubernetes")) |
      length > 0
    ' <<<"$ns_json" >/dev/null; then
    local custom_ns_finalizers
    custom_ns_finalizers=$(jq -r '
      (.spec.finalizers // []) |
      map(select(. != "kubernetes")) |
      join(",")
    ' <<<"$ns_json")
    add_danger "Namespace spec.finalizers 存在非标准值: ${custom_ns_finalizers}"
    danger "custom Namespace finalizer(s): ${custom_ns_finalizers}"
  fi

  condition_count=$(jq '(.status.conditions // []) | length' <<<"$ns_json")

  if (( condition_count == 0 )); then
    info "Namespace has no status.conditions"
  else
    printf '%-43s %-8s %-28s %s\n' "TYPE" "STATUS" "REASON" "MESSAGE"
    printf '%-43s %-8s %-28s %s\n' "----" "------" "------" "-------"

    while IFS=$'\t' read -r ctype cstatus creason cmessage; do
      printf '%-43s %-8s %-28s %s\n' \
        "$ctype" "$cstatus" "$creason" "$cmessage"

      if [[ "$cstatus" == "True" ]]; then
        case "$ctype" in
          NamespaceDeletionDiscoveryFailure)
            add_danger "NamespaceDeletionDiscoveryFailure=True: ${cmessage}"
            ;;
          NamespaceDeletionGroupVersionParsingFailure)
            add_danger "NamespaceDeletionGroupVersionParsingFailure=True: ${cmessage}"
            ;;
          NamespaceDeletionContentFailure)
            add_danger "NamespaceDeletionContentFailure=True: ${cmessage}"
            ;;
          NamespaceContentRemaining)
            add_warning "NamespaceContentRemaining=True: ${cmessage}"
            add_force_blocker "Namespace controller reports remaining content"
            ;;
          NamespaceFinalizersRemaining)
            add_danger "NamespaceFinalizersRemaining=True: ${cmessage}"
            ;;
          *)
            add_warning "Namespace condition ${ctype}=True: ${cmessage}"
            add_force_blocker "Unknown/active Namespace condition: ${ctype}=True"
            ;;
        esac
      fi
    done < <(
      jq -r '
        (.status.conditions // [])[] |
        [
          .type,
          .status,
          (.reason // "-"),
          ((.message // "-") | gsub("[\t\r\n]"; " "))
        ] | @tsv
      ' <<<"$ns_json"
    )
  fi

  if [[ "$NAMESPACE_PHASE" != "Terminating" ]]; then
    add_warning "Namespace 当前 phase=${NAMESPACE_PHASE}，不是 Terminating"
  fi
}

check_apiservices() {
  section "2. APIService / Aggregated API Discovery"

  local data
  if ! data=$(k get apiservice -o json 2>"$TMP_DIR/apiservice.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 APIService；API Discovery 健康状态无法确认"
    danger "failed to list APIService"
    sed 's/^/  /' "$TMP_DIR/apiservice.err"
    return
  fi

  local false_count
  false_count=$(jq '
    [
      .items[] |
      select(
        (([.status.conditions[]? |
          select(.type=="Available") |
          .status][0]) // "Unknown") != "True"
      )
    ] | length
  ' <<<"$data")

  if (( false_count == 0 )); then
    ok "all registered APIService objects report Available=True"
  else
    danger "${false_count} APIService object(s) are not Available=True"
    printf '%-45s %-10s %-30s %s\n' "APISERVICE" "AVAILABLE" "SERVICE" "MESSAGE"

    while IFS=$'\t' read -r name available service message; do
      printf '%-45s %-10s %-30s %s\n' "$name" "$available" "$service" "$message"
      add_danger "APIService ${name} Available=${available}; Namespace discovery may be blocked"
    done < <(
      jq -r '
        .items[] |
        (
          ([.status.conditions[]? |
            select(.type=="Available")][0]) // {}
        ) as $c |
        select(($c.status // "Unknown") != "True") |
        [
          .metadata.name,
          ($c.status // "Unknown"),
          (
            if .spec.service then
              (.spec.service.namespace + "/" + .spec.service.name)
            else
              "<local>"
            end
          ),
          (($c.message // "-") | gsub("[\t\r\n]"; " "))
        ] | @tsv
      ' <<<"$data"
    )
  fi

  local target_backend_count
  target_backend_count=$(jq --arg ns "$NAMESPACE" '
    [
      .items[] |
      select(.spec.service.namespace? == $ns)
    ] | length
  ' <<<"$data")

  if (( target_backend_count > 0 )); then
    danger "target Namespace hosts ${target_backend_count} APIService backend(s)"
    while IFS=$'\t' read -r name svc; do
      printf '  - %s -> %s\n' "$name" "$svc"
      add_danger "APIService ${name} backend service is inside target Namespace (${svc})"
    done < <(
      jq -r --arg ns "$NAMESPACE" '
        .items[] |
        select(.spec.service.namespace? == $ns) |
        [
          .metadata.name,
          (.spec.service.namespace + "/" + .spec.service.name)
        ] | @tsv
      ' <<<"$data"
    )
  fi
}

scan_all_namespaced_resources() {
  section "3. Full Namespaced Resource Scan"

  local resources resource obj_json count term_count finalizer_count
  local err_file="$TMP_DIR/api-resources.err"

  if ! resources=$(k api-resources \
      --verbs=list \
      --namespaced \
      -o name 2>"$err_file"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "kubectl api-resources 执行失败，无法证明 Namespace 已清空"
    danger "API resource discovery failed"
    sed 's/^/  /' "$err_file"
    return
  fi

  if [[ -s "$err_file" ]]; then
    warn "api-resources returned warnings/errors on stderr:"
    sed 's/^/  /' "$err_file"
    add_warning "api-resources 有 stderr 输出，需人工确认 Discovery 是否完整"
  fi

  resources=$(printf '%s\n' "$resources" | sed '/^[[:space:]]*$/d' | sort -u)

  if [[ -z "$resources" ]]; then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "api-resources 返回空列表，资源扫描不可用"
    return
  fi

  printf '%-58s %8s %12s %12s\n' "RESOURCE" "COUNT" "TERMINATING" "FINALIZERS"
  printf '%-58s %8s %12s %12s\n' "--------" "-----" "-----------" "----------"

  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue

    if ! obj_json=$(k get "$resource" \
        -n "$NAMESPACE" \
        --ignore-not-found \
        -o json 2>"$TMP_DIR/resource.err"); then
      SCAN_ERRORS=$((SCAN_ERRORS + 1))
      printf '%-58s %8s %12s %12s\n' "$resource" "ERROR" "-" "-"
      warn "cannot list ${resource}: $(tr '\n' ' ' < "$TMP_DIR/resource.err")"
      add_force_blocker "Unable to list namespaced resource: ${resource}"
      continue
    fi

    count=$(jq '(.items // []) | length' <<<"$obj_json" 2>/dev/null || echo 0)
    term_count=$(jq '
      [(.items // [])[] |
       select(.metadata.deletionTimestamp != null)] |
      length
    ' <<<"$obj_json" 2>/dev/null || echo 0)
    finalizer_count=$(jq '
      [(.items // [])[] |
       select(((.metadata.finalizers // []) | length) > 0)] |
      length
    ' <<<"$obj_json" 2>/dev/null || echo 0)

    RESOURCE_COUNTS["$resource"]="$count"
    RESOURCE_TERM_COUNTS["$resource"]="$term_count"
    RESOURCE_FINALIZER_COUNTS["$resource"]="$finalizer_count"

    if (( count > 0 )); then
      REMAINING_TOTAL=$((REMAINING_TOTAL + count))
      TERMINATING_OBJECT_TOTAL=$((TERMINATING_OBJECT_TOTAL + term_count))
      OBJECT_FINALIZER_TOTAL=$((OBJECT_FINALIZER_TOTAL + finalizer_count))
      printf '%-58s %8d %12d %12d\n' \
        "$resource" "$count" "$term_count" "$finalizer_count"

      add_force_blocker "Remaining resource: ${resource} count=${count}"

      if (( finalizer_count > 0 )); then
        add_danger "${resource} has ${finalizer_count} object(s) with metadata.finalizers"
      fi

      if (( term_count > 0 )); then
        add_warning "${resource} has ${term_count} terminating object(s)"
      fi

      if (( finalizer_count > 0 || term_count > 0 )); then
        jq -r --argjson max "$MAX_DETAILS" '
          [
            (.items // [])[] |
            select(
              .metadata.deletionTimestamp != null or
              ((.metadata.finalizers // []) | length) > 0
            ) |
            [
              .metadata.name,
              (.metadata.deletionTimestamp // "-"),
              ((.metadata.finalizers // []) | join(","))
            ]
          ][: $max][] |
          "    - name=\(.[0]) deletionTimestamp=\(.[1]) finalizers=\(if .[2]==\"\" then \"<none>\" else .[2] end)"
        ' <<<"$obj_json"
      fi
    fi
  done <<<"$resources"

  if (( REMAINING_TOTAL == 0 && SCAN_ERRORS == 0 )); then
    ok "full namespaced resource scan found no remaining objects"
  else
    warn "remaining objects=${REMAINING_TOTAL}, terminating objects=${TERMINATING_OBJECT_TOTAL}, objects-with-finalizers=${OBJECT_FINALIZER_TOTAL}, scan-errors=${SCAN_ERRORS}"
    if (( REMAINING_TOTAL > 0 )); then
      add_warning "Namespace 仍有 ${REMAINING_TOTAL} 个 namespaced object"
    fi
    if (( SCAN_ERRORS > 0 )); then
      add_danger "资源扫描存在 ${SCAN_ERRORS} 个错误，不能证明 Namespace 已清空"
    fi
  fi
}

check_pods() {
  section "4. Pod Deep Check"

  local data count nodes_json
  if ! data=$(k get pods -n "$NAMESPACE" -o json 2>"$TMP_DIR/pods.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 Pod"
    sed 's/^/  /' "$TMP_DIR/pods.err"
    return
  fi

  count=$(jq '.items | length' <<<"$data")
  if (( count == 0 )); then
    ok "no Pod remains"
    return
  fi

  warn "${count} Pod(s) remain"

  nodes_json=$(k get nodes -o json 2>/dev/null || echo '{"items":[]}')

  printf '%-48s %-12s %-36s %-12s %-16s %s\n' \
    "POD" "PHASE" "NODE" "NODE_READY" "DELETING" "FINALIZERS"

  while IFS=$'\t' read -r name phase node deleting finalizers; do
    local node_ready
    node_ready=$(jq -r --arg node "$node" '
      [
        .items[] |
        select(.metadata.name == $node) |
        .status.conditions[]? |
        select(.type=="Ready") |
        .status
      ][0] // "Unknown"
    ' <<<"$nodes_json")

    printf '%-48s %-12s %-36s %-12s %-16s %s\n' \
      "$name" "$phase" "${node:--}" "$node_ready" "${deleting:--}" "${finalizers:-<none>}"

    if [[ "$deleting" != "-" && "$node_ready" != "True" ]]; then
      add_warning "Terminating Pod ${name} is on Node ${node} Ready=${node_ready}"
    fi
  done < <(
    jq -r '
      .items[] |
      [
        .metadata.name,
        (.status.phase // "-"),
        (.spec.nodeName // "-"),
        (.metadata.deletionTimestamp // "-"),
        ((.metadata.finalizers // []) | join(","))
      ] | @tsv
    ' <<<"$data" | head -n "$MAX_DETAILS"
  )
}

check_storage() {
  section "5. PVC / PV / VolumeAttachment"

  local pvc_json pvc_count
  if ! pvc_json=$(k get pvc -n "$NAMESPACE" -o json 2>"$TMP_DIR/pvc.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 PVC"
    sed 's/^/  /' "$TMP_DIR/pvc.err"
  else
    pvc_count=$(jq '.items | length' <<<"$pvc_json")
    if (( pvc_count == 0 )); then
      ok "no PVC remains"
    else
      danger "${pvc_count} PVC(s) remain; storage must be reviewed before force-finalize"
      add_danger "Namespace 中仍有 ${pvc_count} 个 PVC"

      printf '%-42s %-12s %-44s %-16s %s\n' \
        "PVC" "STATUS" "PV" "DELETING" "FINALIZERS"

      jq -r '
        .items[] |
        [
          .metadata.name,
          (.status.phase // "-"),
          (.spec.volumeName // "-"),
          (.metadata.deletionTimestamp // "-"),
          ((.metadata.finalizers // []) | join(","))
        ] | @tsv
      ' <<<"$pvc_json" |
      head -n "$MAX_DETAILS" |
      while IFS=$'\t' read -r name phase pv deleting finalizers; do
        printf '%-42s %-12s %-44s %-16s %s\n' \
          "$name" "$phase" "$pv" "$deleting" "${finalizers:-<none>}"
      done
    fi
  fi

  local pv_json related_count
  if ! pv_json=$(k get pv -o json 2>"$TMP_DIR/pv.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 PV，无法确认 Namespace 关联存储"
    sed 's/^/  /' "$TMP_DIR/pv.err"
    return
  fi

  mapfile -t RELATED_PVS < <(
    jq -r --arg ns "$NAMESPACE" '
      .items[] |
      select(.spec.claimRef.namespace? == $ns) |
      .metadata.name
    ' <<<"$pv_json"
  )
  related_count=${#RELATED_PVS[@]}

  if (( related_count == 0 )); then
    ok "no PV has claimRef.namespace=${NAMESPACE}"
  else
    warn "${related_count} PV(s) still reference target Namespace"
    add_warning "${related_count} PV(s) still reference Namespace ${NAMESPACE}"
    add_force_blocker "PV objects still reference target Namespace"

    printf '%-44s %-12s %-10s %-28s %-16s %s\n' \
      "PV" "PHASE" "RECLAIM" "STORAGECLASS" "DELETING" "FINALIZERS"

    while IFS=$'\t' read -r name phase reclaim sc deleting finalizers; do
      printf '%-44s %-12s %-10s %-28s %-16s %s\n' \
        "$name" "$phase" "$reclaim" "$sc" "$deleting" "${finalizers:-<none>}"

      if [[ "$deleting" != "-" || "$phase" == "Bound" ]]; then
        add_danger "PV ${name} phase=${phase} deletionTimestamp=${deleting}; storage cleanup is not complete"
      fi

      if [[ "$finalizers" == *"external-provisioner.volume.kubernetes.io/finalizer"* ]]; then
        add_danger "PV ${name} still has CSI backend-deletion protection finalizer"
      fi
    done < <(
      jq -r --arg ns "$NAMESPACE" '
        .items[] |
        select(.spec.claimRef.namespace? == $ns) |
        [
          .metadata.name,
          (.status.phase // "-"),
          (.spec.persistentVolumeReclaimPolicy // "-"),
          (.spec.storageClassName // "-"),
          (.metadata.deletionTimestamp // "-"),
          ((.metadata.finalizers // []) | join(","))
        ] | @tsv
      ' <<<"$pv_json" | head -n "$MAX_DETAILS"
    )
  fi

  local va_json pvs_json va_count
  if ! va_json=$(k get volumeattachments.storage.k8s.io -o json 2>"$TMP_DIR/va.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 VolumeAttachment"
    sed 's/^/  /' "$TMP_DIR/va.err"
    return
  fi

  if (( related_count == 0 )); then
    ok "no related VolumeAttachment check required"
    return
  fi

  pvs_json=$(jq -n '$ARGS.positional' --args "${RELATED_PVS[@]}")
  va_count=$(jq --argjson pvs "$pvs_json" '
    [
      .items[] |
      select((.spec.source.persistentVolumeName // "") as $pv | $pvs | index($pv))
    ] | length
  ' <<<"$va_json")

  if (( va_count == 0 )); then
    ok "no VolumeAttachment references related PVs"
  else
    danger "${va_count} VolumeAttachment(s) still reference related PVs"
    add_danger "${va_count} VolumeAttachment(s) remain for Namespace-related PVs"

    jq -r --argjson pvs "$pvs_json" '
      .items[] |
      select((.spec.source.persistentVolumeName // "") as $pv | $pvs | index($pv)) |
      [
        .metadata.name,
        (.spec.source.persistentVolumeName // "-"),
        (.spec.nodeName // "-"),
        ((.status.attached // false) | tostring),
        (.metadata.deletionTimestamp // "-"),
        ((.metadata.finalizers // []) | join(","))
      ] | @tsv
    ' <<<"$va_json" |
    head -n "$MAX_DETAILS" |
    while IFS=$'\t' read -r name pv node attached deleting finalizers; do
      printf '  - VA=%s PV=%s node=%s attached=%s deleting=%s finalizers=%s\n' \
        "$name" "$pv" "$node" "$attached" "$deleting" "${finalizers:-<none>}"
    done
  fi
}

check_custom_resources() {
  section "6. CRD / Custom Resource Residuals"

  local crd_json
  if ! crd_json=$(k get customresourcedefinitions.apiextensions.k8s.io \
      -o json 2>"$TMP_DIR/crd.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 CRD；不能确认残留对象是否为 Custom Resource"
    sed 's/^/  /' "$TMP_DIR/crd.err"
    return
  fi

  local found=0 resource crd count term_count finalizer_count
  printf '%-58s %-48s %8s %12s %12s\n' \
    "CUSTOM RESOURCE" "CRD" "COUNT" "TERMINATING" "FINALIZERS"

  while IFS=$'\t' read -r resource crd; do
    count="${RESOURCE_COUNTS[$resource]:-0}"
    term_count="${RESOURCE_TERM_COUNTS[$resource]:-0}"
    finalizer_count="${RESOURCE_FINALIZER_COUNTS[$resource]:-0}"

    if (( count > 0 )); then
      found=1
      CUSTOM_RESOURCE_TOTAL=$((CUSTOM_RESOURCE_TOTAL + count))
      printf '%-58s %-48s %8d %12d %12d\n' \
        "$resource" "$crd" "$count" "$term_count" "$finalizer_count"
    fi
  done < <(
    jq -r '
      .items[] |
      select(.spec.scope == "Namespaced") |
      [
        (.spec.names.plural + "." + .spec.group),
        .metadata.name
      ] | @tsv
    ' <<<"$crd_json"
  )

  if (( found == 0 )); then
    ok "no remaining Custom Resource detected from installed Namespaced CRDs"
  else
    add_danger "Namespace 中仍有 ${CUSTOM_RESOURCE_TOTAL} 个 Custom Resource；必须确认对应 Operator/Finalizer"
    danger "${CUSTOM_RESOURCE_TOTAL} Custom Resource object(s) remain"
  fi
}

webhook_service_health() {
  local ns="$1"
  local svc="$2"
  local key="${ns}/${svc}"

  if [[ -n "${WEBHOOK_SERVICE_STATE[$key]:-}" ]]; then
    echo "${WEBHOOK_SERVICE_STATE[$key]}"
    return
  fi

  if ! k get service "$svc" -n "$ns" >/dev/null 2>&1; then
    WEBHOOK_SERVICE_STATE["$key"]="SERVICE-NOT-FOUND"
    echo "SERVICE-NOT-FOUND"
    return
  fi

  local slices ready
  if ! slices=$(k get endpointslice.discovery.k8s.io \
      -n "$ns" \
      -l "kubernetes.io/service-name=${svc}" \
      -o json 2>/dev/null); then
    WEBHOOK_SERVICE_STATE["$key"]="UNVERIFIED"
    echo "UNVERIFIED"
    return
  fi

  ready=$(jq '
    [
      .items[].endpoints[]? |
      select(.conditions.ready != false)
    ] | length
  ' <<<"$slices")

  if (( ready > 0 )); then
    WEBHOOK_SERVICE_STATE["$key"]="READY"
  else
    WEBHOOK_SERVICE_STATE["$key"]="NO-READY-ENDPOINT"
  fi

  echo "${WEBHOOK_SERVICE_STATE[$key]}"
}

inspect_webhook_kind() {
  local kind="$1"
  local data config_name webhook_name failure_policy service_ns service_name has_delete_like state

  if ! data=$(k get "$kind" -o json 2>"$TMP_DIR/${kind}.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 ${kind}"
    sed 's/^/  /' "$TMP_DIR/${kind}.err"
    return
  fi

  while IFS=$'\t' read -r config_name webhook_name failure_policy service_ns service_name has_delete_like; do
    [[ "$has_delete_like" == "true" ]] || continue

    if [[ "$service_ns" == "<url>" ]]; then
      if [[ "$failure_policy" == "Fail" ]]; then
        warn "${kind}/${config_name}/${webhook_name}: external URL + failurePolicy=Fail may affect DELETE/UPDATE"
        add_warning "External admission webhook ${config_name}/${webhook_name} may affect deletion"
      fi
      continue
    fi

    state=$(webhook_service_health "$service_ns" "$service_name")

    printf '  - %s/%s webhook=%s policy=%s service=%s/%s state=%s\n' \
      "$kind" "$config_name" "$webhook_name" "$failure_policy" \
      "$service_ns" "$service_name" "$state"

    if [[ "$service_ns" == "$NAMESPACE" ]]; then
      add_danger "${kind}/${config_name} backend ${service_ns}/${service_name} is inside target Namespace"
    fi

    if [[ "$failure_policy" == "Fail" ]]; then
      case "$state" in
        SERVICE-NOT-FOUND|NO-READY-ENDPOINT)
          add_danger "${kind}/${config_name}/${webhook_name} failurePolicy=Fail but backend state=${state}"
          ;;
        UNVERIFIED)
          add_warning "Unable to verify backend of Fail webhook ${config_name}/${webhook_name}"
          add_force_blocker "Fail webhook backend could not be verified: ${config_name}/${webhook_name}"
          ;;
      esac
    fi
  done < <(
    jq -r '
      .items[] as $cfg |
      $cfg.webhooks[]? |
      (
        [
          .rules[]?.operations[]?
        ] | any(. == "DELETE" or . == "UPDATE" or . == "*" )
      ) as $hasDeleteLike |
      [
        $cfg.metadata.name,
        .name,
        (.failurePolicy // "Fail"),
        (
          if .clientConfig.service then
            .clientConfig.service.namespace
          else
            "<url>"
          end
        ),
        (
          if .clientConfig.service then
            .clientConfig.service.name
          else
            "-"
          end
        ),
        ($hasDeleteLike | tostring)
      ] | @tsv
    ' <<<"$data"
  )
}

check_admission() {
  section "7. Admission Webhook / ValidatingAdmissionPolicy"

  info "Webhook check is conservative: DELETE/UPDATE/* + failurePolicy=Fail is treated as relevant."
  inspect_webhook_kind validatingwebhookconfigurations.admissionregistration.k8s.io
  inspect_webhook_kind mutatingwebhookconfigurations.admissionregistration.k8s.io

  if ! k api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null |
      grep -qx 'validatingadmissionpolicies'; then
    info "ValidatingAdmissionPolicy API is not available; skipped"
    return
  fi

  local policy_json binding_json
  if ! policy_json=$(k get validatingadmissionpolicies.admissionregistration.k8s.io \
      -o json 2>"$TMP_DIR/vap.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 ValidatingAdmissionPolicy"
    sed 's/^/  /' "$TMP_DIR/vap.err"
    return
  fi

  if ! binding_json=$(k get validatingadmissionpolicybindings.admissionregistration.k8s.io \
      -o json 2>"$TMP_DIR/vapbinding.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 ValidatingAdmissionPolicyBinding"
    sed 's/^/  /' "$TMP_DIR/vapbinding.err"
    return
  fi

  local policy_name failure_policy destructive binding_name actions param_ns
  while IFS=$'\t' read -r policy_name failure_policy destructive; do
    [[ "$destructive" == "true" ]] || continue

    while IFS=$'\t' read -r binding_name actions param_ns; do
      [[ -n "$binding_name" ]] || continue

      printf '  - VAP=%s binding=%s failurePolicy=%s actions=%s paramNamespace=%s\n' \
        "$policy_name" "$binding_name" "$failure_policy" "$actions" "$param_ns"

      if [[ "$failure_policy" == "Fail" && "$actions" == *"Deny"* ]]; then
        add_warning "VAP ${policy_name}/${binding_name} can Deny DELETE/UPDATE requests"

        if [[ "$param_ns" == "$NAMESPACE" ]]; then
          add_danger "VAP ${policy_name}/${binding_name} paramRef is in target Namespace; deletion ordering can block admission"
        fi
      fi
    done < <(
      jq -r --arg policy "$policy_name" '
        .items[] |
        select(.spec.policyName == $policy) |
        [
          .metadata.name,
          ((.spec.validationActions // []) | join(",")),
          (.spec.paramRef.namespace // "-")
        ] | @tsv
      ' <<<"$binding_json"
    )
  done < <(
    jq -r '
      .items[] |
      (
        [
          .spec.matchConstraints.resourceRules[]?.operations[]?
        ] | any(. == "DELETE" or . == "UPDATE" or . == "*")
      ) as $destructive |
      [
        .metadata.name,
        (.spec.failurePolicy // "Fail"),
        ($destructive | tostring)
      ] | @tsv
    ' <<<"$policy_json"
  )
}

print_risk_lists() {
  section "8. Risk Summary"

  info "remaining namespaced objects : ${REMAINING_TOTAL}"
  info "terminating objects          : ${TERMINATING_OBJECT_TOTAL}"
  info "objects with finalizers      : ${OBJECT_FINALIZER_TOTAL}"
  info "remaining Custom Resources   : ${CUSTOM_RESOURCE_TOTAL}"
  info "scan errors                   : ${SCAN_ERRORS}"
  info "warnings                      : ${#WARNINGS[@]}"
  info "danger findings               : ${#DANGERS[@]}"
  info "force-finalize blockers       : ${#FORCE_BLOCKERS[@]}"

  if (( ${#DANGERS[@]} > 0 )); then
    printf '\n%sDanger findings:%s\n' "$C_RED" "$C_RESET"
    printf '  - %s\n' "${DANGERS[@]}"
  fi

  if (( ${#WARNINGS[@]} > 0 )); then
    printf '\n%sWarnings:%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi

  if (( ${#FORCE_BLOCKERS[@]} > 0 )); then
    printf '\nForce-finalize blockers:\n'
    printf '  - %s\n' "${FORCE_BLOCKERS[@]}"
  fi
}

final_verdict() {
  section "9. Final Verdict"

  local verdict exit_code explanation

  if (( ${#DANGERS[@]} > 0 )); then
    verdict="DANGEROUS"
    exit_code=20
    explanation="存在高风险删除阻塞或外部资源风险；禁止强制清理 Namespace finalizer。应先修复对应 Controller / Storage / APIService / Admission / CR Finalizer。"

  elif [[ "$NAMESPACE_PHASE" == "Terminating" ]] &&
       (( NAMESPACE_AGE_KNOWN == 1 )) &&
       (( NAMESPACE_AGE_SECONDS >= TERMINATING_THRESHOLD_SECONDS )) &&
       (( REMAINING_TOTAL == 0 )) &&
       (( OBJECT_FINALIZER_TOTAL == 0 )) &&
       (( SCAN_ERRORS == 0 )) &&
       (( ${#FORCE_BLOCKERS[@]} == 0 )); then
    verdict="FORCE-FINALIZE-READY"
    exit_code=30
    explanation="只读检查未发现剩余 namespaced object、对象 Finalizer、Discovery/Storage/Admission 高风险阻塞，且 Terminating 已超过阈值。可以进入人工 Break-Glass 复核，但脚本不会执行 /finalize。"

  elif (( ${#WARNINGS[@]} > 0 )) ||
       (( REMAINING_TOTAL > 0 )) ||
       (( SCAN_ERRORS > 0 )) ||
       (( ${#FORCE_BLOCKERS[@]} > 0 )); then
    verdict="WARNING"
    exit_code=10
    explanation="存在剩余资源、暂时性问题或未完全验证项；继续等待/修复并重新执行诊断，不满足强制 finalize 条件。"

  else
    verdict="SAFE"
    exit_code=0
    if [[ "$NAMESPACE_PHASE" == "Terminating" ]]; then
      explanation="未发现高风险阻塞，且 Terminating 尚未超过强制复核阈值；优先继续等待 Namespace Controller 正常收敛。"
    else
      explanation="未发现高风险删除阻塞；Namespace 当前并非 Terminating。"
    fi
  fi

  case "$verdict" in
    SAFE)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_GREEN" "$verdict" "$C_RESET"
      ;;
    WARNING)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_YELLOW" "$verdict" "$C_RESET"
      ;;
    DANGEROUS)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_RED" "$verdict" "$C_RESET"
      ;;
    FORCE-FINALIZE-READY)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_CYAN" "$verdict" "$C_RESET"
      ;;
  esac

  printf 'Reason : %s\n' "$explanation"
  printf 'Exit   : %s\n' "$exit_code"

  if [[ "$verdict" == "FORCE-FINALIZE-READY" ]]; then
    cat <<'EOF'

Break-Glass checklist before any manual /finalize operation:
  [ ] 已确认目标 Namespace 确实应该删除
  [ ] 已确认业务 owner / 数据 owner 同意
  [ ] 已确认不存在云盘、LB、DNS、数据库、快照等外部资源残留
  [ ] 已确认相关 Operator/CSI/Cloud Controller 不再需要执行清理
  [ ] 已保存本脚本报告和 Namespace YAML 作为变更证据
  [ ] 强制 finalize 后将继续检查 PV / VolumeAttachment / CR / 云资源孤儿对象

This script does NOT execute force-finalize.
EOF
  fi

  return "$exit_code"
}

main() {
  parse_args "$@"
  setup_report
  preflight

  printf '\n%snamespace-terminating-diagnose.sh%s\n' "$C_BOLD" "$C_RESET"
  printf 'Generated at: %s\n' "$(date -Is 2>/dev/null || date)"

  check_namespace
  check_apiservices
  scan_all_namespaced_resources
  check_pods
  check_storage
  check_custom_resources
  check_admission
  print_risk_lists

  local rc=0
  final_verdict || rc=$?

  if [[ -n "$REPORT_FILE" ]]; then
    info "report saved to: ${REPORT_FILE}"
  fi

  exit "$rc"
}

main "$@"
