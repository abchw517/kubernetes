#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOL="${TOOL:-${ROOT}/../pod-start-time-check.sh}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/bin"
cp "${ROOT}/mock-kubectl" "${TMP}/bin/kubectl"
chmod 0700 "${TMP}/bin/kubectl"
export PATH="${TMP}/bin:${PATH}"
export MOCK_FIXTURE_DIR="${ROOT}/fixtures"

run_tool() {
  local name="$1"; shift
  local dir="${TMP}/${name}"
  mkdir -p "${dir}/logs" "${dir}/reports" "${dir}/lock"
  LOG_DIR="${dir}/logs" REPORT_DIR="${dir}/reports" LOCK_FILE="${dir}/lock/tool.lock" \
    bash "$TOOL" "$@" >"${dir}/stdout" 2>"${dir}/stderr"
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
export MOCK_PRIVILEGED=1
set +e
run_tool privileged --dry-run
rc=$?
set -e
unset MOCK_PRIVILEGED
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
  bash "$TOOL" --dry-run >"${dir}/stdout" 2>"${dir}/stderr"
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

# 6. P2: --log-dir must re-derive default REPORT_DIR after CLI parsing.
dir="${TMP}/derived-report"
mkdir -p "${dir}/lock"
LOG_DIR= REPORT_DIR= LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --log-dir "${dir}/custom-logs" >"${dir}/stdout" 2>"${dir}/stderr"
report=$(find "${dir}/custom-logs/reports" -type f -name '*.html' -print -quit)
[[ -n "$report" ]]

# Explicit REPORT_DIR must still win over --log-dir.
dir="${TMP}/explicit-report"
mkdir -p "${dir}/lock" "${dir}/explicit-reports"
LOG_DIR= REPORT_DIR="${dir}/explicit-reports" LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --log-dir "${dir}/custom-logs" >"${dir}/stdout" 2>"${dir}/stderr"
report=$(find "${dir}/explicit-reports" -type f -name '*.html' -print -quit)
[[ -n "$report" ]]
[[ ! -d "${dir}/custom-logs/reports" ]]

# 7. P2: Webhook secret must not be accepted via command-line argument.
set +e
run_tool webhook-arg --dry-run --webhook-url 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=SECRET'
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q -- '--webhook-url 已移除' "${TMP}/webhook-arg/stderr"
! bash "$TOOL" --help | grep -q -- '--webhook-url <url>'

# 8. Static regressions: no per-Pod date process and no redundant intermediate TSV helpers.
! grep -q 'date -d' "$TOOL"
grep -q 'fromdateiso8601' "$TOOL"
! grep -q 'kubectl_scope_args' "$TOOL"
! grep -q 'rs-deployment.tsv' "$TOOL"
! grep -q 'pods.tsv' "$TOOL"

# 9. Version marker.
bash "$TOOL" --version | grep -q '2.2.1'

printf 'pod-start-time-check v2.2.1 contract tests: OK\n'
