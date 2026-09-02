#!/usr/bin/env bash
# NamespaceTerminating > 10m 巡检入口
#
# 默认：
#   threshold = 600s
#
# 可通过环境变量覆盖：
#   NAMESPACE_TERMINATING_THRESHOLD=900
#
# 示例：
#   ./namespace-terminating-patrol.sh --json
#   ./namespace-terminating-patrol.sh \
#     --prometheus-output /var/lib/node_exporter/textfile_collector/namespace_terminating.prom

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
THRESHOLD="${NAMESPACE_TERMINATING_THRESHOLD:-600}"

exec "${SCRIPT_DIR}/namespace-terminating-diagnose.sh" \
  check \
  --all-terminating \
  --threshold "${THRESHOLD}" \
  "$@"
