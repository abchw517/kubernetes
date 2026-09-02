#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOL="${TOOL:-${ROOT}/../pod-start-time-check.sh}"
PROVISION="${PROVISION:-${ROOT}/../provision-kubeconfig.sh}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/bin"
cp "${ROOT}/mock-kubectl" "${TMP}/bin/kubectl"
chmod 0700 "${TMP}/bin/kubectl"
export PATH="${TMP}/bin:${PATH}"
export MOCK_FIXTURE_DIR="${ROOT}/fixtures"

make_kubeconfig() {
  local file="$1"
  mkdir -p "$(dirname -- "$file")"
  chmod 0700 "$(dirname -- "$file")"
  cat > "$file" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters: []
users: []
contexts: []
KUBECONFIG
  chmod 0600 "$file"
}

run_tool() {
  local name="$1"; shift
  local dir="${TMP}/${name}"
  local kubeconfig="${dir}/identity/kubeconfig"
  mkdir -p "${dir}/logs" "${dir}/reports" "${dir}/lock"
  make_kubeconfig "$kubeconfig"
  : > "${dir}/kubectl.log"

  KUBECONFIG="${dir}/poison-admin-kubeconfig" \
  KUBECONFIG_FILE="$kubeconfig" \
  MOCK_KUBECTL_LOG="${dir}/kubectl.log" \
  LOG_DIR="${dir}/logs" \
  REPORT_DIR="${dir}/reports" \
  LOCK_FILE="${dir}/lock/tool.lock" \
    bash "$TOOL" "$@" >"${dir}/stdout" 2>"${dir}/stderr"
}

# 1. Main behavior remains unchanged.
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

# Every runtime kubectl invocation must force the dedicated kubeconfig.
while IFS= read -r line; do
  grep -q -- "--kubeconfig=${TMP}/behavior/identity/kubeconfig" <<< "$line"
done < "${TMP}/behavior/kubectl.log"
! grep -q 'poison-admin-kubeconfig' "${TMP}/behavior/kubectl.log"

# 2. Strict RBAC must reject privileged runtime identity.
export MOCK_PRIVILEGED=1
set +e
run_tool privileged --dry-run
rc=$?
set -e
unset MOCK_PRIVILEGED
[[ "$rc" -ne 0 ]]
grep -q 'Strict RBAC 拒绝高权限身份' "${TMP}/privileged/stderr"

# 3. Zero timeout remains rejected.
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

# 4. Identity hardening: missing kubeconfig must Fail Closed and never fall back.
dir="${TMP}/missing-kubeconfig"
mkdir -p "${dir}/logs" "${dir}/lock"
: > "${dir}/kubectl.log"
set +e
KUBECONFIG="${dir}/admin.conf" \
KUBECONFIG_FILE="${dir}/does-not-exist" \
MOCK_KUBECTL_LOG="${dir}/kubectl.log" \
LOG_DIR="${dir}/logs" LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --dry-run >"${dir}/stdout" 2>"${dir}/stderr"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q '禁止回退到默认 kubeconfig' "${dir}/stderr"
[[ ! -s "${dir}/kubectl.log" ]]

# 5. Identity hardening: kubeconfig symlink rejected before kubectl.
dir="${TMP}/symlink-kubeconfig"
mkdir -p "${dir}/identity" "${dir}/logs" "${dir}/lock"
printf 'apiVersion: v1\nkind: Config\n' > "${dir}/target"
chmod 0600 "${dir}/target"
ln -s "${dir}/target" "${dir}/identity/kubeconfig"
: > "${dir}/kubectl.log"
set +e
KUBECONFIG_FILE="${dir}/identity/kubeconfig" \
MOCK_KUBECTL_LOG="${dir}/kubectl.log" \
LOG_DIR="${dir}/logs" LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --dry-run >"${dir}/stdout" 2>"${dir}/stderr"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q '不能是符号链接' "${dir}/stderr"
[[ ! -s "${dir}/kubectl.log" ]]

# 6. Identity hardening: kubeconfig must be 0400 or 0600.
dir="${TMP}/mode-kubeconfig"
mkdir -p "${dir}/logs" "${dir}/lock"
make_kubeconfig "${dir}/identity/kubeconfig"
chmod 0644 "${dir}/identity/kubeconfig"
set +e
KUBECONFIG_FILE="${dir}/identity/kubeconfig" \
LOG_DIR="${dir}/logs" LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --dry-run >"${dir}/stdout" 2>"${dir}/stderr"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q '权限必须为 0400 或 0600' "${dir}/stderr"

