# shellcheck shell=bash
# namespace-terminating-diagnose v2.0.0 library

collect_namespace_state() {
  section "1. Namespace State / Conditions"

  local ns_json condition_count
  ns_json=$(k get namespace "$NAMESPACE" -o json) ||
    die "failed to read namespace JSON"

  NAMESPACE_PHASE=$(jq -r '.status.phase // "Unknown"' <<<"$ns_json")
  NAMESPACE_DELETION_TIMESTAMP=$(jq -r '.metadata.deletionTimestamp // ""' <<<"$ns_json")
  NAMESPACE_FINALIZERS=$(jq -r '(.spec.finalizers // []) | join(",")' <<<"$ns_json")

  info "phase               : ${NAMESPACE_PHASE}"
  info "deletionTimestamp   : ${NAMESPACE_DELETION_TIMESTAMP:-<none>}"
  info "namespace finalizers: ${NAMESPACE_FINALIZERS:-<none>}"

  if [[ -n "$NAMESPACE_DELETION_TIMESTAMP" ]]; then
    if NAMESPACE_AGE_SECONDS=$(timestamp_age_seconds "$NAMESPACE_DELETION_TIMESTAMP"); then
      NAMESPACE_AGE_KNOWN=1
      info "terminating age     : $(human_seconds "$NAMESPACE_AGE_SECONDS") (${NAMESPACE_AGE_SECONDS}s)"
    else
      NAMESPACE_AGE_SECONDS=-1
      NAMESPACE_AGE_KNOWN=0
      add_warning "无法解析 Namespace deletionTimestamp，不能进行 FORCE-READY 判定"
      add_force_blocker "Namespace terminating age is unknown"
      warn "cannot parse Namespace deletionTimestamp"
    fi
  fi

  if jq -e '
      (.spec.finalizers // []) |
      map(select(. != "kubernetes")) |
      length > 0
    ' <<<"$ns_json" >/dev/null; then
    local custom_ns_finalizers
    custom_ns_finalizers=$(jq -r '
      (.spec.finalizers // []) |
      map(select(. != "kubernetes")) |
      join(",")
    ' <<<"$ns_json")
    add_danger "Namespace spec.finalizers 存在非标准值: ${custom_ns_finalizers}"
    danger "custom Namespace finalizer(s): ${custom_ns_finalizers}"
  fi

  condition_count=$(jq '(.status.conditions // []) | length' <<<"$ns_json")

  if (( condition_count == 0 )); then
    info "Namespace has no status.conditions"
  else
    if (( JSON_MODE == 0 )); then
      printf '%-43s %-8s %-28s %s\n' "TYPE" "STATUS" "REASON" "MESSAGE"
      printf '%-43s %-8s %-28s %s\n' "----" "------" "------" "-------"
    fi

    while IFS=$'\t' read -r ctype cstatus creason cmessage; do
      if (( JSON_MODE == 0 )); then
        printf '%-43s %-8s %-28s %s\n' \
          "$ctype" "$cstatus" "$creason" "$cmessage"
      fi

      if [[ "$cstatus" == "True" ]]; then
        case "$ctype" in
          NamespaceDeletionDiscoveryFailure)
            add_danger "NamespaceDeletionDiscoveryFailure=True: ${cmessage}"
            ;;
          NamespaceDeletionGroupVersionParsingFailure)
            add_danger "NamespaceDeletionGroupVersionParsingFailure=True: ${cmessage}"
            ;;
          NamespaceDeletionContentFailure)
            add_danger "NamespaceDeletionContentFailure=True: ${cmessage}"
            ;;
          NamespaceContentRemaining)
            add_warning "NamespaceContentRemaining=True: ${cmessage}"
            add_force_blocker "Namespace controller reports remaining content"
            ;;
          NamespaceFinalizersRemaining)
            add_danger "NamespaceFinalizersRemaining=True: ${cmessage}"
            ;;
          *)
            add_warning "Namespace condition ${ctype}=True: ${cmessage}"
            add_force_blocker "Unknown/active Namespace condition: ${ctype}=True"
            ;;
        esac
      fi
    done < <(
      jq -r '
        (.status.conditions // [])[] |
        [
          .type,
          .status,
          (.reason // "-"),
          ((.message // "-") | gsub("[\t\r\n]"; " "))
        ] | @tsv
      ' <<<"$ns_json"
    )
  fi

  if [[ "$NAMESPACE_PHASE" != "Terminating" ]]; then
    add_warning "Namespace 当前 phase=${NAMESPACE_PHASE}，不是 Terminating"
  fi
}

collect_apiservices() {
  section "2. APIService / Aggregated API Discovery"

  local data false_count target_backend_count
  if ! data=$(k get apiservice -o json 2>"$TMP_DIR/apiservice.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 APIService；API Discovery 健康状态无法确认"
    danger "failed to list APIService"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/apiservice.err"
    return
  fi

  false_count=$(jq '
    [
      .items[] |
      (
        ([.status.conditions[]? |
          select(.type=="Available")][0]) // {}
      ) as $c |
      select(($c.status // "Unknown") != "True")
    ] | length
  ' <<<"$data")

  if (( false_count == 0 )); then
    ok "all registered APIService objects report Available=True"
  else
    danger "${false_count} APIService object(s) are not Available=True"
    (( JSON_MODE == 1 )) ||
      printf '%-45s %-10s %-30s %s\n' "APISERVICE" "AVAILABLE" "SERVICE" "MESSAGE"

    while IFS=$'\t' read -r name available service message; do
      if (( JSON_MODE == 0 )); then
        printf '%-45s %-10s %-30s %s\n' "$name" "$available" "$service" "$message"
      fi
      add_danger "APIService ${name} Available=${available}; Namespace discovery may be blocked"
      jq -nc \
        --arg name "$name" \
        --arg available "$available" \
        --arg service "$service" \
        --arg message "$message" \
        '{name:$name,available:$available,service:$service,message:$message}' \
        >>"$UNAVAILABLE_APISERVICE_FILE"
    done < <(
      jq -r '
        .items[] |
        (
          ([.status.conditions[]? |
            select(.type=="Available")][0]) // {}
        ) as $c |
        select(($c.status // "Unknown") != "True") |
        [
          .metadata.name,
          ($c.status // "Unknown"),
          (
            if .spec.service then
              (.spec.service.namespace + "/" + .spec.service.name)
            else
              "<local>"
            end
          ),
          (($c.message // "-") | gsub("[\t\r\n]"; " "))
        ] | @tsv
      ' <<<"$data"
    )
  fi

  if [[ -z "$NAMESPACE" ]]; then
    return
  fi

  target_backend_count=$(jq --arg ns "$NAMESPACE" '
    [
      .items[] |
      select(.spec.service.namespace? == $ns)
    ] | length
  ' <<<"$data")

  if (( target_backend_count > 0 )); then
    danger "target Namespace hosts ${target_backend_count} APIService backend(s)"
    while IFS=$'\t' read -r name svc; do
      (( JSON_MODE == 1 )) || printf '  - %s -> %s\n' "$name" "$svc"
      add_danger "APIService ${name} backend service is inside target Namespace (${svc})"
    done < <(
      jq -r --arg ns "$NAMESPACE" '
        .items[] |
        select(.spec.service.namespace? == $ns) |
        [
          .metadata.name,
          (.spec.service.namespace + "/" + .spec.service.name)
        ] | @tsv
      ' <<<"$data"
    )
  fi
}

scan_all_namespaced_resources() {
  section "3. Full Namespaced Resource Scan"

  local resources resource obj_json count term_count finalizer_count
  local err_file="$TMP_DIR/api-resources.err"

  if ! resources=$(k api-resources \
      --verbs=list \
      --namespaced \
      -o name 2>"$err_file"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "kubectl api-resources 执行失败，无法证明 Namespace 已清空"
    danger "API resource discovery failed"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$err_file"
    return
  fi

  if [[ -s "$err_file" ]]; then
    warn "api-resources returned stderr output"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$err_file"
    add_warning "api-resources 有 stderr 输出，需人工确认 Discovery 是否完整"
    add_force_blocker "API resource discovery emitted warnings/errors"
  fi

  resources=$(printf '%s\n' "$resources" | sed '/^[[:space:]]*$/d' | sort -u)

  if [[ -z "$resources" ]]; then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "api-resources 返回空列表，资源扫描不可用"
    return
  fi

  if (( JSON_MODE == 0 )); then
    printf '%-58s %8s %12s %12s\n' "RESOURCE" "COUNT" "TERMINATING" "FINALIZERS"
    printf '%-58s %8s %12s %12s\n' "--------" "-----" "-----------" "----------"
  fi

  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue

    if ! obj_json=$(k get "$resource" \
        -n "$NAMESPACE" \
        --ignore-not-found \
        -o json 2>"$TMP_DIR/resource.err"); then
      SCAN_ERRORS=$((SCAN_ERRORS + 1))
      (( JSON_MODE == 1 )) ||
        printf '%-58s %8s %12s %12s\n' "$resource" "ERROR" "-" "-"
      warn "cannot list ${resource}: $(tr '\n' ' ' < "$TMP_DIR/resource.err")"
      add_force_blocker "Unable to list namespaced resource: ${resource}"
      continue
    fi

    count=$(jq '(.items // []) | length' <<<"$obj_json" 2>/dev/null || echo 0)
    term_count=$(jq '
      [(.items // [])[] |
       select(.metadata.deletionTimestamp != null)] |
      length
    ' <<<"$obj_json" 2>/dev/null || echo 0)
    finalizer_count=$(jq '
      [(.items // [])[] |
       select(((.metadata.finalizers // []) | length) > 0)] |
      length
    ' <<<"$obj_json" 2>/dev/null || echo 0)

    RESOURCE_COUNTS["$resource"]="$count"
    RESOURCE_TERM_COUNTS["$resource"]="$term_count"
    RESOURCE_FINALIZER_COUNTS["$resource"]="$finalizer_count"

    if (( count > 0 )); then
      REMAINING_TOTAL=$((REMAINING_TOTAL + count))
      TERMINATING_OBJECT_TOTAL=$((TERMINATING_OBJECT_TOTAL + term_count))
      OBJECT_FINALIZER_TOTAL=$((OBJECT_FINALIZER_TOTAL + finalizer_count))

      (( JSON_MODE == 1 )) ||
        printf '%-58s %8d %12d %12d\n' \
          "$resource" "$count" "$term_count" "$finalizer_count"

      jq -nc \
        --arg resource "$resource" \
        --argjson count "$count" \
        --argjson terminating "$term_count" \
        --argjson with_finalizers "$finalizer_count" \
        '{
          resource:$resource,
          count:$count,
          terminating:$terminating,
          objects_with_finalizers:$with_finalizers
        }' >>"$RESOURCE_RECORDS_FILE"

      add_force_blocker "Remaining resource: ${resource} count=${count}"

      if (( finalizer_count > 0 )); then
        add_danger "${resource} has ${finalizer_count} object(s) with metadata.finalizers"
      fi

      if (( term_count > 0 )); then
        add_warning "${resource} has ${term_count} terminating object(s)"
      fi

      while IFS=$'\t' read -r name deleting finalizers; do
        jq -nc \
          --arg resource "$resource" \
          --arg name "$name" \
          --arg deletion_timestamp "$deleting" \
          --arg finalizers "$finalizers" \
          '{
            resource:$resource,
            name:$name,
            deletion_timestamp:
              (if $deletion_timestamp=="-" then null else $deletion_timestamp end),
            finalizers:
              (if $finalizers=="" then [] else ($finalizers | split(",")) end)
          }' >>"$FINALIZER_RECORDS_FILE"

        if (( JSON_MODE == 0 )); then
          printf '    - name=%s deletionTimestamp=%s finalizers=%s\n' \
            "$name" "$deleting" "${finalizers:-<none>}"
        fi
      done < <(
        jq -r --argjson max "$MAX_DETAILS" '
          [
            (.items // [])[] |
            select(
              .metadata.deletionTimestamp != null or
              ((.metadata.finalizers // []) | length) > 0
            ) |
            [
              .metadata.name,
              (.metadata.deletionTimestamp // "-"),
              ((.metadata.finalizers // []) | join(","))
            ]
          ][: $max][] | @tsv
        ' <<<"$obj_json"
      )
    fi
  done <<<"$resources"

  if (( REMAINING_TOTAL == 0 && SCAN_ERRORS == 0 )); then
    ok "full namespaced resource scan found no remaining objects"
  else
    warn "remaining=${REMAINING_TOTAL}, terminating=${TERMINATING_OBJECT_TOTAL}, finalizers=${OBJECT_FINALIZER_TOTAL}, scan-errors=${SCAN_ERRORS}"

    if (( REMAINING_TOTAL > 0 )); then
      add_warning "Namespace 仍有 ${REMAINING_TOTAL} 个 namespaced object"
    fi
    if (( SCAN_ERRORS > 0 )); then
      add_danger "资源扫描存在 ${SCAN_ERRORS} 个错误，不能证明 Namespace 已清空"
    fi
  fi
}

collect_pods() {
  section "4. Pod Deep Check"

  local data count nodes_json
  if ! data=$(k get pods -n "$NAMESPACE" -o json 2>"$TMP_DIR/pods.err"); then
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    add_danger "无法读取 Pod"
    [[ "$JSON_MODE" -eq 1 ]] || sed 's/^/  /' "$TMP_DIR/pods.err"
    return
  fi

  count=$(jq '.items | length' <<<"$data")
  if (( count == 0 )); then
    ok "no Pod remains"
    return
  fi

  warn "${count} Pod(s) remain"
  nodes_json=$(k get nodes -o json 2>/dev/null || echo '{"items":[]}')

  if (( JSON_MODE == 0 )); then
    printf '%-48s %-12s %-36s %-12s %-16s %s\n' \
      "POD" "PHASE" "NODE" "NODE_READY" "DELETING" "FINALIZERS"
  fi

  while IFS=$'\t' read -r name phase node deleting finalizers; do
    local node_ready
    node_ready=$(jq -r --arg node "$node" '
      [
        .items[] |
        select(.metadata.name == $node) |
        .status.conditions[]? |
        select(.type=="Ready") |
        .status
      ][0] // "Unknown"
    ' <<<"$nodes_json")

    if (( JSON_MODE == 0 )); then
      printf '%-48s %-12s %-36s %-12s %-16s %s\n' \
        "$name" "$phase" "${node:--}" "$node_ready" \
        "${deleting:--}" "${finalizers:-<none>}"
    fi

    if [[ "$deleting" != "-" && "$node_ready" != "True" ]]; then
      add_warning "Terminating Pod ${name} is on Node ${node} Ready=${node_ready}"
    fi
  done < <(
    jq -r --argjson max "$MAX_DETAILS" '
      [
        .items[] |
        [
          .metadata.name,
          (.status.phase // "-"),
          (.spec.nodeName // "-"),
          (.metadata.deletionTimestamp // "-"),
          ((.metadata.finalizers // []) | join(","))
        ]
      ][: $max][] | @tsv
    ' <<<"$data"
  )
}

