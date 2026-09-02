# namespace-terminating-diagnose

Kubernetes Namespace `Terminating` 状态生产级只读诊断工具。

`namespace-terminating-diagnose.sh` 用于定位 Namespace 长时间无法删除的真实阻塞点，自动检查 Namespace Conditions、APIService、全部 namespaced resources、Finalizer、Pod、PVC/PV/VolumeAttachment、Custom Resource、Admission Webhook 与 ValidatingAdmissionPolicy，并最终输出统一风险判定。

当前版本：**v1.0.0**。

> 核心原则：**先证明 Namespace 为什么删不掉，再修复真正负责清理的 Controller，最后才考虑 Break-Glass。**
>
> 本工具严格只读，不执行 `delete`、`patch`、`replace`，也不会调用 Namespace `/finalize` 接口。

---

## 1. 设计目标

Kubernetes Namespace 删除不是 API Server 直接从 etcd 删除对象，而是由 Namespace Controller、Garbage Collector、各种 Operator/CSI/Cloud Controller 共同完成的异步清理流程。

一个 Namespace 长时间处于：

```text
Terminating
```

常见原因包括：

- Namespace Controller 无法完成 API Discovery；
- 某个 `APIService` 不可用；
- Namespace 内仍存在 Pod、Secret、Role、PVC、Job 等普通资源；
- Namespace 内仍存在 CR；
- Pod/PVC/CR 等对象存在无法完成的 Finalizer；
- PVC/PV/VolumeAttachment 存储清理没有完成；
- 对应 Operator/CSI Controller 已经先被删除；
- Admission Webhook 后端不存在或无 Ready Endpoint；
- `failurePolicy=Fail` 的 Webhook/VAP 阻断 DELETE/UPDATE/PATCH；
- Namespace Controller 自身无法正常收敛。

本工具目标不是自动“修掉 Finalizer”，而是建立统一诊断链路：

```text
Discover
   ↓
Locate
   ↓
Classify
   ↓
Repair
   ↓
Verify
   ↓
Break-Glass Review
```

而不是：

```text
Terminating
   ↓
finalizers=[]
```

---

## 2. 核心安全原则

### 2.1 严格只读

脚本只执行 Kubernetes API 的读取操作。

不会执行：

```text
kubectl delete
kubectl patch
kubectl replace
kubectl edit
PUT /api/v1/namespaces/<ns>/finalize
```

所以工具本身可以作为生产环境的第一阶段诊断入口。

### 2.2 Fail-Closed

无法证明安全时，不会给出 `FORCE-FINALIZE-READY`。

例如出现以下任一情况：

```text
API Discovery 无法完整执行
APIService Available != True
无法 list 某个 Namespaced Resource
PVC 仍存在
关联 PV 仍处于 Bound/Terminating
VolumeAttachment 仍存在
Custom Resource 仍存在
对象 metadata.finalizers 仍存在
Webhook 后端异常且 failurePolicy=Fail
VAP 可能阻塞 DELETE/UPDATE
```

都会阻止进入强制 Finalize 前置状态。

### 2.3 Finalizer 是线索，不是故障本身

例如看到：

```text
kubernetes.io/pvc-protection
external-provisioner.volume.kubernetes.io/finalizer
example.io/finalizer
```

不意味着应该立即删除 Finalizer。

它更可能意味着：

```text
存储仍被 Pod 使用
CSI DeleteVolume 尚未完成
Operator 外部资源清理失败
Controller 已经失联
Admission 阻止了 Finalizer PATCH
```

因此推荐：

```text
修 Controller / 外部资源
        ↓
等待 Finalizer 正常完成
        ↓
重新诊断
```

---

## 3. 目录结构

```text
namespace-terminating-diagnose/
├── README.md
└── namespace-terminating-diagnose.sh
```

职责：

