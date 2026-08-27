# Kubernetes Pod 平滑迁移工具

本项目提供两套 Kubernetes Pod 平滑迁移工具：

- `pod-migrate.sh`：Shell 版本，适合人工运维、单次迁移和直接在运维节点执行。
- `pod_migrate.py`：Python 版本，适合 CI/CD、批量迁移以及更结构化的异常处理。

两套工具的目标不是直接 `kubectl delete pod` 或执行整节点 `drain`，而是在尽量保持 Deployment 原有副本数和业务可用性的前提下，将指定节点上的某个 Deployment Pod 平滑迁移到其他可调度节点。

---

## 1. 核心设计思想

迁移核心链路如下：

```text
目标 Deployment + 节点 IP
        |
        v
自动发现 Namespace / Node / Pod
        |
        v
Pre-flight 安全检查
        |
        v
Cordon 目标节点
        |
        v
给旧 Pod 设置 PodDeletionCost=-1000
        |
        v
Pause Deployment Rollout
        |
        v
扩容 +1
   |             |
无 HPA         有 HPA
   |             |
kubectl scale   patch HPA minReplicas=current+1
   |             |
   +-------> 创建新 Pod
                |
                v
        等待新 Pod Ready
                |
                v
        可选 HTTP 健康检查
                |
                v
            缩容 -1
   |                             |
无 HPA                       有 HPA
   |                             |
scale 回原副本数     恢复 HPA min + 强制 scale
   |                             |
   +-------------+---------------+
                 |
                 v
ReplicaSet 按 PodDeletionCost
优先删除 cost=-1000 的旧 Pod
                 |
                 v
等待旧 Pod 完全终止
                 |
                 v
Resume Deployment
                 |
                 v
Uncordon 节点
```

其关键点是：

1. **先 Cordon 节点**，确保新增 Pod 不会再次调度回原节点。
2. **使用 `controller.kubernetes.io/pod-deletion-cost=-1000`** 标记待迁移 Pod，使 ReplicaSet 在缩容时优先删除该 Pod。
3. **迁移前先扩容一个副本**，等待新 Pod Ready 后再缩回原副本数，降低业务容量瞬时下降的风险。
4. **Pause Deployment rollout**，避免迁移过程中 Deployment template 被 CI/CD 更新而触发新的滚动发布。
5. **兼容 HPA**：不能简单固定 Deployment replicas，而是临时提高 HPA `minReplicas` 促进扩容，再恢复原始值。
6. **任何主流程异常均尝试 Rollback**，按逆序恢复 HPA、replicas、rollout、PodDeletionCost 和节点调度状态。

---

## 2. 业务架构

### 2.1 逻辑组件

```text
+-----------------------------+
|       Operator / CI/CD      |
+--------------+--------------+
               |
               v
+-----------------------------+
| pod-migrate.sh / pod_migrate.py |
+-----------------------------+
| 参数解析                    |
| Namespace 自动发现          |
| Node IP -> Node Name        |
| Deployment -> LabelSelector |
| Pod 自动发现                |
| Pre-flight                  |
| Migration Orchestrator      |
| Rollback                    |
+--------------+--------------+
               |
               | kubectl
               v
+---------------------------------------------------+
|               Kubernetes API Server              |
+-----------+-------------+-----------+-------------+
            |             |           |
            v             v           v
      +-----------+ +-----------+ +-----------+
      |Deployment | |    HPA    | |   Node    |
      +-----+-----+ +-----+-----+ +-----+-----+
            |             |             |
            v             |             |
      +-----------+       |             |
      |ReplicaSet |<------+             |
      +-----+-----+                     |
            |                           |
            v                           v
      +-----------+              +-------------+
      | Old Pod   |              | Scheduler   |
      | cost=-1000|              +------+------+ 
      +-----------+                     |
                                        v
                                  +-----------+
                                  | New Pod   |
                                  | Other Node|
                                  +-----------+
```

### 2.2 调度拓扑变化

迁移前：

```text
Node-A
  └── app-xxxx-old    <- 目标 Pod

Node-B
  └── app-yyyy

Deployment replicas = N
```

