# namespace-terminating-diagnose

Kubernetes Namespace `Terminating` 状态生产级只读诊断 CLI。

当前版本：**v2.0.0**。

`namespace-terminating-diagnose` 用于定位 Namespace 长时间无法删除的真实阻塞点，并把结果统一输出给 **人工运维、Jenkins、运维平台、Prometheus 与 AIOps**。

> 核心原则：**先证明 Namespace 为什么删不掉，再修复真正负责清理的 Controller，最后才考虑 Break-Glass。**
>
> 本工具对 Kubernetes API 严格只读，不执行 `delete`、`patch`、`replace`，也不会调用 Namespace `/finalize`。

---

## 1. v2.0.0 主要变化

v2.0.0 将 v1.0.0 单一诊断流程重构为四个子命令：

```text
check
diagnose
report
force-check
```

新增：

- `--json` 机器可读输出；
- Prometheus textfile collector 指标；
- `NamespaceTerminating > 10m` 集群巡检入口；
- `namespace-terminating-patrol.sh` 巡检包装脚本；
- `PrometheusRule` 告警模板；
- TXT / JSON / `.prom` 三类报告；
- 更严格的 Force Finalize fail-closed 门禁；
- v1.0.0 `--report <file>` 兼容入口；
- 代码模块化拆分，方便后续扩展检查器。

目录：

```text
namespace-terminating-diagnose/
├── README.md
├── namespace-terminating-diagnose.sh
├── namespace-terminating-patrol.sh
├── lib/
│   ├── common.sh
│   ├── resources.sh
│   ├── storage-admission.sh
│   ├── output.sh
│   └── patrol.sh
└── prometheus/
    └── namespace-terminating-alerts.yaml
```

模块职责：

```text
namespace-terminating-diagnose.sh
        │
        ├── lib/common.sh
        │   └── CLI / preflight / logging / 通用函数
        ├── lib/resources.sh
        │   └── Namespace / APIService / 全量资源 / Pod
        ├── lib/storage-admission.sh
        │   └── PVC/PV/VA / CR / Webhook / VAP
        ├── lib/output.sh
        │   └── Verdict / JSON / Prometheus / Report
        └── lib/patrol.sh
            └── NamespaceTerminating 集群巡检
```

---

## 2. 为什么 Namespace 会一直 Terminating

Namespace 删除是一条异步清理链：

```text
kubectl delete namespace
        │
        ▼
delectionTimestamp
        │
        ▼
Namespace Controller
        │
        ├── API Discovery
        ├── 枚举所有 namespaced resources
        ├── Garbage Collection
        ├── 等待 Resource Finalizers
        ├── 等待 Operator / CSI / Cloud Controller
        └── 确认 Namespace 为空
                │
                ▼
         Namespace Finalizer
                │
                ▼
             Deleted
```

常见阻塞包括：

- `APIService` 不可用；
- API Discovery 不完整；
- Pod / Job / Secret / Role 等资源仍存在；
- PVC / PV / VolumeAttachment 未释放；
- CR 仍存在；
- 对象带无法完成的 Finalizer；
- Operator 已提前卸载；
- CSI / Cloud Controller 异常；
- Webhook Service 不存在或无 Ready Endpoint；
- `failurePolicy=Fail` 阻断 DELETE/UPDATE；
- ValidatingAdmissionPolicy 参与删除链；
- Namespace Controller 状态没有收敛。

`kubectl get all -n <ns>` 不能覆盖所有 namespaced resource，所以不能作为“Namespace 已清空”的证明。

---

## 3. 安全设计

### 3.1 Kubernetes API 只读

工具不会执行：

```text
kubectl delete
kubectl patch
kubectl replace
kubectl edit
PUT /api/v1/namespaces/<ns>/finalize
```

### 3.2 Fail-Closed

以下任意场景都会阻止 Force Finalize Ready：