```text
README.md
  └── 原理、诊断链路、风险等级、使用方法、生产 SOP

namespace-terminating-diagnose.sh
  └── Kubernetes Namespace Terminating 只读自动诊断
```

---

## 4. 总体架构

```text
                    namespace-terminating-diagnose.sh
                                  │
                                  ▼
                         Kubernetes API
                                  │
          ┌───────────────────────┼────────────────────────┐
          │                       │                        │
          ▼                       ▼                        ▼
 Namespace State            API Discovery             Admission
 Conditions                 APIService                Webhook / VAP
 finalizers                     │                        │
 deletionTimestamp              │                        │
          │                      ▼                        │
          │             Namespaced Resources             │
          │                      │                        │
          │          ┌───────────┼────────────┐           │
          │          │           │            │           │
          ▼          ▼           ▼            ▼           ▼
       Pod Check    PVC         CR/CRD      Finalizer   Webhook
          │          │           │            │         Backend
          │          ▼           │            │
          │         PV           │            │
          │          │           │            │
          │          ▼           │            │
          │   VolumeAttachment   │            │
          │          │           │            │
          └──────────┴───────────┴────────────┘
                                  │
                                  ▼
                           Risk Aggregation
                                  │
              ┌───────────────────┼────────────────────┐
              │                   │                    │
              ▼                   ▼                    ▼
             SAFE              WARNING             DANGEROUS
                                                       │
                                                       │
                                  条件全部满足          │
                                      │                │
                                      ▼                │
                           FORCE-FINALIZE-READY        │
                                      │                │
                                      └──────┬─────────┘
                                             ▼
                                  人工 Break-Glass 复核
```

---

## 5. 自动检查项

脚本当前按以下顺序执行。

### 5.1 Preflight

检查：

- Bash 版本；
- `kubectl`；
- `jq`；
- 当前 kubeconfig Context；
- Kubernetes API 连通性；
- 目标 Namespace 可读取性。

### 5.2 Namespace State / Conditions

读取：

```bash
kubectl get namespace <namespace> -o json
```

重点检查：

```text
status.phase
metadata.deletionTimestamp
spec.finalizers
status.conditions
```

识别以下 Condition：

```text
NamespaceDeletionDiscoveryFailure
NamespaceDeletionGroupVersionParsingFailure
NamespaceDeletionContentFailure
NamespaceContentRemaining
NamespaceFinalizersRemaining
```

### 5.3 APIService / Aggregated API

检查：

```bash
kubectl get apiservice
```

只要存在：

```text
Available != True
```

就按高风险处理。

另外还会识别：

```text
APIService.spec.service.namespace == TARGET_NAMESPACE
```

因为删除目标 Namespace 本身可能直接破坏 Aggregated API Backend，进一步阻断 Namespace Controller Discovery。

### 5.4 完整 Namespaced Resource Scan

脚本不依赖：

```bash
kubectl get all
```

因为 `get all` 并不包含全部 Kubernetes Namespaced Resource。

脚本使用：

```bash
kubectl api-resources \
  --verbs=list \
  --namespaced \
  -o name
```

然后逐一：

```bash
kubectl get <resource> \
  -n <namespace> \
  --ignore-not-found \
  -o json
```

统计：

- 剩余对象总数；
- `deletionTimestamp != null` 的对象；
- `metadata.finalizers` 非空的对象；
- 无法 List 的 Resource。

只要任何 Resource 无法读取，脚本就不会证明 Namespace 已经安全清空。

### 5.5 Pod Deep Check

检查：

```text
Pod Phase
Pod deletionTimestamp
Pod finalizers
Pod 所在 Node
Node Ready 状态
```

可用于辅助定位：

```text
Node 已永久 NotReady
Pod 长时间 Terminating
Job Tracking Finalizer
preStop / graceful termination 异常
```

### 5.6 PVC / PV / VolumeAttachment

检查：

```text
PVC
  ↓
关联 PV
  ↓
PersistentVolumeReclaimPolicy
  ↓
PV Finalizer
  ↓
VolumeAttachment
```

