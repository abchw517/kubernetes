# shellcheck shell=bash

scan_kind() {
  local kind="$1" raw resource nsarg=()
  case "$kind" in
    pod) resource=pods; nsarg=(-A) ;;
    pvc) resource=persistentvolumeclaims; nsarg=(-A) ;;
    pv) resource=persistentvolumes ;;
    volumeattachment) resource=volumeattachments.storage.k8s.io ;;
  esac
  raw=$(k_json_default "scan ${resource}" '{"items":[]}' get "$resource" "${nsarg[@]}")
  jq --arg kind "$kind" --argjson threshold "$THRESHOLD_SECONDS" '[.items[]?
    | select(.metadata.deletionTimestamp != null)
    | {kind:$kind,namespace:(.metadata.namespace // ""),name:.metadata.name,
       deletionTimestamp:.metadata.deletionTimestamp,
       ageSeconds:(try (now-(.metadata.deletionTimestamp|fromdateiso8601)|floor) catch -1),
       finalizers:(.metadata.finalizers // []),
       node:(.spec.nodeName // null),pv:(.spec.volumeName // .spec.source.persistentVolumeName // null),
       reclaimPolicy:(.spec.persistentVolumeReclaimPolicy // null),
       driver:(.spec.csi.driver // null),volumeHandle:(.spec.csi.volumeHandle // null),
       attacher:(.spec.attacher // null),attached:(.status.attached // false),
       attachError:(.status.attachError.message // null),detachError:(.status.detachError.message // null)}
    | . + {overThreshold:(.ageSeconds >= $threshold)}]' <<<"$raw"
}

scan_all() {
  local pods pvcs pvs vas errors complete=true
  : >"$QUERY_ERROR_FILE"
  pods=$(scan_kind pod); pvcs=$(scan_kind pvc); pvs=$(scan_kind pv); vas=$(scan_kind volumeattachment)
  errors=$(query_errors_json)
  [[ $(query_error_count) -gt 0 ]] && complete=false
  jq -n --arg version "$VERSION" --argjson pods "$pods" --argjson pvcs "$pvcs" \
    --argjson pvs "$pvs" --argjson vas "$vas" --argjson errors "$errors" --argjson complete "$complete" '
    {schemaVersion:"1",tool:"resource-terminating-diagnose",version:$version,command:"scan",
     generatedAt:(now|todateiso8601),pods:$pods,pvcs:$pvcs,pvs:$pvs,volumeAttachments:$vas,
     diagnostics:{complete:$complete,queryErrors:$errors},
     summary:{total:([$pods,$pvcs,$pvs,$vas]|map(length)|add),
       overThreshold:([$pods,$pvcs,$pvs,$vas]|map([.[]|select(.overThreshold)]|length)|add),
       volumeAttachmentsDeletingWhileAttached:([$vas[]|select(.attached==true)]|length)}}'
}

prom_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

write_scan_prometheus() {
  local scan="$1" file="$2" dir kind arr obj success=1 now tmp
  tmp="${file}.tmp.$$"
  dir=$(dirname "$file"); mkdir -p "$dir" || return 1
  [[ $(jq -r '.diagnostics.complete' <<<"$scan") == true ]] || success=0
  now=$(date +%s)
  {
    echo '# HELP resource_terminating_diagnose_scan_success Last scan completeness.'
    echo '# TYPE resource_terminating_diagnose_scan_success gauge'
    printf 'resource_terminating_diagnose_scan_success %d\n' "$success"
    echo '# HELP resource_terminating_diagnose_generated_timestamp_seconds Metrics generation time.'
    echo '# TYPE resource_terminating_diagnose_generated_timestamp_seconds gauge'
    printf 'resource_terminating_diagnose_generated_timestamp_seconds %d\n' "$now"
    echo '# HELP resource_terminating_diagnose_terminating_objects Current deleting objects.'
    echo '# TYPE resource_terminating_diagnose_terminating_objects gauge'
    echo '# HELP resource_terminating_diagnose_over_threshold_objects Deleting objects older than threshold.'
    echo '# TYPE resource_terminating_diagnose_over_threshold_objects gauge'
    echo '# HELP resource_terminating_diagnose_object_deletion_age_seconds Current deletion age.'
    echo '# TYPE resource_terminating_diagnose_object_deletion_age_seconds gauge'
    echo '# HELP resource_terminating_diagnose_volumeattachment_attached Attachment state for deleting VolumeAttachments.'
    echo '# TYPE resource_terminating_diagnose_volumeattachment_attached gauge'
    for kind in pod pvc pv volumeattachment; do
      case "$kind" in pod) arr=.pods;; pvc) arr=.pvcs;; pv) arr=.pvs;; *) arr=.volumeAttachments;; esac
      printf 'resource_terminating_diagnose_terminating_objects{kind="%s"} %s\n' "$kind" "$(jq "${arr}|length" <<<"$scan")"
      printf 'resource_terminating_diagnose_over_threshold_objects{kind="%s"} %s\n' "$kind" "$(jq "[${arr}[]|select(.overThreshold)]|length" <<<"$scan")"
      while IFS= read -r obj; do
        printf 'resource_terminating_diagnose_object_deletion_age_seconds{kind="%s",namespace="%s",name="%s"} %s\n' \
          "$kind" "$(prom_escape "$(jq -r '.namespace' <<<"$obj")")" \
          "$(prom_escape "$(jq -r '.name' <<<"$obj")")" "$(jq -r '.ageSeconds' <<<"$obj")"
        if [[ "$kind" == volumeattachment ]]; then
          printf 'resource_terminating_diagnose_volumeattachment_attached{name="%s",pv="%s",node="%s"} %d\n' \
            "$(prom_escape "$(jq -r '.name' <<<"$obj")")" "$(prom_escape "$(jq -r '.pv // ""' <<<"$obj")")" \
            "$(prom_escape "$(jq -r '.node // ""' <<<"$obj")")" "$([[ $(jq -r '.attached' <<<"$obj") == true ]] && echo 1 || echo 0)"
        fi
      done < <(jq -c "${arr}[]?" <<<"$scan")
    done
  } >"$tmp" && mv -f "$tmp" "$file"
}

write_target_prometheus() {
  local graph="$1" file="$2" dir age verdict ready=0 now tmp
  tmp="${file}.tmp.$$"
  dir=$(dirname "$file"); mkdir -p "$dir" || return 1
  age=$(iso_age_seconds "$(jq -r '.target.deletionTimestamp // empty' <<<"$graph")")
  verdict=$(jq -r '.verdict // .forceCheck.decision // "UNKNOWN"' <<<"$graph")
  [[ $(jq -r '.forceCheck.eligibleForHumanReview // false' <<<"$graph") == true ]] && ready=1
  now=$(date +%s)
  {
    echo '# HELP resource_terminating_diagnose_target_info Target diagnosis result.'
    echo '# TYPE resource_terminating_diagnose_target_info gauge'
    printf 'resource_terminating_diagnose_target_info{kind="%s",namespace="%s",name="%s",verdict="%s"} 1\n' \
      "$(prom_escape "$(jq -r '.target.kind' <<<"$graph")")" "$(prom_escape "$(jq -r '.target.namespace // ""' <<<"$graph")")" \
      "$(prom_escape "$(jq -r '.target.name' <<<"$graph")")" "$(prom_escape "$verdict")"
    echo '# HELP resource_terminating_diagnose_target_deletion_age_seconds Target deletion age.'
    echo '# TYPE resource_terminating_diagnose_target_deletion_age_seconds gauge'
    printf 'resource_terminating_diagnose_target_deletion_age_seconds{kind="%s",namespace="%s",name="%s"} %s\n' \
      "$(prom_escape "$(jq -r '.target.kind' <<<"$graph")")" "$(prom_escape "$(jq -r '.target.namespace // ""' <<<"$graph")")" \
      "$(prom_escape "$(jq -r '.target.name' <<<"$graph")")" "$age"
    echo '# HELP resource_terminating_diagnose_force_review_ready Strict Kubernetes-side force-check gate.'
    echo '# TYPE resource_terminating_diagnose_force_review_ready gauge'
    printf 'resource_terminating_diagnose_force_review_ready{kind="%s",namespace="%s",name="%s"} %d\n' \
      "$(prom_escape "$(jq -r '.target.kind' <<<"$graph")")" "$(prom_escape "$(jq -r '.target.namespace // ""' <<<"$graph")")" \
      "$(prom_escape "$(jq -r '.target.name' <<<"$graph")")" "$ready"
    printf 'resource_terminating_diagnose_generated_timestamp_seconds %d\n' "$now"
  } >"$tmp" && mv -f "$tmp" "$file"
}

human_output() {
  jq -r '"Verdict: \(.verdict // .forceCheck.decision // "N/A")",
    "Target : \(.target.kind // "scan") \(.target.namespace // "")/\(.target.name // "")",
    (if .target.deletionTimestamp then "Deleting: \(.target.deletionTimestamp)" else empty end),
    (if .pods then "Pods: \(.pods|length)" else empty end),(if .pvcs then "PVCs: \(.pvcs|length)" else empty end),
    (if .pvs then "PVs: \(.pvs|length)" else empty end),(if .volumeAttachments then "VolumeAttachments: \(.volumeAttachments|length)" else empty end),
    (if .nodes then "Nodes: \(.nodes|length)" else empty end),(if .csi then "CSI drivers: \(.csi|length)" else empty end),
    (if .eventRootCauses then "Event root causes: \([.eventRootCauses[].category]|join(", "))" else empty end),
    (if .diagnostics then "Diagnostics complete: \(.diagnostics.complete)" else empty end),
    (if .forceCheck then "Force-check: \(.forceCheck.decision)\nBlockers: \(.forceCheck.blockers|join(", "))" else empty end)'
}

scan_human_output() {
  jq -r '"Terminating total: \(.summary.total)\nOver threshold: \(.summary.overThreshold)\nDeleting VolumeAttachments still attached: \(.summary.volumeAttachmentsDeletingWhileAttached)\nDiagnostics complete: \(.diagnostics.complete)"'
}

run_collector_once() {
  local scan rc=0
  scan=$(scan_all)
  write_scan_prometheus "$scan" "$PROMETHEUS_OUTPUT" || return "$EXIT_ERROR"
  [[ $(jq -r '.diagnostics.complete' <<<"$scan") == true ]] || rc=$EXIT_WARNING
  if (( JSON_MODE == 1 )); then printf '%s\n' "$scan"; else
    printf '%s collector wrote %s; terminating=%s overThreshold=%s complete=%s\n' \
      "$(date -Is 2>/dev/null || date)" "$PROMETHEUS_OUTPUT" "$(jq -r '.summary.total' <<<"$scan")" \
      "$(jq -r '.summary.overThreshold' <<<"$scan")" "$(jq -r '.diagnostics.complete' <<<"$scan")"
  fi
  return "$rc"
}

collector_loop() {
  local rc=0
  while true; do
    run_collector_once || rc=$?
    (( ONCE == 1 )) && return "$rc"
    sleep "$INTERVAL_SECONDS"; rc=0
  done
}
