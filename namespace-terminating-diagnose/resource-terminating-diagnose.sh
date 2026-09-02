#!/usr/bin/env bash
# ==============================================================================
# resource-terminating-diagnose.sh
# Kubernetes Pod / PVC / PV / VolumeAttachment Terminating 只读关联诊断工具
# v1.0.0
# ==============================================================================
set -uo pipefail

VERSION="1.0.0"
COMMAND=""
KIND=""
NAME=""
NAMESPACE=""
REQUEST_TIMEOUT="10s"
TERMINATING_THRESHOLD_SECONDS=600
JSON_MODE=0
NO_COLOR=0
OUTPUT_DIR="./resource-terminating-diagnose-reports"
PROMETHEUS_OUTPUT=""
TMP_DIR=""
CHAIN_FILE=""
TARGET_JSON=""
TARGET_UID=""
TARGET_PHASE=""
TARGET_DELETION_TIMESTAMP=""
TARGET_AGE_SECONDS=-1
TARGET_AGE_KNOWN=0
TARGET_FINALIZERS=""
TARGET_OWNER_KIND=""
TARGET_OWNER_NAME=""
TARGET_NODE=""
TARGET_RECLAIM_POLICY=""
TARGET_VOLUME_HANDLE=""
NODE_STATE_RESULT=""
SCAN_ERRORS=0
REFERENCING_PODS=0
STATEFUL_PODS=0
ATTACHED_VOLUMEATTACHMENTS=0
UNHEALTHY_NODES=0
BOUND_PVS=0
DELETE_POLICY_PVS=0
CUSTOM_FINALIZER_BLOCKERS=0
VERDICT=""
VERDICT_REASON=""
VERDICT_EXIT=0
BREAK_GLASS_READY=0

declare -a WARNINGS=()
declare -a DANGERS=()
declare -a BLOCKERS=()
declare -A SEEN_PODS=()
declare -A SEEN_PVCS=()
declare -A SEEN_PVS=()
declare -A SEEN_VAS=()
declare -A SEEN_NODES=()

C_RESET=""
C_BOLD=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_CYAN=""

usage() {
  cat <<'EOF'
Usage:
  resource-terminating-diagnose.sh <command> --kind <kind> --name <name> [options]

Commands:
  check       轻量检查目标对象 deletionTimestamp / finalizers / 关键状态。
  diagnose    沿 Pod -> PVC -> PV -> VolumeAttachment -> Node 自动关联诊断。
  report      diagnose + TXT / JSON / Prometheus textfile 报告。
  force-check 只读检查是否满足进入人工 Break-Glass 复核的前置条件。

Required:
      --kind <pod|pvc|pv|volumeattachment>
      --name <resource-name>

Namespace:
  pod / pvc 必须指定 -n/--namespace。
  pv / volumeattachment 为 cluster-scoped，不需要 --namespace。

Options:
      --request-timeout <time>   默认 10s
      --threshold <seconds>      默认 600
      --json
      --prometheus-output <file>
      --output-dir <dir>
      --no-color
  -h, --help
  -V, --version

Examples:
  ./resource-terminating-diagnose.sh diagnose --kind pod -n pro-yunfan --name mysql-0
  ./resource-terminating-diagnose.sh diagnose --kind pvc -n pro-yunfan --name data-mysql-0 --json
  ./resource-terminating-diagnose.sh force-check --kind pv --name pvc-xxxx --threshold 900
EOF
}

die() { printf '[ERROR] %s\n' "$*" >&2; exit 64; }