重点识别：

```text
kubernetes.io/pvc-protection
kubernetes.io/pv-protection
external-provisioner.volume.kubernetes.io/finalizer
```

存在 PVC 或高风险 PV/VolumeAttachment 时，禁止进入 Force Finalize Ready。

### 5.7 CRD / Custom Resource

读取全部：

```bash
kubectl get crd
```

筛选：

```text
spec.scope == Namespaced
```

再与前面的完整资源扫描结果交叉比对。

只要 Namespace 中仍有 Custom Resource：

```text
CR remains
```

就进入 `DANGEROUS`。

原因是 CR 通常意味着对应 Operator 仍有外部资源、状态机或 Finalizer 需要完成。

### 5.8 Admission Webhook

检查：

```text
ValidatingWebhookConfiguration
MutatingWebhookConfiguration
```

重点分析：

```text
operations:
  DELETE
  UPDATE
  *

failurePolicy: Fail
```

并进一步检查 Webhook Backend：

```text
Service
  ↓
EndpointSlice
  ↓
Ready Endpoint
```

如果：

```text
failurePolicy=Fail
+
Service 不存在 / 无 Ready Endpoint
```

则视为高风险删除链路阻塞。

### 5.9 ValidatingAdmissionPolicy

如果集群支持：

```text
validatingadmissionpolicies
validatingadmissionpolicybindings
```

脚本会检查可能涉及：

```text
DELETE
UPDATE
*
```

的 Policy。

尤其关注：

```text
failurePolicy=Fail
validationActions=Deny
```

以及：

```text
paramRef.namespace == TARGET_NAMESPACE
```

因为目标 Namespace 删除过程中，Policy 参数对象本身可能先消失，从而产生删除顺序死锁。

---

## 6. 四级风险判定

脚本统一输出以下四种 Verdict。

| Verdict | Exit Code | 含义 | 建议 |
|---|---:|---|---|
| `SAFE` | `0` | 未发现高风险删除阻塞 | 正常观察 Namespace Controller 收敛 |
| `WARNING` | `10` | 仍有普通资源、暂时性 Terminating 对象或未完全验证项 | 继续等待或修复后重新诊断 |
| `DANGEROUS` | `20` | 存在存储、CR、Finalizer、APIService、Admission 等高风险阻塞 | 禁止强制 Finalize |
| `FORCE-FINALIZE-READY` | `30` | 已满足进入人工 Break-Glass 复核的前置条件 | 人工确认外部资源后再决定是否 `/finalize` |

### 6.1 SAFE

例如：

```text
Namespace 刚进入 Terminating
APIService 正常
没有高风险 Finalizer
没有 Storage/CR/Admission 问题
```

此时优先：

```text
继续等待 Controller 正常完成删除
```

而不是立即 Force Finalize。

### 6.2 WARNING

典型情况：

```text
普通资源仍在删除
NamespaceContentRemaining=True
Terminating 时间还没有超过阈值
某项检查只能部分验证
```

说明当前还没有证据进入 Break-Glass。

### 6.3 DANGEROUS

出现以下任一类问题通常会进入：

```text
DANGEROUS
```

例如：

```text
NamespaceFinalizersRemaining=True
NamespaceDeletionDiscoveryFailure=True
APIService Available=False
PVC remains
PV Bound/Terminating
VolumeAttachment remains
Custom Resource remains
Object metadata.finalizers != []
Fail Webhook Backend unavailable
VAP paramRef located in target Namespace
```

这类情况应该修复根因，而不是清空 Namespace Finalizer。

### 6.4 FORCE-FINALIZE-READY

只有满足类似以下条件时才会进入：

