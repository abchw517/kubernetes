# shellcheck shell=bash
# namespace-terminating-diagnose v2.0.0 library

usage() {
  cat <<'EOF'
Usage:
  namespace-terminating-diagnose.sh <command> [options]

Commands:
  check
      轻量检查 Namespace 状态、Conditions 与 APIService。

      集群巡检入口：
        check --all-terminating --threshold 600

      用于 Jenkins / Cron / AIOps 定时发现 Terminating 超过阈值的 Namespace。

  diagnose
      对单个 Namespace 做完整只读诊断：
      Conditions / APIService / 全量 namespaced resources / Finalizer /
      Pod / PVC / PV / VolumeAttachment / CR / Webhook / VAP。

  report
      执行完整诊断，并在 --output-dir 下生成：
        <namespace>-<timestamp>.txt
        <namespace>-<timestamp>.json
        <namespace>-<timestamp>.prom

  force-check
      执行完整诊断，并严格判断是否满足人工 Break-Glass /finalize 前置条件。
      只有该子命令可以返回 FORCE-FINALIZE-READY / exit 30。

Common options:
  -n, --namespace <name>         目标 Namespace
      --request-timeout <time>   单次 kubectl 请求超时，默认 10s
      --threshold <seconds>      Terminating 阈值，默认 600（10 分钟）
      --max-details <number>     每类最多输出详情数，默认 20
      --json                     stdout 仅输出机器可读 JSON
      --prometheus-output <file> 写 Prometheus textfile collector 格式指标
      --no-color                 禁用颜色
  -h, --help                     显示帮助
  -V, --version                  显示版本

check options:
      --all-terminating          巡检集群内所有 Terminating Namespace。
                                 此模式不需要 -n。

report options:
      --output-dir <dir>         报告输出目录，默认：
                                 ./namespace-terminating-diagnose-reports

Backward compatibility:
      --report <file>            兼容 v1.0.0：在 diagnose/force-check 中额外写摘要 TXT。

Examples:
  ./namespace-terminating-diagnose.sh check -n test

  ./namespace-terminating-diagnose.sh diagnose -n test

  ./namespace-terminating-diagnose.sh diagnose -n test --json

  ./namespace-terminating-diagnose.sh report -n test \
      --output-dir /data/logs/namespace-terminating-diagnose

  ./namespace-terminating-diagnose.sh force-check -n test --threshold 900

  ./namespace-terminating-diagnose.sh check \
      --all-terminating \
      --threshold 600 \
      --json

  ./namespace-terminating-diagnose.sh check \
      --all-terminating \
      --threshold 600 \
      --prometheus-output \
      /var/lib/node_exporter/textfile_collector/namespace_terminating.prom
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 64
}

