#!/bin/bash
# ============================================================
# pod-migrate.sh — Kubernetes Pod 平滑迁移工具(生产级)
#
# 用法: ./pod-migrate.sh -d <deployment> -n <node_ip> [选项]
#
# 原理: Cordon 节点 → 设 PodDeletionCost → 扩容 +1 → 等待就绪
#       → 缩容 -1(RS 优先删低 cost 的旧 Pod)→ 恢复 + Uncordon
#
# 特性: 节点 IP 自动发现 Pod / HPA 协调(patch min/max) / 自动 rollback / dry-run
# ============================================================
set -euo pipefail

# ============================================================
# 全局变量(迁移过程中读写,rollback 依赖)
# ============================================================
DEPLOYMENT=""        # 目标 Deployment 名称(必选参数 -d)
POD=""               # 目标 Pod 名称(自动发现或手动指定)
NODE=""              # 目标节点名(从 IP 解析)
NODE_IP=""           # 目标节点 IP(必选参数 -n)
NAMESPACE="default"  # 命名空间
TIMEOUT=300          # 等待 Pod Ready 的超时秒数
DRY_RUN=false        # 试运行模式(只打印不执行)
VERBOSE=false        # 详细日志开关
HEALTH_URL=""        # 迁移后 HTTP 健康探针 URL(可选)
UNCORDON=true        # 迁移完成后是否自动 uncordon
ASSUME_YES=false     # 跳过交互确认(CI/CD 场景)
LABEL_SELECTOR=""    # 从 Deployment spec 反推的 label selector(替代硬编码 app=)
_OLD_PODS=""         # 扩容前 Pod 名快照(用于 wait_ready 精确识别新 Pod)
KUBECTL_TIMEOUT="--request-timeout=10s"  # kubectl API 请求超时(wait 命令豁免)

# 迁移状态标记(rollback 按逆序检查并恢复)
_ST_CORDONED=false   # 是否已 cordon 节点
_ST_ANNOTATED=false  # 是否已设置 PodDeletionCost
_ST_PAUSED=false     # 是否已 pause rollout
_ST_SCALED_UP=false  # 是否已 scale +1(无 HPA 场景)
_ST_HPA_PATCHED=false # 是否已 patch HPA min/max

# 原始值快照(rollback 时恢复)
_ORIG_REPLICAS=""    # Deployment 原始副本数
_HPA_NAME=""         # HPA 名称(空表示无 HPA)
_HPA_MIN=""          # HPA 原始 minReplicas
_HPA_MAX=""          # HPA 原始 maxReplicas(供 scale_up 校验 current+1<=max)

# ============================================================
# 工具函数
# ============================================================

# 带时间戳的彩色日志输出
log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo -e "[$(date '+%H:%M:%S')] \033[32m✓ $*\033[0m"; }
warn() { echo -e "[$(date '+%H:%M:%S')] \033[33m⚠ $*\033[0m"; }
err()  { echo -e "[$(date '+%H:%M:%S')] \033[31m✗ $*\033[0m"; }

# 命令执行封装:dry-run 时只打印,否则实际执行
run() {
  if $DRY_RUN; then
    warn "[DRY-RUN] $*"
  else
    $VERBOSE && log "执行: $*"
    # wait 类命令不加 request-timeout(它有自己的 --timeout)
    if [[ "$*" == *"wait "* ]]; then
      "$@"
    else
      "$@" $KUBECTL_TIMEOUT
    fi
  fi
}

# 打印帮助信息并退出
usage() {
  cat <<EOF
用法: $0 -d <deployment> -n <node_ip> [选项]

必选:
  -d <name>     Deployment 名称
  -n <ip>       Pod 所在节点 IP(自动发现 Pod 与节点名)

可选:
  -N <ns>       Namespace(可选,未指定时自动查找)
  --timeout <s> 等待 Ready 超时秒数(默认 300)
  --dry-run     只打印操作,不实际执行
  --no-uncordon 迁移完成后不 uncordon 节点
  --health <url> 迁移后 HTTP 健康探针(可选)
  --yes         跳过交互确认(CI/CD 用)
  -v            详细日志
  -h            帮助
EOF
  exit 0
}

# ============================================================
# 核心函数:每个函数对应迁移流程的一个步骤
# ============================================================