```text
Namespace.phase == Terminating
        +
Terminating age >= threshold
        +
Remaining Namespaced Resource == 0
        +
Object Finalizer == 0
        +
APIService Discovery 正常
        +
PVC / 高风险 PV / VolumeAttachment == 0
        +
Custom Resource == 0
        +
Admission 无已知高风险阻塞
        +
SCAN_ERRORS == 0
        +
FORCE_BLOCKERS == 0
```

注意：

```text
FORCE-FINALIZE-READY
```

不是：

```text
SAFE TO DELETE EXTERNAL RESOURCES
```

它只是说明 Kubernetes API 层面的只读检查没有发现已知阻塞，可以进入人工 Break-Glass Review。

---

## 7. 环境要求

### 7.1 Bash

要求：

```text
Bash >= 4
```

脚本使用：

```text
declare -A
mapfile
process substitution
Bash arrays
```

### 7.2 必需命令

```text
kubectl
jq
date
```

其中 `date` 推荐 GNU coreutils 版本，因为脚本使用：

```bash
date -d <RFC3339 timestamp> +%s
```

如果无法解析 `deletionTimestamp`：

```text
FORCE-FINALIZE-READY
```

会被主动禁用。

### 7.3 Kubernetes 版本

推荐：

```text
Kubernetes v1.34+
```

脚本对 ValidatingAdmissionPolicy 做能力探测，不支持该 API 的集群会自动跳过对应检查。

---

## 8. Kubernetes 权限要求

脚本是只读工具，但为了完成完整诊断，执行账号需要同时拥有 Namespaced 和 Cluster-Scoped Resource 的 `get/list` 权限。

典型权限包括：

```text
namespaces
nodes
persistentvolumes
volumeattachments
customresourcedefinitions
apiservices
validatingwebhookconfigurations
mutatingwebhookconfigurations
validatingadmissionpolicies
validatingadmissionpolicybindings
所有可 list 的 namespaced resources
```

生产上建议使用独立诊断账号，并遵循最小权限原则。

可以先检查：

```bash
kubectl auth can-i get namespace <namespace>
kubectl auth can-i list apiservices.apiregistration.k8s.io
kubectl auth can-i list persistentvolumes
kubectl auth can-i list volumeattachments.storage.k8s.io
kubectl auth can-i list customresourcedefinitions.apiextensions.k8s.io
```

如果权限不足，脚本会产生 Scan Error，并阻止 `FORCE-FINALIZE-READY`。

---

## 9. 命令行参数

查看帮助：

```bash
./namespace-terminating-diagnose.sh --help
```

参数：

| 参数 | 默认值 | 含义 |
|---|---:|---|
| `-n, --namespace` | 无 | 目标 Namespace，必填 |
| `--request-timeout` | `10s` | 单次 kubectl API 请求超时 |
| `--threshold` | `300` | Terminating 超过多少秒才允许 FORCE-READY 评估 |
| `--max-details` | `20` | 每类详细对象最多输出数量 |
| `--report` | 空 | 同时保存完整诊断报告 |
| `--no-color` | false | 禁用终端颜色 |
| `-V, --version` | - | 输出版本 |

---

## 10. 使用方法

### 10.1 基础诊断

```bash
chmod +x namespace-terminating-diagnose.sh

./namespace-terminating-diagnose.sh \
  -n test
```

### 10.2 生产环境建议

建议同时保存报告：

```bash
./namespace-terminating-diagnose.sh \
  -n pro-yunfan \
  --threshold 900 \
  --report /tmp/pro-yunfan-namespace-diagnose.log
```

这样可以把本次诊断结果作为：

```text
故障记录
变更审批证据
Break-Glass 前置证据
事后复盘资料
```

### 10.3 CI / 自动化平台

脚本 Exit Code 可以直接接 Jenkins、巡检平台或 AIOps：

```bash
./namespace-terminating-diagnose.sh -n test
rc=$?

case "$rc" in
  0)
    echo "SAFE"
    ;;
  10)
    echo "WARNING"
    ;;
  20)
    echo "DANGEROUS"
    ;;
  30)
    echo "FORCE-FINALIZE-READY"
    ;;
  *)
    echo "TOOL ERROR"
    ;;
esac
```

