# resource-terminating-diagnose

Kubernetes Pod / PVC / PV / VolumeAttachment 长时间 `Terminating` 专项只读诊断与治理工具。

**v1.1.0** 在 v1.0 自动关联资源链的基础上增加：

- `force-check`：严格 fail-closed 的 Break-Glass 前置检查，只判断、不执行强制操作；
- CSI Controller / Node Plugin 关联：CSIDriver、CSINode、CSI Pod 健康信息；
- Kubernetes Events 根因归类：自动识别终止、运行时、挂载、Attach/Detach、Node 等故障类别；
- `--prometheus-output`：输出 Prometheus textfile 指标；
- `collector`：周期扫描 Pod/PVC/PV/VolumeAttachment，并原子刷新指标文件；
- 修复 v1.0 `VolumeAttachment attached==1 for 30m` 的误报模型：长期正常挂载不再被当成 Detach 异常，只有 **已经设置 deletionTimestamp 且仍 attached** 才进入专项告警。

## 1. 安全边界

工具严格只读，**不会**执行：

```text
kubectl delete --force
metadata.finalizers patch/remove
VolumeAttachment delete
Storage backend force-detach / delete
Node fencing
```

`force-check` 返回 `BREAK-GLASS-REVIEW-READY` 也只表示：

> Kubernetes API 可验证范围内没有发现阻断项，可以进入人工复核。

它不代表真实 Storage Backend 一定安全，也不会执行任何变更。

对于：

```text
PV reclaimPolicy=Delete
+
external-provisioner / external-attacher finalizer
```

工具无法仅依赖 Kubernetes API 证明真实后端卷已经删除，因此 PV `force-check` 会保持 fail-closed，并要求存储侧人工确认。

## 2. 诊断链路

```text
Pod
 │
 ├── deletionTimestamp / finalizers / gracePeriod / owner
 ├── Node Ready
 ├── Kubernetes Events
 └── PVC
      │
      ├── consuming Pods
      └── PV
           │
           ├── reclaimPolicy
           ├── CSI driver / volumeHandle
           ├── CSIDriver
           ├── CSINode registration
           └── VolumeAttachment
                  │
                  ├── attached
                  ├── attachError / detachError
                  ├── target Node
                  └── CSI component Pods
```

## 3. 目录

```text
resource-terminating-diagnose/
├── resource-terminating-diagnose.sh
├── README.md
├── collector/
│   └── resource-terminating-collector.sh
├── prometheus/
│   └── prometheus-rule.yaml
├── rbac/
│   └── rbac.yaml
└── tests/
    └── smoke.sh
```

## 4. 依赖

- Kubernetes v1.34+，主要验证目标 v1.36；
- `kubectl`；
- `jq`；
- Bash；
- PrometheusRule 需要 Prometheus Operator；
- Pod/PVC/PV deletion timestamp 原生告警依赖 kube-state-metrics；
- Collector 指标建议通过 node_exporter textfile collector 或已有 textfile exporter 暴露给 Prometheus。

## 5. 基础诊断

### Pod

```bash
./resource-terminating-diagnose.sh \
  diagnose pod mysql-0 \
  -n pro-yunfan
```

### PVC

```bash
./resource-terminating-diagnose.sh \
  diagnose pvc data-mysql-0 \
  -n pro-yunfan
```

### PV

```bash
./resource-terminating-diagnose.sh \
  diagnose pv pvc-xxxxxxxx
```

### VolumeAttachment

```bash
./resource-terminating-diagnose.sh \
  diagnose volumeattachment csi-xxxxxxxx
```

## 6. JSON 输出

```bash
./resource-terminating-diagnose.sh \
  diagnose pvc data-mysql-0 \
  -n pro-yunfan \
  --json
```

v1.1 重点增加：

```json
{
  "csi": [
    {
      "driver": "ebs.csi.aws.com",
      "driverObject": {},
      "nodeRegistration": [],
      "componentPods": [],
      "discovery": {
        "standardObjectsPresent": true,
        "componentPodsFound": 2,
        "heuristicUsed": true
      }
    }
  ],
  "events": [],
  "eventRootCauses": [],
  "diagnostics": {
    "complete": true,
    "queryErrors": []
  }
}
```

`diagnostics.complete=false` 表示至少有一次 API 查询失败。对于普通 `diagnose` 应视为诊断信息不完整；对于 `force-check` 会直接 fail-closed。

## 7. CSI 自动关联

标准 Kubernetes API 没有一个字段可以直接从 `CSIDriver` 定位到“哪个 Namespace / Deployment 是该 Driver 的 Controller”。因此 v1.1 分两层关联：

1. **强关联**：
   - PV `.spec.csi.driver`；
   - VolumeAttachment `.spec.attacher`；
   - `CSIDriver`；
   - 相关 Node 的 `CSINode.spec.drivers[]`。
