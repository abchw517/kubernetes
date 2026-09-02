#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOL="${TOOL:-${ROOT}/../pod-start-time-check.sh}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin"
ln -s "${ROOT}/mock-kubectl" "${TMP}/bin/kubectl"
export PATH="${TMP}/bin:${PATH}"
export MOCK_FIXTURE_DIR="${ROOT}/fixtures"

run_tool() {
  local name="$1"; shift
  local dir="${TMP}/${name}"
  mkdir -p "${dir}/logs" "${dir}/reports" "${dir}/lock"
  LOG_DIR="${dir}/logs" REPORT_DIR="${dir}/reports" LOCK_FILE="${dir}/lock/tool.lock" \
    "$TOOL" "$@" >"${dir}/stdout" 2>"${dir}/stderr"
}

# 1. Main behavior: sorting + threshold boundaries + skip behavior.
run_tool behavior --dry-run
out="${TMP}/behavior/stdout"
grep -q 'pod-critical.*181s' "$out"
grep -q 'pod-warn180.*180s' "$out"
grep -q 'pod-warn121.*121s' "$out"
grep -q 'pod-normal120.*120s' "$out"
! grep -q 'pod-notready' "$out"
! grep -q 'pod-stateful' "$out"
line_181=$(grep -n 'pod-critical' "$out" | cut -d: -f1)
line_180=$(grep -n 'pod-warn180' "$out" | cut -d: -f1)
line_121=$(grep -n 'pod-warn121' "$out" | cut -d: -f1)
line_120=$(grep -n 'pod-normal120' "$out" | cut -d: -f1)
(( line_181 < line_180 && line_180 < line_121 && line_121 < line_120 ))
grep -q '>120s=4, >180s=1' "$out"

# 2. Strict RBAC must reject an obviously privileged identity.
set +e
MOCK_PRIVILEGED=1 run_tool privileged --dry-run
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q 'Strict RBAC 拒绝高权限身份' "${TMP}/privileged/stderr"

# 3. Zero timeout must be rejected before any Kubernetes operation.
set +e
run_tool zero-request --dry-run --request-timeout 0s
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q 'request-timeout 禁止为 0' "${TMP}/zero-request/stderr"

set +e
run_tool zero-command --dry-run --command-timeout 0
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q 'command-timeout 禁止为 0' "${TMP}/zero-command/stderr"

# 4. Safe lock must reject a symlink and must not truncate its target.
dir="${TMP}/symlink-lock"
mkdir -p "${dir}/logs" "${dir}/reports" "${dir}/lock"
printf 'KEEP\n' > "${dir}/target"
ln -s "${dir}/target" "${dir}/lock/tool.lock"
set +e
LOG_DIR="${dir}/logs" REPORT_DIR="${dir}/reports" LOCK_FILE="${dir}/lock/tool.lock" \
  "$TOOL" --dry-run >"${dir}/stdout" 2>"${dir}/stderr"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q '不能是符号链接' "${dir}/stderr"
[[ "$(cat "${dir}/target")" == 'KEEP' ]]

# 5. HTML escaping must be correct; non-dry-run with no webhook keeps report locally.
run_tool html
report=$(find "${TMP}/html/reports" -type f -name '*.html' -print -quit)
[[ -n "$report" ]]
grep -q 'dep&lt;&amp;&quot;' "$report"
! grep -q 'dep<&"' "$report"
grep -q 'scheduled_to_current_ready_transition_seconds' "$report"
grep -q '当前 Ready transition 的代理耗时' "$report"

# 6. Static regression: there must be no per-Pod date -d conversion.
! grep -q 'date -d' "$TOOL"
grep -q 'fromdateiso8601' "$TOOL"

printf 'pod-start-time-check v2.2.0 contract tests: OK\n'
