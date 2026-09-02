#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOOL="${PROJECT_DIR}/namespace-terminating-diagnose.sh"
MOCK_BIN="${PROJECT_DIR}/tests/mock/bin"
TARGET_SCHEMA="${PROJECT_DIR}/tests/schema/target-result.schema.json"
PATROL_SCHEMA="${PROJECT_DIR}/tests/schema/patrol-result.schema.json"
VALIDATE_JSON="${PROJECT_DIR}/tests/validate-json.py"
TMP_DIR=$(mktemp -d -t namespace-diagnose-tests.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

chmod +x "${MOCK_BIN}/kubectl"
export PATH="${MOCK_BIN}:${PATH}"

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

run_json_case() {
  local name="$1"
  local scenario="$2"
  local expected_rc="$3"
  local schema="$4"
  shift 4

  local out="${TMP_DIR}/${name}.json"
  local err="${TMP_DIR}/${name}.err"
  local rc

  set +e
  MOCK_SCENARIO="$scenario" bash "$TOOL" "$@" >"$out" 2>"$err"
  rc=$?
  set -e

  if (( rc != expected_rc )); then
    cat "$err" >&2 || true
    cat "$out" >&2 || true
    fail "${name}: expected exit ${expected_rc}, got ${rc}"
  fi

  python3 "$VALIDATE_JSON" "$schema" "$out"
  pass "${name}: exit=${rc}, JSON schema valid"
  printf '%s\n' "$out"
}

version=$(bash "$TOOL" --version)
[[ "$version" == *"2.1.0"* ]] || fail "version contract expected v2.1.0, got: $version"
pass "version contract"

force_json=$(run_json_case \
  force-ready clean 30 "$TARGET_SCHEMA" \
  force-check -n test --threshold 600 --json | tail -n1)
jq -e '
  .command == "force-check" and
  .verdict == "FORCE-FINALIZE-READY" and
  .exit_code == 30 and
  .force_finalize_ready == true and
  .counts.remaining_objects == 0 and
  .counts.pvc == 0 and
  .counts.related_pv == 0 and
  .counts.volume_attachments == 0
' "$force_json" >/dev/null || fail "force-ready JSON contract mismatch"
pass "force-check FORCE-FINALIZE-READY contract"

pvc_json=$(run_json_case \
  pvc-danger pvc 20 "$TARGET_SCHEMA" \
  diagnose -n test --threshold 600 --json | tail -n1)
jq -e '
  .command == "diagnose" and
  .verdict == "DANGEROUS" and
  .exit_code == 20 and
  .force_finalize_ready == false and
  .counts.pvc == 1 and
  .counts.related_pv == 1 and
  .counts.volume_attachments == 1 and
  .counts.objects_with_finalizers >= 1
' "$pvc_json" >/dev/null || fail "PVC/CSI danger contract mismatch"
pass "PVC/PV/VolumeAttachment danger contract"

discovery_json=$(run_json_case \
  discovery-danger discovery 20 "$TARGET_SCHEMA" \
  check -n test --threshold 600 --json | tail -n1)
jq -e '
  .command == "check" and
  .verdict == "DANGEROUS" and
  .exit_code == 20 and
  .force_finalize_ready == false and
  (.unavailable_apiservices | length) == 1
' "$discovery_json" >/dev/null || fail "APIService discovery contract mismatch"
pass "APIService discovery failure contract"

patrol_json=$(run_json_case \
  patrol-old patrol 10 "$PATROL_SCHEMA" \
  check --all-terminating --threshold 600 --json | tail -n1)
jq -e '
  .command == "check" and
  .mode == "all-terminating" and
  .verdict == "WARNING" and
  .exit_code == 10 and
  .counts.terminating == 1 and
  .counts.over_threshold == 1 and
  (.namespaces | length) == 1 and
  .namespaces[0].over_threshold == true
' "$patrol_json" >/dev/null || fail "patrol contract mismatch"
pass "NamespaceTerminating >10m patrol contract"

prom_file="${TMP_DIR}/patrol.prom"
set +e
MOCK_SCENARIO=patrol bash "$TOOL" \
  check --all-terminating --threshold 600 \
  --prometheus-output "$prom_file" >/dev/null 2>"${TMP_DIR}/prom.err"
prom_rc=$?
set -e
(( prom_rc == 10 )) || fail "Prometheus patrol expected exit 10, got ${prom_rc}"
[[ -s "$prom_file" ]] || fail "Prometheus output file is empty"
grep -q '^namespace_terminating_diagnose_patrol_over_threshold_total 1$' "$prom_file" ||
  fail "missing patrol over-threshold metric"
grep -q 'namespace_terminating_diagnose_namespace_over_threshold{namespace="old-terminating",threshold_seconds="600"} 1' "$prom_file" ||
  fail "missing per-Namespace over-threshold metric"
pass "Prometheus textfile collector contract"

report_dir="${TMP_DIR}/reports"
report_stdout="${TMP_DIR}/report-stdout.json"
set +e
MOCK_SCENARIO=clean bash "$TOOL" \
  report -n test --threshold 600 --output-dir "$report_dir" --json \
  >"$report_stdout" 2>"${TMP_DIR}/report.err"
report_rc=$?
set -e
(( report_rc == 0 )) || {
  cat "${TMP_DIR}/report.err" >&2 || true
  fail "report expected exit 0, got ${report_rc}"
}
python3 "$VALIDATE_JSON" "$TARGET_SCHEMA" "$report_stdout"
mapfile -t report_json_files < <(find "$report_dir" -maxdepth 1 -type f -name '*.json' -print)
mapfile -t report_txt_files < <(find "$report_dir" -maxdepth 1 -type f -name '*.txt' -print)
mapfile -t report_prom_files < <(find "$report_dir" -maxdepth 1 -type f -name '*.prom' -print)
(( ${#report_json_files[@]} == 1 )) || fail "report must generate exactly one JSON file"
(( ${#report_txt_files[@]} == 1 )) || fail "report must generate exactly one TXT file"
(( ${#report_prom_files[@]} == 1 )) || fail "report must generate exactly one Prometheus file"
python3 "$VALIDATE_JSON" "$TARGET_SCHEMA" "${report_json_files[0]}"
pass "report TXT/JSON/Prometheus artifact contract"

bash "${PROJECT_DIR}/tests/validate-readonly.sh"
pass "production Shell read-only contract"

printf '\nAll namespace-terminating-diagnose contract tests passed: %d\n' "$pass_count"
