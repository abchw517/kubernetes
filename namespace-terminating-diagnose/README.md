# namespace-terminating-diagnose

Kubernetes Namespace `Terminating` 状态生产级只读诊断 CLI。

当前版本：**v2.1.0**。

`namespace-terminating-diagnose` 用于定位 Namespace 长时间无法删除的真实阻塞点，并把诊断结果统一输出给人工运维、Jenkins、运维平台、Prometheus 与 AIOps。

> 核心原则：**先证明 Namespace 为什么删不掉，再修复真正负责清理的 Controller，最后才考虑 Break-Glass。**
>
> 本工具对 Kubernetes API 严格只读，不执行 `delete`、`patch`、`replace`、`apply`、`create`，也不会调用 Namespace `/finalize`。

---

## 1. 版本演进

### v2.1.0 Production Delivery Gate

v2.1.0 在 v2.0.0 CLI 基础上补齐生产交付能力：

- 只读 RBAC Manifest；
- 项目级 GitHub Actions Contract Gate；
- `bash -n`；
- ShellCheck；
- Secret Scan；
- JSON Schema Contract；
- mock `kubectl` E2E；
- Verdict / Exit Code Contract；
- Prometheus textfile 输出 Contract；
- RBAC 零写权限静态检查；
- Shell 生产代码只读静态 Guard。

### v2.0.0 Platform CLI

v2.0.0 将单一诊断流程重构为：

```text
check
diagnose
report
force-check
```

并增加：

- `--json`；
- Prometheus textfile collector；
- `NamespaceTerminating > 10m` 巡检；
- TXT / JSON / `.prom` 三类报告；
- `FORCE-FINALIZE-READY` fail-closed 门禁。

---

## 2. 当前目录结构

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
├── prometheus/
│   └── namespace-terminating-alerts.yaml
├── rbac/
│   └── namespace-terminating-diagnose-readonly.yaml
└── tests/
    ├── run-tests.sh
    ├── validate-json.py
    ├── validate-rbac.py
    ├── validate-readonly.sh
    ├── mock/
    │   └── bin/
    │       └── kubectl
    └── schema/
        ├── target-result.schema.json
        └── patrol-result.schema.json
```

项目级 CI：

```text
.github/workflows/namespace-terminating-diagnose-ci.yml
```

---

## 3. 为什么 Namespace 会一直 Terminating

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

常见阻塞：

- `APIService` 不可用；
- API Discovery 不完整；
- Pod / Job / Secret / Role 等普通资源残留；
- PVC / PV / VolumeAttachment 未释放；
- CR 仍存在；
- 对象 Finalizer 无法完成；
- Operator 已提前卸载；
- CSI / Cloud Controller 异常；
- Admission Webhook 后端不可用；
- `failurePolicy=Fail` 阻断请求；
- ValidatingAdmissionPolicy 参与删除链；
- Namespace Controller 未收敛。

`kubectl get all -n <namespace>` 无法覆盖全部 Namespaced Resource，因此不能作为“Namespace 已清空”的证明。

---

## 4. 安全模型

### 4.1 Kubernetes API 严格只读

生产代码不会执行：

```text
kubectl delete
kubectl patch
kubectl replace
kubectl edit
kubectl apply
kubectl create
kubectl scale
PUT /api/v1/namespaces/<namespace>/finalize
```

v2.1.0 CI 会使用 `tests/validate-readonly.sh` 对生产 Shell 文件持续检查，防止后续提交无意引入 Kubernetes 写操作。

### 4.2 Fail-Closed

以下任何一项无法确认，都不能进入 Force Ready：

```text
API Discovery
APIService
全量 Namespaced Resource Scan
对象 Finalizer
CR
PVC
PV
VolumeAttachment
Webhook / VAP
Namespace Conditions
Terminating age
RBAC list 权限
```

原则：

```text
无法证明安全
=
不能进入 FORCE-FINALIZE-READY
```

### 4.3 FORCE-FINALIZE-READY 不是自动删除

它只表示：

```text
可以进入人工 Break-Glass 审批与复核
```

工具不会执行 `/finalize`。

---

## 5. 环境要求

运行时：

```text
Bash >= 4
kubectl
jq
GNU date
```

CI 额外使用：

```text
ShellCheck
Python 3
jsonschema
PyYAML
Gitleaks
```

---

## 6. 四个子命令

### 6.1 check

单 Namespace 轻量检查：

```bash
./namespace-terminating-diagnose.sh check -n test
```

检查：

```text
Namespace phase
DeletionTimestamp
Terminating age
Namespace Conditions
Namespace spec.finalizers
APIService Available
Aggregated API backend
```

`check` 不做完整资源扫描，因此不会返回 `FORCE-FINALIZE-READY`。

### 6.2 diagnose

完整只读诊断：

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
Verdict
```