init_colors() {
  if [[ -t 1 && "$NO_COLOR" -eq 0 && "$JSON_MODE" -eq 0 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
  fi
}

info() { (( JSON_MODE == 1 )) || printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { (( JSON_MODE == 1 )) || printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
danger() { (( JSON_MODE == 1 )) || printf '%s[DANGER]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
section() { (( JSON_MODE == 1 )) || printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }
add_warning() { WARNINGS+=("$*"); }
add_danger() { DANGERS+=("$*"); BLOCKERS+=("$*"); }
add_blocker() { BLOCKERS+=("$*"); }

cleanup() { [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
k() { kubectl --request-timeout="$REQUEST_TIMEOUT" "$@"; }

normalize_kind() {
  case "$1" in
    pod|pods) echo pod ;;
    pvc|persistentvolumeclaim|persistentvolumeclaims) echo pvc ;;
    pv|persistentvolume|persistentvolumes) echo pv ;;
    volumeattachment|volumeattachments|va) echo volumeattachment ;;
    *) return 1 ;;
  esac
}

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 64; }
  case "$1" in
    check|diagnose|report|force-check) COMMAND="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "resource-terminating-diagnose.sh ${VERSION}"; exit 0 ;;
    *) die "unknown command: $1" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) [[ $# -ge 2 ]] || die "--kind requires a value"; KIND=$(normalize_kind "$2") || die "unsupported --kind: $2"; shift 2 ;;
      --name) [[ $# -ge 2 ]] || die "--name requires a value"; NAME="$2"; shift 2 ;;
      -n|--namespace) [[ $# -ge 2 ]] || die "$1 requires a value"; NAMESPACE="$2"; shift 2 ;;
      --request-timeout) [[ $# -ge 2 ]] || die "$1 requires a value"; REQUEST_TIMEOUT="$2"; shift 2 ;;
      --threshold) [[ $# -ge 2 ]] || die "$1 requires a value"; TERMINATING_THRESHOLD_SECONDS="$2"; shift 2 ;;
      --json) JSON_MODE=1; shift ;;
      --prometheus-output) [[ $# -ge 2 ]] || die "$1 requires a value"; PROMETHEUS_OUTPUT="$2"; shift 2 ;;
      --output-dir) [[ $# -ge 2 ]] || die "$1 requires a value"; OUTPUT_DIR="$2"; shift 2 ;;
      --no-color) NO_COLOR=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) echo "resource-terminating-diagnose.sh ${VERSION}"; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [[ -n "$KIND" ]] || die "--kind is required"
  [[ -n "$NAME" ]] || die "--name is required"
  [[ "$TERMINATING_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || die "--threshold must be an integer >= 0"
  case "$KIND" in
    pod|pvc) [[ -n "$NAMESPACE" ]] || die "--namespace is required for kind=${KIND}" ;;
    pv|volumeattachment) [[ -z "$NAMESPACE" ]] || die "--namespace is not valid for cluster-scoped kind=${KIND}" ;;
  esac
  if [[ "$COMMAND" != report && "$OUTPUT_DIR" != "./resource-terminating-diagnose-reports" ]]; then
    die "--output-dir is only supported by report"
  fi
}

setup_runtime() {
  require_command kubectl; require_command jq; require_command date
  (( BASH_VERSINFO[0] >= 4 )) || die "bash >= 4 is required"
  TMP_DIR=$(mktemp -d -t resource-terminating-diagnose.XXXXXX) || die "cannot create temporary directory"
  CHAIN_FILE="$TMP_DIR/chain.ndjson"; : >"$CHAIN_FILE"; init_colors
}

timestamp_age_seconds() {
  local ts="$1" epoch now
  epoch=$(date -d "$ts" +%s 2>/dev/null) || return 1
  now=$(date +%s); (( now >= epoch )) || return 1; echo $((now - epoch))
}

human_seconds() {
  local total="$1" days hours mins secs
  (( total >= 0 )) || { echo unknown; return; }
  days=$((total / 86400)); hours=$(((total % 86400) / 3600)); mins=$(((total % 3600) / 60)); secs=$((total % 60))
  if (( days > 0 )); then printf '%dd%dh%dm%ds' "$days" "$hours" "$mins" "$secs"
  elif (( hours > 0 )); then printf '%dh%dm%ds' "$hours" "$mins" "$secs"
  elif (( mins > 0 )); then printf '%dm%ds' "$mins" "$secs"
  else printf '%ds' "$secs"; fi
}

json_array_from_bash_array() {
  if (( $# == 0 )); then printf '[]'; else printf '%s\n' "$@" | jq -R . | jq -s .; fi
}

prom_escape() {
  local value="$1"; value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//$'\n'/\\n}; printf '%s' "$value"
}

record_chain() {
  local kind="$1" namespace="$2" name="$3" role="$4" status="$5" deleting="$6" finalizers="$7" details_json="$8"
  jq -nc --arg kind "$kind" --arg namespace "$namespace" --arg name "$name" --arg role "$role" --arg status "$status" \
    --arg deletion_timestamp "$deleting" --arg finalizers "$finalizers" --argjson details "$details_json" \
    '{kind:$kind,namespace:(if $namespace=="" then null else $namespace end),name:$name,role:$role,status:$status,deletion_timestamp:(if $deletion_timestamp=="" then null else $deletion_timestamp end),finalizers:(if $finalizers=="" then [] else ($finalizers|split(",")) end),details:$details}' >>"$CHAIN_FILE"
}

fetch_json() {
  local kind="$1" name="$2" namespace="$3" out=""
  if [[ -n "$namespace" ]]; then out=$(k get "$kind" "$name" -n "$namespace" -o json 2>"$TMP_DIR/fetch.err") || return 1
  else out=$(k get "$kind" "$name" -o json 2>"$TMP_DIR/fetch.err") || return 1; fi
  printf '%s' "$out"
}

node_health() {
  local node="$1" data ready
  if [[ -z "$node" ]]; then NODE_STATE_RESULT="Unscheduled"; return 0; fi
  if [[ -n "${SEEN_NODES[$node]:-}" ]]; then NODE_STATE_RESULT="${SEEN_NODES[$node]}"; return 0; fi
  if ! data=$(k get node "$node" -o json 2>/dev/null); then
    SEEN_NODES["$node"]="Missing"; UNHEALTHY_NODES=$((UNHEALTHY_NODES + 1)); NODE_STATE_RESULT="Missing"; return 0
  fi
  ready=$(jq -r '[.status.conditions[]? | select(.type=="Ready") | .status][0] // "Unknown"' <<<"$data")
  case "$ready" in
    True) SEEN_NODES["$node"]="Ready" ;;
    False) SEEN_NODES["$node"]="NotReady"; UNHEALTHY_NODES=$((UNHEALTHY_NODES + 1)) ;;
    *) SEEN_NODES["$node"]="Unknown"; UNHEALTHY_NODES=$((UNHEALTHY_NODES + 1)) ;;
  esac
  NODE_STATE_RESULT="${SEEN_NODES[$node]}"
}

classify_target_finalizers() {
  local finalizers="$1" f
  local -a arr=()
  [[ -n "$finalizers" ]] || return 0
  IFS=',' read -r -a arr <<<"$finalizers"
  for f in "${arr[@]}"; do
    case "$KIND:$f" in
      pvc:kubernetes.io/pvc-protection|pv:kubernetes.io/pv-protection|pv:external-provisioner.volume.kubernetes.io/finalizer|volumeattachment:external-attacher/*|pod:batch.kubernetes.io/job-tracking) ;;
      *) CUSTOM_FINALIZER_BLOCKERS=$((CUSTOM_FINALIZER_BLOCKERS + 1)); add_blocker "目标对象存在未识别/自定义 Finalizer: ${f}" ;;
    esac
  done
}

set_target_fields() {
  local data="$1"
  TARGET_JSON="$data"
  TARGET_UID=$(jq -r '.metadata.uid // ""' <<<"$data")
  TARGET_DELETION_TIMESTAMP=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$data")
  TARGET_FINALIZERS=$(jq -r '(.metadata.finalizers // []) | join(",")' <<<"$data")
  TARGET_PHASE=$(jq -r '.status.phase // (if .status.attached != null then ("attached=" + (.status.attached|tostring)) else "Unknown" end)' <<<"$data")
  TARGET_OWNER_KIND=$(jq -r '[.metadata.ownerReferences[]? | select(.controller==true) | .kind][0] // ""' <<<"$data")
  TARGET_OWNER_NAME=$(jq -r '[.metadata.ownerReferences[]? | select(.controller==true) | .name][0] // ""' <<<"$data")
  TARGET_NODE=$(jq -r '.spec.nodeName // ""' <<<"$data")
  TARGET_RECLAIM_POLICY=$(jq -r '.spec.persistentVolumeReclaimPolicy // ""' <<<"$data")
  TARGET_VOLUME_HANDLE=$(jq -r '.spec.csi.volumeHandle // ""' <<<"$data")
  if [[ -n "$TARGET_DELETION_TIMESTAMP" ]]; then
    if TARGET_AGE_SECONDS=$(timestamp_age_seconds "$TARGET_DELETION_TIMESTAMP"); then TARGET_AGE_KNOWN=1
    else TARGET_AGE_SECONDS=-1; TARGET_AGE_KNOWN=0; add_warning "无法解析 deletionTimestamp"; add_blocker "目标对象删除时长未知"; fi
  fi
  classify_target_finalizers "$TARGET_FINALIZERS"
}

preflight() {
  section "Preflight"
  local data
  if ! data=$(fetch_json "$KIND" "$NAME" "$NAMESPACE"); then [[ "$JSON_MODE" -eq 1 ]] || cat "$TMP_DIR/fetch.err" >&2; die "cannot read target ${KIND}/${NAME}"; fi
  set_target_fields "$data"
  info "tool version       : ${VERSION}"; info "command            : ${COMMAND}"; info "kind               : ${KIND}"
  info "namespace          : ${NAMESPACE:-<cluster-scoped>}"; info "name               : ${NAME}"; info "phase/status       : ${TARGET_PHASE}"
  info "deletionTimestamp  : ${TARGET_DELETION_TIMESTAMP:-<none>}"
  info "terminating age    : $([[ "$TARGET_AGE_KNOWN" -eq 1 ]] && human_seconds "$TARGET_AGE_SECONDS" || echo unknown)"
  info "finalizers         : ${TARGET_FINALIZERS:-<none>}"
}

collect_pod() {
  local namespace="$1" name="$2" role="$3" key="${1}/${2}" data phase deleting finalizers node node_state owner_kind owner_name grace details pvc
  [[ -z "${SEEN_PODS[$key]:-}" ]] || return 0; SEEN_PODS["$key"]=1
  if ! data=$(fetch_json pod "$name" "$namespace"); then SCAN_ERRORS=$((SCAN_ERRORS + 1)); add_warning "无法读取 Pod ${namespace}/${name}"; return 0; fi
  phase=$(jq -r '.status.phase // "Unknown"' <<<"$data"); deleting=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$data"); finalizers=$(jq -r '(.metadata.finalizers // []) | join(",")' <<<"$data")
  node=$(jq -r '.spec.nodeName // ""' <<<"$data"); owner_kind=$(jq -r '[.metadata.ownerReferences[]? | select(.controller==true) | .kind][0] // ""' <<<"$data"); owner_name=$(jq -r '[.metadata.ownerReferences[]? | select(.controller==true) | .name][0] // ""' <<<"$data"); grace=$(jq -r '.spec.terminationGracePeriodSeconds // 30' <<<"$data")
  node_health "$node"; node_state="$NODE_STATE_RESULT"
  details=$(jq -nc --arg node "$node" --arg node_state "$node_state" --arg owner_kind "$owner_kind" --arg owner_name "$owner_name" --argjson grace "$grace" '{node:$node,node_ready:$node_state,owner_kind:$owner_kind,owner_name:$owner_name,termination_grace_period_seconds:$grace}')
  record_chain Pod "$namespace" "$name" "$role" "$phase" "$deleting" "$finalizers" "$details"
  if [[ "$owner_kind" == StatefulSet ]]; then STATEFUL_PODS=$((STATEFUL_PODS + 1)); add_danger "Pod ${namespace}/${name} 由 StatefulSet/${owner_name} 管理；强制删除存在双实例/存储身份风险"; fi
  case "$node_state" in Missing|NotReady|Unknown) add_warning "Pod ${namespace}/${name} 所在 Node ${node:-<none>} 状态=${node_state}" ;; esac
  while IFS= read -r pvc; do [[ -n "$pvc" ]] || continue; collect_pvc "$namespace" "$pvc" "referenced-by-pod:${namespace}/${name}"; done < <(jq -r '.spec.volumes[]? | .persistentVolumeClaim.claimName? // empty' <<<"$data" | sort -u)
}

collect_pvc() {
  local namespace="$1" name="$2" role="$3" key="${1}/${2}" data phase deleting finalizers pv sc details pods_json pod_name ref_count
  [[ -z "${SEEN_PVCS[$key]:-}" ]] || return 0; SEEN_PVCS["$key"]=1
  if ! data=$(fetch_json pvc "$name" "$namespace"); then SCAN_ERRORS=$((SCAN_ERRORS + 1)); add_warning "无法读取 PVC ${namespace}/${name}"; return 0; fi
  phase=$(jq -r '.status.phase // "Unknown"' <<<"$data"); deleting=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$data"); finalizers=$(jq -r '(.metadata.finalizers // []) | join(",")' <<<"$data")
  pv=$(jq -r '.spec.volumeName // ""' <<<"$data"); sc=$(jq -r '.spec.storageClassName // ""' <<<"$data"); details=$(jq -nc --arg pv "$pv" --arg storage_class "$sc" '{pv:$pv,storage_class:$storage_class}')
  record_chain PersistentVolumeClaim "$namespace" "$name" "$role" "$phase" "$deleting" "$finalizers" "$details"
  if pods_json=$(k get pods -n "$namespace" -o json 2>/dev/null); then
    ref_count=$(jq --arg pvc "$name" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $pvc))] | length' <<<"$pods_json")
    if (( ref_count > 0 )); then
      REFERENCING_PODS=$((REFERENCING_PODS + ref_count))
      if [[ "$KIND" == pod ]]; then add_warning "Pod 依赖 PVC ${namespace}/${name}；强制删除前必须确认卸载/Detach 链路"
      else add_danger "PVC ${namespace}/${name} 仍被 ${ref_count} 个 Pod 引用；pvc-protection 不应被绕过"; fi
      while IFS= read -r pod_name; do collect_pod "$namespace" "$pod_name" "uses-pvc:${namespace}/${name}"; done < <(jq -r --arg pvc "$name" '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $pvc)) | .metadata.name' <<<"$pods_json")
    fi
  else SCAN_ERRORS=$((SCAN_ERRORS + 1)); add_blocker "无法列举 Namespace ${namespace} 的 Pod，PVC 使用关系无法证明"; fi
  [[ -z "$pv" ]] || collect_pv "$pv" "bound-from-pvc:${namespace}/${name}"
}

collect_pv() {
  local name="$1" role="$2" data phase deleting finalizers reclaim sc claim_ns claim_name driver handle details va_json va_name va_count
  [[ -z "${SEEN_PVS[$name]:-}" ]] || return 0; SEEN_PVS["$name"]=1
  if ! data=$(fetch_json pv "$name" ""); then SCAN_ERRORS=$((SCAN_ERRORS + 1)); add_warning "无法读取 PV ${name}"; return 0; fi
  phase=$(jq -r '.status.phase // "Unknown"' <<<"$data"); deleting=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$data"); finalizers=$(jq -r '(.metadata.finalizers // []) | join(",")' <<<"$data")
  reclaim=$(jq -r '.spec.persistentVolumeReclaimPolicy // ""' <<<"$data"); sc=$(jq -r '.spec.storageClassName // ""' <<<"$data"); claim_ns=$(jq -r '.spec.claimRef.namespace // ""' <<<"$data"); claim_name=$(jq -r '.spec.claimRef.name // ""' <<<"$data"); driver=$(jq -r '.spec.csi.driver // ""' <<<"$data"); handle=$(jq -r '.spec.csi.volumeHandle // ""' <<<"$data")
  [[ "$phase" != Bound ]] || BOUND_PVS=$((BOUND_PVS + 1)); [[ "$reclaim" != Delete ]] || DELETE_POLICY_PVS=$((DELETE_POLICY_PVS + 1))
  details=$(jq -nc --arg reclaim "$reclaim" --arg storage_class "$sc" --arg claim_namespace "$claim_ns" --arg claim_name "$claim_name" --arg csi_driver "$driver" --arg volume_handle "$handle" '{reclaim_policy:$reclaim,storage_class:$storage_class,claim_namespace:$claim_namespace,claim_name:$claim_name,csi_driver:$csi_driver,volume_handle:$volume_handle}')
  record_chain PersistentVolume "" "$name" "$role" "$phase" "$deleting" "$finalizers" "$details"
  if [[ "$phase" == Bound && -n "$claim_name" ]]; then
    if [[ "$KIND" == pod ]]; then add_warning "Pod 关联 PV ${name} 仍 Bound，claimRef=${claim_ns}/${claim_name}"
    else add_danger "PV ${name} 仍处于 Bound，claimRef=${claim_ns}/${claim_name}"; fi
  fi
  [[ "$finalizers" != *external-provisioner.volume.kubernetes.io/finalizer* ]] || add_blocker "PV ${name} 仍有 external-provisioner backend-deletion finalizer；仅凭 Kubernetes API 无法证明后端卷已删除"
  [[ "$reclaim" != Delete || -z "$deleting" ]] || add_blocker "PV ${name} reclaimPolicy=Delete；Break-Glass 前必须在存储后端核验 volumeHandle=${handle:-<unknown>}"
  [[ -z "$claim_ns" || -z "$claim_name" ]] || collect_pvc "$claim_ns" "$claim_name" "claimRef-from-pv:${name}"
  if va_json=$(k get volumeattachments.storage.k8s.io -o json 2>/dev/null); then
    va_count=$(jq --arg pv "$name" '[.items[] | select(.spec.source.persistentVolumeName? == $pv)] | length' <<<"$va_json")
    if (( va_count > 0 )); then while IFS= read -r va_name; do collect_va "$va_name" "references-pv:${name}"; done < <(jq -r --arg pv "$name" '.items[] | select(.spec.source.persistentVolumeName? == $pv) | .metadata.name' <<<"$va_json"); fi
  else SCAN_ERRORS=$((SCAN_ERRORS + 1)); add_blocker "无法列举 VolumeAttachment，PV detach 状态无法证明"; fi
}

collect_va() {
  local name="$1" role="$2" data deleting finalizers pv node attached attacher node_state details
  [[ -z "${SEEN_VAS[$name]:-}" ]] || return 0; SEEN_VAS["$name"]=1
  if ! data=$(fetch_json volumeattachment "$name" ""); then SCAN_ERRORS=$((SCAN_ERRORS + 1)); add_warning "无法读取 VolumeAttachment ${name}"; return 0; fi
  deleting=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$data"); finalizers=$(jq -r '(.metadata.finalizers // []) | join(",")' <<<"$data"); pv=$(jq -r '.spec.source.persistentVolumeName // ""' <<<"$data"); node=$(jq -r '.spec.nodeName // ""' <<<"$data"); attached=$(jq -r '.status.attached // false' <<<"$data"); attacher=$(jq -r '.spec.attacher // ""' <<<"$data")
  node_health "$node"; node_state="$NODE_STATE_RESULT"
  details=$(jq -nc --arg pv "$pv" --arg node "$node" --arg node_state "$node_state" --arg attached "$attached" --arg attacher "$attacher" '{pv:$pv,node:$node,node_ready:$node_state,attached:($attached=="true"),attacher:$attacher}')
  record_chain VolumeAttachment "" "$name" "$role" "attached=${attached}" "$deleting" "$finalizers" "$details"
  if [[ "$attached" == true ]]; then ATTACHED_VOLUMEATTACHMENTS=$((ATTACHED_VOLUMEATTACHMENTS + 1)); add_danger "VolumeAttachment ${name} 仍 attached=true，PV=${pv:-<unknown>} Node=${node:-<unknown>}"; fi
  case "$node_state" in Missing|NotReady|Unknown) add_warning "VolumeAttachment ${name} 指向 Node ${node:-<none>}，Node 状态=${node_state}" ;; esac
  [[ -z "$pv" ]] || collect_pv "$pv" "source-from-volumeattachment:${name}"
}

collect_target_only() {
  section "Target State"
  local deleting="$TARGET_DELETION_TIMESTAMP" finalizers="$TARGET_FINALIZERS" details status node_state
  case "$KIND" in
    pod)
      node_health "$TARGET_NODE"; node_state="$NODE_STATE_RESULT"
      details=$(jq -nc --arg node "$TARGET_NODE" --arg node_state "$node_state" --arg owner_kind "$TARGET_OWNER_KIND" --arg owner_name "$TARGET_OWNER_NAME" '{node:$node,node_ready:$node_state,owner_kind:$owner_kind,owner_name:$owner_name}')
      record_chain Pod "$NAMESPACE" "$NAME" target "$TARGET_PHASE" "$deleting" "$finalizers" "$details" ;;
    pvc)
      details=$(jq -nc --arg pv "$(jq -r '.spec.volumeName // ""' <<<"$TARGET_JSON")" --arg storage_class "$(jq -r '.spec.storageClassName // ""' <<<"$TARGET_JSON")" '{pv:$pv,storage_class:$storage_class}')
      record_chain PersistentVolumeClaim "$NAMESPACE" "$NAME" target "$TARGET_PHASE" "$deleting" "$finalizers" "$details" ;;
    pv)
      details=$(jq -nc --arg reclaim "$TARGET_RECLAIM_POLICY" --arg claim_namespace "$(jq -r '.spec.claimRef.namespace // ""' <<<"$TARGET_JSON")" --arg claim_name "$(jq -r '.spec.claimRef.name // ""' <<<"$TARGET_JSON")" --arg csi_driver "$(jq -r '.spec.csi.driver // ""' <<<"$TARGET_JSON")" --arg volume_handle "$TARGET_VOLUME_HANDLE" '{reclaim_policy:$reclaim,claim_namespace:$claim_namespace,claim_name:$claim_name,csi_driver:$csi_driver,volume_handle:$volume_handle}')
      record_chain PersistentVolume "" "$NAME" target "$TARGET_PHASE" "$deleting" "$finalizers" "$details" ;;
    volumeattachment)
      status=$(jq -r '.status.attached // false' <<<"$TARGET_JSON"); node_health "$TARGET_NODE"; node_state="$NODE_STATE_RESULT"
      details=$(jq -nc --arg pv "$(jq -r '.spec.source.persistentVolumeName // ""' <<<"$TARGET_JSON")" --arg node "$TARGET_NODE" --arg node_state "$node_state" --arg attached "$status" --arg attacher "$(jq -r '.spec.attacher // ""' <<<"$TARGET_JSON")" '{pv:$pv,node:$node,node_ready:$node_state,attached:($attached=="true"),attacher:$attacher}')
      record_chain VolumeAttachment "" "$NAME" target "attached=${status}" "$deleting" "$finalizers" "$details" ;;
  esac
}

collect_full_chain() {
  section "Full Dependency Chain"
  case "$KIND" in
    pod) collect_pod "$NAMESPACE" "$NAME" target ;;
    pvc) collect_pvc "$NAMESPACE" "$NAME" target ;;
    pv) collect_pv "$NAME" target ;;
    volumeattachment) collect_va "$NAME" target ;;
  esac
}

apply_force_check_policy() {
  [[ "$COMMAND" == force-check ]] || return 0
  [[ -n "$TARGET_DELETION_TIMESTAMP" ]] || add_blocker "目标对象没有 deletionTimestamp，不属于卡住的 Terminating 删除流程"
  (( TARGET_AGE_KNOWN == 1 )) || add_blocker "无法证明目标对象已经超过 Terminating 阈值"
  if (( TARGET_AGE_KNOWN == 1 && TARGET_AGE_SECONDS < TERMINATING_THRESHOLD_SECONDS )); then add_blocker "目标对象 Terminating 时长未达到 ${TERMINATING_THRESHOLD_SECONDS}s"; fi
  (( SCAN_ERRORS == 0 )) || add_blocker "关联扫描存在 ${SCAN_ERRORS} 个错误，必须 fail-closed"
  case "$KIND" in
    pod)
      (( STATEFUL_PODS == 0 )) || add_blocker "StatefulSet Pod 禁止由工具自动进入强制删除就绪"
      if (( ${#SEEN_PVCS[@]} > 0 || ${#SEEN_PVS[@]} > 0 || ${#SEEN_VAS[@]} > 0 )); then add_blocker "Pod 关联持久化存储；必须先完成卸载/Detach 与数据一致性核验"; fi ;;
    pvc)
      (( REFERENCING_PODS == 0 )) || add_blocker "PVC 仍被 Pod 引用"; (( BOUND_PVS == 0 )) || add_blocker "PVC 关联 PV 仍 Bound"; (( ATTACHED_VOLUMEATTACHMENTS == 0 )) || add_blocker "PVC 关联 VolumeAttachment 仍 attached" ;;
    pv)
      (( BOUND_PVS == 0 )) || add_blocker "PV 仍 Bound"; (( REFERENCING_PODS == 0 )) || add_blocker "PV 关联 PVC 仍被 Pod 引用"; (( ATTACHED_VOLUMEATTACHMENTS == 0 )) || add_blocker "PV 仍存在 attached VolumeAttachment"; (( DELETE_POLICY_PVS == 0 )) || add_blocker "reclaimPolicy=Delete 的 PV 必须由人工到真实存储后端确认删除状态" ;;
    volumeattachment) add_blocker "VolumeAttachment 的真实 Detach 状态无法仅凭 Kubernetes API 证明；force-check 永不自动返回 Break-Glass Ready" ;;
  esac
}

determine_verdict() {
  BREAK_GLASS_READY=0
  if (( ${#DANGERS[@]} > 0 )); then VERDICT=DANGEROUS; VERDICT_EXIT=20; VERDICT_REASON="发现明确依赖关系、Stateful 身份或存储 Attach 风险；禁止绕过保护机制。"; return; fi
  if [[ "$COMMAND" == force-check && -n "$TARGET_DELETION_TIMESTAMP" ]] && (( TARGET_AGE_KNOWN == 1 && TARGET_AGE_SECONDS >= TERMINATING_THRESHOLD_SECONDS && SCAN_ERRORS == 0 && ${#BLOCKERS[@]} == 0 )); then
    BREAK_GLASS_READY=1; VERDICT=BREAK-GLASS-REVIEW-READY; VERDICT_EXIT=30; VERDICT_REASON="只读检查未发现已知依赖阻塞；可进入人工 Break-Glass 复核，但工具不会执行变更。"; return
  fi
  if (( ${#WARNINGS[@]} > 0 || ${#BLOCKERS[@]} > 0 || SCAN_ERRORS > 0 )); then VERDICT=WARNING; VERDICT_EXIT=10; VERDICT_REASON="存在未完全验证项、关联扫描错误或 Break-Glass 阻塞条件；修复后重新诊断。"; return; fi
  if [[ -n "$TARGET_DELETION_TIMESTAMP" ]]; then VERDICT=WARNING; VERDICT_EXIT=10; VERDICT_REASON="目标对象正在删除；当前未发现高风险关联，应优先让正常 Controller/kubelet/CSI 流程继续收敛。"
  else VERDICT=SAFE; VERDICT_EXIT=0; VERDICT_REASON="目标对象未处于 Terminating，未发现高风险关联。"; fi
}

print_chain() {
  (( JSON_MODE == 1 )) && return 0; section "Dependency Graph"; [[ -s "$CHAIN_FILE" ]] || { info "no chain records"; return; }
  jq -r '[.kind,(.namespace // "-"),.name,.role,.status,(.deletion_timestamp // "-"),((.finalizers // [])|join(","))] | @tsv' "$CHAIN_FILE" |
  while IFS=$'\t' read -r kind ns name role status deleting finalizers; do printf '  %-22s %-24s %-44s role=%-34s status=%-18s deleting=%-20s finalizers=%s\n' "$kind" "$ns" "$name" "$role" "$status" "$deleting" "${finalizers:-<none>}"; done
}

print_summary() {
  (( JSON_MODE == 1 )) && return 0; section "Risk Summary"
  info "pods                       : ${#SEEN_PODS[@]}"; info "pvcs                       : ${#SEEN_PVCS[@]}"; info "pvs                        : ${#SEEN_PVS[@]}"; info "volumeattachments          : ${#SEEN_VAS[@]}"
  info "referencing pods           : ${REFERENCING_PODS}"; info "stateful pods              : ${STATEFUL_PODS}"; info "attached volumeattachments : ${ATTACHED_VOLUMEATTACHMENTS}"; info "unhealthy/missing nodes    : ${UNHEALTHY_NODES}"; info "bound pvs                  : ${BOUND_PVS}"; info "scan errors                : ${SCAN_ERRORS}"
  if (( ${#DANGERS[@]} > 0 )); then printf '\n%sDanger findings:%s\n' "$C_RED" "$C_RESET"; printf '  - %s\n' "${DANGERS[@]}"; fi
  if (( ${#WARNINGS[@]} > 0 )); then printf '\n%sWarnings:%s\n' "$C_YELLOW" "$C_RESET"; printf '  - %s\n' "${WARNINGS[@]}"; fi
  if (( ${#BLOCKERS[@]} > 0 )); then printf '\nBreak-Glass blockers:\n'; printf '  - %s\n' "${BLOCKERS[@]}"; fi
}

print_verdict() {
  (( JSON_MODE == 1 )) && return 0; section "Final Verdict"
  case "$VERDICT" in SAFE) printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_GREEN" "$VERDICT" "$C_RESET" ;; WARNING) printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_YELLOW" "$VERDICT" "$C_RESET" ;; DANGEROUS) printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_RED" "$VERDICT" "$C_RESET" ;; BREAK-GLASS-REVIEW-READY) printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_CYAN" "$VERDICT" "$C_RESET" ;; esac
  printf 'Reason : %s\nExit   : %s\nBreak-Glass review ready: %s\n' "$VERDICT_REASON" "$VERDICT_EXIT" "$([[ "$BREAK_GLASS_READY" -eq 1 ]] && echo true || echo false)"
}

build_json() {
  local warnings_json dangers_json blockers_json chain_json
  warnings_json=$(json_array_from_bash_array "${WARNINGS[@]}"); dangers_json=$(json_array_from_bash_array "${DANGERS[@]}"); blockers_json=$(json_array_from_bash_array "${BLOCKERS[@]}"); if [[ -s "$CHAIN_FILE" ]]; then chain_json=$(jq -s '.' "$CHAIN_FILE"); else chain_json='[]'; fi
  jq -n --arg schema_version 1 --arg tool resource-terminating-diagnose --arg version "$VERSION" --arg command "$COMMAND" --arg kind "$KIND" --arg namespace "$NAMESPACE" --arg name "$NAME" --arg uid "$TARGET_UID" --arg phase "$TARGET_PHASE" --arg deletion_timestamp "$TARGET_DELETION_TIMESTAMP" --arg finalizers "$TARGET_FINALIZERS" \
    --argjson terminating_age_seconds "$TARGET_AGE_SECONDS" --argjson threshold_seconds "$TERMINATING_THRESHOLD_SECONDS" --arg verdict "$VERDICT" --arg verdict_reason "$VERDICT_REASON" --argjson exit_code "$VERDICT_EXIT" --argjson break_glass_ready "$BREAK_GLASS_READY" --argjson pod_count "${#SEEN_PODS[@]}" --argjson pvc_count "${#SEEN_PVCS[@]}" --argjson pv_count "${#SEEN_PVS[@]}" --argjson va_count "${#SEEN_VAS[@]}" --argjson referencing_pods "$REFERENCING_PODS" --argjson stateful_pods "$STATEFUL_PODS" --argjson attached_vas "$ATTACHED_VOLUMEATTACHMENTS" --argjson unhealthy_nodes "$UNHEALTHY_NODES" --argjson bound_pvs "$BOUND_PVS" --argjson scan_errors "$SCAN_ERRORS" --argjson warnings "$warnings_json" --argjson dangers "$dangers_json" --argjson blockers "$blockers_json" --argjson chain "$chain_json" \
    '{schema_version:$schema_version,tool:$tool,version:$version,command:$command,generated_at:(now|todateiso8601),target:{kind:$kind,namespace:(if $namespace=="" then null else $namespace end),name:$name,uid:$uid,phase_or_status:$phase,deletion_timestamp:(if $deletion_timestamp=="" then null else $deletion_timestamp end),terminating_age_seconds:$terminating_age_seconds,finalizers:(if $finalizers=="" then [] else ($finalizers|split(",")) end)},threshold_seconds:$threshold_seconds,verdict:$verdict,verdict_reason:$verdict_reason,exit_code:$exit_code,break_glass_review_ready:($break_glass_ready==1),counts:{pods:$pod_count,pvcs:$pvc_count,pvs:$pv_count,volumeattachments:$va_count,referencing_pods:$referencing_pods,stateful_pods:$stateful_pods,attached_volumeattachments:$attached_vas,unhealthy_nodes:$unhealthy_nodes,bound_pvs:$bound_pvs,scan_errors:$scan_errors,warnings:($warnings|length),dangers:($dangers|length),blockers:($blockers|length)},warnings:$warnings,dangers:$dangers,blockers:$blockers,chain:$chain}'
}

write_prometheus() {
  local file="$1" dir tmp ns kind name verdict now ready
  dir=$(dirname "$file"); mkdir -p "$dir" || die "cannot create Prometheus output directory: $dir"; tmp="${file}.tmp.$$"; ns=$(prom_escape "$NAMESPACE"); kind=$(prom_escape "$KIND"); name=$(prom_escape "$NAME"); verdict=$(prom_escape "$VERDICT"); now=$(date +%s); ready=0; (( BREAK_GLASS_READY == 1 )) && ready=1
  {
    echo '# HELP resource_terminating_diagnose_target_info Last diagnosis verdict for a target resource.'; echo '# TYPE resource_terminating_diagnose_target_info gauge'; printf 'resource_terminating_diagnose_target_info{kind="%s",namespace="%s",name="%s",verdict="%s",command="%s"} 1\n' "$kind" "$ns" "$name" "$verdict" "$(prom_escape "$COMMAND")"
    echo '# HELP resource_terminating_diagnose_target_terminating_age_seconds Target terminating age; -1 means unknown/not deleting.'; echo '# TYPE resource_terminating_diagnose_target_terminating_age_seconds gauge'; printf 'resource_terminating_diagnose_target_terminating_age_seconds{kind="%s",namespace="%s",name="%s"} %d\n' "$kind" "$ns" "$name" "$TARGET_AGE_SECONDS"
    echo '# HELP resource_terminating_diagnose_attached_volumeattachments Attached VolumeAttachments in the dependency chain.'; echo '# TYPE resource_terminating_diagnose_attached_volumeattachments gauge'; printf 'resource_terminating_diagnose_attached_volumeattachments{kind="%s",namespace="%s",name="%s"} %d\n' "$kind" "$ns" "$name" "$ATTACHED_VOLUMEATTACHMENTS"
    echo '# HELP resource_terminating_diagnose_referencing_pods Pods that reference PVCs in the dependency chain.'; echo '# TYPE resource_terminating_diagnose_referencing_pods gauge'; printf 'resource_terminating_diagnose_referencing_pods{kind="%s",namespace="%s",name="%s"} %d\n' "$kind" "$ns" "$name" "$REFERENCING_PODS"
    echo '# HELP resource_terminating_diagnose_scan_errors Dependency scan errors.'; echo '# TYPE resource_terminating_diagnose_scan_errors gauge'; printf 'resource_terminating_diagnose_scan_errors{kind="%s",namespace="%s",name="%s"} %d\n' "$kind" "$ns" "$name" "$SCAN_ERRORS"
    echo '# HELP resource_terminating_diagnose_break_glass_review_ready Whether the target passed strict read-only Break-Glass prechecks.'; echo '# TYPE resource_terminating_diagnose_break_glass_review_ready gauge'; printf 'resource_terminating_diagnose_break_glass_review_ready{kind="%s",namespace="%s",name="%s"} %d\n' "$kind" "$ns" "$name" "$ready"
    echo '# HELP resource_terminating_diagnose_generated_timestamp_seconds Unix timestamp of the diagnosis.'; echo '# TYPE resource_terminating_diagnose_generated_timestamp_seconds gauge'; printf 'resource_terminating_diagnose_generated_timestamp_seconds{kind="%s",namespace="%s",name="%s"} %d\n' "$kind" "$ns" "$name" "$now"
  } >"$tmp" || { rm -f "$tmp"; die "cannot write Prometheus file"; }
  mv -f "$tmp" "$file" || die "cannot install Prometheus file"
}

write_text_report() {
  local file="$1"; mkdir -p "$(dirname "$file")" || die "cannot create report directory"
  {
    printf 'resource-terminating-diagnose v%s\nGenerated: %s\nCommand: %s\nTarget: %s %s/%s\nDeletionTimestamp: %s\nTerminatingAgeSeconds: %s\nVerdict: %s\nExitCode: %s\nBreakGlassReviewReady: %s\nReason: %s\n' "$VERSION" "$(date -Is 2>/dev/null || date)" "$COMMAND" "$KIND" "${NAMESPACE:-<cluster-scoped>}" "$NAME" "${TARGET_DELETION_TIMESTAMP:-<none>}" "$TARGET_AGE_SECONDS" "$VERDICT" "$VERDICT_EXIT" "$([[ "$BREAK_GLASS_READY" -eq 1 ]] && echo true || echo false)" "$VERDICT_REASON"
    printf '\nCounts:\n  pods=%s\n  pvcs=%s\n  pvs=%s\n  volumeattachments=%s\n  referencing_pods=%s\n  attached_volumeattachments=%s\n  stateful_pods=%s\n  unhealthy_nodes=%s\n  scan_errors=%s\n' "${#SEEN_PODS[@]}" "${#SEEN_PVCS[@]}" "${#SEEN_PVS[@]}" "${#SEEN_VAS[@]}" "$REFERENCING_PODS" "$ATTACHED_VOLUMEATTACHMENTS" "$STATEFUL_PODS" "$UNHEALTHY_NODES" "$SCAN_ERRORS"
    printf '\nWarnings:\n'; (( ${#WARNINGS[@]} == 0 )) || printf '  - %s\n' "${WARNINGS[@]}"; printf '\nDangers:\n'; (( ${#DANGERS[@]} == 0 )) || printf '  - %s\n' "${DANGERS[@]}"; printf '\nBlockers:\n'; (( ${#BLOCKERS[@]} == 0 )) || printf '  - %s\n' "${BLOCKERS[@]}"; printf '\nDependency chain (JSON Lines):\n'; cat "$CHAIN_FILE"
  } >"$file"
}

run_report() {
  local stamp base json_file txt_file prom_file result_json
  stamp=$(date +%Y%m%d-%H%M%S); base="${KIND}-${NAMESPACE:+${NAMESPACE}-}${NAME}-${stamp}"; mkdir -p "$OUTPUT_DIR" || die "cannot create output directory: $OUTPUT_DIR"; result_json=$(build_json); json_file="${OUTPUT_DIR}/${base}.json"; txt_file="${OUTPUT_DIR}/${base}.txt"; prom_file="${OUTPUT_DIR}/${base}.prom"; printf '%s\n' "$result_json" >"$json_file"; write_text_report "$txt_file"; write_prometheus "$prom_file"
  (( JSON_MODE == 1 )) || { info "JSON report       : ${json_file}"; info "TXT report        : ${txt_file}"; info "Prometheus report : ${prom_file}"; }
}

main() {
  parse_args "$@"; setup_runtime; preflight
  if [[ "$COMMAND" == check ]]; then collect_target_only; else collect_full_chain; fi
  apply_force_check_policy; determine_verdict
  [[ "$COMMAND" == check ]] || print_chain; print_summary; print_verdict
  [[ -z "$PROMETHEUS_OUTPUT" ]] || write_prometheus "$PROMETHEUS_OUTPUT"
  [[ "$COMMAND" != report ]] || run_report
  (( JSON_MODE == 0 )) || build_json
  exit "$VERDICT_EXIT"
}

main "$@"
