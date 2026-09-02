# Kubernetes Terminating 专项治理：Pod / PVC / PV / VolumeAttachment 自动关联诊断

## 1. 目标

`namespace-terminating-diagnose` 原本以 Namespace 为入口，解决 Namespace 长时间 `Terminating` 的全量资源、Finalizer、APIService、CSI 与 Admission 诊断。

本阶段增加 Resource Chain Engine，把以下对象提升为一等诊断入口：

```text
Pod
PVC
PV
VolumeAttachment
```

统一目标：

```text
Terminating Object
      │
      ▼
自动解析 deletionTimestamp / finalizers
      │
      ▼
建立 Pod -> PVC -> PV -> VolumeAttachment -> Node 关联图
      │
      ▼
识别 Stateful / RWO / CSI / Node 风险
      │
      ▼
输出 Human / JSON / Prometheus
      │
      ▼
force-check 只读安全门禁
```

核心原则：

> 诊断工具只负责“证明删除链路卡在哪里”和“是否允许进入人工 Break-Glass 复核”，不负责执行强制删除、清 Finalizer 或强制 Detach。

---

## 2. 统一入口

推荐使用：

```bash
./terminating-diagnose.sh <command> <target> [options]
```

支持：

```text
command:
  check
  diagnose
  report
  force-check

target:
  namespace
  pod
  pvc
  pv
  volumeattachment
```

原有入口保持兼容：

```text
namespace-terminating-diagnose.sh
namespace-terminating-patrol.sh
```

新增资源链入口：

```text
resource-terminating-diagnose.sh
```

---

## 3. 诊断链路

### 3.1 Pod

```text
Pod
 │
 ├── deletionTimestamp
 ├── Finalizers
 ├── terminationGracePeriodSeconds
 ├── ownerReferences
 ├── Node / Ready
 │
 └── PVC[]
      │
      ▼
     PV
      │
      ├── phase
      ├── reclaimPolicy
      ├── CSI driver
      ├── volumeHandle
      └── finalizers
             │
             ▼
      VolumeAttachment
             │
             ├── attached
             ├── attacher
             └── Node / Ready
```

重点识别：StatefulSet Pod、Pod 仍关联 PVC、Node Missing/NotReady/Unknown、PV 仍 Bound、`reclaimPolicy=Delete`、CSI backend deletion finalizer、VolumeAttachment `attached=true`。

### 3.2 PVC

```text
PVC
 ├── deletionTimestamp
 ├── kubernetes.io/pvc-protection
 ├── 引用它的所有 Pod
 └── spec.volumeName
        │
        ▼
       PV
        │
        ▼
 VolumeAttachment
        │
        ▼
       Node
```

如果 PVC 仍被任何 Pod 引用，`pvc-protection` 代表真实依赖仍存在。工具判定为高风险，不允许绕过保护。

### 3.3 PV

```text
PV
 ├── claimRef
 ├── phase
 ├── reclaimPolicy
 ├── csi.driver
 ├── csi.volumeHandle
 ├── pv-protection
 └── external-provisioner finalizer
       │
       ├── PVC
       │    └── referencing Pods
       │
       └── VolumeAttachment
             └── Node
```

对于 `reclaimPolicy=Delete`，即使 Kubernetes 内部已没有 Pod/PVC/VolumeAttachment，工具仍不会仅凭 API 状态声明后端 Volume 已删除。必须人工到真实存储系统核验 `volumeHandle`、attached/detached、exists/deleted、snapshot/backup，因此 `force-check` 采用 fail-closed。

### 3.4 VolumeAttachment

```text
VolumeAttachment
 ├── status.attached
 ├── spec.attacher
 ├── spec.nodeName
 ├── finalizers
 └── spec.source.persistentVolumeName
       │
       ▼
      PV
       │
       ▼
      PVC
       │
       ▼
     Pod(s)
```

特别规则：**VolumeAttachment 永远不会被工具自动判定为 `BREAK-GLASS-REVIEW-READY`**。因为 Kubernetes API 中 `status.attached=false` 仍不能证明真实 Storage Backend 已经完成 Detach。

---

## 4. 使用示例

### Pod

```bash
./terminating-diagnose.sh diagnose pod \
  -n pro-yunfan \
  --name mysql-0
```

JSON：

```bash
./terminating-diagnose.sh diagnose pod \
  -n pro-yunfan \
  --name mysql-0 \
  --json
```

### PVC

```bash
./terminating-diagnose.sh diagnose pvc \
  -n pro-yunfan \
  --name data-mysql-0
```

### PV

```bash
./terminating-diagnose.sh diagnose pv \
  --name pvc-xxxxxxxx
```

### VolumeAttachment

```bash
./terminating-diagnose.sh diagnose volumeattachment \
  --name csi-xxxxxxxx
```

### Report

```bash
./terminating-diagnose.sh report pvc \
  -n pro-yunfan \
  --name data-mysql-0 \
  --output-dir /data/logs/resource-terminating-diagnose
```

输出：

```text
pvc-pro-yunfan-data-mysql-0-YYYYmmdd-HHMMSS.txt
pvc-pro-yunfan-data-mysql-0-YYYYmmdd-HHMMSS.json
pvc-pro-yunfan-data-mysql-0-YYYYmmdd-HHMMSS.prom
```

---

## 5. JSON Contract

核心结构：

