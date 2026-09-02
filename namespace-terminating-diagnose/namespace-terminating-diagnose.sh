#!/usr/bin/env bash
# ==============================================================================
# namespace-terminating-diagnose.sh
#
# Kubernetes Namespace Terminating 生产级只读诊断 CLI
#
# v2.1.0
#
# 子命令：
#   check       轻量检查；支持 --all-terminating 作为集群巡检入口
#   diagnose    单 Namespace 全链路深度诊断
#   report      深度诊断并生成 TXT / JSON / Prometheus 三类报告
#   force-check 严格检查是否满足人工 Break-Glass /finalize 前置条件
#
# 安全边界：
#   - Kubernetes API 严格只读，不执行 delete / patch / replace / finalize。
#   - FORCE-FINALIZE-READY 只表示满足“进入人工复核”的前置条件。
#   - 任何 Discovery、RBAC、资源枚举不完整都会 fail-closed。
#
# Exit Code:
#   0   SAFE
#   10  WARNING
#   20  DANGEROUS
#   30  FORCE-FINALIZE-READY（仅 force-check）
#   64  参数 / 依赖 / Kubernetes API 基础访问错误
# ==============================================================================

set -uo pipefail

VERSION="2.1.0"

COMMAND=""
NAMESPACE=""
ALL_TERMINATING=0
REQUEST_TIMEOUT="10s"
TERMINATING_THRESHOLD_SECONDS=600
MAX_DETAILS=20
JSON_MODE=0
NO_COLOR=0
PROMETHEUS_OUTPUT=""
OUTPUT_DIR="./namespace-terminating-diagnose-reports"
LEGACY_REPORT_FILE=""

TMP_DIR=""
RESOURCE_RECORDS_FILE=""
FINALIZER_RECORDS_FILE=""
PATROL_RECORDS_FILE=""
UNAVAILABLE_APISERVICE_FILE=""

SCAN_ERRORS=0
REMAINING_TOTAL=0
OBJECT_FINALIZER_TOTAL=0
TERMINATING_OBJECT_TOTAL=0
CUSTOM_RESOURCE_TOTAL=0
PVC_TOTAL=0
RELATED_PV_TOTAL=0
VOLUME_ATTACHMENT_TOTAL=0

NAMESPACE_PHASE=""
NAMESPACE_DELETION_TIMESTAMP=""
NAMESPACE_AGE_SECONDS=-1
NAMESPACE_AGE_KNOWN=0
NAMESPACE_FINALIZERS=""

VERDICT=""
VERDICT_EXIT=0
VERDICT_REASON=""
FORCE_READY=0

PATROL_TERMINATING_TOTAL=0
PATROL_OVER_THRESHOLD_TOTAL=0
PATROL_UNKNOWN_AGE_TOTAL=0

declare -a WARNINGS=()
declare -a DANGERS=()
declare -a FORCE_BLOCKERS=()
declare -a RELATED_PVS=()

declare -A RESOURCE_COUNTS=()
declare -A RESOURCE_TERM_COUNTS=()
declare -A RESOURCE_FINALIZER_COUNTS=()
declare -A WEBHOOK_SERVICE_STATE=()

C_RESET=""
C_BOLD=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_CYAN=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/resources.sh
source "${SCRIPT_DIR}/lib/resources.sh"
# shellcheck source=lib/storage-admission.sh
source "${SCRIPT_DIR}/lib/storage-admission.sh"
# shellcheck source=lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/patrol.sh
source "${SCRIPT_DIR}/lib/patrol.sh"

main() {
  parse_args "$@"
  setup_runtime

  local rc=0

  if (( ALL_TERMINATING == 1 )); then
    run_patrol_command || rc=$?
  else
    run_target_command || rc=$?
  fi

  exit "$rc"
}

main "$@"
