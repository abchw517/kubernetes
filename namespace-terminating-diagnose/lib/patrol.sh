# shellcheck shell=bash
# namespace-terminating-diagnose v2.0.0 library

collect_patrol() {
  section "NamespaceTerminating Patrol"

  local ns_json name phase deletion age over
  if ! ns_json=$(k get namespaces -o json 2>"$TMP_DIR/namespaces.err"); then
    [[ "$JSON_MODE" -eq 1 ]] || cat "$TMP_DIR/namespaces.err" >&2
    die "cannot list namespaces"
  fi

  if (( JSON_MODE == 0 )); then
    printf '%-48s %-14s %-30s %-12s %s\n' \
      "NAMESPACE" "PHASE" "DELETION_TIMESTAMP" "AGE_SECONDS" "OVER_THRESHOLD"
  fi

  while IFS=$'\t' read -r name phase deletion; do
    [[ -n "$deletion" && "$deletion" != "-" ]] || continue

    PATROL_TERMINATING_TOTAL=$((PATROL_TERMINATING_TOTAL + 1))
    age=-1
    over=0

    if age=$(timestamp_age_seconds "$deletion"); then
      if (( age >= TERMINATING_THRESHOLD_SECONDS )); then
        over=1
        PATROL_OVER_THRESHOLD_TOTAL=$((PATROL_OVER_THRESHOLD_TOTAL + 1))
      fi
    else
      age=-1
      PATROL_UNKNOWN_AGE_TOTAL=$((PATROL_UNKNOWN_AGE_TOTAL + 1))
    fi

    if (( JSON_MODE == 0 )); then
      printf '%-48s %-14s %-30s %-12s %s\n' \
        "$name" "$phase" "$deletion" "$age" \
        "$([[ "$over" -eq 1 ]] && echo true || echo false)"
    fi

    jq -nc \
      --arg namespace "$name" \
      --arg phase "$phase" \
      --arg deletion_timestamp "$deletion" \
      --argjson age_seconds "$age" \
      --argjson over_threshold "$over" \
      '{
        namespace:$namespace,
        phase:$phase,
        deletion_timestamp:$deletion_timestamp,
        age_seconds:$age_seconds,
        over_threshold:($over_threshold == 1)
      }' >>"$PATROL_RECORDS_FILE"
  done < <(
    jq -r '
      .items[] |
      select(.metadata.deletionTimestamp != null or .status.phase == "Terminating") |
      [
        .metadata.name,
        (.status.phase // "Unknown"),
        (.metadata.deletionTimestamp // "-")
      ] | @tsv
    ' <<<"$ns_json"
  )

  if (( PATROL_UNKNOWN_AGE_TOTAL > 0 )); then
    add_warning "${PATROL_UNKNOWN_AGE_TOTAL} Terminating Namespace deletionTimestamp 无法解析"
  fi

  if (( PATROL_OVER_THRESHOLD_TOTAL > 0 )); then
    VERDICT="WARNING"
    VERDICT_EXIT=10
    VERDICT_REASON="${PATROL_OVER_THRESHOLD_TOTAL} Namespace(s) Terminating 超过 ${TERMINATING_THRESHOLD_SECONDS}s"
  elif (( PATROL_UNKNOWN_AGE_TOTAL > 0 )); then
    VERDICT="WARNING"
    VERDICT_EXIT=10
    VERDICT_REASON="存在 Terminating Namespace，但部分删除时长无法验证"
  else
    VERDICT="SAFE"
    VERDICT_EXIT=0
    VERDICT_REASON="没有 Namespace Terminating 超过 ${TERMINATING_THRESHOLD_SECONDS}s"
  fi

  if (( JSON_MODE == 0 )); then
    printf '\nPatrol summary: terminating=%d over-threshold=%d unknown-age=%d\n' \
      "$PATROL_TERMINATING_TOTAL" \
      "$PATROL_OVER_THRESHOLD_TOTAL" \
      "$PATROL_UNKNOWN_AGE_TOTAL"
    printf 'VERDICT: %s\nReason : %s\nExit   : %s\n' \
      "$VERDICT" "$VERDICT_REASON" "$VERDICT_EXIT"
  fi
}

build_patrol_json() {
  local items_json warnings_json
  items_json=$(ndjson_to_array "$PATROL_RECORDS_FILE")
  warnings_json=$(json_array_from_bash_array "${WARNINGS[@]}")

  jq -n \
    --arg schema_version "1" \
    --arg tool "namespace-terminating-diagnose" \
    --arg version "$VERSION" \
    --arg command "check" \
    --arg mode "all-terminating" \
    --argjson threshold_seconds "$TERMINATING_THRESHOLD_SECONDS" \
    --arg verdict "$VERDICT" \
    --arg verdict_reason "$VERDICT_REASON" \
    --argjson exit_code "$VERDICT_EXIT" \
    --argjson terminating_total "$PATROL_TERMINATING_TOTAL" \
    --argjson over_threshold_total "$PATROL_OVER_THRESHOLD_TOTAL" \
    --argjson unknown_age_total "$PATROL_UNKNOWN_AGE_TOTAL" \
    --argjson warnings "$warnings_json" \
    --argjson items "$items_json" \
    '{
      schema_version:$schema_version,
      tool:$tool,
      version:$version,
      command:$command,
      mode:$mode,
      generated_at:(now | todateiso8601),
      threshold_seconds:$threshold_seconds,
      verdict:$verdict,
      verdict_reason:$verdict_reason,
      exit_code:$exit_code,
      counts:{
        terminating:$terminating_total,
        over_threshold:$over_threshold_total,
        unknown_age:$unknown_age_total
      },
      warnings:$warnings,
      namespaces:$items
    }'
}