执行 Cordon 和扩容后：

```text
Node-A [SchedulingDisabled]
  └── app-xxxx-old    cost=-1000

Node-B
  └── app-yyyy

Node-C
  └── app-zzzz-new    <- 新扩出的 Pod

Deployment replicas = N + 1
```

缩容后：

```text
Node-A [SchedulingDisabled]
  └── 目标 Pod 被 ReplicaSet 优先删除

Node-B
  └── app-yyyy

Node-C
  └── app-zzzz-new

Deployment replicas = N
```

最终：

```text
Node-A [Schedulable]
Node-B
  └── app-yyyy
Node-C
  └── app-zzzz-new

Deployment replicas = 原始值 N
```

---

## 3. 完整执行流程

### Step 0：参数解析与资源自动发现

工具根据 Deployment 名称和节点 InternalIP 完成以下解析：

```text
Deployment Name
    |
    +--> Namespace
    |
    +--> Deployment spec.selector.matchLabels
                      |
                      v
                 Label Selector

Node InternalIP
    |
    v
Node Name
    |
    v
spec.nodeName=<node> + label selector
    |
    v
目标 Pod
```

如果未显式指定 Namespace：

- 单 Pod 模式会跨 Namespace 搜索指定 Deployment。
- 如果 Deployment 不存在则退出。
- 如果同名 Deployment 存在于多个 Namespace，则要求使用 `-N` 明确指定。

Shell 版依赖 `jq` 时会从 `matchLabels` 生成 selector；如果 `jq` 不存在，则回退到：

```text
app=<deployment>
```

Python 版直接读取 Deployment JSON 并解析 `spec.selector.matchLabels`。

---

## 4. Pre-flight 安全检查

正式修改集群前，工具会检查关键运行状态。

主要检查项包括：

| 检查项 | 目的 |
|---|---|
| Deployment 是否存在 | 防止操作错误对象 |
| Pod 是否位于目标节点 | 防止节点与 Pod 不匹配 |
| Node Ready | NotReady 节点建议使用 drain 等方式处理 |
| Pod Phase=Running | 非 Running Pod 不适合该迁移流程 |
| Pod Ready 状态 | NotReady Pod 可能在 RS 缩容排序中被提前删除 |
| Deployment 是否 paused | 防止继承上一次异常残留状态 |
| Node 是否已 cordoned | 防止覆盖已有运维状态 |
| Deployment 是否正在 rollout | 避免迁移和发布同时发生 |
| Deployment strategy | 非 RollingUpdate 时提示风险 |
| ReadinessProbe | 无探针时新 Pod Ready 的业务可信度降低 |
| Deployment 原副本数 | 用于迁移后恢复 |
| HPA min/max | 用于 HPA 模式扩缩容和回滚 |
| Pod Finalizer | Finalizer 可能导致旧 Pod 长时间 Terminating |
| PDB | 提醒 ReplicaSet scaling 不受 PDB 驱逐保护约束 |

Shell 版在非 `--dry-run` 模式下还会进行人工确认；非交互环境需要使用 `--yes`。

---

## 5. 九步迁移状态机

### Step 1：Cordon 目标节点

```bash
kubectl cordon <node>
```

作用：禁止新的 Pod 被 Scheduler 调度到目标节点。

注意：

- 已经运行在该节点上的 Pod 不会因为 cordon 被自动驱逐。
- 本工具只迁移当前指定 Deployment 的一个目标 Pod。

### Step 2：确认目标 Pod

记录当前迁移对象：

```text
Pod -> Node -> Deployment
```

### Step 3：设置 PodDeletionCost

```bash
kubectl annotate pod <pod> \
  -n <namespace> \
  controller.kubernetes.io/pod-deletion-cost=-1000 \
  --overwrite
```

作用：在 ReplicaSet 缩容时提高该 Pod 被优先删除的概率。

### Step 4：Pause Deployment

```bash
kubectl rollout pause deployment/<deployment> -n <namespace>
```

作用：冻结 Deployment rollout，减少迁移期间 CI/CD 或模板更新造成的并发干扰。

Pause 不会阻止 `scale` 操作。

### Step 5：扩容 +1