```text
API Discovery 失败
APIService 不可用
资源枚举失败
RBAC 无法 list 某类资源
仍有 namespaced resource
仍有 metadata.finalizers
仍有 CR
仍有 PVC
仍有关联 PV
仍有 VolumeAttachment
Webhook/VAP 有高风险阻塞
Namespace Condition 仍报告剩余内容/Finalizer
删除时长无法验证
```

原则：

```text
无法证明安全
=
不能进入 FORCE-FINALIZE-READY
```

### 3.3 Break-Glass 不是自动修复

`FORCE-FINALIZE-READY` 只表示：

```text
可以进入人工 Break-Glass 复核
```

不表示脚本会执行 `/finalize`。

---

## 4. 安装与基础使用

依赖：

```text
Bash >= 4
kubectl
jq
GNU date
```

建议克隆后赋执行权限：

```bash
chmod +x namespace-terminating-diagnose.sh
chmod +x namespace-terminating-patrol.sh
```

查看版本：

```bash
./namespace-terminating-diagnose.sh --version
```

查看帮助：

```bash
./namespace-terminating-diagnose.sh --help
```

---

## 5. 四个子命令

### 5.1 check

轻量检查：

```bash
./namespace-terminating-diagnose.sh check -n test
```

检查：

```text
Namespace phase
delectionTimestamp
Terminating age
Namespace Conditions
Namespace spec.finalizers
APIService Available
Aggregated API backend 是否位于目标 Namespace
```

`check` 不做完整资源扫描，因此**永远不会**声明 `FORCE-FINALIZE-READY`。

如果 Namespace 已处于 Terminating，通常返回：

```text
WARNING
exit 10
```

建议继续：

```bash
./namespace-terminating-diagnose.sh diagnose -n test
```

### 5.2 diagnose

完整根因诊断：

```bash
./namespace-terminating-diagnose.sh diagnose -n test
```

链路：

```text
Namespace State
      ↓
APIService
      ↓
Full Namespaced Resource Scan
      ↓
Pod
      ↓
PVC / PV / VolumeAttachment
      ↓
CRD / Custom Resource
      ↓
Webhook / VAP
      ↓
Risk Summary
      ↓
SAFE / WARNING / DANGEROUS
```

### 5.3 report

完整诊断并生成审计文件：

```bash
./namespace-terminating-diagnose.sh report \
  -n test \
  --output-dir /data/logs/namespace-terminating-diagnose
```

输出：

```text
test-YYYYmmdd-HHMMSS.txt
test-YYYYmmdd-HHMMSS.json
test-YYYYmmdd-HHMMSS.prom
```

用于：

- 故障复盘；
- Jenkins Artifact；
- AIOps 工单附件；
- Prometheus textfile collector；
- Force Finalize 前的审计证据。

### 5.4 force-check

严格判断是否满足人工 Force Finalize 前置条件：

```bash
./namespace-terminating-diagnose.sh force-check \
  -n test \
  --threshold 900
```

必须同时满足：

```text
Namespace = Terminating
Terminating age >= threshold
Full namespaced resource scan = 0
Object finalizers = 0
Custom Resources = 0
PVC = 0
Namespace-related PV = 0
VolumeAttachment = 0
APIService = Healthy
Admission = no high-risk blocker
Namespace Conditions = no active blocker
scan_errors = 0
force_blockers = 0
```

才返回：

```text
FORCE-FINALIZE-READY
exit 30
```

`exit 30` 适合在 Jenkins 中作为**人工审批门**，不是“已执行 finalize”。

---

## 6. Verdict 与 Exit Code

| Verdict | Exit Code | 含义 |
|---|---:|---|
| `SAFE` | `0` | 未发现高风险阻塞 |
| `WARNING` | `10` | 有剩余资源、暂时性状态或验证不完整 |
| `DANGEROUS` | `20` | 存在明确高风险阻塞或外部资源风险 |
| `FORCE-FINALIZE-READY` | `30` | 仅 `force-check`：满足人工 Break-Glass 前置条件 |
| 参数/API 基础错误 | `64` | 工具无法完成基础检查 |