### 6.3 report

执行完整诊断并生成审计文件：

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

### 6.4 force-check

严格检查 Break-Glass 前置条件：

```bash
./namespace-terminating-diagnose.sh force-check \
  -n test \
  --threshold 900
```

只有完整检查满足安全条件时才返回：

```text
FORCE-FINALIZE-READY
exit 30
```

---

## 7. Verdict 与 Exit Code Contract

| Verdict | Exit Code | 语义 |
|---|---:|---|
| `SAFE` | `0` | 未发现高风险阻塞 |
| `WARNING` | `10` | 存在剩余资源、暂时状态或验证不完整 |
| `DANGEROUS` | `20` | 存在明确高风险阻塞或外部资源风险 |
| `FORCE-FINALIZE-READY` | `30` | 仅 `force-check`：满足人工 Break-Glass 前置条件 |
| Tool/API Error | `64` | 参数、依赖、RBAC 或 API 基础访问失败 |

推荐 Jenkins：

```text
0  -> PASS
10 -> UNSTABLE / 自动进入 diagnose
20 -> FAIL / 禁止 Force Finalize
30 -> 人工审批
64 -> 工具 / RBAC / Kubernetes API 故障
```

---

## 8. `--json` 机器接口

```bash
./namespace-terminating-diagnose.sh diagnose \
  -n test \
  --json
```

stdout 只输出 JSON。

核心字段：

```text
schema_version
tool
version
command
generated_at
namespace.name
namespace.phase
namespace.deletion_timestamp
namespace.terminating_age_seconds
namespace.spec_finalizers
threshold_seconds
verdict
verdict_reason
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

### JSON Schema

v2.1.0 将 JSON 输出正式定义为 CI Contract：

```text
tests/schema/target-result.schema.json
tests/schema/patrol-result.schema.json
```

目标 Namespace 输出使用：

```text
target-result.schema.json
```

集群巡检输出使用：

```text
patrol-result.schema.json
```

CI 会验证：

```text
字段存在
字段类型
合法 Verdict
合法 Exit Code
FORCE-FINALIZE-READY -> force-check + exit 30 + force_finalize_ready=true
check -> force_finalize_ready=false
```

---

## 9. NamespaceTerminating > 10m 巡检

主入口：

```bash
./namespace-terminating-diagnose.sh \
  check \
  --all-terminating \
  --threshold 600
```

包装入口：

```bash
./namespace-terminating-patrol.sh
```

默认：

```text
600 秒 = 10 分钟
```

超过阈值：

```text
WARNING
exit 10
```

机器输出：

```bash
./namespace-terminating-patrol.sh --json
```

---

## 10. Prometheus textfile collector

巡检：

```bash
./namespace-terminating-patrol.sh \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/namespace_terminating.prom
```

核心指标：

```text
namespace_terminating_diagnose_patrol_terminating_total
namespace_terminating_diagnose_patrol_over_threshold_total
namespace_terminating_diagnose_patrol_unknown_age_total
namespace_terminating_diagnose_namespace_terminating
namespace_terminating_diagnose_namespace_terminating_age_seconds
namespace_terminating_diagnose_namespace_over_threshold
namespace_terminating_diagnose_generated_timestamp_seconds
```

写入采用：

```text
临时文件
   ↓
