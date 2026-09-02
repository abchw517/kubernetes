# resource-terminating-diagnose

Kubernetes `Pod / PVC / PV / VolumeAttachment` 长时间 `Terminating` 专项只读诊断、Break-Glass 前置检查与持续巡检工具。

当前版本：**v1.1.0**。

> 核心原则：**先建立删除依赖链，再定位真正阻塞 Controller / Node / CSI / Storage，最后才进入人工 Break-Glass 复核。**
>
> 本工具严格只读，不执行 `delete`、`patch`、`replace`、`apply`、`create`、Finalizer 删除、VolumeAttachment 删除、Node fencing 或 Storage Backend force-detach。

---

## 1. 先说明：本项目是否覆盖 Namespace Terminating？

### 1.1 结论

**不直接覆盖。**

`resource-terminating-diagnose` 当前 CLI 只支持：

```text
pod
pvc
pv
volumeattachment
```

不存在：

```bash
resource-terminating-diagnose.sh diagnose namespace <name>
```

代码中也没有执行：

```text
kubectl delete namespace
kubectl patch namespace
PUT /api/v1/namespaces/<namespace>/finalize
Namespace Controller 强制清理
```

因此，如果问题是：

```text
kubectl delete namespace <ns>
        ↓
Namespace 一直 Terminating
```

应先使用仓库中的独立项目：

```text
../namespace-terminating-diagnose/
```

### 1.2 Namespace 基础诊断命令

轻量检查：

```bash
cd ../namespace-terminating-diagnose

./namespace-terminating-diagnose.sh \
  check \
  -n pro-yunfan
```

完整诊断：

```bash
./namespace-terminating-diagnose.sh \
  diagnose \
  -n pro-yunfan
```

Break-Glass 前置检查：

```bash
./namespace-terminating-diagnose.sh \
  force-check \
  -n pro-yunfan \
  --threshold 900
```

集群 Namespace Terminating 巡检：

```bash
./namespace-terminating-patrol.sh \
  --json
```

### 1.3 两个项目的职责边界

| 能力 | namespace-terminating-diagnose | resource-terminating-diagnose |
|---|---:|---:|
| Namespace phase / deletionTimestamp | ✅ | ❌ |
| Namespace Conditions | ✅ | ❌ |
| API Discovery / APIService | ✅ | ❌ |
| 全量 Namespaced Resource 枚举 | ✅ | ❌ |
| CRD / Custom Resource 残留 | ✅ | ❌ |
| Admission Webhook / VAP 风险 | ✅ | ❌ |
| Namespace Finalizer Gate | ✅ | ❌ |
| Pod Terminating 深度诊断 | 基础关联 | ✅ |
| PVC / PV 依赖链 | 基础关联 | ✅ |
| VolumeAttachment 深度状态 | 基础关联 | ✅ |
| Node Ready 关联 | 部分 | ✅ |
| CSIDriver / CSINode | 部分 | ✅ |
| CSI Controller / Node Plugin Pod 关联 | ❌ | ✅ |
| Kubernetes Events 根因分类 | ❌ | ✅ |
| Resource Break-Glass Gate | ❌ | ✅ |
| Resource Collector / Prometheus | ❌ | ✅ |

### 1.4 推荐组合方式

```text
Namespace Terminating
        │
        ▼
namespace-terminating-diagnose
        │
        ├── APIService / Discovery
        ├── Remaining Resources
        ├── CR / Finalizer
        ├── Webhook / VAP
        └── PVC / PV / VolumeAttachment 线索
                     │
                     ▼
          resource-terminating-diagnose
                     │
                     ├── Pod
                     ├── PVC
                     ├── PV
                     ├── VolumeAttachment
                     ├── Node
                     ├── CSI
                     └── Events
```

即：

```text
Namespace 工具负责“为什么整个 Namespace 删不掉”
Resource 工具负责“具体 Pod/PVC/PV/VA 为什么删不掉”
```