#### 无 HPA

```text
original replicas = N
new replicas      = N + 1
```

执行：

```bash
kubectl scale deployment/<deployment> \
  -n <namespace> \
  --replicas=N+1
```

#### 有 HPA

工具读取：

```text
HPA.status.currentReplicas
HPA.spec.minReplicas
HPA.spec.maxReplicas
```

然后计算：

```text
newMin = currentReplicas + 1
```

再 patch：

```text
spec.minReplicas = newMin
```

使用 `currentReplicas + 1` 而不是简单 `minReplicas + 1`，是为了避免当前负载已经使 replicas 高于 minReplicas 时，修改 minReplicas 却不能真正触发新的扩容。

如果：

```text
currentReplicas + 1 > maxReplicas
```

则停止迁移。

### Step 6：等待新 Pod Ready

工具在扩容前保存当前 Pod 列表：

```text
OLD_PODS = {pod-a, pod-b, pod-c}
```

扩容后循环查询：

```text
CURRENT_PODS - OLD_PODS = NEW_POD
```

找到新 Pod 后执行精确等待：

```bash
kubectl wait \
  --for=condition=Ready \
  pod/<new-pod> \
  -n <namespace> \
  --timeout=<timeout>s
```

这样可以避免使用 Deployment label selector 等待时，被原本已经 Ready 的旧 Pod 干扰判断。

### 可选：HTTP 健康检查

如果指定：

```bash
--health https://service.example.com/health
```

新 Pod Ready 后执行 HTTP 检查。

健康检查失败只记录 Warning，不直接判定整个迁移失败。

### Step 7：HPA 状态确认

有 HPA 时读取：

```text
.status.desiredReplicas
```

用于输出当前 HPA 状态。

### Step 8：缩容恢复原副本数

#### 无 HPA

```bash
kubectl scale deployment/<deployment> \
  -n <namespace> \
  --replicas=<original>
```

ReplicaSet 进入缩容，优先选择 `PodDeletionCost=-1000` 的目标旧 Pod。

#### 有 HPA

先恢复原 HPA `minReplicas`，再直接将 Deployment scale 回原副本数。

原因是只恢复 HPA minReplicas 时，HPA 的 scale-down stabilization window 可能导致副本在一段时间内不立即减少，因此代码通过直接 scale 触发 ReplicaSet 立即缩容。

### 等待旧 Pod 终止

工具最长等待约 90 秒。

如果目标 Pod 因 Finalizer、preStop 或其他原因长时间处于 Terminating，则判定迁移失败并进入 rollback。

### Step 9：Resume + Uncordon

恢复 Deployment：

```bash
kubectl rollout resume deployment/<deployment> -n <namespace>
```

默认恢复节点调度：

```bash
kubectl uncordon <node>
```

如果指定：

```bash
--no-uncordon
```

则节点保持 `SchedulingDisabled`，由运维人员后续手工处理。

---

## 6. Rollback 机制

迁移过程中发生异常、中断或者关键等待超时后，工具按操作逆序尝试恢复。

```text
迁移操作顺序：
Cordon
  -> Annotation
  -> Pause
  -> Scale/HPA Patch

Rollback：
HPA Restore
  -> Scale Restore
  -> Resume Deployment
  -> Remove PodDeletionCost
  -> Uncordon Node
```

主要恢复内容：

1. 恢复 HPA 原始 `minReplicas`。
2. 无 HPA 场景恢复 Deployment 原始 replicas。
3. Resume Deployment rollout。
4. 删除目标 Pod 的 PodDeletionCost annotation。
5. 如果允许自动恢复，则 Uncordon 节点。

Python 版每个 rollback 子步骤单独捕获异常，一个恢复动作失败不会阻塞其他恢复动作，并会汇总未恢复成功的步骤。

> Rollback 完成后仍建议人工检查 Deployment、HPA、Node 和 Pod 的最终状态。

---

## 7. Shell 版参数

基本格式：

```bash
./pod-migrate.sh -d <deployment> -n <node_ip> [选项]
```