---

## 11. 推荐生产排障流程

统一使用：

```text
Namespace Terminating
        │
        ▼
1. Namespace Conditions
        │
        ▼
2. APIService / Discovery
        │
        ▼
3. 完整 Namespaced Resource Scan
        │
        ▼
4. deletionTimestamp / Finalizers
        │
        ├──────────┐
        │          │
        ▼          ▼
5. Pod        6. PVC / PV / VA
        │          │
        └─────┬────┘
              ▼
7. CR / Operator
              │
              ▼
8. Webhook / VAP
              │
              ▼
9. Risk Verdict
              │
      ┌───────┼─────────────┐
      │       │             │
     SAFE   WARNING      DANGEROUS
                             │
                             ▼
                       修复真实根因
                             │
                             ▼
                         重新诊断

仅当所有前置条件满足：

FORCE-FINALIZE-READY
        │
        ▼
人工 Break-Glass Review
```

---

## 12. 常见故障场景

### 12.1 Pod 一直 Terminating

重点查看：

```text
Pod deletionTimestamp
Pod finalizers
Node Ready
OwnerReferences
```

如果 Node 已经永久失联，要特别注意有状态应用和 RWO 存储，避免强制删除 Pod 后产生双写或 split-brain。

### 12.2 PVC 一直 Terminating

常见：

```text
kubernetes.io/pvc-protection
```

优先确认：

```text
是否仍被 Pod 使用
PV 状态
VolumeAttachment
CSI Controller
```

### 12.3 PV / CSI 删除失败

重点查看：

```text
PV phase
reclaimPolicy
PV deletionTimestamp
external-provisioner.volume.kubernetes.io/finalizer
VolumeAttachment
```

不要直接清 CSI Finalizer，否则可能产生实际云盘泄漏或后端存储状态不一致。

### 12.4 CR / Operator Finalizer

典型错误顺序：

```text
先删除 Operator
      ↓
再删除 CR
      ↓
Finalizer 没有 Controller 处理
      ↓
Namespace 永久 Terminating
```

推荐：

```text
删除 CR
   ↓
Operator 完成清理
   ↓
Finalizer 消失
   ↓
删除 Operator
   ↓
删除 CRD / Namespace
```

### 12.5 APIService Discovery Failure

例如：

```text
metrics-server
prometheus-adapter
custom metrics adapter
aggregated apiserver
```

如果 APIService 已注册但 Backend 不可用，Namespace Controller 可能无法证明 Namespace 已清空。

### 12.6 Admission Webhook 阻塞删除

典型组合：

```text
WebhookConfiguration exists
        +
Webhook Service deleted
        +
failurePolicy=Fail
        ↓
DELETE / UPDATE 被拒绝
        ↓
Finalizer 无法更新
        ↓
Namespace Terminating
```

---

## 13. Break-Glass 边界

只有脚本输出：

```text
VERDICT: FORCE-FINALIZE-READY
```

才建议进入人工复核。

但在真正调用 `/finalize` 前，至少必须确认：

```text
[ ] Namespace 确实应该删除
[ ] 业务 Owner 已确认
[ ] 数据 Owner 已确认
[ ] 不存在需要保留的 PVC/PV 数据
[ ] 不存在云盘残留
[ ] 不存在 LoadBalancer / 公网 IP / DNS 残留
[ ] 不存在数据库 Operator 外部资源
[ ] 不存在 Snapshot / Backup 残留
[ ] CSI / Operator / Cloud Controller 不再需要完成清理
[ ] 已保存 Namespace YAML
[ ] 已保存本工具诊断报告
[ ] 已准备 Force Finalize 后的 Orphan Resource Audit
```

本脚本不会自动执行这一步。

---

## 14. 强制 Finalize 后的审计建议