完整写入
   ↓
atomic mv
   ↓
正式 .prom
```

PrometheusRule：

```text
prometheus/namespace-terminating-alerts.yaml
```

---

## 11. Read-Only RBAC

Manifest：

```text
rbac/namespace-terminating-diagnose-readonly.yaml
```

安装：

```bash
kubectl apply -f \
  namespace-terminating-diagnose/rbac/namespace-terminating-diagnose-readonly.yaml
```

默认对象：

```text
ServiceAccount
  kube-system/namespace-terminating-diagnose

ClusterRole
  namespace-terminating-diagnose-readonly

ClusterRoleBinding
  namespace-terminating-diagnose-readonly
```

### 11.1 为什么权限看起来比较大

Full Diagnosis 的核心要求是：

```text
kubectl api-resources --verbs=list --namespaced
        ↓
动态发现所有资源类型
        ↓
逐个 list
        ↓
包含未知 CRD/CR
```

因此无法预先枚举所有第三方 API Group 和 Resource Name。

Manifest 使用：

```yaml
apiGroups:
  - "*"
resources:
  - "*"
verbs:
  - get
  - list
```

这是**广泛读取权限**，但没有任何 Kubernetes Resource 写权限。

### 11.2 Secret 风险必须明确

Kubernetes RBAC 不支持：

```text
允许 list Secret metadata
但禁止读取 Secret data
```

一旦授予 Secret 的 `get/list`，API 返回中可能包含 Secret 内容。

所以：

```text
Read-Only
≠
Low-Sensitivity
```

生产建议：

- 只给专用 ServiceAccount；
- 不给普通业务 Pod 使用；
- kubeconfig/token 按高敏凭据管理；
- Jenkins Credential 中隔离；
- 仅在诊断节点或运维平台使用；
- 不把原始 API JSON 随意落盘；
- 定期审计 ClusterRoleBinding。

### 11.3 CI RBAC Gate

执行：

```bash
python3 tests/validate-rbac.py \
  rbac/namespace-terminating-diagnose-readonly.yaml
```

CI 明确禁止：

```text
*
create
update
patch
delete
deletecollection
escalate
bind
impersonate
```

Resource API 只允许：

```text
get
list
```

Non-Resource URL 只允许：

```text
get
```

---

## 12. Mock E2E

测试入口：

```bash
bash tests/run-tests.sh
```

不依赖真实 Kubernetes 集群。

测试通过：

```text
tests/mock/bin/kubectl
```

模拟 Kubernetes API。

当前场景：

### 12.1 clean / Force Ready

模拟：

```text
Namespace Terminating 很久
APIService Healthy
Namespaced Resource = 0
Finalizer = 0
PVC/PV/VA = 0
CR = 0
Admission blocker = 0
```

期望：

```text
force-check
-> FORCE-FINALIZE-READY
-> exit 30
```

### 12.2 PVC / CSI Danger

模拟：

```text
PVC Terminating
kubernetes.io/pvc-protection
PV Bound
external-provisioner.volume.kubernetes.io/finalizer
VolumeAttachment attached=true
```

期望：

```text
DANGEROUS
exit 20
force_finalize_ready=false
```

### 12.3 APIService Discovery Failure

模拟：

```text
APIService Available=False
```

期望：

```text
DANGEROUS
exit 20
```

### 12.4 Patrol >10m

模拟：

```text
Namespace Terminating > 600s
```

期望：

```text
WARNING
exit 10
```

### 12.5 Report Contract

验证：

```text
report
-> exactly one TXT
-> exactly one JSON
-> exactly one PROM
```

并继续对 JSON 做 Schema Validation。

---

## 13. GitHub Actions Production Delivery Gate

工作流：

```text
.github/workflows/namespace-terminating-diagnose-ci.yml
```

仅在子项目或该 Workflow 发生变化时触发。

### Job 1: Bash syntax and ShellCheck

执行：

```text
bash -n
ShellCheck --severity=error
Read-Only Shell Contract
```

### Job 2: JSON, mock E2E and exit-code contracts

执行：

```text
JSON Schema
mock kubectl E2E
Verdict Contract
Exit Code Contract
Prometheus Contract
RBAC Contract
Report Artifact Contract
```

### Job 3: Secret Scan

使用 Gitleaks：

```text
Secret Scan
```

避免 Webhook Key、Token、Password、Private Key 等敏感信息进入仓库历史。

建议将以下三个 Job 设为分支 Required Checks：

```text
Bash syntax and ShellCheck
JSON, mock E2E and exit-code contracts
Secret Scan
```

---

## 14. 本地 CI 等价验证

基础语法：

```bash
find namespace-terminating-diagnose \
  -type f -name '*.sh' \
  -exec bash -n {} \;