---

## 2. 项目解决什么问题

本工具主要解决以下生产场景：

```text
kubectl delete pod ...
Pod 长时间 Terminating

kubectl delete pvc ...
PVC 长时间 Terminating

kubectl delete pv ...
PV 长时间 Terminating

VolumeAttachment 已 deletionTimestamp
但长时间 attached=true
```

传统排查往往停留在：

```bash
kubectl get pod
kubectl describe pod
kubectl get pvc
kubectl get pv
```

但真正的删除链可能跨越：

```text
Pod
 ↓
PVC
 ↓
PV
 ↓
VolumeAttachment
 ↓
Node
 ↓
CSINode / CSIDriver
 ↓
CSI Controller / Node Plugin
 ↓
Storage Backend
```

本项目的核心价值就是把这些对象自动关联成一张诊断图。

---

## 3. 业务实现总览

主执行链：

```text
CLI 参数
  │
  ▼
parse_args()
  │
  ▼
setup_runtime()
  │
  ├── 检查 kubectl
  ├── 检查 jq
  └── 建立 query error 临时文件
  │
  ▼
┌─────────────────────────────────────┐
│ command                             │
├─────────────────────────────────────┤
│ diagnose                            │
│ force-check                         │
│ scan                                │
│ collector                           │
└─────────────────────────────────────┘
```

### diagnose

```text
Target Resource
     │
     ▼
diagnose_target()
     │
     ├── diagnose_pod()
     ├── diagnose_pvc()
     ├── diagnose_pv()
     └── diagnose_va()
     │
     ▼
建立 Resource Graph
     │
     ▼
enrich_graph()
     │
     ├── collect_csi_context()
     ├── collect_events()
     ├── event_root_causes()
     └── diagnostics.complete
     │
     ▼
risk_from_graph()
     │
     ▼
SAFE / WARNING / DANGEROUS
```

### force-check

```text
diagnose
   │
   ▼
完整 Resource Graph
   │
   ▼
force_check_graph()
   │
   ├── deletion age
   ├── API 查询完整性
   ├── Live Pod 引用
   ├── VolumeAttachment attached
   ├── Node Ready
   ├── CSI Health
   ├── StatefulSet identity
   ├── Finalizer allowlist
   └── Storage Backend 可证明性
   │
   ▼
BLOCKED
   或
BREAK-GLASS-REVIEW-READY
```

### scan / collector

```text
Cluster List
  │
  ├── Pods
  ├── PVCs
  ├── PVs
  └── VolumeAttachments
       │
       ▼
筛选 deletionTimestamp != null
       │
       ▼
计算 deletion age
       │
       ▼
判断 threshold
       │
       ▼
JSON / Human Output
       │
       ▼
Prometheus textfile
```

---

## 4. 项目目录与模块职责

```text
resource-terminating-diagnose/
├── README.md
├── resource-terminating-diagnose.sh
│
├── lib/
│   ├── common.sh
│   ├── csi-events.sh
│   ├── diagnose.sh
│   └── scan-output.sh
│
├── collector/
│   └── resource-terminating-collector.sh
│
├── prometheus/
│   └── prometheus-rule.yaml
│
├── rbac/
│   └── rbac.yaml
│
└── tests/
    ├── smoke.sh
    └── validate-readonly.sh
```

### resource-terminating-diagnose.sh

主入口，负责：

- CLI 参数解析；
- 命令分发；
- Runtime 初始化；
- Exit Code；
- JSON / Human Output；
- Collector 调度。

### lib/common.sh

基础 Kubernetes 查询层：

- `kubectl --request-timeout` 包装；
- Query Error 收集；
- Node 状态读取；
- PVC / PV 序列化；
- 查询引用 PVC 的 Pod；
- 查询 PV 对应 VolumeAttachment；
- VolumeAttachment 序列化；
- 删除时间 age 计算。