2. **组件 Pod 关联**：
   - 先匹配完整 Driver 名；
   - 无法完整匹配时，用 Driver 首段 token 对 Pod 名、Namespace、labels、annotations、container name/image/args 做启发式关联；
   - JSON 中通过 `matchMode=exact|heuristic-token` 明确区分。

因此 CSI Pod 结果适合定位 Controller/Node Plugin 健康问题，但不要把启发式匹配当作存储后端事实证明。

## 8. Kubernetes Events 根因归类

v1.1 会把目标对象及相关 Pod/PVC 的 Events 分类为：

| Category | 典型事件 |
|---|---|
| `POD_TERMINATION` | FailedKillPod、FailedPreStopHook、Killing |
| `CONTAINER_RUNTIME` | FailedCreatePodSandBox、KillPodSandbox、PLEG/runtime |
| `STORAGE_MOUNT_UNMOUNT` | FailedMount、FailedUnmount、MountVolume |
| `STORAGE_ATTACH_DETACH` | FailedAttachVolume、FailedDetachVolume、Multi-Attach |
| `STORAGE_PROVISIONER` | ProvisioningFailed、VolumeFailedDelete、DeleteVolume |
| `NODE_UNAVAILABLE` | NodeNotReady、NodeUnreachable |
| `SCHEDULING` | FailedScheduling |
| `OTHER` | 其余事件 |

例如：

```bash
./resource-terminating-diagnose.sh \
  diagnose pod mysql-0 \
  -n prod \
  --json \
| jq '.eventRootCauses'
```

Events 是辅助证据。历史 Event 不等同于当前状态，因此 `force-check` 不会仅凭一个旧 Event 自动做高风险结论。

## 9. force-check：只读 Break-Glass Gate

### Pod

```bash
./resource-terminating-diagnose.sh \
  force-check pod web-xxx \
  -n prod \
  --json
```

重点阻断：

- 目标尚未进入删除流程；
- Terminating 时间未达到阈值；
- API / RBAC / CSI 查询不完整；
- Pod 存在 PVC；
- StatefulSet Identity 风险；
- Finalizer 仍存在；
- 相关 VolumeAttachment 仍 attached；
- 相关 Node NotReady / Unknown，无法证明 fencing；
- CSI 组件无法关联、组件异常或 Driver 未注册到相关 Node。

### PVC

```bash
./resource-terminating-diagnose.sh \
  force-check pvc data-mysql-0 \
  -n prod \
  --json
```

只要还有 Pod 对象引用 PVC，就会：

```text
BLOCKED
PVC_STILL_REFERENCED_BY_POD_OBJECTS
```

### PV

```bash
./resource-terminating-diagnose.sh \
  force-check pv pvc-xxxxxxxx \
  --json
```

对于动态 CSI PV：

```text
reclaimPolicy=Delete
```

或者存在：

```text
external-provisioner...
external-attacher...
```

会加入：

```text
BACKEND_STORAGE_DELETION_CANNOT_BE_PROVEN_BY_KUBERNETES_API
```

必须到云盘 / SAN / Ceph / CSI Storage Backend 根据 `volumeHandle` 验证真实状态。

### VolumeAttachment

```bash
./resource-terminating-diagnose.sh \
  force-check volumeattachment csi-xxxx \
  --json
```

如果：

```text
status.attached=true
```

永远不能通过只读 Gate。

即使 `attached=false`，仍会提示人工到存储后端确认已经 Detach。

### Exit Code

| Code | 含义 |
|---:|---|
| `0` | SAFE / scan 正常 |
| `10` | WARNING / scan 不完整 |
| `20` | DANGEROUS 或 force-check BLOCKED |
| `30` | BREAK-GLASS-REVIEW-READY，仅表示可进入人工复核 |
| `64` | 参数、依赖或目标基础访问失败 |

自动化平台不要把 exit code `30` 解释成“允许自动删除”。

## 10. 集群扫描

```bash
./resource-terminating-diagnose.sh scan --json
```

指定阈值：

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

并输出：

- 当前带 `deletionTimestamp` 数量；
- 删除持续时间；
- 是否超过阈值；
- 删除中的 VolumeAttachment 是否仍 `attached=true`；
- API 查询是否完整。

## 11. Prometheus textfile 输出

一次扫描并生成：

```bash
./resource-terminating-diagnose.sh \
  scan \
  --threshold-seconds 600 \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/resource-terminating.prom
```

采用：

```text
<file>.tmp.<pid>
        ↓
     完整写入
        ↓
      rename
        ↓
最终 .prom
```

避免 Prometheus/Exporter 读取到半写文件。

核心指标：

```text
resource_terminating_diagnose_scan_success
resource_terminating_diagnose_generated_timestamp_seconds
resource_terminating_diagnose_terminating_objects{kind="..."}
resource_terminating_diagnose_over_threshold_objects{kind="..."}
resource_terminating_diagnose_object_deletion_age_seconds{kind,namespace,name}
resource_terminating_diagnose_volumeattachment_attached{name,pv,node}
```

`object_deletion_age_seconds` 只为当前 Terminating 对象生成，因此不会为所有正常 Pod 建立高基数时序。

