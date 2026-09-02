#!/usr/bin/env bash
# ==============================================================================
# terminating-diagnose.sh
# Kubernetes Terminating 专项治理统一入口（只读）
# ==============================================================================
set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage:
  terminating-diagnose.sh <command> <target> [options]

Commands:
  check | diagnose | report | force-check

Targets:
  namespace | pod | pvc | pv | volumeattachment

Examples:
  ./terminating-diagnose.sh diagnose namespace -n stuck-ns
  ./terminating-diagnose.sh diagnose pod -n pro-yunfan --name mysql-0
  ./terminating-diagnose.sh diagnose pvc -n pro-yunfan --name data-mysql-0 --json
  ./terminating-diagnose.sh force-check pv --name pvc-xxxxxxxx --threshold 900

Safety:
  统一入口及其后端诊断器都只读，不执行 Kubernetes 资源修改。
EOF
}

[[ $# -gt 0 ]] || {
  usage
  exit 64
}

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  -V|--version)
    echo "terminating-diagnose.sh ${VERSION}"
    exit 0
    ;;
esac

[[ $# -ge 2 ]] || {
  usage
  exit 64
}

command="$1"
target="$2"
shift 2

case "$command" in
  check|diagnose|report|force-check) ;;
  *)
    echo "[ERROR] unsupported command: ${command}" >&2
    exit 64
    ;;
esac

case "$target" in
  namespace|ns)
    exec "${SCRIPT_DIR}/namespace-terminating-diagnose.sh" "$command" "$@"
    ;;
  pod|pods|pvc|persistentvolumeclaim|pv|persistentvolume|volumeattachment|volumeattachments|va)
    exec "${SCRIPT_DIR}/resource-terminating-diagnose.sh" \
      "$command" --kind "$target" "$@"
    ;;
  *)
    echo "[ERROR] unsupported target: ${target}" >&2
    exit 64
    ;;
esac