### lib/csi-events.sh

CSI 与 Event 关联层：

- 从 PV / VolumeAttachment 提取 CSI Driver；
- 查询 `CSIDriver`；
- 查询相关 Node 的 `CSINode`；
- 发现 CSI Controller / Node Plugin Pods；
- 标记 `exact` 与 `heuristic-token` 匹配；
- 收集目标对象相关 Events；
- Event Root Cause 分类。

### lib/diagnose.sh

核心业务判断层：

- Pod/PVC/PV/VolumeAttachment Dependency Graph；
- `SAFE / WARNING / DANGEROUS`；
- `force-check`；
- fail-closed blockers；
- Finalizer allowlist；
- Storage Backend 人工核验要求。

### lib/scan-output.sh

巡检与输出层：

- 集群级扫描；
- deletion age；
- threshold；
- Prometheus 指标生成；
- 原子 textfile 写入；
- Collector Loop；
- Human Output。

### collector/resource-terminating-collector.sh

Collector 薄包装器，本身不重复实现业务逻辑，直接调用：

```text
resource-terminating-diagnose.sh collector
```

---

## 5. 完整架构拓扑

```text
                         ┌─────────────────────┐
                         │      Operator       │
                         │ Jenkins / AIOps /   │
                         │   SRE / CronJob     │
                         └──────────┬──────────┘
                                    │
                                    ▼
                    ┌─────────────────────────────┐
                    │ resource-terminating-       │
                    │ diagnose.sh                 │
                    └──────────────┬──────────────┘
                                   │
             ┌─────────────────────┼─────────────────────┐
             │                     │                     │
             ▼                     ▼                     ▼
         diagnose              force-check           scan/collector
             │                     │                     │
             ▼                     ▼                     ▼
      Resource Graph         Fail-Closed Gate      Cluster List Scan
             │                     │                     │
     ┌───────┼────────┐            │               ┌─────┴─────┐
     │       │        │            │               │           │
     ▼       ▼        ▼            │               ▼           ▼
    Pod     PVC       PV           │             JSON      Prometheus
     │       │        │            │                           │
     └───────┼────────┘            │                           ▼
             │                     │                    Alertmanager
             ▼                     │
     VolumeAttachment              │
             │                     │
             ▼                     │
           Node                    │
             │                     │
      ┌──────┴──────┐              │
      │             │              │
      ▼             ▼              │
  CSIDriver       CSINode          │
      │             │              │
      └──────┬──────┘              │
             ▼                     │
 CSI Controller / Node Plugin      │
             │                     │
             ▼                     │
       Kubernetes Events           │
             │                     │
             └──────────┬──────────┘
                        ▼
          SAFE / WARNING / DANGEROUS
                        │
                        ▼
              BLOCKED / HUMAN REVIEW
```

---

## 6. 删除链路模型

### 6.1 Pod + Storage

```text
kubectl delete pod
      │
      ▼
Pod deletionTimestamp
      │
      ├── PreStop
      ├── SIGTERM
      ├── terminationGracePeriodSeconds
      └── Container Exit
              │
              ▼
       kubelet volume teardown
              │
              ▼
       CSI NodeUnpublishVolume
              │
              ▼
        VolumeAttachment
              │
              ▼
       ControllerUnpublishVolume
              │
              ▼
             Detach
```

### 6.2 PVC / PV

```text
PVC delete
   │
   ├── Pod 是否仍引用 PVC
   │
   ├── kubernetes.io/pvc-protection
   │
   ▼
PV
   │
   ├── Bound / Released
   ├── reclaimPolicy
   ├── pv-protection
   └── CSI provisioner finalizer
          │
          ▼
      Storage Backend
```

本工具不会假设：

```text
Kubernetes API Object 已消失
=
Storage Backend 已安全清理
```

---

## 7. 环境依赖

运行时：

```text
Bash
kubectl
jq
```