如果最终人工执行了 Namespace `/finalize`，不能以：

```bash
kubectl get namespace
```

发现 Namespace 消失作为故障结束条件。

至少继续检查：

```bash
kubectl get pv
kubectl get volumeattachments
kubectl get apiservice
kubectl get crd
```

同时根据环境检查：

```text
云盘
NFS/NAS
Ceph/RBD
Longhorn Volume
LoadBalancer
公网 IP
Security Group
ENI
DNS
Snapshot
Backup
数据库实例
```

目标是确认不存在 Orphaned Infrastructure。

---

## 15. 输出示例

### 15.1 高风险存储场景

```text
== 8. Risk Summary ==
[INFO] remaining namespaced objects : 3
[INFO] objects with finalizers      : 2
[INFO] remaining Custom Resources   : 1

Danger findings:
  - persistentvolumeclaims has object(s) with metadata.finalizers
  - PV pvc-xxxx still has CSI backend-deletion protection finalizer
  - VolumeAttachment remains
  - Custom Resource remains

== 9. Final Verdict ==
VERDICT: DANGEROUS
Exit   : 20
```

### 15.2 满足 Break-Glass 前置条件

```text
== 8. Risk Summary ==
[INFO] remaining namespaced objects : 0
[INFO] terminating objects          : 0
[INFO] objects with finalizers      : 0
[INFO] remaining Custom Resources   : 0
[INFO] scan errors                  : 0

== 9. Final Verdict ==
VERDICT: FORCE-FINALIZE-READY
Exit   : 30
```

---

## 16. Exit Code

| Code | Meaning |
|---:|---|
| `0` | SAFE |
| `10` | WARNING |
| `20` | DANGEROUS |
| `30` | FORCE-FINALIZE-READY |
| `64` | 参数、依赖或 Kubernetes 基础访问错误 |

注意：

```text
30 != success
```

`30` 是专门设计给自动化平台识别的“需要人工 Break-Glass Review”状态。

---

## 17. 已知边界

当前 v1.0.0 仍有以下边界：

1. 无法直接确认 AWS/Azure/阿里云等云平台中的真实磁盘/LB/DNS 是否已删除；
2. 无法理解任意第三方 Finalizer 的具体业务语义；
3. Admission Webhook 的 `namespaceSelector` / `objectSelector` 是否真正匹配目标对象，目前采用保守风险判断；
4. 无法替代 CSI/Operator Controller 日志分析；
5. 不自动读取 kube-controller-manager 日志；
6. 不执行任何修复动作；
7. 不自动 Force Finalize。

这些边界是刻意保留的安全设计，而不是通过扩大脚本写权限来解决。

---

## 18. 后续工程规划

建议后续版本继续演进：

```text
v1.1
├── check
├── diagnose
├── report
└── force-check
```

增加：

- `--json` 机器可读输出；
- `--quiet` 自动化模式；
- Finalizer Owner / Controller 映射；
- CSI Controller 健康关联；
- Operator Deployment 自动关联；
- kube-controller-manager Namespace 日志提示；
- Prometheus Exporter；
- `NamespaceTerminating > N minutes` 集群巡检模式；
- Jenkins / AIOps 集成；
- 独立只读 RBAC Manifest；
- GitHub Actions `bash -n + ShellCheck`。

---

## 19. 生产原则总结

推荐把 Namespace Terminating 的处理原则统一为：

```text
先看 Condition
     ↓
再看 Discovery
     ↓
再枚举全部资源
     ↓
定位 Finalizer Owner
     ↓
检查 Storage / CR / Admission
     ↓
修 Controller / 外部资源
     ↓
重新验证
     ↓
最后才考虑 Break-Glass
```

一句话：

> **Finalizer 是 Kubernetes 用来保护真实清理事务的机制。生产环境中最危险的操作不是 Namespace Terminating，而是在不知道 Finalizer 为什么存在时把它直接删除。**