## 12. 周期 Collector

主 CLI：

```bash
./resource-terminating-diagnose.sh \
  collector \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/resource-terminating.prom \
  --interval-seconds 60
```

也可以使用包装脚本：

```bash
./collector/resource-terminating-collector.sh \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/resource-terminating.prom \
  --interval-seconds 60
```

单次执行适合 Cron / Kubernetes CronJob：

```bash
./collector/resource-terminating-collector.sh \
  --prometheus-output /data/resource-terminating.prom \
  --once
```

Collector 最短周期限制为 `30s`，建议生产使用：

```text
60s ～ 300s
```

该扫描会执行集群级 Pod/PVC/PV/VolumeAttachment list，因此不建议高频执行。

生产上不要直接给 Collector 使用 `admin.conf`。应使用 `rbac/rbac.yaml` 对应的只读 ServiceAccount，或者生成等效的最小权限 kubeconfig。

## 13. PrometheusRule

```bash
kubectl apply -f prometheus/prometheus-rule.yaml
```

默认包含两类规则。

### kube-state-metrics 原生规则

```text
KubernetesPodStuckTerminating
KubernetesPVCStuckTerminating
KubernetesPVStuckTerminating
```

### v1.1 Collector 规则

```text
ResourceTerminatingCollectorMissing
ResourceTerminatingCollectorStale
ResourceTerminatingCollectorScanFailed
KubernetesTerminatingObjectsOverThreshold
KubernetesVolumeAttachmentStuckTerminating
```

`KubernetesVolumeAttachmentStuckTerminating` 的逻辑已经改为：

```promql
resource_terminating_diagnose_object_deletion_age_seconds{kind="volumeattachment"} > 600
and on(name)
resource_terminating_diagnose_volumeattachment_attached == 1
```

因此：

```text
正常业务 VolumeAttachment
attached=true
但没有 deletionTimestamp
```

不会再产生“Detach Error”误报。

如果暂未部署 v1.1 Collector，请先不要启用 `kubernetes.resource-terminating.collector` 规则组，否则 `ResourceTerminatingCollectorMissing` 会按设计告警。

## 14. RBAC

```bash
kubectl apply -f rbac/rbac.yaml
```

ClusterRole 只允许：

```text
get
list
```

覆盖：

```text
pods
persistentvolumeclaims
persistentvolumes
nodes
events
volumeattachments
csidrivers
csinodes
storageclasses
```

不包含：

```text
create
update
patch
delete
```

这构成第二层安全边界：即使脚本逻辑出现错误，该 ServiceAccount 也没有 API 写权限。

## 15. 推荐生产处置流程

```text
Prometheus / Collector 检测 Terminating
                 │
                 ▼
              diagnose
                 │
       ┌─────────┼──────────┐
       │         │          │
      SAFE    WARNING    DANGEROUS
                 │          │
                 ▼          ▼
           恢复 controller  Node fencing
           kubelet/runtime  CSI / storage
           CSI reconcile    StatefulSet identity
                 │          │
                 └────┬─────┘
                      ▼
                  force-check
                      │
             ┌────────┴────────┐
             │                 │
          BLOCKED      BREAK-GLASS-REVIEW-READY
             │                 │
          继续修复          人工审批/存储确认
                               │
                               ▼
                        人工 Break-Glass
```

Break-Glass 不属于本工具自动化能力。

## 16. 与 namespace-terminating-diagnose 的关系

两个工具形成两层治理：

```text
namespace-terminating-diagnose
        │
        ├── Namespace Controller / discovery / finalizers
        ├── 剩余 namespaced objects
        └── Namespace /finalize Break-Glass Gate

resource-terminating-diagnose
        │
        ├── Pod / PVC / PV / VolumeAttachment
        ├── Node / CSI / Events
        ├── Storage deletion dependency graph
        └── Resource Break-Glass Gate
```

推荐先使用 `namespace-terminating-diagnose` 找到 Namespace 删除阻塞对象，再交给 `resource-terminating-diagnose` 深挖 Pod/Storage 删除链。

## 17. 测试

```bash
bash tests/smoke.sh
```

仓库根 CI 还会执行：

```text
bash -n
shellcheck --severity=error
yamllint
```

## 18. v1.1 生产验收建议

正式合并前建议至少覆盖：

1. Stateless Pod 正常 Terminating；
2. Pod + PreStop 失败 Event；
3. PVC 仍被 Pod 引用；
4. StatefulSet + RWO；
5. Node NotReady + attached VolumeAttachment；
6. VolumeAttachment deletionTimestamp + attached=true；
7. CSI Controller Pod NotReady；
8. CSINode 无对应 Driver；
9. PV reclaimPolicy=Delete + external-provisioner finalizer；
10. RBAC 刻意缺失权限，确认 `force-check` fail-closed；
11. Collector API 查询失败时 `scan_success=0`；
12. 正常长期 attached 的 VolumeAttachment 不产生 StuckTerminating 告警。