建议环境：

```text
Kubernetes v1.34+
主要验证目标：v1.36
```

PrometheusRule 额外需要：

```text
Prometheus Operator
kube-state-metrics
```

Collector 指标建议暴露给：

```text
node_exporter textfile collector
或其他兼容 Prometheus textfile 的 exporter
```

---

## 8. CLI 命令总览

```text
diagnose
force-check
scan
collector
```

查看帮助：

```bash
./resource-terminating-diagnose.sh --help
```

查看版本：

```bash
./resource-terminating-diagnose.sh --version
```

---

## 9. diagnose：资源基础诊断

### 9.1 Pod

```bash
./resource-terminating-diagnose.sh \
  diagnose pod mysql-0 \
  -n pro-yunfan
```

JSON：

```bash
./resource-terminating-diagnose.sh \
  diagnose pod mysql-0 \
  -n pro-yunfan \
  --json
```

自动关联：

```text
Pod
├── deletionTimestamp
├── finalizers
├── owner
├── terminationGracePeriodSeconds
├── Node Ready
├── PVC
│   └── PV
│       └── VolumeAttachment
├── CSI
└── Events
```

### 9.2 PVC

```bash
./resource-terminating-diagnose.sh \
  diagnose pvc data-mysql-0 \
  -n pro-yunfan
```

自动关联：

```text
PVC
├── deletionTimestamp
├── finalizers
├── consuming Pods
├── PV
├── VolumeAttachment
├── Node
└── CSI
```

### 9.3 PV

```bash
./resource-terminating-diagnose.sh \
  diagnose pv pvc-xxxxxxxx
```

自动关联：

```text
PV
├── claimRef
├── reclaimPolicy
├── finalizers
├── CSI driver
├── volumeHandle
├── PVC
├── consuming Pods
├── VolumeAttachment
└── Node / CSI
```

### 9.4 VolumeAttachment

```bash
./resource-terminating-diagnose.sh \
  diagnose volumeattachment csi-xxxxxxxx
```

自动关联：

```text
VolumeAttachment
├── attached
├── deletionTimestamp
├── finalizers
├── attachError
├── detachError
├── PV
├── PVC
├── Pods
├── Node
└── CSI
```

---

## 10. JSON 输出模型

示例：

```bash
./resource-terminating-diagnose.sh \
  diagnose pvc data-mysql-0 \
  -n pro-yunfan \
  --json
```

重点字段：

```json
{
  "target": {},
  "pods": [],
  "pv": {},
  "volumeAttachments": [],
  "nodes": [],
  "csi": [],
  "events": [],
  "eventRootCauses": [],
  "diagnostics": {
    "complete": true,
    "queryErrors": []
  },
  "verdict": "WARNING"
}
```

### diagnostics.complete

```text
true
=
当前诊断所需 API 查询均成功

false
=
至少一个 API / RBAC 查询失败
```

对于 `force-check`：

```text
diagnostics.complete=false
        ↓
DIAGNOSTIC_DATA_INCOMPLETE_FAIL_CLOSED
        ↓
BLOCKED
```

---

## 11. CSI 自动关联

CSI 强关联来自：

```text
PV.spec.csi.driver
VolumeAttachment.spec.attacher
CSIDriver
CSINode.spec.drivers[]
```

CSI Controller / Node Plugin Pod 无标准反向索引，因此组件发现分两层：

```text
exact
    完整 Driver Name 命中

heuristic-token
    Driver 首段 token 命中 Pod metadata / container / image / args
```

JSON 中明确保留：

```text
matchMode=exact
matchMode=heuristic-token
```

注意：

```text
heuristic-token
≠
Storage Backend 事实证明
```

它只能作为定位 CSI Controller / Node Plugin 的运维线索。

---

## 12. Kubernetes Events 根因归类

当前分类：

