# shellcheck shell=bash

drivers_from_graph() {
  jq '[
    (.target.csi.driver? // empty),
    (.target.attacher? // empty),
    (.pv.csi.driver? // empty),
    (.pvs[]?.csi.driver? // empty),
    (.volumeAttachments[]?.attacher? // empty)
  ] | map(select(. != "" and . != null)) | unique' 
}

csi_driver_info() {
  local driver="$1" raw
  raw=$(k_json_default "get csidriver/${driver}" 'null' get csidriver.storage.k8s.io "${driver}")
  jq '{
    name:(.metadata.name // null),
    attachRequired:(.spec.attachRequired // true),
    podInfoOnMount:(.spec.podInfoOnMount // false),
    storageCapacity:(.spec.storageCapacity // false),
    fsGroupPolicy:(.spec.fsGroupPolicy // null),
    requiresRepublish:(.spec.requiresRepublish // false),
    seLinuxMount:(.spec.seLinuxMount // false)
  }' <<<"${raw}" 2>/dev/null || echo 'null'
}

csi_node_driver_info() {
  local driver="$1" node="$2" raw
  [[ -n "$node" ]] || { echo 'null'; return; }
  raw=$(k_json_default "get csinode/${node} for driver/${driver}" 'null' get csinode.storage.k8s.io "${node}")
  jq --arg d "$driver" '{
    node:(.metadata.name // null),
    driver:([.spec.drivers[]?|select(.name==$d)][0] // null)
  }' <<<"${raw}" 2>/dev/null || echo 'null'
}

csi_component_pods() {
  local driver="$1" nodes_json="$2" raw token
  raw=$(k_json_default "list pods for CSI component correlation driver/${driver}" '{"items":[]}' get pods -A)
  token=$(awk -F. '{print $1}' <<<"$driver")
  jq --arg d "$driver" --arg token "$token" --argjson nodes "$nodes_json" '
    def lc: ascii_downcase;
    def text: ((.metadata.name // "") + " " + (.metadata.namespace // "") + " " + ((.metadata.labels // {})|tostring) + " " + ((.metadata.annotations // {})|tostring) + " " + ((.spec.containers // [])|tostring)) | lc;
    [ .items[]?
      | . as $p
      | (text) as $txt
      | (($d|lc) as $driver | ($token|lc) as $tok |
          ($txt | contains($driver)) or
          (($tok|length)>=3 and ($txt | test("(^|[^a-z0-9])" + ($tok|gsub("[.]";"\\.")) + "([^a-z0-9]|$)")))) as $matched
      | select($matched)
      | {
          namespace:.metadata.namespace,
          name:.metadata.name,
          node:(.spec.nodeName // null),
          phase:(.status.phase // null),
          deleting:(.metadata.deletionTimestamp != null),
          ready:((.status.containerStatuses // []) as $s | (($s|length)>0 and all($s[]; .ready==true))),
          restarts:((.status.containerStatuses // []) | map(.restartCount // 0) | add // 0),
          roles:([
            (.spec.containers[]? | ((.name // "") + " " + (.image // "")) | lc) as $c
            | if ($c|test("csi-(provisioner|attacher|resizer|snapshotter)")) then "controller"
              elif ($c|test("node-driver-registrar")) then "node"
              else empty end
          ] | unique),
          relatedNode:((.spec.nodeName // "") as $n | ($nodes | index($n)) != null),
          matchMode:(if ($txt|contains($d|lc)) then "exact" else "heuristic-token" end)
        }
    ] | unique_by(.namespace,.name)
  ' <<<"${raw}"
}

collect_csi_context() {
  local graph="$1" drivers nodes result='[]' driver di nodeInfos pods node
  drivers=$(drivers_from_graph <<<"$graph")
  nodes=$(jq '[.nodes[]?.name] | map(select(.!=null)) | unique' <<<"$graph")

  while IFS= read -r driver; do
    [[ -n "$driver" ]] || continue
    di=$(csi_driver_info "$driver")
    nodeInfos='[]'
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      local ni
      ni=$(csi_node_driver_info "$driver" "$node")
      nodeInfos=$(jq --argjson x "$ni" '. + (if $x==null then [] else [$x] end)' <<<"$nodeInfos")
    done < <(jq -r '.[]?' <<<"$nodes")
    pods=$(csi_component_pods "$driver" "$nodes")
    result=$(jq -n --argjson acc "$result" --arg driver "$driver" --argjson di "$di" --argjson nodes "$nodeInfos" --argjson pods "$pods" '
      $acc + [{
        driver:$driver,
        driverObject:$di,
        nodeRegistration:$nodes,
        componentPods:$pods,
        discovery:{
          standardObjectsPresent:($di != null),
          componentPodsFound:($pods|length),
          heuristicUsed:($pods|any(.matchMode=="heuristic-token"))
        }
      }]')
  done < <(jq -r '.[]?' <<<"$drivers")

  echo "$result"
}

event_category_filter() {
  cat <<'JQ'
    def category:
      ((.reason // "") + " " + (.message // "")) as $x
      | if ($x|test("FailedAttachVolume|FailedDetachVolume|Multi-Attach|AttachVolume|DetachVolume|NodeUnpublish|NodeUnstage";"i")) then "STORAGE_ATTACH_DETACH"
        elif ($x|test("FailedMount|FailedUnmount|MountVolume|UnmountVolume|device or resource busy";"i")) then "STORAGE_MOUNT_UNMOUNT"
        elif ($x|test("VolumeFailedDelete|ProvisioningFailed|ExternalProvisioning|DeleteVolume";"i")) then "STORAGE_PROVISIONER"
        elif ($x|test("FailedKillPod|FailedPreStopHook|Killing|PreStop";"i")) then "POD_TERMINATION"
        elif ($x|test("FailedCreatePodSandBox|KillPodSandbox|PodSandbox|container runtime|PLEG";"i")) then "CONTAINER_RUNTIME"
        elif ($x|test("NodeNotReady|NodeUnreachable|KubeletNotReady";"i")) then "NODE_UNAVAILABLE"
        elif ($x|test("FailedScheduling";"i")) then "SCHEDULING"
        else "OTHER" end;
JQ
}

collect_events() {
  local graph="$1" namespaces refs events='[]' ns raw filter jqcat
  refs=$(jq '[
      .target,
      (.pods[]? // empty),
      (.pvcs[]? // empty),
      (.pvs[]? // empty),
      (.pvc? // empty),
      (.pv? // empty)
    ]
    | map(select(. != null and .name? != null))
    | map({kind:.kind,name:.name,namespace:(.namespace // null),uid:(.uid // null)})
    | unique_by(.kind,.namespace,.name)' <<<"$graph")
  namespaces=$(jq '[.[]?.namespace] | map(select(.!=null and .!="")) | unique' <<<"$refs")
  jqcat=$(event_category_filter)

  while IFS= read -r ns; do
    [[ -n "$ns" ]] || continue
    raw=$(k_json_default "list events namespace/${ns}" '{"items":[]}' get events -n "$ns")
    filter=$(jq --arg ns "$ns" '[.[]|select(.namespace==$ns)]' <<<"$refs")
    local selected
    selected=$(jq --argjson refs "$filter" --argjson limit "$EVENTS_LIMIT" "
      ${jqcat}
      [ .items[]?
        | . as \$e
        | select(any(\$refs[]?; ((.uid != null and .uid == (\$e.involvedObject.uid // null)) or (.kind == (\$e.involvedObject.kind // \"\") and .name == (\$e.involvedObject.name // \"\")))))
        | {
            namespace:(.metadata.namespace // null),
            involvedKind:(.involvedObject.kind // null),
            involvedName:(.involvedObject.name // null),
            type:(.type // null),reason:(.reason // null),category:category,
            message:((.message // \"\") | if length>500 then .[0:500] + \"...\" else . end),
            count:(.count // 1),
            firstTimestamp:(.firstTimestamp // null),
            lastTimestamp:(.eventTime // .lastTimestamp // .metadata.creationTimestamp // null)
          }
      ] | sort_by(.lastTimestamp // \"\") | reverse | .[0:\$limit]
    " <<<"$raw")
    events=$(jq --argjson x "$selected" '. + $x | unique_by(.namespace,.involvedKind,.involvedName,.reason,.message) | sort_by(.lastTimestamp // "") | reverse | .[0:'"${EVENTS_LIMIT}"']' <<<"$events")
  done < <(jq -r '.[]?' <<<"$namespaces")

  echo "$events"
}

event_root_causes() {
  jq '[.[] | select(.category != "OTHER")]
      | group_by(.category)
      | map({category:.[0].category,eventCount:length,reasons:([.[].reason]|map(select(.!=null))|unique),latest:(map(.lastTimestamp)|max)})
      | sort_by(.eventCount) | reverse'
}