```

ShellCheck：

```bash
shellcheck --severity=error \
  namespace-terminating-diagnose/*.sh \
  namespace-terminating-diagnose/lib/*.sh \
  namespace-terminating-diagnose/tests/*.sh \
  namespace-terminating-diagnose/tests/mock/bin/kubectl
```

RBAC：

```bash
python3 namespace-terminating-diagnose/tests/validate-rbac.py \
  namespace-terminating-diagnose/rbac/namespace-terminating-diagnose-readonly.yaml
```

Mock Contract：

```bash
bash namespace-terminating-diagnose/tests/run-tests.sh
```

---

## 15. Jenkins 集成

巡检：

```groovy
int rc = sh(
    script: '''
      ./namespace-terminating-diagnose/namespace-terminating-patrol.sh \
        --json > namespace-terminating.json
    ''',
    returnStatus: true
)

archiveArtifacts artifacts: 'namespace-terminating.json'

if (rc == 10) {
    unstable('存在 Namespace Terminating 超过阈值')
} else if (rc != 0) {
    error("namespace patrol failed, exit=${rc}")
}
```

Force Gate：

```text
force-check
   │
   ├─ 0/10 -> 不进入强制流程
   ├─ 20   -> 禁止强制流程
   ├─ 30   -> Jenkins Input 人工审批
   └─ 64   -> 工具/RBAC/API 故障
```

---

## 16. 生产操作建议

推荐流程：

```text
Namespace Terminating
        │
        ▼
check
        │
        ▼
diagnose --json
        │
        ├─ APIService
        ├─ Remaining Resource
        ├─ Finalizer
        ├─ PVC/PV/VA
        ├─ CR/Operator
        └─ Webhook/VAP
        │
        ▼
修复真实根因
        │
        ▼
重新 diagnose
        │
        ▼
force-check
        │
        ├─ Not Ready -> 继续修复
        │
        └─ FORCE-FINALIZE-READY
                    │
                    ▼
             人工 Break-Glass 审批
```

不要建立：

```text
Terminating
   ↓
直接清 finalizer
```

---

## 17. 当前工程验收目标

v2.1.0 的 Definition of Done：

```text
[ ] Repository CI 全绿
[ ] Namespace Project Gate 全绿
[ ] Bash syntax and ShellCheck 全绿
[ ] JSON/mock contract 全绿
[ ] Secret Scan 全绿
[ ] RBAC 无写权限
[ ] JSON Schema 无破坏性变化
[ ] force-check clean mock -> exit 30
[ ] PVC/CSI mock -> exit 20
[ ] APIService failure mock -> exit 20
[ ] patrol >10m mock -> exit 10
[ ] report -> TXT/JSON/PROM
```

只有这些检查全部通过，才应把 v2.1.0 视为完整生产交付版本。