| 参数 | 必选 | 默认值 | 含义 |
|---|---:|---|---|
| `-d <name>` | 是 | - | Deployment 名称 |
| `-n <ip>` | 是 | - | 目标 Pod 所在节点 InternalIP |
| `-N <namespace>` | 否 | 自动发现 | Namespace |
| `--timeout <s>` | 否 | `300` | 等待新 Pod Ready 的超时时间 |
| `--dry-run` | 否 | `false` | 只输出写操作，不实际修改资源 |
| `--no-uncordon` | 否 | 自动 uncordon | 迁移完成后保持节点 cordon |
| `--health <url>` | 否 | 空 | 新 Pod Ready 后执行 HTTP 健康检查 |
| `--yes` | 否 | `false` | 跳过 Shell 版人工确认，适合 CI/CD |
| `-v` | 否 | `false` | 输出详细执行日志 |
| `-h / --help` | 否 | - | 查看帮助 |

Shell 版内部 kubectl 普通 API 请求使用：

```text
--request-timeout=10s
```

`kubectl wait` 使用独立的 `--timeout` 参数。

---

## 8. Python 版参数

基本格式：

```bash
python3 pod_migrate.py -d <deployment> -n <node_ip> [选项]
```

| 参数 | 必选 | 默认值 | 含义 |
|---|---:|---|---|
| `-d, --deployment` | 单 Pod 模式必选 | - | Deployment 名称 |
| `-n, --node-ip` | 单 Pod 模式必选 | - | Pod 所在节点 InternalIP |
| `--pod` | 否 | 自动发现 | 直接指定 Pod 名 |
| `-N, --namespace` | 否 | 自动发现 | Namespace |
| `--timeout` | 否 | `300` | 等待新 Pod Ready 的超时时间 |
| `--dry-run` | 否 | `false` | 写操作只打印，不执行；读操作继续执行 |
| `--no-uncordon` | 否 | `false` | 迁移结束后不恢复节点调度 |
| `--health` | 否 | 空 | HTTP 健康探针 URL |
| `--batch` | 否 | - | 批量迁移文件 |
| `--yes` | 否 | `false` | 当前代码解析该参数，但 Python 主流程没有交互确认逻辑 |
| `-v, --verbose` | 否 | `false` | DEBUG 日志 |

Python 版退出码：

| 退出码 | 含义 |
|---:|---|
| `0` | 迁移成功 |
| `1` | 迁移失败，已执行 rollback |
| `2` | Pre-flight 或资源发现失败 |
| `130` | 顶层收到 Ctrl+C |

---

## 9. 环境依赖

执行端至少需要：

```text
kubectl
KUBECONFIG / ServiceAccount 权限
网络可访问 Kubernetes API Server
```

Shell 版建议同时安装：

```text
bash
jq
curl
awk
```

其中：

- `jq` 用于解析 Deployment `matchLabels`；没有 `jq` 时会回退 `app=<deployment>`。
- `curl` 用于 Shell 版 `--health` HTTP 探针。

Python 版要求：

```text
Python 3
```

不依赖 Kubernetes Python SDK，所有 Kubernetes 操作仍通过 `kubectl` 完成。

---

## 10. Kubernetes RBAC 权限

运行账号至少需要针对相关 Namespace / Node 具备以下操作权限：

```text
get/list Pods
get/list Deployments
patch Deployments
update Deployment scale
get/list HPAs
patch HPAs
get/list PDBs
get/patch Nodes
patch Pods
```

建议执行前验证：

```bash
kubectl auth can-i get deployments -n <namespace>
kubectl auth can-i patch deployments -n <namespace>
kubectl auth can-i update deployments/scale -n <namespace>
kubectl auth can-i patch pods -n <namespace>
kubectl auth can-i get hpa -n <namespace>
kubectl auth can-i patch hpa -n <namespace>
kubectl auth can-i patch nodes
```

---

## 11. Shell 版使用步骤

### 11.1 查看帮助

```bash
chmod +x pod-migrate.sh
./pod-migrate.sh --help
```

### 11.2 先执行 Dry-run

```bash
./pod-migrate.sh \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --dry-run
```

建议生产环境始终先执行 dry-run，确认：