# 解析命令行参数,填充全局变量
parse_args() {
  local ns_explicit=false   # 标记 -N 是否由用户显式指定
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) DEPLOYMENT="$2"; shift 2;;
      -n) NODE_IP="$2"; shift 2;;
      -N) NAMESPACE="$2"; ns_explicit=true; shift 2;;
      --timeout) TIMEOUT="$2"; shift 2;;
      --dry-run) DRY_RUN=true; shift;;
      --no-uncordon) UNCORDON=false; shift;;
      --yes) ASSUME_YES=true; shift;;
      --health) HEALTH_URL="$2"; shift 2;;
      -v) VERBOSE=true; shift;;
      -h|--help) usage;;
      *) err "未知参数: $1"; usage;;
    esac
  done
  # 校验必选参数
  [[ -z "$DEPLOYMENT" || -z "$NODE_IP" ]] && { err "缺少必选参数 -d/-n"; usage; }
  # 命名空间:未用 -N 指定时,自动从集群中查找 Deployment 所在的 namespace
  if ! $ns_explicit; then
    NAMESPACE=$(kubectl get deployment -A -o jsonpath='{range .items[?(@.metadata.name=="'"$DEPLOYMENT"'")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null)
    if [[ -z "$NAMESPACE" ]]; then
      err "未指定 -N,且集群中未找到 Deployment '$DEPLOYMENT'"; exit 2
    fi
    if [[ $(echo "$NAMESPACE" | wc -l) -gt 1 ]]; then
      err "Deployment '$DEPLOYMENT' 在多个 namespace 中存在:$(echo $NAMESPACE | tr '\n' ' '),请用 -N 指定"; exit 2
    fi
    ok "自动发现 namespace: $NAMESPACE"
  fi
}

# 从节点 IP 自动发现:节点名 + 该节点上目标 Deployment 的 Pod
discover_pod_and_node() {
  log "===== 自动发现(Pod / Node)====="
  # 从 Deployment spec 反推 label selector(替代硬编码 app=$DEPLOYMENT)
  # jq 缺失时(精简镜像)直接兜底 app=,避免 set -e+pipefail 下管道 127 退出使回退成死代码
  if command -v jq &>/dev/null; then
    LABEL_SELECTOR=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" \
      -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
      | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null)
  fi
  # jq 不可用时退回 app= 约定
  [[ -z "$LABEL_SELECTOR" ]] && LABEL_SELECTOR="app=$DEPLOYMENT"
  ok "Label selector: $LABEL_SELECTOR"
  # 节点 IP → 节点名(jsonpath 精确匹配 InternalIP,避免子串误匹配)
  NODE=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null \
    | awk -v ip="$NODE_IP" '$2==ip{print $1}')
  [[ -z "$NODE" ]] && { err "无法从 IP '$NODE_IP' 找到节点"; exit 2; }
  ok "节点 IP $NODE_IP → 节点名 $NODE"
  # 在该节点上找 Deployment 的 Pod(field-selector 精确匹配 + label selector)
  POD=$(kubectl get pods -n "$NAMESPACE" --field-selector spec.nodeName="$NODE" \
    -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "$POD" ]] && { err "在节点 $NODE 上未找到 '$DEPLOYMENT' 的 Pod(label $LABEL_SELECTOR)"; exit 2; }
  # 多副本同节点检测
  local pod_count
  pod_count=$(kubectl get pods -n "$NAMESPACE" --field-selector spec.nodeName="$NODE" \
    -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  [[ "$pod_count" -gt 1 ]] && warn "节点 $NODE 上有 $pod_count 个同 Deployment Pod,本脚本仅处理第一个: $POD"
  ok "发现 Pod: $POD @ $NODE"
}