| Category | 典型事件 |
|---|---|
| `POD_TERMINATION` | FailedKillPod / FailedPreStopHook / Killing |
| `CONTAINER_RUNTIME` | FailedCreatePodSandBox / KillPodSandbox / PLEG |
| `STORAGE_MOUNT_UNMOUNT` | FailedMount / FailedUnmount / MountVolume |
| `STORAGE_ATTACH_DETACH` | FailedAttachVolume / FailedDetachVolume / Multi-Attach |
| `STORAGE_PROVISIONER` | ProvisioningFailed / VolumeFailedDelete / DeleteVolume |
| `NODE_UNAVAILABLE` | NodeNotReady / NodeUnreachable |
| `SCHEDULING` | FailedScheduling |
| `OTHER` | 其他事件 |

查询：

```bash
./resource-terminating-diagnose.sh \
  diagnose pod mysql-0 \
  -n pro-yunfan \
  --json \
| jq '.eventRootCauses'
```

Events 只是辅助证据：

```text
历史 Event
≠
当前真实状态
```

所以 `force-check` 不会仅凭 Event 放行。

---

## 13. Verdict

普通 `diagnose`：

| Verdict | 含义 |
|---|---|
| `SAFE` | 当前目标没有进入删除流程或未发现明显删除风险 |
| `WARNING` | 已删除中，但未发现直接高危依赖；仍需要继续分析 |
| `DANGEROUS` | 存在 attached volume、Node 异常、Live Pod 引用等高风险依赖 |

典型 DANGEROUS 条件：

```text
VolumeAttachment attached=true
Node Ready != True
PVC/PV 仍被 Live Pod 使用
```

---

## 14. force-check：Break-Glass 只读门禁

### 14.1 Pod

```bash
./resource-terminating-diagnose.sh \
  force-check pod mysql-0 \
  -n pro-yunfan \
  --json
```

阻断条件包括：

- 未进入 Terminating；
- Terminating 时间低于阈值；
- API/RBAC/CSI 数据不完整；
- Pod 有持久存储依赖；
- StatefulSet Identity 风险；
- Pod Finalizer 仍存在；
- VolumeAttachment 仍 Attached；
- Node NotReady / Unknown；
- CSI 组件未发现或不健康；
- CSINode 未注册 Driver。

### 14.2 PVC

```bash
./resource-terminating-diagnose.sh \
  force-check pvc data-mysql-0 \
  -n pro-yunfan \
  --json
```

只要还有 Pod 对象引用：

```text
PVC_STILL_REFERENCED_BY_POD_OBJECTS
        ↓
BLOCKED
```

### 14.3 PV

```bash
./resource-terminating-diagnose.sh \
  force-check pv pvc-xxxxxxxx \
  --json
```

如果：

```text
reclaimPolicy=Delete
```

或者 CSI 外部 Finalizer 表示后端清理尚需确认，则：

```text
BACKEND_STORAGE_DELETION_CANNOT_BE_PROVEN_BY_KUBERNETES_API
        ↓
BLOCKED
```

必须根据：

```text
PV.spec.csi.volumeHandle
```

去云盘 / SAN / Ceph / CSI Backend 验证真实卷状态。

### 14.4 VolumeAttachment

```bash
./resource-terminating-diagnose.sh \
  force-check volumeattachment csi-xxxxxxxx \
  --json
```

如果：

```text
status.attached=true
```

一定阻断。

即使：

```text
attached=false
```

仍建议人工确认 Storage Backend 已 Detach。

### 14.5 未知 / 自定义 Finalizer

v1.1 最终生产审查增加了 fail-closed Finalizer Guard。

对于 PVC/PV/VolumeAttachment：

```text
未知或第三方自定义 Finalizer
        ↓
UNKNOWN_OR_CUSTOM_FINALIZER_REQUIRES_CONTROLLER_REVIEW
        ↓
BLOCKED
```

原因是：

```text
工具无法证明自定义 Controller 的清理契约已经完成
```

