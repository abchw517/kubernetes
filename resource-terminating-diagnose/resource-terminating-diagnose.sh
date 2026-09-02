#!/usr/bin/env bash
# ==============================================================================
# resource-terminating-diagnose.sh
# Kubernetes Pod/PVC/PV/VolumeAttachment Terminating production read-only CLI
# v1.1.0
# ==============================================================================

set -uo pipefail

VERSION="1.1.0"
COMMAND=""
RESOURCE_KIND=""
RESOURCE_NAME=""
NAMESPACE=""
JSON_MODE=0
THRESHOLD_SECONDS=600
REQUEST_TIMEOUT="10s"
EVENTS_LIMIT=20
PROMETHEUS_OUTPUT=""
INTERVAL_SECONDS=60
ONCE=0
TMP_DIR=""
QUERY_ERROR_FILE=""

EXIT_SAFE=0
EXIT_WARNING=10
EXIT_DANGEROUS=20
EXIT_FORCE_READY=30
EXIT_ERROR=64


SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/csi-events.sh
source "${SCRIPT_DIR}/lib/csi-events.sh"
# shellcheck source=lib/diagnose.sh
source "${SCRIPT_DIR}/lib/diagnose.sh"
# shellcheck source=lib/scan-output.sh
source "${SCRIPT_DIR}/lib/scan-output.sh"

trap cleanup EXIT

usage() {
  cat <<'USAGE'
resource-terminating-diagnose.sh v1.1.0

Usage:
  resource-terminating-diagnose.sh diagnose pod <name> -n <namespace> [--json]
  resource-terminating-diagnose.sh diagnose pvc <name> -n <namespace> [--json]
  resource-terminating-diagnose.sh diagnose pv <name> [--json]
  resource-terminating-diagnose.sh diagnose volumeattachment <name> [--json]

  resource-terminating-diagnose.sh force-check pod <name> -n <namespace> [--json]
  resource-terminating-diagnose.sh force-check pvc <name> -n <namespace> [--json]
  resource-terminating-diagnose.sh force-check pv <name> [--json]
  resource-terminating-diagnose.sh force-check volumeattachment <name> [--json]

  resource-terminating-diagnose.sh scan [--json] [--threshold-seconds 600]
      [--prometheus-output /path/resource-terminating.prom]

  resource-terminating-diagnose.sh collector --prometheus-output /path/resource-terminating.prom
      [--interval-seconds 60] [--once]

Common options:
  -n, --namespace <ns>          Namespace for Pod/PVC targets
  --json                        Machine-readable JSON output
  --threshold-seconds <sec>     Stuck/force-check age threshold (default: 600)
  --request-timeout <duration>  kubectl request timeout (default: 10s)
  --events-limit <n>            Max correlated events (default: 20)
  --prometheus-output <file>    Atomically write Prometheus textfile metrics
  --interval-seconds <sec>      Collector interval (default: 60)
  --once                        Collector executes one scan and exits

Exit codes:
  0   SAFE / successful scan
  10  WARNING
  20  DANGEROUS / force-check BLOCKED
  30  BREAK-GLASS-REVIEW-READY (force-check only; no mutation is performed)
  64  argument/dependency/target-access error

Safety:
  Strictly read-only. This tool never force-deletes resources, removes finalizers,
  deletes VolumeAttachments, or detaches/deletes backend storage.
USAGE
}

