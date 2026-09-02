# shellcheck shell=bash
# namespace-terminating-diagnose v2.0.0 library

strict_force_ready() {
  FORCE_READY=0

  # check 子命令不执行完整资源扫描，因此永远不能声明 force-ready。
  [[ "$COMMAND" != "check" ]] || return 1
  [[ "$NAMESPACE_PHASE" == "Terminating" ]] || return 1
  (( NAMESPACE_AGE_KNOWN == 1 )) || return 1
  (( NAMESPACE_AGE_SECONDS >= TERMINATING_THRESHOLD_SECONDS )) || return 1
  (( REMAINING_TOTAL == 0 )) || return 1
  (( OBJECT_FINALIZER_TOTAL == 0 )) || return 1
  (( CUSTOM_RESOURCE_TOTAL == 0 )) || return 1
  (( PVC_TOTAL == 0 )) || return 1
  (( RELATED_PV_TOTAL == 0 )) || return 1
  (( VOLUME_ATTACHMENT_TOTAL == 0 )) || return 1
  (( SCAN_ERRORS == 0 )) || return 1
  (( ${#DANGERS[@]} == 0 )) || return 1
  (( ${#FORCE_BLOCKERS[@]} == 0 )) || return 1

  FORCE_READY=1
  return 0
}

determine_target_verdict() {
  strict_force_ready || true

  if (( ${#DANGERS[@]} > 0 )); then
    VERDICT="DANGEROUS"
    VERDICT_EXIT=20
    VERDICT_REASON="存在高风险删除阻塞或外部资源风险；禁止强制清理 Namespace finalizer。"
    return
  fi

  if [[ "$COMMAND" == "force-check" && "$FORCE_READY" -eq 1 ]]; then
    VERDICT="FORCE-FINALIZE-READY"
    VERDICT_EXIT=30
    VERDICT_REASON="完整只读检查满足人工 Break-Glass 前置条件；脚本不会执行 /finalize。"
    return
  fi

  if (( ${#WARNINGS[@]} > 0 )) ||
     (( REMAINING_TOTAL > 0 )) ||
     (( SCAN_ERRORS > 0 )) ||
     (( ${#FORCE_BLOCKERS[@]} > 0 )); then
    VERDICT="WARNING"
    VERDICT_EXIT=10
    VERDICT_REASON="存在剩余资源、暂时性问题或未完全验证项；继续等待或修复后重新检查。"
    return
  fi

  VERDICT="SAFE"
  VERDICT_EXIT=0

  if [[ "$NAMESPACE_PHASE" == "Terminating" ]]; then
    if [[ "$COMMAND" == "check" ]]; then
      VERDICT="WARNING"
      VERDICT_EXIT=10
      VERDICT_REASON="Namespace 正处于 Terminating；check 仅做轻量检查，需运行 diagnose 获取完整根因。"
    else
      VERDICT_REASON="未发现高风险阻塞；Namespace Controller 可继续正常收敛。"
    fi
  else
    VERDICT_REASON="未发现高风险删除阻塞；Namespace 当前并非 Terminating。"
  fi
}

print_risk_summary() {
  section "8. Risk Summary"

  info "remaining namespaced objects : ${REMAINING_TOTAL}"
  info "terminating objects          : ${TERMINATING_OBJECT_TOTAL}"
  info "objects with finalizers      : ${OBJECT_FINALIZER_TOTAL}"
  info "remaining Custom Resources   : ${CUSTOM_RESOURCE_TOTAL}"
  info "PVC                          : ${PVC_TOTAL}"
  info "related PV                   : ${RELATED_PV_TOTAL}"
  info "VolumeAttachment             : ${VOLUME_ATTACHMENT_TOTAL}"
  info "scan errors                   : ${SCAN_ERRORS}"
  info "warnings                      : ${#WARNINGS[@]}"
  info "danger findings               : ${#DANGERS[@]}"
  info "force-finalize blockers       : ${#FORCE_BLOCKERS[@]}"

  if (( JSON_MODE == 0 && ${#DANGERS[@]} > 0 )); then
    printf '\n%sDanger findings:%s\n' "$C_RED" "$C_RESET"
    printf '  - %s\n' "${DANGERS[@]}"
  fi

  if (( JSON_MODE == 0 && ${#WARNINGS[@]} > 0 )); then
    printf '\n%sWarnings:%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi

  if (( JSON_MODE == 0 && ${#FORCE_BLOCKERS[@]} > 0 )); then
    printf '\nForce-finalize blockers:\n'
    printf '  - %s\n' "${FORCE_BLOCKERS[@]}"
  fi
}

print_target_verdict() {
  (( JSON_MODE == 1 )) && return 0

  section "9. Final Verdict"

  case "$VERDICT" in
    SAFE)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_GREEN" "$VERDICT" "$C_RESET"
      ;;
    WARNING)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_YELLOW" "$VERDICT" "$C_RESET"
      ;;
    DANGEROUS)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_RED" "$VERDICT" "$C_RESET"
      ;;
    FORCE-FINALIZE-READY)
      printf '%s%sVERDICT: %s%s\n' "$C_BOLD" "$C_CYAN" "$VERDICT" "$C_RESET"
      ;;
  esac

  printf 'Reason : %s\n' "$VERDICT_REASON"
  printf 'Exit   : %s\n' "$VERDICT_EXIT"
  printf 'Force-ready candidate: %s\n' \
    "$([[ "$FORCE_READY" -eq 1 ]] && echo true || echo false)"

  if [[ "$VERDICT" == "FORCE-FINALIZE-READY" ]]; then
    cat <<'EOF'

Break-Glass checklist before any manual /finalize operation:
  [ ] 已确认目标 Namespace 确实应该删除
  [ ] 已确认业务 owner / 数据 owner 同意
  [ ] 已确认不存在云盘、LB、DNS、数据库、快照等外部资源残留
  [ ] 已确认相关 Operator/CSI/Cloud Controller 不再需要执行清理
  [ ] 已保存本工具 TXT / JSON 报告与 Namespace YAML
  [ ] 强制 finalize 后继续检查 PV / VolumeAttachment / CR / 云资源孤儿对象

This tool does NOT execute force-finalize.
EOF
  fi
}

build_target_json() {
  local warnings_json dangers_json blockers_json resources_json finalizers_json apiservices_json

  warnings_json=$(json_array_from_bash_array "${WARNINGS[@]}")
  dangers_json=$(json_array_from_bash_array "${DANGERS[@]}")
  blockers_json=$(json_array_from_bash_array "${FORCE_BLOCKERS[@]}")
  resources_json=$(ndjson_to_array "$RESOURCE_RECORDS_FILE")
  finalizers_json=$(ndjson_to_array "$FINALIZER_RECORDS_FILE")
  apiservices_json=$(ndjson_to_array "$UNAVAILABLE_APISERVICE_FILE")

  jq -n \
    --arg schema_version "1" \
    --arg tool "namespace-terminating-diagnose" \
    --arg version "$VERSION" \
    --arg command "$COMMAND" \
    --arg namespace "$NAMESPACE" \
    --arg phase "$NAMESPACE_PHASE" \
    --arg deletion_timestamp "$NAMESPACE_DELETION_TIMESTAMP" \
    --arg namespace_finalizers "$NAMESPACE_FINALIZERS" \
    --argjson terminating_age_seconds "$NAMESPACE_AGE_SECONDS" \
    --argjson threshold_seconds "$TERMINATING_THRESHOLD_SECONDS" \
    --arg verdict "$VERDICT" \
    --arg verdict_reason "$VERDICT_REASON" \
    --argjson exit_code "$VERDICT_EXIT" \
    --argjson force_finalize_ready "$FORCE_READY" \
    --argjson remaining_objects "$REMAINING_TOTAL" \
    --argjson terminating_objects "$TERMINATING_OBJECT_TOTAL" \
    --argjson objects_with_finalizers "$OBJECT_FINALIZER_TOTAL" \
    --argjson custom_resources "$CUSTOM_RESOURCE_TOTAL" \
    --argjson pvc "$PVC_TOTAL" \
    --argjson related_pv "$RELATED_PV_TOTAL" \
    --argjson volume_attachments "$VOLUME_ATTACHMENT_TOTAL" \
    --argjson scan_errors "$SCAN_ERRORS" \
    --argjson warnings "$warnings_json" \
    --argjson dangers "$dangers_json" \
    --argjson force_blockers "$blockers_json" \
    --argjson remaining_resources "$resources_json" \
    --argjson finalizer_objects "$finalizers_json" \
    --argjson unavailable_apiservices "$apiservices_json" \
    '{
      schema_version:$schema_version,
      tool:$tool,
      version:$version,
      command:$command,
      generated_at:(now | todateiso8601),
      namespace:{
        name:$namespace,
        phase:$phase,
        deletion_timestamp:
          (if $deletion_timestamp=="" then null else $deletion_timestamp end),
        terminating_age_seconds:$terminating_age_seconds,
        spec_finalizers:
          (if $namespace_finalizers=="" then [] else ($namespace_finalizers | split(",")) end)
      },
      threshold_seconds:$threshold_seconds,
      verdict:$verdict,
      verdict_reason:$verdict_reason,
      exit_code:$exit_code,
      force_finalize_ready:($force_finalize_ready == 1),
      counts:{
        remaining_objects:$remaining_objects,
        terminating_objects:$terminating_objects,
        objects_with_finalizers:$objects_with_finalizers,
        custom_resources:$custom_resources,
        pvc:$pvc,
        related_pv:$related_pv,
        volume_attachments:$volume_attachments,
        scan_errors:$scan_errors,
        warnings:($warnings|length),
        dangers:($dangers|length),
        force_blockers:($force_blockers|length)
      },
      warnings:$warnings,
      dangers:$dangers,
      force_blockers:$force_blockers,
      remaining_resources:$remaining_resources,
      finalizer_objects:$finalizer_objects,
      unavailable_apiservices:$unavailable_apiservices
    }'
}

write_target_prometheus() {
  local file="$1"
  local dir tmp ns verdict phase ready now
  dir=$(dirname "$file")
  mkdir -p "$dir" || die "cannot create Prometheus output directory: $dir"
  tmp="${file}.tmp.$$"

  ns=$(prom_escape "$NAMESPACE")
  verdict=$(prom_escape "$VERDICT")
  phase=$(prom_escape "$NAMESPACE_PHASE")
  ready=0
  (( FORCE_READY == 1 )) && ready=1
  now=$(date +%s)

  {
    echo '# HELP namespace_terminating_diagnose_info Tool verdict and Namespace phase.'
    echo '# TYPE namespace_terminating_diagnose_info gauge'
    printf 'namespace_terminating_diagnose_info{namespace="%s",phase="%s",verdict="%s",command="%s"} 1\n' \
      "$ns" "$phase" "$verdict" "$(prom_escape "$COMMAND")"

    echo '# HELP namespace_terminating_diagnose_terminating_age_seconds Namespace terminating age in seconds; -1 means unknown/not terminating.'
    echo '# TYPE namespace_terminating_diagnose_terminating_age_seconds gauge'
    printf 'namespace_terminating_diagnose_terminating_age_seconds{namespace="%s"} %d\n' \
      "$ns" "$NAMESPACE_AGE_SECONDS"

    echo '# HELP namespace_terminating_diagnose_remaining_objects Remaining namespaced objects.'
    echo '# TYPE namespace_terminating_diagnose_remaining_objects gauge'
    printf 'namespace_terminating_diagnose_remaining_objects{namespace="%s"} %d\n' \
      "$ns" "$REMAINING_TOTAL"

    echo '# HELP namespace_terminating_diagnose_terminating_objects Remaining objects with deletionTimestamp.'
    echo '# TYPE namespace_terminating_diagnose_terminating_objects gauge'
    printf 'namespace_terminating_diagnose_terminating_objects{namespace="%s"} %d\n' \
      "$ns" "$TERMINATING_OBJECT_TOTAL"

    echo '# HELP namespace_terminating_diagnose_objects_with_finalizers Objects with metadata.finalizers.'
    echo '# TYPE namespace_terminating_diagnose_objects_with_finalizers gauge'
    printf 'namespace_terminating_diagnose_objects_with_finalizers{namespace="%s"} %d\n' \
      "$ns" "$OBJECT_FINALIZER_TOTAL"

    echo '# HELP namespace_terminating_diagnose_custom_resources Remaining custom resources.'
    echo '# TYPE namespace_terminating_diagnose_custom_resources gauge'
    printf 'namespace_terminating_diagnose_custom_resources{namespace="%s"} %d\n' \
      "$ns" "$CUSTOM_RESOURCE_TOTAL"

    echo '# HELP namespace_terminating_diagnose_pvc Remaining PVCs.'
    echo '# TYPE namespace_terminating_diagnose_pvc gauge'
    printf 'namespace_terminating_diagnose_pvc{namespace="%s"} %d\n' \
      "$ns" "$PVC_TOTAL"

    echo '# HELP namespace_terminating_diagnose_related_pv PVs whose claimRef points to the Namespace.'
    echo '# TYPE namespace_terminating_diagnose_related_pv gauge'
    printf 'namespace_terminating_diagnose_related_pv{namespace="%s"} %d\n' \
      "$ns" "$RELATED_PV_TOTAL"

    echo '# HELP namespace_terminating_diagnose_volume_attachments VolumeAttachments referencing Namespace-related PVs.'
    echo '# TYPE namespace_terminating_diagnose_volume_attachments gauge'
    printf 'namespace_terminating_diagnose_volume_attachments{namespace="%s"} %d\n' \
      "$ns" "$VOLUME_ATTACHMENT_TOTAL"

    echo '# HELP namespace_terminating_diagnose_scan_errors Diagnostic scan errors.'
    echo '# TYPE namespace_terminating_diagnose_scan_errors gauge'
    printf 'namespace_terminating_diagnose_scan_errors{namespace="%s"} %d\n' \
      "$ns" "$SCAN_ERRORS"

    echo '# HELP namespace_terminating_diagnose_force_finalize_ready Whether strict read-only checks allow Break-Glass review.'
    echo '# TYPE namespace_terminating_diagnose_force_finalize_ready gauge'
    printf 'namespace_terminating_diagnose_force_finalize_ready{namespace="%s"} %d\n' \
      "$ns" "$ready"

    echo '# HELP namespace_terminating_diagnose_generated_timestamp_seconds Unix timestamp of this diagnostic result.'
    echo '# TYPE namespace_terminating_diagnose_generated_timestamp_seconds gauge'
    printf 'namespace_terminating_diagnose_generated_timestamp_seconds{namespace="%s"} %d\n' \
      "$ns" "$now"
  } >"$tmp" || {
    rm -f "$tmp"
    die "cannot write Prometheus metrics: $file"
  }

  mv -f "$tmp" "$file" || die "cannot atomically install Prometheus metrics: $file"
  info "Prometheus metrics written: ${file}"
}

write_text_summary() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  mkdir -p "$dir" || die "cannot create report directory: $dir"

  {
    printf 'namespace-terminating-diagnose v%s\n' "$VERSION"
    printf 'Generated: %s\n' "$(date -Is 2>/dev/null || date)"
    printf 'Command: %s\n' "$COMMAND"
    printf 'Namespace: %s\n' "$NAMESPACE"
    printf 'Phase: %s\n' "$NAMESPACE_PHASE"
    printf 'DeletionTimestamp: %s\n' "${NAMESPACE_DELETION_TIMESTAMP:-<none>}"
    printf 'TerminatingAgeSeconds: %s\n' "$NAMESPACE_AGE_SECONDS"
    printf 'ThresholdSeconds: %s\n' "$TERMINATING_THRESHOLD_SECONDS"
    printf 'Verdict: %s\n' "$VERDICT"
    printf 'ExitCode: %s\n' "$VERDICT_EXIT"
    printf 'ForceFinalizeReady: %s\n' \
      "$([[ "$FORCE_READY" -eq 1 ]] && echo true || echo false)"
    printf 'Reason: %s\n' "$VERDICT_REASON"

    printf '\nCounts:\n'
    printf '  remaining_objects=%s\n' "$REMAINING_TOTAL"
    printf '  terminating_objects=%s\n' "$TERMINATING_OBJECT_TOTAL"
    printf '  objects_with_finalizers=%s\n' "$OBJECT_FINALIZER_TOTAL"
    printf '  custom_resources=%s\n' "$CUSTOM_RESOURCE_TOTAL"
    printf '  pvc=%s\n' "$PVC_TOTAL"
    printf '  related_pv=%s\n' "$RELATED_PV_TOTAL"
    printf '  volume_attachments=%s\n' "$VOLUME_ATTACHMENT_TOTAL"
    printf '  scan_errors=%s\n' "$SCAN_ERRORS"

    if (( ${#DANGERS[@]} > 0 )); then
      printf '\nDanger findings:\n'
      printf '  - %s\n' "${DANGERS[@]}"
    fi

    if (( ${#WARNINGS[@]} > 0 )); then
      printf '\nWarnings:\n'
      printf '  - %s\n' "${WARNINGS[@]}"
    fi

    if (( ${#FORCE_BLOCKERS[@]} > 0 )); then
      printf '\nForce-finalize blockers:\n'
      printf '  - %s\n' "${FORCE_BLOCKERS[@]}"
    fi

    if [[ -s "$RESOURCE_RECORDS_FILE" ]]; then
      printf '\nRemaining resource summary:\n'
      jq -r '"  - \(.resource): count=\(.count), terminating=\(.terminating), finalizers=\(.objects_with_finalizers)"' \
        "$RESOURCE_RECORDS_FILE"
    fi
  } >"$file" || die "cannot write report: $file"
}

write_report_bundle() {
  local ts base text_file json_file prom_file target_json

  mkdir -p "$OUTPUT_DIR" || die "cannot create report output directory: $OUTPUT_DIR"
  ts=$(date +%Y%m%d-%H%M%S)
  base="${OUTPUT_DIR%/}/${NAMESPACE}-${ts}"
  text_file="${base}.txt"
  json_file="${base}.json"
  prom_file="${base}.prom"

  target_json=$(build_target_json)
  write_text_summary "$text_file"
  printf '%s\n' "$target_json" >"$json_file" ||
    die "cannot write JSON report: $json_file"
  write_target_prometheus "$prom_file"

  info "TXT report  : ${text_file}"
  info "JSON report : ${json_file}"
  info "Prom metrics: ${prom_file}"

  if (( JSON_MODE == 1 )); then
    jq \
      --arg text_report "$text_file" \
      --arg json_report "$json_file" \
      --arg prometheus_report "$prom_file" \
      '. + {artifacts:{
        text:$text_report,
        json:$json_report,
        prometheus:$prometheus_report
      }}' <<<"$target_json"
  fi
}

run_target_full_scan() {
  collect_namespace_state
  collect_apiservices
  scan_all_namespaced_resources
  collect_pods
  collect_storage
  collect_custom_resources
  collect_admission
  print_risk_summary
  determine_target_verdict
}

run_target_check() {
  collect_namespace_state
  collect_apiservices
  determine_target_verdict
}

run_target_command() {
  preflight_cluster
  preflight_namespace

  case "$COMMAND" in
    check)
      run_target_check
      ;;
    diagnose|report|force-check)
      run_target_full_scan
      ;;
  esac

  print_target_verdict

  if [[ -n "$PROMETHEUS_OUTPUT" ]]; then
    write_target_prometheus "$PROMETHEUS_OUTPUT"
  fi

  if [[ -n "$LEGACY_REPORT_FILE" ]]; then
    write_text_summary "$LEGACY_REPORT_FILE"
    info "legacy text report written: ${LEGACY_REPORT_FILE}"
  fi

  case "$COMMAND" in
    report)
      write_report_bundle
      ;;
    *)
      if (( JSON_MODE == 1 )); then
        build_target_json
      fi
      ;;
  esac

  return "$VERDICT_EXIT"
}