init_colors() {
  if [[ -t 1 && "$NO_COLOR" -eq 0 && "$JSON_MODE" -eq 0 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
  fi
}

section() {
  (( JSON_MODE == 1 )) && return 0
  printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"
}

info() {
  (( JSON_MODE == 1 )) && return 0
  printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
}

ok() {
  (( JSON_MODE == 1 )) && return 0
  printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
  (( JSON_MODE == 1 )) && return 0
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

danger() {
  (( JSON_MODE == 1 )) && return 0
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
  [[ $# -gt 0 ]] || {
    usage
    exit 64
  }

  case "$1" in
    check|diagnose|report|force-check)
      COMMAND="$1"
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
      die "unknown command: $1"
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --all-terminating)
        ALL_TERMINATING=1
        shift
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
      --json)
        JSON_MODE=1
        shift
        ;;
      --prometheus-output)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        PROMETHEUS_OUTPUT="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --report)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        LEGACY_REPORT_FILE="$2"
        shift 2
        ;;
      --no-color)
        NO_COLOR=1
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

  [[ "$TERMINATING_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] ||
    die "--threshold must be an integer >= 0"
  [[ "$MAX_DETAILS" =~ ^[1-9][0-9]*$ ]] ||
    die "--max-details must be an integer > 0"

  if (( ALL_TERMINATING == 1 )); then
    [[ "$COMMAND" == "check" ]] ||
      die "--all-terminating is only supported by the check command"
    [[ -z "$NAMESPACE" ]] ||
      die "--all-terminating cannot be combined with --namespace"
  else
    [[ -n "$NAMESPACE" ]] ||
      die "${COMMAND} requires -n/--namespace"
  fi

  if [[ "$COMMAND" != "report" && "$OUTPUT_DIR" != "./namespace-terminating-diagnose-reports" ]]; then
    die "--output-dir is only supported by the report command"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "required command not found: $1"
}

setup_runtime() {
  require_command kubectl
  require_command jq
  require_command date

  if (( BASH_VERSINFO[0] < 4 )); then
    die "bash >= 4 is required; current: ${BASH_VERSION}"
  fi

  TMP_DIR=$(mktemp -d -t ns-terminating-diagnose.XXXXXX) ||
    die "cannot create temporary directory"

  RESOURCE_RECORDS_FILE="$TMP_DIR/resource-records.ndjson"
  FINALIZER_RECORDS_FILE="$TMP_DIR/finalizer-records.ndjson"
  PATROL_RECORDS_FILE="$TMP_DIR/patrol-records.ndjson"
  UNAVAILABLE_APISERVICE_FILE="$TMP_DIR/unavailable-apiservices.ndjson"

  : >"$RESOURCE_RECORDS_FILE"
  : >"$FINALIZER_RECORDS_FILE"
  : >"$PATROL_RECORDS_FILE"
  : >"$UNAVAILABLE_APISERVICE_FILE"

  init_colors
}

k() {
  kubectl --request-timeout="$REQUEST_TIMEOUT" "$@"
}

timestamp_age_seconds() {
  local ts="$1"
  local epoch now

  if ! epoch=$(date -d "$ts" +%s 2>/dev/null); then
    return 1
  fi

  now=$(date +%s)
  local age=$((now - epoch))
  (( age >= 0 )) || return 1
  echo "$age"
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

json_array_from_bash_array() {
  if (( $# == 0 )); then
    printf '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -s .
  fi
}

ndjson_to_array() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf '[]'
  else
    jq -s '.' "$file"
  fi
}

prom_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

preflight_cluster() {
  section "Preflight"

  local context client_version server_version

  context=$(k config current-context 2>/dev/null || true)
  client_version=$(kubectl version --client -o json 2>/dev/null |
    jq -r '.clientVersion.gitVersion // "unknown"' 2>/dev/null || true)

  if ! server_version=$(k version -o json 2>"$TMP_DIR/version.err"); then
    [[ "$JSON_MODE" -eq 1 ]] || cat "$TMP_DIR/version.err" >&2
    die "cannot access Kubernetes API"
  fi
  server_version=$(jq -r '.serverVersion.gitVersion // "unknown"' <<<"$server_version")

  info "tool version      : ${VERSION}"
  info "command           : ${COMMAND}"
  info "kubectl context   : ${context:-unknown}"
  info "kubectl client    : ${client_version:-unknown}"
  info "Kubernetes server : ${server_version:-unknown}"
  info "request timeout   : ${REQUEST_TIMEOUT}"
  info "threshold         : ${TERMINATING_THRESHOLD_SECONDS}s"
}

preflight_namespace() {
  if ! k get namespace "$NAMESPACE" >/dev/null 2>"$TMP_DIR/ns-access.err"; then
    [[ "$JSON_MODE" -eq 1 ]] || cat "$TMP_DIR/ns-access.err" >&2
    die "cannot read namespace '${NAMESPACE}'"
  fi
  info "namespace         : ${NAMESPACE}"
  ok "Kubernetes API and Namespace are readable"
}