write_patrol_prometheus() {
  local file="$1"
  local dir tmp now
  dir=$(dirname "$file")
  mkdir -p "$dir" || die "cannot create Prometheus output directory: $dir"
  tmp="${file}.tmp.$$"
  now=$(date +%s)

  {
    echo '# HELP namespace_terminating_diagnose_patrol_terminating_total Number of namespaces currently terminating.'
    echo '# TYPE namespace_terminating_diagnose_patrol_terminating_total gauge'
    printf 'namespace_terminating_diagnose_patrol_terminating_total %d\n' \
      "$PATROL_TERMINATING_TOTAL"

    echo '# HELP namespace_terminating_diagnose_patrol_over_threshold_total Number of terminating namespaces older than configured threshold.'
    echo '# TYPE namespace_terminating_diagnose_patrol_over_threshold_total gauge'
    printf 'namespace_terminating_diagnose_patrol_over_threshold_total %d\n' \
      "$PATROL_OVER_THRESHOLD_TOTAL"

    echo '# HELP namespace_terminating_diagnose_patrol_unknown_age_total Number of terminating namespaces whose deletion age cannot be parsed.'
    echo '# TYPE namespace_terminating_diagnose_patrol_unknown_age_total gauge'
    printf 'namespace_terminating_diagnose_patrol_unknown_age_total %d\n' \
      "$PATROL_UNKNOWN_AGE_TOTAL"

    echo '# HELP namespace_terminating_diagnose_namespace_terminating Namespace is currently terminating.'
    echo '# TYPE namespace_terminating_diagnose_namespace_terminating gauge'

    echo '# HELP namespace_terminating_diagnose_namespace_terminating_age_seconds Namespace terminating age in seconds.'
    echo '# TYPE namespace_terminating_diagnose_namespace_terminating_age_seconds gauge'

    echo '# HELP namespace_terminating_diagnose_namespace_over_threshold Namespace terminating age is over configured threshold.'
    echo '# TYPE namespace_terminating_diagnose_namespace_over_threshold gauge'

    while IFS=$'\t' read -r name age over; do
      name=$(prom_escape "$name")
      printf 'namespace_terminating_diagnose_namespace_terminating{namespace="%s"} 1\n' "$name"
      printf 'namespace_terminating_diagnose_namespace_terminating_age_seconds{namespace="%s"} %d\n' \
        "$name" "$age"
      printf 'namespace_terminating_diagnose_namespace_over_threshold{namespace="%s",threshold_seconds="%s"} %d\n' \
        "$name" "$TERMINATING_THRESHOLD_SECONDS" "$over"
    done < <(
      jq -r '
        [
          .namespace,
          (.age_seconds | tostring),
          (if .over_threshold then "1" else "0" end)
        ] | @tsv
      ' "$PATROL_RECORDS_FILE" 2>/dev/null || true
    )

    echo '# HELP namespace_terminating_diagnose_generated_timestamp_seconds Unix timestamp of the patrol result.'
    echo '# TYPE namespace_terminating_diagnose_generated_timestamp_seconds gauge'
    printf 'namespace_terminating_diagnose_generated_timestamp_seconds{mode="patrol"} %d\n' "$now"
  } >"$tmp" || {
    rm -f "$tmp"
    die "cannot write Prometheus metrics: $file"
  }

  mv -f "$tmp" "$file" || die "cannot atomically install Prometheus metrics: $file"
  info "Prometheus patrol metrics written: ${file}"
}

run_patrol_command() {
  preflight_cluster
  collect_patrol

  if [[ -n "$PROMETHEUS_OUTPUT" ]]; then
    write_patrol_prometheus "$PROMETHEUS_OUTPUT"
  fi

  if (( JSON_MODE == 1 )); then
    build_patrol_json
  fi

  return "$VERDICT_EXIT"
}