推荐 Jenkins 分流：

```text
0  -> PASS
10 -> UNSTABLE / 继续诊断
20 -> FAIL / 禁止 Force Finalize
30 -> INPUT APPROVAL
64 -> TOOL / RBAC / API ERROR
```

---

## 7. `--json` 机器可读输出

```bash
./namespace-terminating-diagnose.sh diagnose \
  -n test \
  --json
```

stdout 只输出 JSON，不混入彩色诊断日志。

核心结构：

```json
{
  "schema_version": "1",
  "tool": "namespace-terminating-diagnose",
  "version": "2.0.0",
  "command": "diagnose",
  "namespace": {
    "name": "test",
    "phase": "Terminating",
    "deletion_timestamp": "2026-09-02T01:00:00Z",
    "terminating_age_seconds": 1200,
    "spec_finalizers": ["kubernetes"]
  },
  "threshold_seconds": 600,
  "verdict": "WARNING",
  "exit_code": 10,
  "force_finalize_ready": false,
  "counts": {
    "remaining_objects": 2,
    "terminating_objects": 2,
    "objects_with_finalizers": 1,
    "custom_resources": 0,
    "pvc": 1,
    "related_pv": 1,
    "volume_attachments": 1,
    "scan_errors": 0
  },
  "warnings": [],
  "dangers": [],
  "force_blockers": [],
  "remaining_resources": [],
  "finalizer_objects": [],
  "unavailable_apiservices": []
}
```

AIOps 建议重点消费：

```text
namespace.name
namespace.phase
namespace.terminating_age_seconds
verdict
exit_code
force_finalize_ready
counts.*
warnings[]
dangers[]
force_blockers[]
remaining_resources[]
finalizer_objects[]
unavailable_apiservices[]
```

---

## 8. NamespaceTerminating > 10m 巡检

主脚本入口：

```bash
./namespace-terminating-diagnose.sh \
  check \
  --all-terminating \
  --threshold 600
```

`600s = 10m`。

存在超过阈值的 Namespace 时：

```text
VERDICT: WARNING
Exit: 10
```

### 巡检包装脚本

```bash
./namespace-terminating-patrol.sh
```

等价于：

```bash
./namespace-terminating-diagnose.sh \
  check \
  --all-terminating \
  --threshold 600
```

修改阈值：

```bash
export NAMESPACE_TERMINATING_THRESHOLD=900
./namespace-terminating-patrol.sh
```

JSON：

```bash
./namespace-terminating-patrol.sh --json
```

巡检 JSON 结构：

```json
{
  "command": "check",
  "mode": "all-terminating",
  "threshold_seconds": 600,
  "verdict": "WARNING",
  "exit_code": 10,
  "counts": {
    "terminating": 2,
    "over_threshold": 1,
    "unknown_age": 0
  },
  "namespaces": [
    {
      "namespace": "test",
      "phase": "Terminating",
      "deletion_timestamp": "2026-09-02T01:00:00Z",
      "age_seconds": 1800,
      "over_threshold": true
    }
  ]
}
```

---

## 9. Prometheus 指标

### 单 Namespace

```bash
./namespace-terminating-diagnose.sh diagnose \
  -n test \
  --prometheus-output /tmp/test.prom
```

指标：

```text
namespace_terminating_diagnose_info
namespace_terminating_diagnose_terminating_age_seconds
namespace_terminating_diagnose_remaining_objects
namespace_terminating_diagnose_terminating_objects
namespace_terminating_diagnose_objects_with_finalizers
namespace_terminating_diagnose_custom_resources
namespace_terminating_diagnose_pvc
namespace_terminating_diagnose_related_pv
namespace_terminating_diagnose_volume_attachments
namespace_terminating_diagnose_scan_errors
namespace_terminating_diagnose_force_finalize_ready
namespace_terminating_diagnose_generated_timestamp_seconds
```

### 集群巡检

```bash
./namespace-terminating-patrol.sh \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/namespace_terminating.prom
```