---

## 15. force-check Exit Code

| Code | 含义 |
|---:|---|
| `0` | SAFE / scan 成功 |
| `10` | WARNING / scan 不完整 |
| `20` | DANGEROUS / force-check BLOCKED |
| `30` | BREAK-GLASS-REVIEW-READY |
| `64` | 参数 / 依赖 / API 基础访问失败 |

必须明确：

```text
exit 30
≠
允许自动删除
```

它只代表：

```text
可以进入人工审批、存储侧确认和 Break-Glass Runbook
```

---

## 16. scan：集群级 Terminating 扫描

```bash
./resource-terminating-diagnose.sh \
  scan \
  --json
```

自定义阈值：

```bash
./resource-terminating-diagnose.sh \
  scan \
  --threshold-seconds 600 \
  --json
```

扫描：

```text
Pod
PVC
PV
VolumeAttachment
```

只保留：

```text
metadata.deletionTimestamp != null
```

输出：

- Terminating 数量；
- deletionTimestamp；
- ageSeconds；
- overThreshold；
- Finalizers；
- PV / Node / CSI 基础字段；
- VolumeAttachment attached / attachError / detachError；
- Query completeness。

---

## 17. Collector

长期周期运行：

```bash
./resource-terminating-diagnose.sh \
  collector \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/resource-terminating.prom \
  --interval-seconds 60
```

包装入口：

```bash
./collector/resource-terminating-collector.sh \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/resource-terminating.prom \
  --interval-seconds 60
```

Cron / CronJob 单次模式：

```bash
./collector/resource-terminating-collector.sh \
  --prometheus-output /data/resource-terminating.prom \
  --once
```

建议周期：

```text
60s ~ 300s
```

最小允许：

```text
30s
```

因为每轮都会执行集群级 list，不建议秒级高频扫描。

---

## 18. Prometheus textfile

一次生成：

```bash
./resource-terminating-diagnose.sh \
  scan \
  --threshold-seconds 600 \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/resource-terminating.prom
```

原子写入流程：

```text
resource-terminating.prom.tmp.<pid>
             │
             ▼
          完整写入
             │
             ▼
            mv
             │
             ▼
resource-terminating.prom
```

核心指标：

```text
resource_terminating_diagnose_scan_success
resource_terminating_diagnose_generated_timestamp_seconds
resource_terminating_diagnose_terminating_objects{kind}
resource_terminating_diagnose_over_threshold_objects{kind}
resource_terminating_diagnose_object_deletion_age_seconds{kind,namespace,name}
resource_terminating_diagnose_volumeattachment_attached{name,pv,node}
```

只有 Terminating 对象生成 deletion-age 指标，避免给全部正常对象建立高基数时序。

---

## 19. PrometheusRule

文件：

```text
prometheus/prometheus-rule.yaml
```

安装：

```bash
kubectl apply -f prometheus/prometheus-rule.yaml
```

默认 Namespace：

```text
cattle-prometheus
```

如 Prometheus Operator 部署在其他 Namespace，请修改 Manifest。

### kube-state-metrics 告警

```text
KubernetesPodStuckTerminating
KubernetesPVCStuckTerminating
KubernetesPVStuckTerminating
```

### Collector 告警

```text
ResourceTerminatingCollectorMissing
ResourceTerminatingCollectorStale
ResourceTerminatingCollectorScanFailed
KubernetesTerminatingObjectsOverThreshold
KubernetesVolumeAttachmentStuckTerminating
```

VolumeAttachment 告警关键逻辑：

```promql
resource_terminating_diagnose_object_deletion_age_seconds{kind="volumeattachment"} > 600
and on(name)
resource_terminating_diagnose_volumeattachment_attached == 1
```

因此不会把正常长期：

```text
attached=true
但没有 deletionTimestamp
```

的业务 VolumeAttachment 误判为 Detach 故障。

---