```text
Deployment
Namespace
Node
Pod
Label Selector
HPA
Replicas
```

均符合预期。

### 11.3 正式执行

```bash
./pod-migrate.sh \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx
```

工具会要求输入：

```text
yes
```

确认后继续。

### 11.4 CI/CD 非交互执行

```bash
./pod-migrate.sh \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --yes
```

### 11.5 设置 Ready 超时时间

```bash
./pod-migrate.sh \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --timeout 600
```

### 11.6 增加业务健康检查

```bash
./pod-migrate.sh \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --health https://api.example.com/actuator/health
```

### 11.7 迁移完成后保持节点 Cordoned

适合节点维护、内核升级、重启等后续操作：

```bash
./pod-migrate.sh \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --no-uncordon
```

维护完成后手工恢复：

```bash
kubectl uncordon <node-name>
```

---

## 12. Python 版使用步骤

### 12.1 查看帮助

```bash
python3 pod_migrate.py --help
```

### 12.2 单 Deployment Dry-run

```bash
python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --dry-run
```

### 12.3 单 Deployment 正式迁移

```bash
python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx
```

### 12.4 Namespace 自动发现

```bash
python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21
```

前提是集群内该 Deployment 名称唯一。

### 12.5 直接指定 Pod

```bash
python3 pod_migrate.py \
  -d dev-xxx-app \
  --pod dev-xxx-app-7db6f7ddbf-x9abc \
  -n 10.10.10.21 \
  -N dev-xxx
```

该模式省去目标 Pod 的自动选择，但仍会通过节点 IP 解析 Node，并在 preflight 阶段验证 Pod 实际所在节点。

### 12.6 HTTP 健康检查

```bash
python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --health https://api.example.com/actuator/health
```

### 12.7 保持节点 Cordoned

```bash
python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --no-uncordon
```

---

## 13. Python 批量迁移

Python 版支持：

```bash
python3 pod_migrate.py --batch pods.txt
```

批量文件格式：

```text
# deploy,node_ip,namespace
app-api,10.10.10.21,dev-xxx
app-service,10.10.10.22,dev-xxx
app-worker,10.10.10.23,pro-worker
```

第三列 Namespace 可省略：

```text
app-api,10.10.10.21
app-service,10.10.10.22
```

如果没有第三列，则使用全局 `-N`；如果全局也没有指定，则使用 `default`。

执行示例：

```bash
python3 pod_migrate.py \
  --batch pods.txt \
  --timeout 600
```

带统一默认 Namespace：

```bash
python3 pod_migrate.py \
  --batch pods.txt \
  -N dev-xxx
```

批量模式特征：

- 按文件顺序逐个迁移。
- 单个迁移失败不会立即中止整个批次。
- 每个对象独立执行 Pre-flight、迁移和 Rollback。
- 每个迁移对象之间默认间隔 5 秒。
- 最终输出成功数量，例如：

```text
批量完成: 9/10 成功
```

如果不是全部成功，程序返回退出码 `1`。

---

## 14. HPA 场景说明

HPA 是该工具区别于普通 `kubectl scale` 脚本的重要部分。

假设：

```text
HPA minReplicas = 3
HPA maxReplicas = 10
currentReplicas = 6
```

如果仅执行：

```text
minReplicas: 3 -> 4
```

因为当前已经有 6 个副本，HPA 不需要扩容，因此无法产生迁移所需的新 Pod。

本工具使用：

```text
newMin = currentReplicas + 1
       = 7
```

促使 HPA 至少维持 7 个副本。

待新 Pod Ready 后：

```text
minReplicas -> 原值 3
Deployment scale -> 原始副本数
```

从而触发 ReplicaSet 缩容，并利用 PodDeletionCost 删除目标旧 Pod。

---

## 15. Dry-run 行为

### Shell

Shell 版 `run()` 封装的写操作仅打印，不执行。

但为了完成资源发现和 Pre-flight，仍需要执行部分只读 kubectl 查询。

### Python

Python 版区分读写操作。

Dry-run 时跳过的写操作包括：

```text
cordon
uncordon
annotate
scale
patch
rollout
delete
apply
label
taint
drain
```

