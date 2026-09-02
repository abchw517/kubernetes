#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOOL="${SCRIPT_DIR}/resource-terminating-diagnose.sh"
COLLECTOR="${SCRIPT_DIR}/collector/resource-terminating-collector.sh"

bash -n "$TOOL"
for lib in "${SCRIPT_DIR}"/lib/*.sh; do bash -n "$lib"; done
bash -n "$COLLECTOR"
bash "$TOOL" --help >/dev/null
[[ $(bash "$TOOL" --version) == "1.1.0" ]]

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
[[ ${args[0]:-} == --request-timeout=* ]] && args=("${args[@]:1}")
clean=()
for ((i=0; i<${#args[@]}; i++)); do
  if [[ ${args[$i]} == -o && ${args[$((i+1))]:-} == json ]]; then
    ((i++))
    continue
  fi
  clean+=("${args[$i]}")
done
cmd="${clean[*]}"

case "$cmd" in
  "get pod web-0 -n prod")
    cat <<'JSON'
{"metadata":{"uid":"poduid","name":"web-0","namespace":"prod","deletionTimestamp":"2020-01-01T00:00:00Z","finalizers":[],"ownerReferences":[{"kind":"ReplicaSet","name":"web-rs"}]},"spec":{"nodeName":"node-a","terminationGracePeriodSeconds":30,"volumes":[]},"status":{"phase":"Running"}}
JSON
    ;;
  "get node node-a")
    echo '{"metadata":{"name":"node-a"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True","reason":"KubeletReady"}]}}'
    ;;
  "get pvc custom-pvc -n prod")
    cat <<'JSON'
{"metadata":{"uid":"pvcuid","name":"custom-pvc","namespace":"prod","deletionTimestamp":"2020-01-01T00:00:00Z","finalizers":["example.com/external-cleanup"]},"spec":{},"status":{"phase":"Bound"}}
JSON
    ;;
  "get pods -n prod")
    echo '{"items":[]}'
    ;;
  "get events -n prod")
    cat <<'JSON'
{"items":[{"metadata":{"namespace":"prod","creationTimestamp":"2026-09-02T01:00:00Z"},"involvedObject":{"uid":"poduid","kind":"Pod","name":"web-0"},"type":"Warning","reason":"FailedKillPod","message":"error killing pod","count":2,"lastTimestamp":"2026-09-02T01:00:00Z"}]}
JSON
    ;;
  "get pods -A")
    echo '{"items":[]}'
    ;;
  "get persistentvolumeclaims -A")
    echo '{"items":[]}'
    ;;
  "get persistentvolumes")
    echo '{"items":[]}'
    ;;
  "get volumeattachments.storage.k8s.io")
    cat <<'JSON'
{"items":[{"metadata":{"name":"va-stuck","deletionTimestamp":"2020-01-01T00:00:00Z","finalizers":["external-attacher/test"]},"spec":{"nodeName":"node-a","attacher":"test.csi.example.com","source":{"persistentVolumeName":"pv-test"}},"status":{"attached":true}}]}
JSON
    ;;
  *)
    echo "fake kubectl: unmatched request: $cmd" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$tmp/bin/kubectl"

set +e
PATH="$tmp/bin:$PATH" "$TOOL" force-check pod web-0 -n prod --json >"$tmp/force.json"
rc=$?
set -e
[[ $rc -eq 30 ]]
jq -e '.forceCheck.decision=="BREAK-GLASS-REVIEW-READY"' "$tmp/force.json" >/dev/null
jq -e '.eventRootCauses | any(.category=="POD_TERMINATION")' "$tmp/force.json" >/dev/null

# Unknown/custom finalizers must fail closed instead of becoming Break-Glass ready.
set +e
PATH="$tmp/bin:$PATH" "$TOOL" force-check pvc custom-pvc -n prod --json >"$tmp/custom-finalizer.json"
rc=$?
set -e
[[ $rc -eq 20 ]]
jq -e '.forceCheck.decision=="BLOCKED"' "$tmp/custom-finalizer.json" >/dev/null
jq -e '.forceCheck.blockers | index("UNKNOWN_OR_CUSTOM_FINALIZER_REQUIRES_CONTROLLER_REVIEW") != null' \
  "$tmp/custom-finalizer.json" >/dev/null

PATH="$tmp/bin:$PATH" "$TOOL" scan \
  --threshold-seconds 600 \
  --prometheus-output "$tmp/resource-terminating.prom" \
  --json >"$tmp/scan.json"

jq -e '.summary.volumeAttachmentsDeletingWhileAttached==1' "$tmp/scan.json" >/dev/null
grep -F 'resource_terminating_diagnose_scan_success 1' "$tmp/resource-terminating.prom" >/dev/null
grep -F 'resource_terminating_diagnose_volumeattachment_attached{name="va-stuck",pv="pv-test",node="node-a"} 1' "$tmp/resource-terminating.prom" >/dev/null

PATH="$tmp/bin:$PATH" "$COLLECTOR" \
  --prometheus-output "$tmp/collector.prom" \
  --once >/dev/null
grep -F 'resource_terminating_diagnose_generated_timestamp_seconds' "$tmp/collector.prom" >/dev/null

echo "resource-terminating-diagnose smoke tests passed"