指标：

```text
namespace_terminating_diagnose_patrol_terminating_total
namespace_terminating_diagnose_patrol_over_threshold_total
namespace_terminating_diagnose_patrol_unknown_age_total
namespace_terminating_diagnose_namespace_terminating{namespace="..."}
namespace_terminating_diagnose_namespace_terminating_age_seconds{namespace="..."}
namespace_terminating_diagnose_namespace_over_threshold{namespace="...",threshold_seconds="600"}
namespace_terminating_diagnose_generated_timestamp_seconds{mode="patrol"}
```

指标文件采用：

```text
临时文件
  ↓
完整写入
  ↓
mv 原子替换
```

避免 Node Exporter 抓到半写入文件。

---

## 10. PrometheusRule

项目提供：

```text
prometheus/namespace-terminating-alerts.yaml
```

应用：

```bash
kubectl apply -f \
  namespace-terminating-diagnose/prometheus/namespace-terminating-alerts.yaml
```

包含：

### NamespaceTerminatingOverThreshold

```promql
namespace_terminating_diagnose_namespace_over_threshold == 1
```

### NamespaceTerminatingPatrolStale

同时检测指标缺失和超过 15 分钟未更新：

```promql
absent(
  namespace_terminating_diagnose_generated_timestamp_seconds{mode="patrol"}
)
or
(
  time()
  - namespace_terminating_diagnose_generated_timestamp_seconds{mode="patrol"}
  > 900
)
```

### NamespaceTerminatingPatrolUnknownAge

```promql
namespace_terminating_diagnose_patrol_unknown_age_total > 0
```

---

## 11. Cron / Node Exporter

每 5 分钟巡检：

```cron
*/5 * * * * /opt/namespace-terminating-diagnose/namespace-terminating-patrol.sh --prometheus-output /var/lib/node_exporter/textfile_collector/namespace_terminating.prom >> /var/log/namespace-terminating-patrol.log 2>&1
```

注意：

```text
exit 10
```

代表“发现超阈值 Namespace”，属于业务告警状态，不是工具崩溃。

---

## 12. Jenkins 集成

巡检：

```groovy
stage('Namespace Terminating Patrol') {
    steps {
        script {
            int rc = sh(
                script: '''
                  ./namespace-terminating-diagnose/namespace-terminating-patrol.sh \
                    --json > namespace-terminating.json
                ''',
                returnStatus: true
            )

            archiveArtifacts artifacts: 'namespace-terminating.json'

            if (rc == 10) {
                unstable('存在 Namespace Terminating 超过 10 分钟')
            } else if (rc != 0) {
                error("namespace patrol failed, exit=${rc}")
            }
        }
    }
}
```

报告任务建议同样使用 `returnStatus`，因为 `report` 会保留诊断 Verdict 的 Exit Code：

```groovy
int rc = sh(
    script: '''
      ./namespace-terminating-diagnose/namespace-terminating-diagnose.sh \
        report \
        -n "${TARGET_NAMESPACE}" \
        --output-dir namespace-report
    ''',
    returnStatus: true
)

archiveArtifacts artifacts: 'namespace-report/**'
```

---

## 13. 完整诊断范围

### Namespace

```text
phase
delectionTimestamp
terminating age
spec.finalizers
status.conditions
```

重点 Condition：

```text
NamespaceDeletionDiscoveryFailure
NamespaceDeletionGroupVersionParsingFailure
NamespaceDeletionContentFailure
NamespaceContentRemaining
NamespaceFinalizersRemaining
```

### APIService

识别：

```text
Available != True
APIService backend Service 位于待删除 Namespace
```

### Full Namespaced Resource Scan

```bash
kubectl api-resources \
  --verbs=list \
  --namespaced \
  -o name
```

然后逐个 `kubectl get <resource> -n <namespace> -o json`。

### Pod

检查：

```text
phase
nodeName
Node Ready
deletionTimestamp
finalizers
```