```json
{
  "schema_version": "1",
  "tool": "resource-terminating-diagnose",
  "command": "diagnose",
  "target": {
    "kind": "pvc",
    "namespace": "pro-yunfan",
    "name": "data-mysql-0",
    "deletion_timestamp": "2026-09-02T00:00:00Z",
    "terminating_age_seconds": 1200,
    "finalizers": ["kubernetes.io/pvc-protection"]
  },
  "verdict": "DANGEROUS",
  "exit_code": 20,
  "break_glass_review_ready": false,
  "counts": {
    "pods": 1,
    "pvcs": 1,
    "pvs": 1,
    "volumeattachments": 1,
    "attached_volumeattachments": 1
  },
  "warnings": [],
  "dangers": [],
  "blockers": [],
  "chain": []
}
```

Schema：`tests/schema/resource-result.schema.json`。

---

## 6. Verdict / Exit Code

| Verdict | Exit | 含义 |
|---|---:|---|
| `SAFE` | 0 | 对象未处于 Terminating，未发现高风险关联 |
| `WARNING` | 10 | 正在删除、存在未完全验证项或需要等待 Controller 收敛 |
| `DANGEROUS` | 20 | 存在明确 Stateful / Pod 引用 / Bound PV / attached VA 等风险 |
| `BREAK-GLASS-REVIEW-READY` | 30 | 仅 `force-check`；满足进入人工复核的前置条件 |
| Tool/API Error | 64 | 参数、kubectl、jq、RBAC 或 API 基础访问失败 |

`BREAK-GLASS-REVIEW-READY` 不等于可以直接强制删除，只表示可以进入人工审批、存储核验和节点 fencing 复核。

---

## 7. force-check 安全门禁

Pod 阻止放行：StatefulSet Owner、关联 PVC/PV/VolumeAttachment、扫描不完整、自定义 Finalizer、Terminating 未达到阈值。

PVC 阻止放行：仍有 Pod 引用、关联 PV 仍 Bound、VolumeAttachment 仍 attached、API/RBAC 扫描不完整。

PV 阻止放行：PV 仍 Bound、claimRef 仍有效、PVC 仍被 Pod 使用、VolumeAttachment 仍 attached、`reclaimPolicy=Delete`、`external-provisioner.volume.kubernetes.io/finalizer`、无法核验真实存储后端。

VolumeAttachment：始终要求人工 Storage Backend / CSI Detach 核验，不自动 Ready。

---

## 8. Prometheus

静态 Kubernetes 状态告警：`prometheus/terminating-resource-alerts.yaml`。

Recording Rules：

```text
kubernetes:pod_terminating_age_seconds
kubernetes:pvc_terminating_age_seconds
kubernetes:pv_terminating_age_seconds
```

Alerts：

```text
KubernetesPodStuckTerminating
KubernetesPVCStuckTerminating
KubernetesPVStuckTerminating
KubernetesVolumeAttachmentAttachedToNotReadyNode
ResourceTerminatingDiagnosisStale
```

诊断工具 textfile 指标：

```text
resource_terminating_diagnose_target_info
resource_terminating_diagnose_target_terminating_age_seconds
resource_terminating_diagnose_attached_volumeattachments
resource_terminating_diagnose_referencing_pods
resource_terminating_diagnose_scan_errors
resource_terminating_diagnose_break_glass_review_ready
resource_terminating_diagnose_generated_timestamp_seconds
```

当前 kube-state-metrics 可提供 VolumeAttachment attached/info/created 等指标，但没有与 Pod/PVC/PV 相同的 VolumeAttachment deletion timestamp 指标。因此告警采用 `attached=true + Node Ready != true + 持续 10m` 作为高风险 Detach 信号，而不是伪造不存在的 `VolumeAttachmentTerminatingAge` 指标。

---

## 9. CI Contract

现有 GitHub Actions Gate 继续覆盖：

```text
bash -n
ShellCheck --severity=error
read-only static guard
RBAC zero-write validation
Secret Scan
```

新增：

```text
tests/resource-run-tests.sh
tests/schema/resource-result.schema.json
```

Mock 场景至少覆盖：

```text
PVC + StatefulSet + PV + attached VA
  -> DANGEROUS / 20

Stateless Pod + no PVC + old deletionTimestamp
  -> BREAK-GLASS-REVIEW-READY / 30

VolumeAttachment attached=false
  -> 仍不能自动强制清理
  -> WARNING / 10
```

---

## 10. 生产排障顺序

推荐固定：

```text
1. check
      │
      ▼
2. diagnose
      │
      ▼
3. 修复真实 Controller / kubelet / containerd / CSI / Node
      │
      ▼
4. 再次 diagnose
      │
      ▼
5. force-check
      │
      ▼
6. 人工核验：
   Node fencing
   Storage backend
   volumeHandle
   Snapshot/Backup
   Stateful identity
      │
      ▼
7. Break-Glass 变更单
```

禁止默认路径：`Terminating -> 直接清 Finalizer`。

---

## 11. 生产安全结论

这套工具的设计重点不是“帮你删掉对象”，而是**让错误的强制删除更难发生**。

特别是 `StatefulSet + RWO + CSI + Node NotReady` 场景，必须把 Pod、PV、VolumeAttachment 和真实存储后端视为同一个故障域。

任何自动化平台接入 `exit 30` 时，都必须继续走人工审批，不得把它映射成自动 `patch finalizers=[]`。