# 迁移前置检查:Deployment 存在性、滚动更新策略、就绪探针、副本数、HPA
preflight() {
  log "===== Pre-flight 检查 ====="
  # Deployment 存在
  kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null \
    || { err "Deployment '$DEPLOYMENT' 不存在"; exit 2; }
  ok "Deployment 存在,Pod=$POD @ Node=$NODE(IP=$NODE_IP)"
  # 脏状态检测:拒绝在残留状态上运行(上次崩溃可能留下 paused/cordoned)
  local is_paused is_cordoned
  is_paused=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.spec.paused}' 2>/dev/null) || { err "查询 Deployment paused 状态失败(集群不可达?)"; exit 2; }
  is_cordoned=$(kubectl get node "$NODE" $KUBECTL_TIMEOUT -o jsonpath='{.spec.unschedulable}' 2>/dev/null) || { err "查询 Node 状态失败(集群不可达?)"; exit 2; }
  [[ "$is_paused" == "true" ]] && { err "Deployment 已 paused(上次崩溃残留?),拒绝运行"; exit 2; }
  [[ "$is_cordoned" == "true" ]] && { err "节点 $NODE 已 Cordoned(上次残留?),拒绝运行"; exit 2; }
  # 进行中 rollout 检测(updatedReplicas != replicas 说明有未完成的滚动)
  local updated_reps total_reps
  updated_reps=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  total_reps=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  [[ "$updated_reps" != "$total_reps" ]] && { err "Deployment 有进行中的 rollout(updated=$updated_reps/total=$total_reps),请等滚动完成再迁移"; exit 2; }
  # 滚动更新策略检查
  local strategy
  strategy=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" $KUBECTL_TIMEOUT \
    -o jsonpath='{.spec.strategy.type}' 2>/dev/null || echo "")
  [[ "$strategy" != "RollingUpdate" ]] \
    && warn "strategy 非 RollingUpdate(当前: ${strategy:-none}),迁移可能不安全"
  # 就绪探针检查
  local has_probe
  has_probe=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" $KUBECTL_TIMEOUT \
    -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null || echo "")
  [[ -z "$has_probe" ]] \
    && warn "未检测到 ReadinessProbe,新 Pod 可能未就绪就接流量"
  # 记录原始副本数(缩容时恢复)
  _ORIG_REPLICAS=$(kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" $KUBECTL_TIMEOUT \
    -o jsonpath='{.spec.replicas}' || echo "")
  [[ "$_ORIG_REPLICAS" =~ ^[0-9]+$ ]] || { warn "spec.replicas 为空或非数字('$_ORIG_REPLICAS'),按 1 处理"; _ORIG_REPLICAS=1; }
  ok "当前 replicas=$_ORIG_REPLICAS"
  # HPA 检测:按 scaleTargetRef 反查(避免 Deployment 与 HPA 同名假设)
  _HPA_NAME=$(kubectl get hpa -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{range .items[?(@.spec.scaleTargetRef.name=="'"$DEPLOYMENT"'")]}{.metadata.name}{end}' 2>/dev/null || echo "")
  if [[ -n "$_HPA_NAME" ]]; then
    _HPA_MIN=$(kubectl get hpa "$_HPA_NAME" -n "$NAMESPACE" $KUBECTL_TIMEOUT \
      -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "")
    [[ "$_HPA_MIN" =~ ^[0-9]+$ ]] || { err "HPA minReplicas 解析失败:'$_HPA_MIN'"; exit 2; }
    # 记录 maxReplicas(供 scale_up 运行时校验 current+1<=max)
    _HPA_MAX=$(kubectl get hpa "$_HPA_NAME" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "0")
    [[ "$_HPA_MAX" =~ ^[0-9]+$ ]] || { err "HPA maxReplicas 解析失败"; exit 2; }
    ok "检测到 HPA '$_HPA_NAME'(min=${_HPA_MIN}, max=${_HPA_MAX}) — 将用 patch(current+1)调整"
  else
    ok "无 HPA,使用 kubectl scale"
  fi
  # Pod 健康状态检查:必须 Running + Ready(否则 RS 排序时 NotReady 先于 cost)
  local pod_phase pod_ready
  pod_phase=$(kubectl get pod "$POD" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  pod_ready=$(kubectl get pod "$POD" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
  [[ "$pod_phase" == "Running" ]] || { err "目标 Pod 状态=$pod_phase(非 Running),拒绝迁移"; exit 2; }
  [[ "$pod_ready" == "true" ]] || warn "目标 Pod ready=$pod_ready(NotReady 会被 RS 优先删除,cost 可能无效)"
  # Node 健康检查:NotReady 节点上的 Pod 可能已 Unknown
  local node_ready
  node_ready=$(kubectl get node "$NODE" $KUBECTL_TIMEOUT -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$node_ready" == "True" ]] || { err "节点 $NODE NotReady(status=$node_ready),请用 drain 代替"; exit 2; }
  # Finalizer 检查:有 finalizer 的 Pod 删除后会卡 Terminating
  local has_fin
  has_fin=$(kubectl get pod "$POD" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "")
  [[ -n "$has_fin" && "$has_fin" != "" ]] && warn "目标 Pod 有 finalizer($has_fin),删除后可能卡 Terminating"
  # PDB 检查:RS scaling 绕过 PDB,需让用户知情(jq 不可用时静默跳过)
  if command -v jq &>/dev/null; then
    local pdb_match
    # PDB selector 含 deploy 名即视为可能匹配(子串判定,与 Python 版对齐;
    # 原 test($sel) 把 app=foo 当正则匹配 JSON,因 JSON 不含 '=' 字面量而永不命中)
    pdb_match=$(kubectl get pdb -n "$NAMESPACE" -o json 2>/dev/null \
      | jq -r --arg d "$DEPLOYMENT" '.items[] | select((.spec.selector // {})|tostring|contains($d)) | .metadata.name' 2>/dev/null || echo "")
    [[ -n "$pdb_match" ]] && warn "存在匹配的 PDB: $pdb_match(RS scaling 不受 PDB 约束,可能绕过保护)"
  fi
  # 生产确认(非 dry-run 时)
  if ! $DRY_RUN; then
    log "Context: $(kubectl config current-context 2>/dev/null || echo '?'), NS=$NAMESPACE, Deploy=$DEPLOYMENT, Node=$NODE"
    if [[ "$ASSUME_YES" != "true" ]]; then
      if [[ -t 0 ]]; then
        read -p "确认执行迁移?(输入 yes 继续): " confirm
        [[ "$confirm" == "yes" ]] || { warn "用户取消"; exit 0; }
      else
        err "非交互环境,请加 --yes 或用 Python 版"; exit 2
      fi
    fi
  fi
  ok "Pre-flight 通过"
}

# Cordon 目标节点,阻止新 Pod 调度
cordon_node() {
  log "===== Step 1: Cordon $NODE ====="
  run kubectl cordon "$NODE"
  _ST_CORDONED=true
  ok "节点已 Cordon(新 Pod 不会调度到 $NODE)"
}

# 给目标 Pod 设置 PodDeletionCost=-1000,使 RS 缩容时优先删除
set_deletion_cost() {
  log "===== Step 3: 设 PodDeletionCost ====="
  run kubectl annotate pod "$POD" -n "$NAMESPACE" \
    controller.kubernetes.io/pod-deletion-cost="-1000" --overwrite
  _ST_ANNOTATED=true
  ok "PodDeletionCost=-1000(RS 缩容时优先删此 Pod)"
}

# 暂停 Deployment rollout(冻结滚动更新,不影响 scale/patch)
pause_deployment() {
  log "===== Step 4: Pause Deployment ====="
  run kubectl rollout pause deploy "$DEPLOYMENT" -n "$NAMESPACE"
  _ST_PAUSED=true
  ok "Deployment 已 Pause"
}

# 扩容 +1:有 HPA 时 patch min/max+1,无 HPA 时 kubectl scale replicas+1
scale_up() {
  log "===== Step 5: 扩容 +1 ====="
  if [[ -n "$_HPA_NAME" ]]; then
    # HPA 场景:按【当前副本数+1】提高 minReplicas(负载下 current>min 时,min+1 不改 desired,
    # HPA 不扩容、无新 Pod 产生,迁移必失败)。不动 max,避免过度扩容
    [[ "$_HPA_MIN" =~ ^[0-9]+$ ]] || { err "HPA minReplicas 解析失败:'$_HPA_MIN'"; exit 2; }
    local cur
    cur=$(kubectl get hpa "$_HPA_NAME" -n "$NAMESPACE" $KUBECTL_TIMEOUT -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
    [[ "$cur" =~ ^[0-9]+$ ]] || cur="$_HPA_MIN"
    local new_min=$(( cur + 1 ))
    (( new_min > _HPA_MAX )) && { err "HPA current+1(${new_min}) > max(${_HPA_MAX}),无法扩容"; rollback; exit 1; }
    run kubectl patch hpa "$_HPA_NAME" -n "$NAMESPACE" --type merge \
      -p "{\"spec\":{\"minReplicas\":${new_min}}}"
    _ST_HPA_PATCHED=true
    ok "HPA patch: min=${new_min}(current=${cur},HPA 扩容到 ${new_min})"
  else
    # 无 HPA:直接调整 Deployment 副本数
    local new_replicas=$(( _ORIG_REPLICAS + 1 ))
    run kubectl scale deploy "$DEPLOYMENT" -n "$NAMESPACE" --replicas="$new_replicas"
    _ST_SCALED_UP=true
    ok "Scale → ${new_replicas}(新 Pod 在 $NODE 以外的节点启动)"
  fi
}

# 等待新 Pod Ready(先轮询发现新 Pod 名,再精确 wait 该 Pod,避免旧 Pod Ready 干扰)
wait_ready() {
  log "===== Step 6: 等待新 Pod Ready ====="
  if ! $DRY_RUN; then
    # 轮询发现新 Pod(scale_up 后新 Pod 进入 API server 有延迟)
    local new_pod=""
    for i in $(seq 1 30); do
      local current_pods
      current_pods=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      # 找出不在 _OLD_PODS 里的新 Pod
      for p in $current_pods; do
        if ! echo "$_OLD_PODS" | grep -qw "$p"; then
          new_pod="$p"; break
        fi
      done
      [[ -n "$new_pod" ]] && break
      sleep 2
    done
    if [[ -z "$new_pod" ]]; then
      err "60s 内未发现新 Pod(scale_up 可能失败)"; rollback; exit 1
    fi
    ok "发现新 Pod: $new_pod"
    # 精确等待该 Pod Ready(不用 label selector,避免旧 Pod 干扰)
    kubectl wait --for=condition=Ready "pod/$new_pod" -n "$NAMESPACE" \
      --timeout="${TIMEOUT}s" \
      || { err "等待新 Pod $new_pod Ready 超时(${TIMEOUT}s)"; rollback; exit 1; }
  fi
  ok "新 Pod 已 Ready"
}

# 可选:HTTP 健康探针(迁移后确认服务可用)
health_check() {
  [[ -z "$HEALTH_URL" || $DRY_RUN ]] && return
  log "===== 健康探针: $HEALTH_URL ====="
  curl -sf --max-time 10 "$HEALTH_URL" >/dev/null 2>&1 \
    && ok "健康探针通过" \
    || warn "健康探针失败(非致命,继续)"
}

# HPA 状态确认(已通过 patch 管理,仅打印当前 desiredReplicas)
confirm_hpa() {
  log "===== Step 7: HPA 确认 ====="
  if [[ -n "$_HPA_NAME" ]] && ! $DRY_RUN; then
    local desired
    desired=$(kubectl get hpa "$_HPA_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "?")
    ok "HPA desiredReplicas=${desired}(扩容由 HPA 驱动)"
  else
    ok "无 HPA,跳过"
  fi
}

# 缩容 -1:有 HPA 时恢复原 min/max(HPA 自然缩容),无 HPA 时 scale 回原值
scale_down() {
  log "===== Step 8: 缩容(RS 删低 cost Pod)====="
  if [[ -n "$_HPA_NAME" ]]; then
    # HPA 场景:先恢复 min,再强制 scale 缩容
    # (仅 patch min 会受 HPA scaleDownStabilizationWindow 默认 300s 阻挡,
    #  RS 不缩容、目标 Pod 不被删;强制 scale 绕过该窗口,RS 立即按 cost 删 Pod)
    run kubectl patch hpa "$_HPA_NAME" -n "$NAMESPACE" --type merge \
      -p "{\"spec\":{\"minReplicas\":${_HPA_MIN}}}"
    run kubectl scale deploy "$DEPLOYMENT" -n "$NAMESPACE" --replicas="$_ORIG_REPLICAS"
    ok "HPA 恢复 min=${_HPA_MIN} + 强制缩容到 ${_ORIG_REPLICAS}(RS 按 cost 删旧 Pod)"
  else
    # 无 HPA:缩回原始副本数,RS 按 PodDeletionCost 删除目标 Pod
    run kubectl scale deploy "$DEPLOYMENT" -n "$NAMESPACE" --replicas="$_ORIG_REPLICAS"
    ok "Scale 回 $_ORIG_REPLICAS"
  fi
}

# 等待旧 Pod 完全终止(轮询,最长 90s);超时则判失败
wait_pod_terminated() {
  $DRY_RUN && return
  log "等待旧 Pod $POD 终止..."
  local dead=false
  for _ in $(seq 1 45); do
    kubectl get pod "$POD" -n "$NAMESPACE" &>/dev/null || { dead=true; break; }
    sleep 2
  done
  $dead && ok "旧 Pod $POD 已终止" || { err "旧 Pod $POD 90s 未终止(finalizer/preStop 过长),已 rollback,需手动确认 Pod 终止"; rollback; exit 1; }
}

# 收尾:uncordon 节点(独立处理失败,不让清理失败影响迁移结果)
cleanup() {
  log "===== Step 9: Resume + Uncordon 收尾 ====="
  # 先 resume rollout(释放 pause 期间 hold 的 template 变更)
  run kubectl rollout resume deploy "$DEPLOYMENT" -n "$NAMESPACE"
  if $UNCORDON; then
    if ! $DRY_RUN; then
      if kubectl uncordon "$NODE" 2>/dev/null; then
        ok "节点 $NODE 已 Uncordon"
      else
        warn "Uncordon $NODE 失败!请手动执行: kubectl uncordon $NODE"
      fi
    else
      warn "[DRY-RUN] uncordon $NODE"
    fi
  fi
}

# 失败回滚:按操作逆序恢复集群到迁移前状态
rollback() {
  err "===== 开始 Rollback ====="
  # 逆序:最后操作的先恢复
  if $_ST_HPA_PATCHED && [[ -n "$_HPA_MIN" ]]; then
    warn "恢复 HPA min/max..."
    run kubectl patch hpa "$_HPA_NAME" -n "$NAMESPACE" --type merge \
      -p "{\"spec\":{\"minReplicas\":${_HPA_MIN}}}" || true
  fi
  if $_ST_SCALED_UP && [[ -n "$_ORIG_REPLICAS" ]]; then
    warn "Scale 回 $_ORIG_REPLICAS..."
    run kubectl scale deploy "$DEPLOYMENT" -n "$NAMESPACE" \
      --replicas="$_ORIG_REPLICAS" || true
  fi
  if $_ST_PAUSED; then
    warn "Resume rollout..."
    run kubectl rollout resume deploy "$DEPLOYMENT" -n "$NAMESPACE" || true
  fi
  if $_ST_ANNOTATED; then
    warn "删除 PodDeletionCost..."
    run kubectl annotate pod "$POD" -n "$NAMESPACE" \
      controller.kubernetes.io/pod-deletion-cost- || true
  fi
  if $_ST_CORDONED && $UNCORDON; then
    warn "Uncordon $NODE..."
    run kubectl uncordon "$NODE" || true
  fi
  err "Rollback 完成(请人工确认集群状态)"
}

# ============================================================
# 主流程:编排 9 个步骤
# ============================================================
main() {
  parse_args "$@"          # 解析参数
  discover_pod_and_node    # IP → 节点名 + Pod 自动发现
  preflight                # 前置检查

  trap 'rollback; exit 1' ERR
  trap 'rollback; exit 130' INT TERM

  cordon_node              # Step 1: 封节点
  log "Step 2: 目标 Pod $POD @ $NODE"
  set_deletion_cost        # Step 3: 设 PodDeletionCost
  # 快照当前 Pod 列表(供 wait_ready 精确识别扩容后的新 Pod)
  _OLD_PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  pause_deployment         # Step 4: 暂停 rollout(防 CI/CD 干扰)
  scale_up                 # Step 5: 扩容 +1(HPA-aware)
  wait_ready               # Step 6: 等待就绪(精确等新 Pod,不受旧 Pod Ready 干扰)
  health_check             # 可选:健康探针
  confirm_hpa              # Step 7: HPA 状态确认
  scale_down               # Step 8: 缩容 -1(HPA-aware)
  wait_pod_terminated      # 等待旧 Pod 终止
  cleanup                  # Step 9: Resume + Uncordon

  echo ""
  ok "=========================================="
  ok "  Pod 迁移完成!"
  ok "  Deployment: $DEPLOYMENT (ns=$NAMESPACE)"
  ok "  原 Pod:     $POD @ $NODE (已迁出)"
  ok "  新 Pod:     在其它节点运行"
  ok "  Replicas:   $_ORIG_REPLICAS(不变)"
  ok "=========================================="
}

main "$@"
