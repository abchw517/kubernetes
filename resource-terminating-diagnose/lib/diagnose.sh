# shellcheck shell=bash

risk_from_graph() {
  jq -r '
    if (.target.deletionTimestamp == null) then "SAFE"
    elif ((.volumeAttachments // []) | any(.attached == true)) then "DANGEROUS"
    elif ((.nodes // []) | any(.ready != "True")) then "DANGEROUS"
    elif ((.pods // []) | any(.deletionTimestamp == null)) then "DANGEROUS"
    elif ((.target.finalizers // []) | length) > 0 then "WARNING"
    else "WARNING" end
  '
}

enrich_graph() {
  local graph="$1" csi events roots errors complete
  csi=$(collect_csi_context "$graph")
  events=$(collect_events "$graph")
  roots=$(event_root_causes <<<"$events")
  errors=$(query_errors_json)
  complete=true
  [[ $(query_error_count) -gt 0 ]] && complete=false
  jq -n --argjson g "$graph" --argjson csi "$csi" --argjson events "$events" --argjson roots "$roots" --argjson errors "$errors" --argjson complete "$complete" '
    $g + {csi:$csi,events:$events,eventRootCauses:$roots,diagnostics:{complete:$complete,queryErrors:$errors}}'
}

diagnose_pod() {
  local raw target pod_pvcs pvcs='[]' pvs='[]' vas='[]' nodes='[]' target_node graph risk pvc pj pvname pvj vaj
  raw=$(k_json_default "get pod ${NAMESPACE}/${RESOURCE_NAME}" 'null' get pod "${RESOURCE_NAME}" -n "${NAMESPACE}")
  [[ "$raw" != "null" ]] || return "$EXIT_ERROR"
  target=$(jq '{kind:"Pod",uid:(.metadata.uid // null),name:.metadata.name,namespace:.metadata.namespace,phase:(.status.phase // null),node:(.spec.nodeName // null),deletionTimestamp:(.metadata.deletionTimestamp // null),finalizers:(.metadata.finalizers // []),gracePeriodSeconds:(.spec.terminationGracePeriodSeconds // null),owner:(.metadata.ownerReferences[0] // null)}' <<<"$raw")
  pod_pvcs=$(jq -r '[.spec.volumes[]?|select(.persistentVolumeClaim)|.persistentVolumeClaim.claimName]|unique|.[]?' <<<"${raw}")
  target_node=$(jq -r '.spec.nodeName // empty' <<<"${raw}")
  if [[ -n "${target_node}" ]]; then
    nodes=$(nodes_from_names "$(jq -n --arg n "$target_node" '[$n]')")
  fi

  while IFS= read -r pvc; do
    [[ -n "${pvc}" ]] || continue
    pj=$(pvc_json "${NAMESPACE}" "${pvc}")
    [[ "${pj}" != "null" ]] || continue
    pvcs=$(jq --argjson x "${pj}" '. + [$x]' <<<"${pvcs}")
    pvname=$(jq -r '.volumeName // empty' <<<"${pj}")
    if [[ -n "${pvname}" ]]; then
      pvj=$(pv_json "${pvname}")
      [[ "${pvj}" != "null" ]] && pvs=$(jq --argjson x "${pvj}" '. + [$x] | unique_by(.name)' <<<"${pvs}")
      vaj=$(volumeattachments_for_pv "${pvname}")
      vas=$(jq --argjson x "${vaj}" '. + $x | unique_by(.name)' <<<"${vas}")
    fi
  done <<<"${pod_pvcs}"

  nodes=$(nodes_from_names "$(jq -n --arg targetNode "$target_node" --argjson vas "$vas" '[ $targetNode, $vas[]?.node ] | map(select(.!=null and .!="")) | unique')")

  graph=$(jq -n --argjson target "$target" --argjson pvcs "$pvcs" --argjson pvs "$pvs" --argjson vas "$vas" --argjson nodes "$nodes" '{target:$target,pvcs:$pvcs,pvs:$pvs,volumeAttachments:$vas,nodes:$nodes}')
  graph=$(enrich_graph "$graph")
  risk=$(risk_from_graph <<<"${graph}")
  jq --arg verdict "${risk}" '. + {verdict:$verdict}' <<<"${graph}"
}

diagnose_pvc() {
  local target pods pvname pv='null' vas='[]' nodeNames nodes graph risk
  target=$(pvc_json "${NAMESPACE}" "${RESOURCE_NAME}")
  [[ "$target" != "null" ]] || return "$EXIT_ERROR"
  pods=$(pods_for_pvc "${NAMESPACE}" "${RESOURCE_NAME}")
  pvname=$(jq -r '.volumeName // empty' <<<"${target}")
  if [[ -n "${pvname}" ]]; then
    pv=$(pv_json "${pvname}")
    vas=$(volumeattachments_for_pv "${pvname}")
  fi
  nodeNames=$(jq -n --argjson pods "$pods" --argjson vas "$vas" '[ $pods[]?.node, $vas[]?.node ] | map(select(.!=null and .!="")) | unique')
  nodes=$(nodes_from_names "$nodeNames")
  graph=$(jq -n --argjson target "$target" --argjson pods "$pods" --argjson pv "$pv" --argjson vas "$vas" --argjson nodes "$nodes" '{target:$target,pods:$pods,pv:$pv,volumeAttachments:$vas,nodes:$nodes}')
  graph=$(enrich_graph "$graph")
  risk=$(risk_from_graph <<<"${graph}")
  [[ $(jq '(.pods // [])|length' <<<"${graph}") -gt 0 ]] && risk="DANGEROUS"
  jq --arg verdict "${risk}" '. + {verdict:$verdict}' <<<"${graph}"
}

diagnose_pv() {
  local target ns claim pvc='null' pods='[]' vas nodeNames nodes graph risk
  target=$(pv_json "${RESOURCE_NAME}")
  [[ "$target" != "null" ]] || return "$EXIT_ERROR"
  ns=$(jq -r '.claimRef.namespace // empty' <<<"${target}")
  claim=$(jq -r '.claimRef.name // empty' <<<"${target}")
  if [[ -n "${ns}" && -n "${claim}" ]]; then
    pvc=$(pvc_json "${ns}" "${claim}")
    pods=$(pods_for_pvc "${ns}" "${claim}")
  fi
  vas=$(volumeattachments_for_pv "${RESOURCE_NAME}")
  nodeNames=$(jq '[.[].node]|map(select(.!=null))|unique' <<<"${vas}")
  nodes=$(nodes_from_names "$nodeNames")
  graph=$(jq -n --argjson target "$target" --argjson pvc "$pvc" --argjson pods "$pods" --argjson vas "$vas" --argjson nodes "$nodes" '{target:$target,pvc:$pvc,pods:$pods,volumeAttachments:$vas,nodes:$nodes}')
  graph=$(enrich_graph "$graph")
  risk=$(risk_from_graph <<<"${graph}")
  [[ $(jq '(.volumeAttachments // [])|any(.attached==true)' <<<"${graph}") == "true" ]] && risk="DANGEROUS"
  jq --arg verdict "${risk}" '. + {verdict:$verdict}' <<<"${graph}"
}

diagnose_va() {
  local target pvname pv='null' ns claim pvc='null' pods='[]' nodeName nodes graph risk
  target=$(volumeattachment_json "${RESOURCE_NAME}")
  [[ "$target" != "null" ]] || return "$EXIT_ERROR"
  pvname=$(jq -r '.pv // empty' <<<"${target}")
  [[ -n "$pvname" ]] && pv=$(pv_json "$pvname")
  ns=$(jq -r '.claimRef.namespace // empty' <<<"${pv}")
  claim=$(jq -r '.claimRef.name // empty' <<<"${pv}")
  if [[ -n "$ns" && -n "$claim" ]]; then
    pvc=$(pvc_json "$ns" "$claim")
    pods=$(pods_for_pvc "$ns" "$claim")
  fi
  nodeName=$(jq -r '.node // empty' <<<"${target}")
  nodes=$(nodes_from_names "$(jq -n --arg n "$nodeName" 'if $n=="" then [] else [$n] end')")
  graph=$(jq -n --argjson target "$target" --argjson pv "$pv" --argjson pvc "$pvc" --argjson pods "$pods" --argjson nodes "$nodes" '{target:$target,pv:$pv,pvc:$pvc,pods:$pods,nodes:$nodes,volumeAttachments:[$target]}')
  graph=$(enrich_graph "$graph")
  risk=$(risk_from_graph <<<"${graph}")
  [[ $(jq -r '.target.attached' <<<"${graph}") == "true" ]] && risk="DANGEROUS"
  jq --arg verdict "${risk}" '. + {verdict:$verdict}' <<<"${graph}"
}

diagnose_target() {
  case "$RESOURCE_KIND" in
    pod) diagnose_pod ;;
    pvc) diagnose_pvc ;;
    pv) diagnose_pv ;;
    volumeattachment) diagnose_va ;;
  esac
}

force_check_graph() {
  local graph="$1" age blockers='[]' manual='[]' decision ready=false reason kind
  kind=$(jq -r '.target.kind' <<<"$graph")
  age=$(iso_age_seconds "$(jq -r '.target.deletionTimestamp // empty' <<<"$graph")")

  add_blocker() { blockers=$(jq --arg x "$1" '. + [$x] | unique' <<<"$blockers"); }
  add_manual() { manual=$(jq --arg x "$1" '. + [$x] | unique' <<<"$manual"); }

  [[ $(jq -r '.target.deletionTimestamp == null' <<<"$graph") == "true" ]] && add_blocker "TARGET_NOT_TERMINATING"
  (( age >= 0 && age < THRESHOLD_SECONDS )) && add_blocker "TERMINATING_AGE_BELOW_THRESHOLD"
  (( age < 0 )) && add_blocker "TERMINATING_AGE_UNKNOWN"
  [[ $(jq -r '.diagnostics.complete' <<<"$graph") != "true" ]] && add_blocker "DIAGNOSTIC_DATA_INCOMPLETE_FAIL_CLOSED"
  [[ $(jq '(.volumeAttachments // []) | any(.attached==true)' <<<"$graph") == "true" ]] && add_blocker "VOLUME_STILL_ATTACHED"
  [[ $(jq '(.nodes // []) | any(.ready!="True")' <<<"$graph") == "true" ]] && add_blocker "RELATED_NODE_NOT_READY_OR_UNKNOWN_FENCING_REQUIRED"
  [[ $(jq '(.pods // []) | any(.deletionTimestamp==null)' <<<"$graph") == "true" ]] && add_blocker "PVC_OR_PV_STILL_CONSUMED_BY_LIVE_POD"

  if [[ $(jq '(.csi // [])|length > 0' <<<"$graph") == "true" ]]; then
    [[ $(jq '(.csi // []) | any(.discovery.componentPodsFound == 0)' <<<"$graph") == "true" ]] && add_blocker "CSI_COMPONENT_DISCOVERY_INCOMPLETE"
    [[ $(jq '(.csi // []) | any(any(.componentPods[]?; (.ready != true or .deleting == true)))' <<<"$graph") == "true" ]] && add_blocker "CSI_COMPONENT_UNHEALTHY_OR_DELETING"
    [[ $(jq '(.csi // []) | any(any(.nodeRegistration[]?; .driver == null))' <<<"$graph") == "true" ]] && add_blocker "CSI_DRIVER_NOT_REGISTERED_ON_RELATED_NODE"
  fi

  if [[ "$kind" == "Pod" ]]; then
    [[ $(jq '(.pvcs // [])|length > 0' <<<"$graph") == "true" ]] && add_blocker "POD_HAS_PERSISTENT_STORAGE_DEPENDENCIES"
    [[ $(jq -r '.target.owner.kind // empty' <<<"$graph") == "StatefulSet" ]] && add_blocker "STATEFULSET_IDENTITY_SPLIT_BRAIN_RISK"
    [[ $(jq '(.target.finalizers // [])|length > 0' <<<"$graph") == "true" ]] && add_blocker "POD_FINALIZER_PRESENT_CONTROLLER_CLEANUP_REQUIRED"
  elif [[ "$kind" == "PersistentVolumeClaim" ]]; then
    [[ $(jq '(.pods // [])|length > 0' <<<"$graph") == "true" ]] && add_blocker "PVC_STILL_REFERENCED_BY_POD_OBJECTS"
    add_manual "Confirm backend volume and snapshot/backup state before any PVC finalizer change."
    add_manual "Confirm the related PV reclaimPolicy and intended data-retention outcome."
  elif [[ "$kind" == "PersistentVolume" ]]; then
    [[ $(jq '.pvc != null' <<<"$graph") == "true" ]] && add_blocker "BOUND_OR_REFERENCED_PVC_STILL_EXISTS"
    if [[ $(jq -r '.target.reclaimPolicy // empty' <<<"$graph") == "Delete" ]] ||
       [[ $(jq '(.target.finalizers // []) | any(test("external-provisioner|external-attacher"))' <<<"$graph") == "true" ]]; then
      add_blocker "BACKEND_STORAGE_DELETION_CANNOT_BE_PROVEN_BY_KUBERNETES_API"
      add_manual "Verify target.csi.volumeHandle in the storage provider/backend is already deleted or intentionally retained."
    fi
  elif [[ "$kind" == "VolumeAttachment" ]]; then
    [[ $(jq -r '.target.attached' <<<"$graph") == "true" ]] && add_blocker "VOLUMEATTACHMENT_STATUS_ATTACHED_TRUE"
    add_manual "Verify the storage provider reports the volume detached from the target node before removing an attacher finalizer."
  fi

  if [[ $(jq 'length' <<<"$blockers") -eq 0 ]]; then
    ready=true
    decision="BREAK-GLASS-REVIEW-READY"
    reason="Strict read-only checks found no Kubernetes-side blockers. Manual checklist is still required; no mutation is performed."
  else
    decision="BLOCKED"
    reason="One or more safety blockers remain. Do not force-delete, remove finalizers, or force-detach based on this result."
  fi

  jq -n --argjson g "$graph" --argjson age "$age" --argjson threshold "$THRESHOLD_SECONDS" --arg decision "$decision" --arg reason "$reason" --argjson ready "$ready" --argjson blockers "$blockers" --argjson manual "$manual" '
    $g + {
      command:"force-check",
      verdict:$decision,
      forceCheck:{
        decision:$decision,
        eligibleForHumanReview:$ready,
        exitCode:(if $ready then 30 else 20 end),
        reason:$reason,
        terminatingAgeSeconds:$age,
        thresholdSeconds:$threshold,
        blockers:$blockers,
        manualChecks:$manual
      }
    }'
}

