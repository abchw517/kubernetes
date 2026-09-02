#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TOOL="${ROOT_DIR}/resource-terminating-diagnose.sh"
VALIDATOR="${ROOT_DIR}/tests/validate-json.py"
SCHEMA="${ROOT_DIR}/tests/schema/resource-result.schema.json"

TMP=$(mktemp -d -t resource-terminating-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
scenario="${RESOURCE_TEST_SCENARIO:-pvc-danger}"
args=()
for a in "$@"; do
  case "$a" in --request-timeout=*) ;; *) args+=("$a") ;; esac
done
set -- "${args[@]}"

if [[ "${1:-}" == "version" ]]; then
  echo '{"clientVersion":{"gitVersion":"v1.36.0"},"serverVersion":{"gitVersion":"v1.36.0"}}'
  exit 0
fi
[[ "${1:-}" == "get" ]] || { echo "mock: unsupported: $*" >&2; exit 1; }
resource="${2:-}"
name=""
[[ -z "${3:-}" || "${3:-}" == -* ]] || name="${3}"
namespace=""
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "-n" ]]; then j=$((i+1)); namespace="${!j}"; fi
done
old_ts="2020-01-01T00:00:00Z"

case "$scenario" in
  pvc-danger)
    case "${resource}:${name}:${namespace}" in
      pvc:data:demo)
        cat <<JSON
{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"data","namespace":"demo","uid":"pvc-uid","deletionTimestamp":"${old_ts}","finalizers":["kubernetes.io/pvc-protection"]},"spec":{"volumeName":"pv1","storageClassName":"csi-sc"},"status":{"phase":"Bound"}}
JSON
        ;;
      pods::demo)
        echo '{"apiVersion":"v1","kind":"PodList","items":[{"metadata":{"name":"db-0","namespace":"demo"},"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"data"}}]}}]}'
        ;;
      pod:db-0:demo)
        cat <<JSON
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"db-0","namespace":"demo","uid":"pod-uid","deletionTimestamp":"${old_ts}","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"db","controller":true}]},"spec":{"nodeName":"node-a","terminationGracePeriodSeconds":30,"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"data"}}]},"status":{"phase":"Running"}}
JSON
        ;;
      node:node-a:)
        echo '{"apiVersion":"v1","kind":"Node","metadata":{"name":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
        ;;
      pv:pv1:)
        cat <<JSON
{"apiVersion":"v1","kind":"PersistentVolume","metadata":{"name":"pv1","uid":"pv-uid","deletionTimestamp":"${old_ts}","finalizers":["kubernetes.io/pv-protection","external-provisioner.volume.kubernetes.io/finalizer"]},"spec":{"persistentVolumeReclaimPolicy":"Delete","storageClassName":"csi-sc","claimRef":{"namespace":"demo","name":"data"},"csi":{"driver":"mock.csi.io","volumeHandle":"vol-001"}},"status":{"phase":"Bound"}}
JSON
        ;;
      volumeattachments.storage.k8s.io::)
        echo '{"apiVersion":"storage.k8s.io/v1","kind":"VolumeAttachmentList","items":[{"metadata":{"name":"va1"},"spec":{"source":{"persistentVolumeName":"pv1"}}}]}'
        ;;
      volumeattachment:va1:)
        cat <<JSON
{"apiVersion":"storage.k8s.io/v1","kind":"VolumeAttachment","metadata":{"name":"va1","uid":"va-uid","deletionTimestamp":"${old_ts}","finalizers":["external-attacher/mock.csi.io"]},"spec":{"attacher":"mock.csi.io","nodeName":"node-a","source":{"persistentVolumeName":"pv1"}},"status":{"attached":true}}
JSON
        ;;
      *) echo "mock pvc-danger: unsupported ${resource}:${name}:${namespace}" >&2; exit 1 ;;
    esac
    ;;
  pod-ready)
    case "${resource}:${name}:${namespace}" in
      pod:web-abc:demo)
        cat <<JSON
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"web-abc","namespace":"demo","uid":"pod-web","deletionTimestamp":"${old_ts}","ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"web-123","controller":true}]},"spec":{"nodeName":"node-a","terminationGracePeriodSeconds":30,"volumes":[]},"status":{"phase":"Running"}}
JSON
        ;;
      node:node-a:)
        echo '{"apiVersion":"v1","kind":"Node","metadata":{"name":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
        ;;
      *) echo "mock pod-ready: unsupported ${resource}:${name}:${namespace}" >&2; exit 1 ;;
    esac
    ;;
  va-detached)
    case "${resource}:${name}:${namespace}" in
      volumeattachment:va2:)
        cat <<JSON
{"apiVersion":"storage.k8s.io/v1","kind":"VolumeAttachment","metadata":{"name":"va2","uid":"va2-uid","deletionTimestamp":"${old_ts}","finalizers":["external-attacher/mock.csi.io"]},"spec":{"attacher":"mock.csi.io","nodeName":"node-a","source":{"persistentVolumeName":"pv2"}},"status":{"attached":false}}
JSON
        ;;
      node:node-a:)
        echo '{"apiVersion":"v1","kind":"Node","metadata":{"name":"node-a"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
        ;;
      pv:pv2:)
        echo '{"apiVersion":"v1","kind":"PersistentVolume","metadata":{"name":"pv2","uid":"pv2-uid"},"spec":{"persistentVolumeReclaimPolicy":"Retain"},"status":{"phase":"Available"}}'
        ;;
      volumeattachments.storage.k8s.io::)
        echo '{"apiVersion":"storage.k8s.io/v1","kind":"VolumeAttachmentList","items":[{"metadata":{"name":"va2"},"spec":{"source":{"persistentVolumeName":"pv2"}}}]}'
        ;;
      *) echo "mock va-detached: unsupported ${resource}:${name}:${namespace}" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unknown scenario" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"

run_expect() {
  local scenario="$1" expected_rc="$2" expected_verdict="$3"
  shift 3
  local out="$TMP/${scenario}.json" rc=0
  RESOURCE_TEST_SCENARIO="$scenario" "$TOOL" "$@" --json >"$out" || rc=$?
  [[ "$rc" -eq "$expected_rc" ]] || {
    echo "scenario=$scenario expected rc=$expected_rc got=$rc" >&2
    cat "$out" >&2
    return 1
  }
  jq -e --arg v "$expected_verdict" '.verdict == $v' "$out" >/dev/null
  python3 "$VALIDATOR" "$SCHEMA" "$out"
  echo "PASS: $scenario -> $expected_verdict/$expected_rc"
}

run_expect pvc-danger 20 DANGEROUS diagnose --kind pvc -n demo --name data
jq -e '.counts.pods == 1 and .counts.pvcs == 1 and .counts.pvs == 1 and .counts.volumeattachments == 1 and .counts.attached_volumeattachments == 1 and .counts.stateful_pods == 1' "$TMP/pvc-danger.json" >/dev/null

run_expect pod-ready 30 BREAK-GLASS-REVIEW-READY force-check --kind pod -n demo --name web-abc
jq -e '.break_glass_review_ready == true' "$TMP/pod-ready.json" >/dev/null

run_expect va-detached 10 WARNING force-check --kind volumeattachment --name va2
jq -e '.break_glass_review_ready == false and (.blockers|length) > 0' "$TMP/va-detached.json" >/dev/null

echo "resource-terminating-diagnose contract tests OK"