而以下读取仍正常执行：

```text
kubectl get ...
kubectl jsonpath ...
```

因此 Python 版 dry-run 仍然可以真实验证 Deployment、Node、Pod、HPA 等对象。

---

## 16. Shell 与 Python 版本能力对比

| 能力 | Shell | Python |
|---|---:|---:|
| 单 Deployment 迁移 | ✅ | ✅ |
| Namespace 自动发现 | ✅ | ✅ |
| Node IP 自动解析 | ✅ | ✅ |
| Pod 自动发现 | ✅ | ✅ |
| 指定 Pod 名 | ❌ | ✅ `--pod` |
| PodDeletionCost | ✅ | ✅ |
| HPA 兼容 | ✅ | ✅ |
| Pause/Resume rollout | ✅ | ✅ |
| Dry-run | ✅ | ✅ |
| HTTP 健康检查 | ✅ | ✅ |
| 自动 rollback | ✅ | ✅ |
| 批量迁移 | ❌ | ✅ |
| 标准退出码 | 部分依赖 shell exit | ✅ |
| 人工确认 | ✅ | 当前主流程无交互确认 |
| CI/CD 集成 | 可用 | 更适合 |
| 结构化异常处理 | Bash trap | Python try/except |

推荐：

```text
人工临时运维 / 单应用迁移
        -> pod-migrate.sh

Jenkins / GitLab CI / 自动化平台
        -> pod_migrate.py

多应用、跨节点批量迁移
        -> pod_migrate.py --batch
```

---

## 17. 生产使用建议

### 17.1 先确认节点容量

工具会把新 Pod 调度到其他节点，因此应先检查：

```bash
kubectl top nodes
kubectl get nodes
kubectl describe node <target-other-node>
```

至少需要确认：

```text
CPU
Memory
Pod 数量
Taints/Tolerations
NodeAffinity
TopologySpreadConstraints
PVC topology
GPU / Local PV 等特殊资源
```

否则 Cordon 后新增 Pod 可能长时间 Pending。

### 17.2 建议配置 ReadinessProbe

工具等待的是 Kubernetes Ready 条件，因此 Deployment 最好配置真实有效的 readinessProbe。

如果应用没有 ReadinessProbe，即使容器启动，也不能充分代表业务已经可以安全接收流量。

### 17.3 注意 PDB 的保护边界

该工具通过 Deployment/ReplicaSet 扩缩容完成迁移，而不是 eviction API。

因此 PDB 并不能像 `kubectl drain` 那样完整保护本次缩容过程。

迁移关键应用前应确认：

```bash
kubectl get pdb -n <namespace>
kubectl get deploy <deployment> -n <namespace>
```

并结合业务最小可用副本评估风险。

### 17.4 单副本应用风险更高

虽然流程会先扩容 +1 并等待 Ready，再删除旧 Pod，但单副本业务仍建议确认：

```text
ReadinessProbe 正确
新节点资源充足
镜像可以正常拉取
Secret / ConfigMap 正常
PVC 可跨节点挂载
应用允许多副本短暂并存
```

### 17.5 StatefulSet 不适用

当前两个工具均围绕 Deployment / ReplicaSet 设计。

不建议直接用于：

```text
StatefulSet
DaemonSet
裸 Pod
Job / CronJob
```

StatefulSet 应使用独立迁移流程处理 Pod identity、PVC、拓扑和有序更新问题。

### 17.6 Local PV / 本地状态应用需谨慎

即使 Pod 能被创建，带有本地存储、Local PV、hostPath、固定 nodeAffinity 或特定硬件资源的应用，也可能无法迁移到其他节点。

---

## 18. 迁移前推荐检查命令

```bash
# Deployment
kubectl get deploy <deployment> -n <namespace> -o wide

# Deployment rollout
kubectl rollout status deploy/<deployment> -n <namespace>

# Pod 分布
kubectl get pod -n <namespace> -l <selector> -o wide

# HPA
kubectl get hpa -n <namespace>

# PDB
kubectl get pdb -n <namespace>

# 节点
kubectl get node -o wide

# 资源
kubectl top node
kubectl top pod -n <namespace>
```