# 7. Existing safe lock symlink protection remains intact.
dir="${TMP}/symlink-lock"
mkdir -p "${dir}/logs" "${dir}/reports" "${dir}/lock"
make_kubeconfig "${dir}/identity/kubeconfig"
printf 'KEEP\n' > "${dir}/target"
ln -s "${dir}/target" "${dir}/lock/tool.lock"
set +e
KUBECONFIG_FILE="${dir}/identity/kubeconfig" \
LOG_DIR="${dir}/logs" REPORT_DIR="${dir}/reports" LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --dry-run >"${dir}/stdout" 2>"${dir}/stderr"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q '不能是符号链接' "${dir}/stderr"
[[ "$(cat "${dir}/target")" == 'KEEP' ]]

# 8. HTML escaping remains correct.
run_tool html
report=$(find "${TMP}/html/reports" -type f -name '*.html' -print -quit)
[[ -n "$report" ]]
grep -q 'dep&lt;&amp;&quot;' "$report"
! grep -q 'dep<&"' "$report"
grep -q 'scheduled_to_current_ready_transition_seconds' "$report"

# 9. --log-dir still derives report dir, explicit REPORT_DIR still wins.
dir="${TMP}/derived-report"
mkdir -p "${dir}/lock"
make_kubeconfig "${dir}/identity/kubeconfig"
KUBECONFIG_FILE="${dir}/identity/kubeconfig" \
LOG_DIR= REPORT_DIR= LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --log-dir "${dir}/custom-logs" >"${dir}/stdout" 2>"${dir}/stderr"
report=$(find "${dir}/custom-logs/reports" -type f -name '*.html' -print -quit)
[[ -n "$report" ]]

dir="${TMP}/explicit-report"
mkdir -p "${dir}/lock" "${dir}/explicit-reports"
make_kubeconfig "${dir}/identity/kubeconfig"
KUBECONFIG_FILE="${dir}/identity/kubeconfig" \
LOG_DIR= REPORT_DIR="${dir}/explicit-reports" LOCK_FILE="${dir}/lock/tool.lock" \
  bash "$TOOL" --log-dir "${dir}/custom-logs" >"${dir}/stdout" 2>"${dir}/stderr"
report=$(find "${dir}/explicit-reports" -type f -name '*.html' -print -quit)
[[ -n "$report" ]]
[[ ! -d "${dir}/custom-logs/reports" ]]

# 10. Provisioning helper: ADMIN_KUBECONFIG is mandatory and output is dedicated 0600 kubeconfig.
dir="${TMP}/provision"
mkdir -p "${dir}/admin" "${dir}/runtime"
make_kubeconfig "${dir}/admin/admin.conf"
: > "${dir}/kubectl.log"
ADMIN_KUBECONFIG="${dir}/admin/admin.conf" \
KUBECONFIG_FILE="${dir}/runtime/kubeconfig" \
TOKEN_DURATION=24h \
MOCK_KUBECTL_LOG="${dir}/kubectl.log" \
  bash "$PROVISION" >"${dir}/stdout" 2>"${dir}/stderr"
[[ -f "${dir}/runtime/kubeconfig" && ! -L "${dir}/runtime/kubeconfig" ]]
[[ "$(stat -c '%a' "${dir}/runtime/kubeconfig")" == '600' ]]
grep -q 'server: "https://127.0.0.1:6443"' "${dir}/runtime/kubeconfig"
grep -q 'token: "eyJhbGci' "${dir}/runtime/kubeconfig"
grep -q 'current-context: pod-start-time-check' "${dir}/runtime/kubeconfig"
grep -q -- "--kubeconfig=${dir}/admin/admin.conf create token pod-start-time-check" "${dir}/kubectl.log"

set +e
ADMIN_KUBECONFIG= KUBECONFIG_FILE="${dir}/runtime/other" \
  bash "$PROVISION" >"${dir}/no-admin.out" 2>"${dir}/no-admin.err"
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -q '必须显式设置 ADMIN_KUBECONFIG' "${dir}/no-admin.err"

# 11. Static identity regressions.
grep -q 'KUBECONFIG_FILE="${KUBECONFIG_FILE:-/data/pod-start-time-check/kubeconfig}"' "$TOOL"
grep -q -- '--kubeconfig="${KUBECONFIG_FILE}"' "$TOOL"
! grep -q 'date -d' "$TOOL"
! bash "$TOOL" --help | grep -q -- '--kubeconfig'
bash "$TOOL" --version | grep -q '2.3.0'

printf 'pod-start-time-check v2.3.0 identity contract tests: OK\n'