## 20. RBAC

安装：

```bash
kubectl apply -f rbac/rbac.yaml
```

ServiceAccount：

```text
kube-system/resource-terminating-diagnose
```

ClusterRole 仅允许：

```text
get
list
```

资源范围：

```text
core/v1:
  pods
  persistentvolumeclaims
  persistentvolumes
  nodes
  events

storage.k8s.io:
  volumeattachments
  csidrivers
  csinodes
  storageclasses
```

明确不包含：

```text
create
update
patch
delete
deletecollection
```

### 与 Namespace 工具 RBAC 的差异

`namespace-terminating-diagnose` 为了动态发现所有 CRD/Namespaced Resource，需要更广泛的只读 API 权限。

本项目只针对固定资源链，因此使用更收敛的资源级 `get/list`。

---

## 21. 生产安全模型

### 第一层：代码只读

不会实现：

```text
kubectl delete --force
kubectl patch
finalizer remove
VolumeAttachment delete
Node taint / fencing
Storage force-detach
```

### 第二层：RBAC 只读

即使 Shell 出现逻辑错误，ServiceAccount 也没有 Kubernetes API 写权限。

### 第三层：force-check fail-closed

```text
不知道
=
不放行
```

包括：

```text
API 查询失败
CSI 无法确认
Node Unknown
Storage Backend 无法证明
未知 Finalizer
```

### 第四层：人工 Storage Backend 复核

尤其是：

```text
StatefulSet
RWO Volume
reclaimPolicy=Delete
CSI external finalizer
VolumeAttachment
```

必须确认真实后端状态。

---

## 22. 推荐生产排障 SOP

### 场景 A：Namespace 删除卡住

```text
kubectl delete namespace
        │
        ▼
namespace-terminating-diagnose check
        │
        ▼
namespace-terminating-diagnose diagnose
        │
        ├── APIService ?
        ├── CR ?
        ├── Webhook ?
        ├── Finalizer ?
        └── PVC/PV/VA ?
                 │
                 ▼
    resource-terminating-diagnose diagnose
```

### 场景 B：Pod 单独卡 Terminating

```bash
./resource-terminating-diagnose.sh \
  diagnose pod <pod> \
  -n <namespace> \
  --json
```

重点看：

```text
Node
PVC
VolumeAttachment
CSI
Events
```

### 场景 C：PVC 卡 Terminating

```bash
./resource-terminating-diagnose.sh \
  diagnose pvc <pvc> \
  -n <namespace> \
  --json
```

重点看：

```text
pods[]
pv
volumeAttachments[]
finalizers
csi[]
```

### 场景 D：PV 卡 Terminating

```bash
./resource-terminating-diagnose.sh \
  diagnose pv <pv> \
  --json
```

重点看：

```text
claimRef
reclaimPolicy
volumeHandle
finalizers
VolumeAttachment
```

### 场景 E：VolumeAttachment 卡 Terminating

```bash
./resource-terminating-diagnose.sh \
  diagnose volumeattachment <va> \
  --json
```

重点看：

```text
attached
node
detachError
CSINode
CSI component Pods
```

---

## 23. Break-Glass 决策流程

```text
Terminating
    │
    ▼
diagnose
    │
    ├── Controller / Node / CSI 可恢复
    │        │
    │        ▼
    │     优先恢复
    │        │
    │        ▼
    │     等待 reconcile
    │
    ▼
force-check
    │
    ├── BLOCKED
    │      │
    │      └── 禁止 force-delete / finalizer remove
    │
    └── BREAK-GLASS-REVIEW-READY
           │
           ▼
      人工变更审批
           │
           ├── Node 是否真正停止
           ├── Pod 进程是否死亡
           ├── StatefulSet 是否有双实例风险
           ├── Storage 是否已 Detach
           ├── Backend Volume 是否保留/删除
           └── Snapshot / Backup 是否存在
```

