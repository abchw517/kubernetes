# shellcheck shell=bash

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit "$EXIT_ERROR"
  }
}

cleanup() {
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

k() {
  kubectl --request-timeout="${REQUEST_TIMEOUT}" "$@"
}

record_query_error() {
  local context="$1" message="${2:-unknown error}"
  printf '%s\t%s\n' "$context" "${message//$'\n'/ }" >>"${QUERY_ERROR_FILE}"
}

query_errors_json() {
  if [[ ! -s "${QUERY_ERROR_FILE}" ]]; then
    echo '[]'
    return
  fi
  jq -Rn '[inputs | split("\t") | {context:.[0],message:(.[1] // "")}]' <"${QUERY_ERROR_FILE}"
}

query_error_count() {
  [[ -s "${QUERY_ERROR_FILE}" ]] || { echo 0; return; }
  wc -l <"${QUERY_ERROR_FILE}" | tr -d ' '
}

k_json_default() {
  local context="$1" default_json="$2"
  shift 2
  local out err rc
  err=$(mktemp "${TMP_DIR}/err.XXXXXX")
  if out=$(k "$@" -o json 2>"$err"); then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  rc=$?
  record_query_error "$context" "$(cat "$err" 2>/dev/null)"
  rm -f "$err"
  printf '%s\n' "$default_json"
  return "$rc"
}

iso_age_seconds() {
  local ts="$1"
  [[ -n "$ts" && "$ts" != "null" ]] || { echo -1; return; }
  jq -nr --arg ts "$ts" 'try (now - ($ts | fromdateiso8601) | floor) catch -1'
}

node_json() {
  local node="$1" raw
  [[ -n "${node}" ]] || { echo 'null'; return; }
  raw=$(k_json_default "get node/${node}" 'null' get node "${node}")
  jq '{
    name:.metadata.name,
    ready:([.status.conditions[]?|select(.type=="Ready")][0].status // "Unknown"),
    readyReason:([.status.conditions[]?|select(.type=="Ready")][0].reason // null),
    unschedulable:(.spec.unschedulable // false),
    taints:(.spec.taints // [])
  }' <<<"${raw}" 2>/dev/null || echo 'null'
}

pvc_json() {
  local ns="$1" pvc="$2" raw
  raw=$(k_json_default "get pvc ${ns}/${pvc}" 'null' get pvc "${pvc}" -n "${ns}")
  jq '{
    kind:"PersistentVolumeClaim",
    uid:(.metadata.uid // null),
    name:.metadata.name,
    namespace:.metadata.namespace,
    phase:(.status.phase // null),
    volumeName:(.spec.volumeName // null),
    storageClass:(.spec.storageClassName // null),
    deletionTimestamp:(.metadata.deletionTimestamp // null),
    finalizers:(.metadata.finalizers // [])
  }' <<<"${raw}" 2>/dev/null || echo 'null'
}

pv_json() {
  local pv="$1" raw
  raw=$(k_json_default "get pv/${pv}" 'null' get pv "${pv}")
  jq '{
    kind:"PersistentVolume",
    uid:(.metadata.uid // null),
    name:.metadata.name,
    phase:(.status.phase // null),
    reclaimPolicy:(.spec.persistentVolumeReclaimPolicy // null),
    storageClass:(.spec.storageClassName // null),
    deletionTimestamp:(.metadata.deletionTimestamp // null),
    finalizers:(.metadata.finalizers // []),
    claimRef:(.spec.claimRef // null),
    csi:(if .spec.csi then {driver:.spec.csi.driver,volumeHandle:.spec.csi.volumeHandle} else null end)
  }' <<<"${raw}" 2>/dev/null || echo 'null'
}

pods_for_pvc() {
  local ns="$1" pvc="$2" raw
  raw=$(k_json_default "list pods namespace/${ns} for pvc/${pvc}" '{"items":[]}' get pods -n "${ns}")
  jq --arg pvc "${pvc}" '[
    .items[]?
    | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName==$pvc))
    | {
        kind:"Pod",uid:(.metadata.uid // null),name:.metadata.name,namespace:.metadata.namespace,
        phase:(.status.phase // null),node:(.spec.nodeName // null),
        deletionTimestamp:(.metadata.deletionTimestamp // null),
        finalizers:(.metadata.finalizers // []),owner:(.metadata.ownerReferences[0] // null)
      }
  ]' <<<"${raw}"
}

volumeattachments_for_pv() {
  local pv="$1" raw
  raw=$(k_json_default "list volumeattachments for pv/${pv}" '{"items":[]}' get volumeattachments.storage.k8s.io)
  jq --arg pv "${pv}" '[
    .items[]?
    | select(.spec.source.persistentVolumeName==$pv)
    | {
        kind:"VolumeAttachment",uid:(.metadata.uid // null),name:.metadata.name,
        node:(.spec.nodeName // null),attacher:(.spec.attacher // null),
        pv:(.spec.source.persistentVolumeName // null),attached:(.status.attached // false),
        deletionTimestamp:(.metadata.deletionTimestamp // null),finalizers:(.metadata.finalizers // []),
        attachError:(.status.attachError.message // null),detachError:(.status.detachError.message // null)
      }
  ]' <<<"${raw}"
}

volumeattachment_json() {
  local name="$1" raw
  raw=$(k_json_default "get volumeattachment/${name}" 'null' get volumeattachment.storage.k8s.io "${name}")
  jq '{
    kind:"VolumeAttachment",uid:(.metadata.uid // null),name:.metadata.name,
    node:(.spec.nodeName // null),attacher:(.spec.attacher // null),
    pv:(.spec.source.persistentVolumeName // null),attached:(.status.attached // false),
    deletionTimestamp:(.metadata.deletionTimestamp // null),finalizers:(.metadata.finalizers // []),
    attachError:(.status.attachError.message // null),detachError:(.status.detachError.message // null)
  }' <<<"${raw}" 2>/dev/null || echo 'null'
}

nodes_from_names() {
  local names_json="$1" nodes='[]' n nj
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    nj=$(node_json "$n")
    nodes=$(jq --argjson x "$nj" '. + (if $x==null then [] else [$x] end) | unique_by(.name)' <<<"$nodes")
  done < <(jq -r '.[]?' <<<"$names_json")
  echo "$nodes"
}