### Storage

检查：

```text
PVC
PV claimRef.namespace
PV phase
reclaimPolicy
PV finalizers
VolumeAttachment
```

重点 Finalizer：

```text
kubernetes.io/pvc-protection
kubernetes.io/pv-protection
external-provisioner.volume.kubernetes.io/finalizer
```

### CR / Operator

通过 Namespaced CRD 自动识别剩余 CR。只要仍有 CR，工具判为高风险，要求先确认对应 Operator / Finalizer。

### Admission

检查：

```text
ValidatingWebhookConfiguration
MutatingWebhookConfiguration
ValidatingAdmissionPolicy
ValidatingAdmissionPolicyBinding
```

重点：

```text
DELETE / UPDATE / *
+
failurePolicy=Fail
+
Service missing / no ready endpoint
```

---

## 14. RBAC

完整 `diagnose / report / force-check` 至少需要读取：

```text
namespaces
nodes
pods
persistentvolumeclaims
persistentvolumes
volumeattachments
apiservices
customresourcedefinitions
validatingwebhookconfigurations
mutatingwebhookconfigurations
validatingadmissionpolicies
validatingadmissionpolicybindings
```

同时需要对集群中所有支持：

```text
verbs=list
namespaced=true
```

的资源执行 `list`。

生产环境建议使用专用只读 ServiceAccount / kubeconfig，只授予 `get/list`，不要授予 `delete/patch/update`。

---

## 15. 与 kube-state-metrics 的关系

已有 kube-state-metrics 时，可通过：

```promql
kube_namespace_status_phase{phase="Terminating"} == 1
```

做基础监控。

本工具不替代 kube-state-metrics，而是补充：

```text
Terminating age
统一 Exit Code
JSON 巡检接口
自动 diagnose/report 链路
Force Finalize 门禁
```

推荐：

```text
kube-state-metrics
    └── 基础状态告警

namespace-terminating-diagnose
    ├── 工程巡检
    ├── 自动诊断
    ├── 结构化报告
    └── Break-Glass Gate
```

---

## 16. v1.0.0 迁移

v1.0.0：

```bash
./namespace-terminating-diagnose.sh \
  -n test \
  --report /tmp/test.log
```

v2.0.0：

```bash
./namespace-terminating-diagnose.sh \
  diagnose \
  -n test \
  --report /tmp/test.log
```

推荐新系统使用：

```bash
./namespace-terminating-diagnose.sh \
  report \
  -n test \
  --output-dir /tmp/ns-report
```

---

## 17. Break-Glass 清单

即使 `FORCE-FINALIZE-READY`，也必须人工确认：

```text
[ ] Namespace 确实应该永久删除
[ ] 业务 Owner 同意
[ ] 数据 Owner 同意
[ ] PVC/PV 已确认
[ ] 云盘/共享存储已确认
[ ] LoadBalancer / DNS / EIP 已确认
[ ] 数据库 Operator 外部资源已确认
[ ] Snapshot / Backup 已确认
[ ] Operator 不再需要完成清理
[ ] CSI / Cloud Controller 不再需要完成清理
[ ] 已保存 report / JSON
[ ] 已制定 Force Finalize 后 Orphan Audit
```

工具不会执行 `/finalize`。

---

## 18. 推荐生产链路

```text
check --all-terminating
        │
        ├── <= 10m -> SAFE
        │
        └── > 10m -> WARNING
                       │
                       ▼
                 diagnose --json
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
        SAFE        WARNING      DANGEROUS
                                  │
                                  ▼
                             修复 Controller
                                  │
                                  ▼
                               report
                                  │
                                  ▼
                             force-check
                                  │
                                  ▼
                    FORCE-FINALIZE-READY
                                  │
                                  ▼
                         人工 Break-Glass
```

推荐流程：

```text
巡检
→ 诊断
→ 修复根因
→ 报告
→ Force Gate
→ 人工审批
```

而不是：

```text
Terminating
→ finalizers=[]
```