本项目永远停在：

```text
人工复核之前
```

不会自动执行 Break-Glass。

---

## 24. 常用命令速查

### Namespace Terminating

```bash
cd ../namespace-terminating-diagnose
./namespace-terminating-diagnose.sh check -n <ns>
./namespace-terminating-diagnose.sh diagnose -n <ns>
./namespace-terminating-diagnose.sh force-check -n <ns> --threshold 900
```

### Pod

```bash
./resource-terminating-diagnose.sh diagnose pod <pod> -n <ns>
./resource-terminating-diagnose.sh force-check pod <pod> -n <ns> --json
```

### PVC

```bash
./resource-terminating-diagnose.sh diagnose pvc <pvc> -n <ns>
./resource-terminating-diagnose.sh force-check pvc <pvc> -n <ns> --json
```

### PV

```bash
./resource-terminating-diagnose.sh diagnose pv <pv>
./resource-terminating-diagnose.sh force-check pv <pv> --json
```

### VolumeAttachment

```bash
./resource-terminating-diagnose.sh diagnose volumeattachment <va>
./resource-terminating-diagnose.sh force-check volumeattachment <va> --json
```

### Cluster Scan

```bash
./resource-terminating-diagnose.sh scan --threshold-seconds 600 --json
```

### Collector

```bash
./collector/resource-terminating-collector.sh \
  --prometheus-output /var/lib/node_exporter/textfile_collector/resource-terminating.prom \
  --interval-seconds 60
```

---

## 25. 当前明确不覆盖的能力

为了避免误解，本项目当前不负责：

```text
Namespace API Discovery
APIService 健康检查
全量 CRD / Custom Resource 枚举
Admission Webhook / VAP 诊断
Namespace /finalize
Node OS 级 mount namespace 检查
直接 journalctl kubelet/containerd
Storage Provider API 查询
云盘/SAN/Ceph 后端强制 Detach
自动删除 Finalizer
自动 Force Delete
```

其中 Namespace 相关能力请使用：

```text
namespace-terminating-diagnose
```

Node/Runtime/Storage Backend 级别操作仍应进入人工 Runbook。

---

## 26. CI 与回归测试

项目级 GitHub Actions：

```text
.github/workflows/resource-terminating-diagnose-ci.yml
```

检查：

```text
bash -n
ShellCheck
read-only contract
mock behavior contracts
Gitleaks
```

只读 Guard：

```text
tests/validate-readonly.sh
```

Mock 行为测试：

```text
tests/smoke.sh
```

已覆盖包括：

- Pod `force-check` exit 30；
- FailedKillPod → `POD_TERMINATION`；
- deleting VolumeAttachment + attached=true；
- Prometheus textfile；
- Collector `--once`；
- 自定义 PVC Finalizer → `BLOCKED / exit 20`。

---

## 27. Terminating 治理体系

仓库中两套工具组合后形成完整链路：

```text
                  Kubernetes Terminating Governance
                               │
             ┌─────────────────┴─────────────────┐
             │                                   │
             ▼                                   ▼
namespace-terminating-diagnose       resource-terminating-diagnose
             │                                   │
             ├── Namespace                       ├── Pod
             ├── API Discovery                   ├── PVC
             ├── APIService                      ├── PV
             ├── Remaining Resources             ├── VolumeAttachment
             ├── CR / Finalizer                  ├── Node
             ├── Webhook / VAP                   ├── CSI
             └── Namespace Force Gate            ├── Events
                                                 ├── Resource Force Gate
                                                 └── Collector / Prometheus
```

推荐生产原则：

```text
先诊断
  ↓
恢复真正负责 reconcile 的组件
  ↓
等待 Kubernetes 自己完成删除
  ↓
仍无法恢复时执行 force-check
  ↓
人工审批
  ↓
最后才考虑 Break-Glass
```

**不要把删除 Finalizer 当成第一排障步骤。**
