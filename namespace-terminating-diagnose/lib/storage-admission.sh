# shellcheck shell=bash
# namespace-terminating-diagnose v2.0.0 library

collect_storage() {
  section "5. PVC / PV / VolumeAttachment"

  local pvc_json pvc_count
  if ! pvc_json=$(k get pvc -n "$NAMESPACE" -o json 2>"$TMP_DIR/pvc.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 PVC"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/pvc.err"
  else
    pvc_count=$(jq '.items | length' <<<"$pvc_json")
    PVC_TOTAL=$pvc_count

    if (( pvc_count == 0 )); then
      ok "no PVC remains"
    else
      danger "${pvc_count} PVC(s) remain; storage must be reviewed before force-finalize"
      add_danger "Namespace 中仍有 ${pvc_count} 个 PVC"

      if (( JSON_MODE == 0 )); then
        printf '%-42s %-12s %-44s %-16s %s\n' \
          "PVC" "STATUS" "PV" "DELETING" "FINALIZERS"
        jq -r --argjson max "$MAX_DETAILS" '
          [
            .items[] |
            [
              .metadata.name,
              (.status.phase // "-"),
              (.spec.volumeName // "-"),
              (.metadata.deletionTimestamp // "-"),
              ((.metadata.finalizers // []) | join(","))
            ]
          ][: $max][] | @tsv
        ' <<<"$pvc_json" |
        while IFS=$'\t' read -r name phase pv deleting finalizers; do
          printf '%-42s %-12s %-44s %-16s %s\n' \
            "$name" "$phase" "$pv" "$deleting" "${finalizers:-<none>}"
        done
      fi
    fi
  fi

  local pv_json related_count
  if ! pv_json=$(k get pv -o json 2>"$TMP_DIR/pv.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 PV，无法确认 Namespace 关联存储"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/pv.err"
    return
  fi

  mapfile -t RELATED_PVS < <(
    jq -r --arg ns "$NAMESPACE" '
      .items[] |
      select(.spec.claimRef.namespace? == $ns) |
      .metadata.name
    ' <<<"$pv_json"
  )
  related_count=${#RELATED_PVS[@]}
  RELATED_PV_TOTAL=$related_count

  if (( related_count == 0 )); then
    ok "no PV has claimRef.namespace=${NAMESPACE}"
  else
    warn "${related_count} PV(s) still reference target Namespace"
    add_warning "${related_count} PV(s) still reference Namespace ${NAMESPACE}"
    add_force_blocker "PV objects still reference target Namespace"

    if (( JSON_MODE == 0 )); then
      printf '%-44s %-12s %-10s %-28s %-16s %s\n' \
        "PV" "PHASE" "RECLAIM" "STORAGECLASS" "DELETING" "FINALIZERS"
    fi

    while IFS=$'\t' read -r name phase reclaim sc deleting finalizers; do
      if (( JSON_MODE == 0 )); then
        printf '%-44s %-12s %-10s %-28s %-16s %s\n' \
          "$name" "$phase" "$reclaim" "$sc" "$deleting" "${finalizers:-<none>}"
      fi

      if [[ "$deleting" != "-" || "$phase" == "Bound" ]]; then
        add_danger "PV ${name} phase=${phase} deletionTimestamp=${deleting}; storage cleanup is not complete"
      fi

      if [[ "$finalizers" == *"external-provisioner.volume.kubernetes.io/finalizer"* ]]; then
        add_danger "PV ${name} still has CSI backend-deletion protection finalizer"
      fi
    done < <(
      jq -r --arg ns "$NAMESPACE" --argjson max "$MAX_DETAILS" '
        [
          .items[] |
          select(.spec.claimRef.namespace? == $ns) |
          [
            .metadata.name,
            (.status.phase // "-"),
            (.spec.persistentVolumeReclaimPolicy // "-"),
            (.spec.storageClassName // "-"),
            (.metadata.deletionTimestamp // "-"),
            ((.metadata.finalizers // []) | join(","))
          ]
        ][: $max][] | @tsv
      ' <<<"$pv_json"
    )
  fi

  local va_json pvs_json va_count
  if ! va_json=$(k get volumeattachments.storage.k8s.io -o json 2>"$TMP_DIR/va.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 VolumeAttachment"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/va.err"
    return
  fi

  if (( related_count == 0 )); then
    ok "no related VolumeAttachment check required"
    return
  fi

  pvs_json=$(jq -n '$ARGS.positional' --args "${RELATED_PVS[@]}")
  va_count=$(jq --argjson pvs "$pvs_json" '
    [
      .items[] |
      select((.spec.source.persistentVolumeName // "") as $pv | $pvs | index($pv))
    ] | length
  ' <<<"$va_json")
  VOLUME_ATTACHMENT_TOTAL=$va_count

  if (( va_count == 0 )); then
    ok "no VolumeAttachment references related PVs"
  else
    danger "${va_count} VolumeAttachment(s) still reference related PVs"
    add_danger "${va_count} VolumeAttachment(s) remain for Namespace-related PVs"

    if (( JSON_MODE == 0 )); then
      jq -r --argjson pvs "$pvs_json" --argjson max "$MAX_DETAILS" '
        [
          .items[] |
          select((.spec.source.persistentVolumeName // "") as $pv | $pvs | index($pv)) |
          [
            .metadata.name,
            (.spec.source.persistentVolumeName // "-"),
            (.spec.nodeName // "-"),
            ((.status.attached // false) | tostring),
            (.metadata.deletionTimestamp // "-"),
            ((.metadata.finalizers // []) | join(","))
          ]
        ][: $max][] | @tsv
      ' <<<"$va_json" |
      while IFS=$'\t' read -r name pv node attached deleting finalizers; do
        printf '  - VA=%s PV=%s node=%s attached=%s deleting=%s finalizers=%s\n' \
          "$name" "$pv" "$node" "$attached" "$deleting" "${finalizers:-<none>}"
      done
    fi
  fi
}

collect_custom_resources() {
  section "6. CRD / Custom Resource Residuals"

  local crd_json
  if ! crd_json=$(k get customresourcedefinitions.apiextensions.k8s.io \
      -o json 2>"$TMP_DIR/crd.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 CRD；不能确认残留对象是否为 Custom Resource"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/crd.err"
    return
  fi

  local found=0 resource crd count term_count finalizer_count

  if (( JSON_MODE == 0 )); then
    printf '%-58s %-48s %8s %12s %12s\n' \
      "CUSTOM RESOURCE" "CRD" "COUNT" "TERMINATING" "FINALIZERS"
  fi

  while IFS=$'\t' read -r resource crd; do
    count="${RESOURCE_COUNTS[$resource]:-0}"
    term_count="${RESOURCE_TERM_COUNTS[$resource]:-0}"
    finalizer_count="${RESOURCE_FINALIZER_COUNTS[$resource]:-0}"

    if (( count > 0 )); then
      found=1
      CUSTOM_RESOURCE_TOTAL=$((CUSTOM_RESOURCE_TOTAL + count))

      if (( JSON_MODE == 0 )); then
        printf '%-58s %-48s %8d %12d %12d\n' \
          "$resource" "$crd" "$count" "$term_count" "$finalizer_count"
      fi
    fi
  done < <(
    jq -r '
      .items[] |
      select(.spec.scope == "Namespaced") |
      [
        (.spec.names.plural + "." + .spec.group),
        .metadata.name
      ] | @tsv
    ' <<<"$crd_json"
  )

  if (( found == 0 )); then
    ok "no remaining Custom Resource detected from installed Namespaced CRDs"
  else
    add_danger "Namespace 中仍有 ${CUSTOM_RESOURCE_TOTAL} 个 Custom Resource；必须确认对应 Operator/Finalizer"
    danger "${CUSTOM_RESOURCE_TOTAL} Custom Resource object(s) remain"
  fi
}

webhook_service_health() {
  local ns="$1"
  local svc="$2"
  local key="${ns}/${svc}"

  if [[ -n "${WEBHOOK_SERVICE_STATE[$key]:-}" ]]; then
    echo "${WEBHOOK_SERVICE_STATE[$key]}"
    return
  fi

  if ! k get service "$svc" -n "$ns" >/dev/null 2>&1; then
    WEBHOOK_SERVICE_STATE["$key"]="SERVICE-NOT-FOUND"
    echo "SERVICE-NOT-FOUND"
    return
  fi

  local slices ready
  if ! slices=$(k get endpointslice.discovery.k8s.io \
      -n "$ns" \
      -l "kubernetes.io/service-name=${svc}" \
      -o json 2>/dev/null); then
    WEBHOOK_SERVICE_STATE["$key"]="UNVERIFIED"
    echo "UNVERIFIED"
    return
  fi

  ready=$(jq '
    [
      .items[].endpoints[]? |
      select(.conditions.ready != false)
    ] | length
  ' <<<"$slices")

  if (( ready > 0 )); then
    WEBHOOK_SERVICE_STATE["$key"]="READY"
  else
    WEBHOOK_SERVICE_STATE["$key"]="NO-READY-ENDPOINT"
  fi

  echo "${WEBHOOK_SERVICE_STATE[$key]}"
}

inspect_webhook_kind() {
  local kind="$1"
  local data config_name webhook_name failure_policy service_ns service_name has_delete_like state

  if ! data=$(k get "$kind" -o json 2>"$TMP_DIR/${kind}.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 ${kind}"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/${kind}.err"
    return
  fi

  while IFS=$'\t' read -r config_name webhook_name failure_policy service_ns service_name has_delete_like; do
    [[ "$has_delete_like" == "true" ]] || continue

    if [[ "$service_ns" == "<url>" ]]; then
      if [[ "$failure_policy" == "Fail" ]]; then
        warn "${kind}/${config_name}/${webhook_name}: external URL + failurePolicy=Fail may affect DELETE/UPDATE"
        add_warning "External admission webhook ${config_name}/${webhook_name} may affect deletion"
      fi
      continue
    fi

    state=$(webhook_service_health "$service_ns" "$service_name")

    if (( JSON_MODE == 0 )); then
      printf '  - %s/%s webhook=%s policy=%s service=%s/%s state=%s\n' \
        "$kind" "$config_name" "$webhook_name" "$failure_policy" \
        "$service_ns" "$service_name" "$state"
    fi

    if [[ "$service_ns" == "$NAMESPACE" ]]; then
      add_danger "${kind}/${config_name} backend ${service_ns}/${service_name} is inside target Namespace"
    fi

    if [[ "$failure_policy" == "Fail" ]]; then
      case "$state" in
        SERVICE-NOT-FOUND|NO-READY-ENDPOINT)
          add_danger "${kind}/${config_name}/${webhook_name} failurePolicy=Fail but backend state=${state}"
          ;;
        UNVERIFIED)
          add_warning "Unable to verify backend of Fail webhook ${config_name}/${webhook_name}"
          add_force_blocker "Fail webhook backend could not be verified: ${config_name}/${webhook_name}"
          ;;
      esac
    fi
  done < <(
    jq -r '
      .items[] as $cfg |
      $cfg.webhooks[]? |
      (
        [
          .rules[]?.operations[]?
        ] | any(. == "DELETE" or . == "UPDATE" or . == "*" )
      ) as $hasDeleteLike |
      [
        $cfg.metadata.name,
        .name,
        (.failurePolicy // "Fail"),
        (
          if .clientConfig.service then
            .clientConfig.service.namespace
          else
            "<url>"
          end
        ),
        (
          if .clientConfig.service then
            .clientConfig.service.name
          else
            "-"
          end
        ),
        ($hasDeleteLike | tostring)
      ] | @tsv
    ' <<<"$data"
  )
}

collect_admission() {
  section "7. Admission Webhook / ValidatingAdmissionPolicy"

  info "Webhook check: DELETE/UPDATE/* + failurePolicy=Fail is treated conservatively."
  inspect_webhook_kind validatingwebhookconfigurations.admissionregistration.k8s.io
  inspect_webhook_kind mutatingwebhookconfigurations.admissionregistration.k8s.io

  local admission_resources
  admission_resources=$(k api-resources \
      --api-group=admissionregistration.k8s.io \
      -o name 2>/dev/null || true)

  if ! grep -Eq '^validatingadmissionpolicies(\.|$)' <<<"$admission_resources"; then
    info "ValidatingAdmissionPolicy API is not available; skipped"
    return
  fi

  local policy_json binding_json
  if ! policy_json=$(k get validatingadmissionpolicies.admissionregistration.k8s.io \
      -o json 2>"$TMP_DIR/vap.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 ValidatingAdmissionPolicy"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/vap.err"
    return
  fi

  if ! binding_json=$(k get validatingadmissionpolicybindings.admissionregistration.k8s.io \
      -o json 2>"$TMP_DIR/vapbinding.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 ValidatingAdmissionPolicyBinding"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/vapbinding.err"
    return
  fi

  local policy_name failure_policy destructive binding_name actions param_ns
  while IFS=$'\t' read -r policy_name failure_policy destructive; do
    [[ "$destructive" == "true" ]] || continue

    while IFS=$'\t' read -r binding_name actions param_ns; do
      [[ -n "$binding_name" ]] || continue

      if (( JSON_MODE == 0 )); then
        printf '  - VAP=%s binding=%s failurePolicy=%s actions=%s paramNamespace=%s\n' \
          "$policy_name" "$binding_name" "$failure_policy" "$actions" "$param_ns"
      fi

      if [[ "$failure_policy" == "Fail" && "$actions" == *"Deny"* ]]; then
        add_warning "VAP ${policy_name}/${binding_name} can Deny DELETE/UPDATE requests"

        if [[ "$param_ns" == "$NAMESPACE" ]]; then
          add_danger "VAP ${policy_name}/${binding_name} paramRef is in target Namespace; deletion ordering can block admission"
        fi
      fi
    done < <(
      jq -r --arg policy "$policy_name" '
        .items[] |
        select(.spec.policyName == $policy) |
        [
          .metadata.name,
          ((.spec.validationActions // []) | join(",")),
          (.spec.paramRef.namespace // "-")
        ] | @tsv
      ' <<<"$binding_json"
    )
  done < <(
    jq -r '
      .items[] |
      (
        [
          .spec.matchConstraints.resourceRules[]?.operations[]?
        ] | any(. == "DELETE" or . == "UPDATE" or . == "*")
      ) as $destructive |
      [
        .metadata.name,
        (.spec.failurePolicy // "Fail"),
        ($destructive | tostring)
      ] | @tsv
    ' <<<"$policy_json"
  )
}