---

## 19. 迁移后检查

迁移成功后建议执行：

```bash
kubectl get pod -n <namespace> -l <selector> -o wide
kubectl get deploy <deployment> -n <namespace>
kubectl rollout status deploy/<deployment> -n <namespace>
kubectl get hpa -n <namespace>
kubectl get node <node-name>
```

期望状态：

```text
旧 Pod 已不存在
新 Pod 位于其他节点
Deployment replicas 与迁移前一致
Deployment 已 resume
HPA minReplicas 已恢复
Node 已 uncordon（除非使用 --no-uncordon）
```

---

## 20. 异常后的人工恢复

如果工具提示 rollback 部分失败，应依次检查。

### Node

```bash
kubectl get node <node>
kubectl uncordon <node>
```

### Deployment Pause

```bash
kubectl get deploy <deployment> -n <namespace> \
  -o jsonpath='{.spec.paused}'

kubectl rollout resume deploy/<deployment> -n <namespace>
```

### Deployment replicas

```bash
kubectl get deploy <deployment> -n <namespace> \
  -o jsonpath='{.spec.replicas}'
```

必要时：

```bash
kubectl scale deploy/<deployment> \
  -n <namespace> \
  --replicas=<original>
```

### HPA

```bash
kubectl get hpa <hpa-name> -n <namespace> -o yaml
```

检查：

```text
spec.minReplicas
spec.maxReplicas
status.currentReplicas
status.desiredReplicas
```

### PodDeletionCost

```bash
kubectl get pod <pod> -n <namespace> -o yaml | \
  grep pod-deletion-cost
```

删除：

```bash
kubectl annotate pod <pod> -n <namespace> \
  controller.kubernetes.io/pod-deletion-cost-
```

---

## 21. 当前代码边界

基于当前两个脚本的实现，需要明确以下边界：

1. Shell 版同一节点发现多个同 Deployment Pod 时，只迁移查询结果中的第一个 Pod。
2. Python 自动发现模式同样只选择第一个匹配 Pod；如需精确指定可使用 `--pod`。
3. 两版均只处理 Deployment，不是通用 Kubernetes workload migrator。
4. 健康 URL 检查失败目前只是 Warning，不会触发 rollback。
5. PDB 检查属于风险提示，不会阻止执行。
6. Python 版定义了 `retry()` 指数退避函数，但当前主迁移链路没有调用该函数。
7. Python CLI 已声明 `--yes` 参数，但当前 Python 版本没有人工确认步骤，因此该参数不会改变迁移行为。
8. 两版都依赖当前 kubectl context；执行前必须确认连接的是正确集群。

---

## 22. 推荐标准操作流程

生产环境建议采用以下 SOP：

```text
1. 确认 kubectl context
        |
2. 检查 Node / Deployment / HPA / PDB
        |
3. 检查其他节点可调度容量
        |
4. 执行 --dry-run
        |
5. 人工确认目标 Deployment / Pod / Node
        |
6. 正式执行迁移
        |
7. 等待迁移成功
        |
8. 检查新 Pod 节点分布
        |
9. 检查 replicas / HPA / rollout
        |
10. 确认 Node 是否需要继续保持 cordon
```

推荐命令：

```bash
kubectl config current-context

python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --dry-run

python3 pod_migrate.py \
  -d dev-xxx-app \
  -n 10.10.10.21 \
  -N dev-xxx \
  --timeout 600 \
  --health https://api.example.com/actuator/health
```

---

## 23. 总结

该工具本质上是一套基于 Deployment / ReplicaSet 调度行为实现的 **“先增后减” Pod 平滑迁移机制**：

```text
Cordon
  +
PodDeletionCost
  +
Pause Rollout
  +
Scale/HPA +1
  +
Wait Ready
  +
Scale -1
  +
Rollback Protection
```

相比直接删除 Pod，它能够先建立替代副本并确认 Ready；相比整节点 drain，它可以只迁移指定 Deployment 的单个 Pod，操作范围更小。

Shell 版更适合人工运维场景，Python 版则在批量执行、退出码、异常隔离和 CI/CD 集成方面更完整。