parse_args() {
  [[ $# -gt 0 ]] || { usage; exit "$EXIT_ERROR"; }
  COMMAND="$1"
  shift

  case "${COMMAND}" in
    diagnose|force-check)
      [[ $# -ge 2 ]] || { usage; exit "$EXIT_ERROR"; }
      RESOURCE_KIND="$1"
      RESOURCE_NAME="$2"
      shift 2
      ;;
    scan|collector) ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "${VERSION}"; exit 0 ;;
    *)
      echo "ERROR: unknown command: ${COMMAND}" >&2
      usage
      exit "$EXIT_ERROR"
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit "$EXIT_ERROR"; }
        NAMESPACE="$2"; shift 2
        ;;
      --json) JSON_MODE=1; shift ;;
      --threshold-seconds)
        [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit "$EXIT_ERROR"; }
        THRESHOLD_SECONDS="$2"; shift 2
        ;;
      --request-timeout)
        [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit "$EXIT_ERROR"; }
        REQUEST_TIMEOUT="$2"; shift 2
        ;;
      --events-limit)
        [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit "$EXIT_ERROR"; }
        EVENTS_LIMIT="$2"; shift 2
        ;;
      --prometheus-output)
        [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit "$EXIT_ERROR"; }
        PROMETHEUS_OUTPUT="$2"; shift 2
        ;;
      --interval-seconds)
        [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit "$EXIT_ERROR"; }
        INTERVAL_SECONDS="$2"; shift 2
        ;;
      --once) ONCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "ERROR: unknown argument: $1" >&2; exit "$EXIT_ERROR" ;;
    esac
  done

  [[ "${THRESHOLD_SECONDS}" =~ ^[0-9]+$ ]] || { echo "ERROR: --threshold-seconds must be an integer" >&2; exit "$EXIT_ERROR"; }
  [[ "${EVENTS_LIMIT}" =~ ^[0-9]+$ && "${EVENTS_LIMIT}" -gt 0 ]] || { echo "ERROR: --events-limit must be a positive integer" >&2; exit "$EXIT_ERROR"; }
  [[ "${INTERVAL_SECONDS}" =~ ^[0-9]+$ && "${INTERVAL_SECONDS}" -ge 30 ]] || { echo "ERROR: --interval-seconds must be >= 30" >&2; exit "$EXIT_ERROR"; }

  if [[ "${COMMAND}" == "diagnose" || "${COMMAND}" == "force-check" ]]; then
    case "${RESOURCE_KIND}" in
      pod|pvc)
        [[ -n "${NAMESPACE}" ]] || { echo "ERROR: ${RESOURCE_KIND} requires -n/--namespace" >&2; exit "$EXIT_ERROR"; }
        ;;
      pv|volumeattachment) ;;
      *) echo "ERROR: supported kinds: pod, pvc, pv, volumeattachment" >&2; exit "$EXIT_ERROR" ;;
    esac
  fi

  if [[ "${COMMAND}" == "collector" && -z "${PROMETHEUS_OUTPUT}" ]]; then
    echo "ERROR: collector requires --prometheus-output" >&2
    exit "$EXIT_ERROR"
  fi
}

setup_runtime() {
  need_cmd kubectl
  need_cmd jq
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/resource-terminating-diagnose.XXXXXX") || exit "$EXIT_ERROR"
  QUERY_ERROR_FILE="${TMP_DIR}/query-errors.tsv"
  : >"${QUERY_ERROR_FILE}"
}

main() {
  parse_args "$@"
  setup_runtime

  local out rc=0 verdict
  case "$COMMAND" in
    diagnose)
      out=$(diagnose_target) || exit "$EXIT_ERROR"
      verdict=$(jq -r '.verdict' <<<"$out")
      case "$verdict" in
        SAFE) rc=$EXIT_SAFE ;;
        WARNING) rc=$EXIT_WARNING ;;
        DANGEROUS) rc=$EXIT_DANGEROUS ;;
      esac
      if [[ -n "$PROMETHEUS_OUTPUT" ]]; then
        write_target_prometheus "$out" "$PROMETHEUS_OUTPUT" || exit "$EXIT_ERROR"
      fi
      if (( JSON_MODE == 1 )); then printf '%s\n' "$out"; else human_output <<<"$out"; fi
      ;;
    force-check)
      out=$(diagnose_target) || exit "$EXIT_ERROR"
      out=$(force_check_graph "$out")
      if [[ -n "$PROMETHEUS_OUTPUT" ]]; then
        write_target_prometheus "$out" "$PROMETHEUS_OUTPUT" || exit "$EXIT_ERROR"
      fi
      if (( JSON_MODE == 1 )); then printf '%s\n' "$out"; else human_output <<<"$out"; fi
      if [[ $(jq -r '.forceCheck.eligibleForHumanReview' <<<"$out") == "true" ]]; then rc=$EXIT_FORCE_READY; else rc=$EXIT_DANGEROUS; fi
      ;;
    scan)
      out=$(scan_all)
      if [[ -n "$PROMETHEUS_OUTPUT" ]]; then
        write_scan_prometheus "$out" "$PROMETHEUS_OUTPUT" || exit "$EXIT_ERROR"
      fi
      if (( JSON_MODE == 1 )); then printf '%s\n' "$out"; else scan_human_output <<<"$out"; fi
      [[ $(jq -r '.diagnostics.complete' <<<"$out") == "true" ]] || rc=$EXIT_WARNING
      ;;
    collector)
      collector_loop
      return $?
      ;;
  esac

  return "$rc"
}

main "$@"
