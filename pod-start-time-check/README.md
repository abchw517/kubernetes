# pod-start-time-check

Kubernetes Pod 启动耗时巡检工具。面向生产集群，以**只读、最小 RBAC、API 超时保护、可审计**为核心设计，统计 Deployment 管理的 Pod 从 `PodScheduled=True` 到当前 `Ready=True` 的时间差，并对慢启动 Pod 进行分级展示、HTML 留档和企业微信通知。

当前版本：**v2.1.0**

## 1. 功能

- 默认扫描全集群所有 Namespace。
- `-n/--namespace` 只扫描指定 Namespace。
- 自动解析 `Pod -> ReplicaSet -> Deployment` OwnerReference。
- 按启动耗时从高到低排序。
- 输出：Namespace、Deployment、Pod、启动耗时。
- `>120s` 黄色，`>180s` 红色，阈值可调整。
- 将 `>120s` 的记录生成 HTML 报告。
- 可通过企业微信群机器人发送摘要和 HTML 文件。
- 日志、`flock` 互斥锁、`--dry-run`、临时文件自动清理。
- **v2.1.0：RBAC 最小权限预检。**
- **v2.1.0：`kubectl --request-timeout` + GNU `timeout` 双层超时。**
- **v2.1.0：删除 `kubectl get namespace` 预检查，不再需要 `namespaces:get`。**

## 2. 启动耗时口径

保持原有业务口径不变：

```text
startup_seconds =
Ready=True condition.lastTransitionTime
-
PodScheduled condition.lastTransitionTime
```

只统计当前存在 `Ready=True` 条件并能够关联到 Deployment 的 Pod。

> 注意：该指标反映 Kubernetes Condition 的时间差。如果 Pod 在运行期间发生过 Readiness 状态反复切换，`Ready.lastTransitionTime` 可能代表最近一次重新 Ready 的时间，而不一定严格等价于容器进程第一次启动完成时间。本版本为了保持原业务逻辑，不改变这一计算口径。

## 3. 架构与数据链路

```text
                         +------------------------+
                         | pod-start-time-check.sh|
                         +-----------+------------+
                                     |
                         RBAC auth can-i preflight
                                     |
                    +----------------+----------------+
                    |                                 |
                    v                                 v
             pods:list                         replicasets:list
                    |                                 |
                    +----------------+----------------+
                                     |
                          kubectl_safe 双层超时
                                     |
                 +-------------------+-------------------+
                 |                                       |
        --request-timeout=30s                   GNU timeout=45s
        单次 API Request                         整个 kubectl 进程
                 |                                       |
                 +-------------------+-------------------+
                                     |
                                     v
                            本地 JSON 批量分析
                                     |
                  Pod -> ReplicaSet -> Deployment
                                     |
                                     v
                      PodScheduled -> Ready 时间差
                                     |
                                     v
                              startup_seconds
                                     |
                         sort DESC by seconds
                                     |
                +--------------------+--------------------+
                |                    |                    |
             <=120s              120s~180s             >180s
              NORMAL                WARN               CRITICAL
                                     |                    |
                                     +----------+---------+
                                                |
                                                v
                                         HTML Report
                                                |
                                                v
                                      WeCom Robot(optional)
```

## 4. RBAC 最小权限

### 4.1 为什么脚本需要独立 RBAC

RBAC 约束的是**脚本所使用的 Kubernetes 身份**，不是 Shell 文件本身。

如果仍然使用：

```text
cluster-admin kubeconfig
```

即使脚本只执行 `get/list`，该凭据仍然具有管理员权限。因此生产环境建议为该工具使用独立 ServiceAccount 或独立低权限 kubeconfig。

### 4.2 v2.1.0 最小权限

脚本只需要：

| API Group | Resource | Verb | 用途 |
|---|---|---|---|
| core | pods | list | 批量获取 Pod Condition、OwnerReference |
| apps | replicasets | list | 将 ReplicaSet 映射到 Deployment |

明确**不需要**：

```text
pods:get
pods:watch
pods/log
pods/exec
namespaces:get
nodes:*
deployments:*
secrets:*
configmaps:*
create/update/patch/delete
```

### 4.3 部署默认全集群只读 RBAC

```bash
kubectl apply -f rbac.yaml
```

验证：

```bash
SA='system:serviceaccount:pod-start-time-check-system:pod-start-time-check'

kubectl auth can-i list pods \
  --all-namespaces \
  --as="${SA}"

kubectl auth can-i list replicasets.apps \
  --all-namespaces \
  --as="${SA}"

kubectl auth can-i get secrets \
  --all-namespaces \
  --as="${SA}"
```

预期：

```text
yes
yes
no
```

### 4.4 仅允许单 Namespace

如果生产策略不允许全集群扫描，不要应用 `rbac.yaml` 中的 `ClusterRoleBinding`。保留 `ClusterRole`，改为在目标 Namespace 建立 `RoleBinding`：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-start-time-check
  namespace: pro-yunfan
subjects:
  - kind: ServiceAccount
    name: pod-start-time-check
    namespace: pod-start-time-check-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pod-start-time-check
```

此时执行：

```bash
./pod-start-time-check.sh -n pro-yunfan
```

而全集群扫描会在 RBAC Preflight 阶段 Fail Closed。

## 5. RBAC Preflight

脚本启动后先执行：

```text
kubectl auth can-i list pods
kubectl auth can-i list replicasets.apps
```

全集群模式检查 `--all-namespaces`；`-n` 模式检查指定 Namespace。

任一权限不是 `yes`：

```text
RBAC 权限不足 -> 立即退出 -> 不继续扫描 -> 不生成错误报告
```

v2.1.0 不再执行：

```bash
kubectl get namespace <namespace>
```

因此不会为了 Namespace 存在性检查额外申请 `namespaces:get`。

如果 `-n` 指定了不存在的 Namespace，真正的 Pod List 请求会失败并终止。

## 6. kubectl 双层 Timeout

### 6.1 第一层：API Request Timeout

默认：

```text
30s
```

对应：

```bash
kubectl --request-timeout=30s ...
```

用于限制单次 Kubernetes API Server Request。

### 6.2 第二层：kubectl Command Timeout

默认：

```text
45s
```

对应：

```bash
timeout --signal=TERM --kill-after=5s 45s kubectl ...
```

用于限制整个 `kubectl` 进程，避免网络、认证插件、代理、客户端异常等场景长期卡死。

### 6.3 推荐关系

生产环境建议：

```text
request-timeout < command-timeout
```

默认：

```text
30s < 45s
```

自定义：

```bash
./pod-start-time-check.sh \
  --request-timeout 20s \
  --command-timeout 30s
```

也支持环境变量：

```bash
export KUBECTL_REQUEST_TIMEOUT=20s
export KUBECTL_COMMAND_TIMEOUT=30s
./pod-start-time-check.sh
```

## 7. 使用方法

### 7.1 依赖

必需：

```text
bash 4+
kubectl
jq
GNU coreutils date
GNU coreutils timeout
sort
awk
sed
flock
mktemp
```

启用企业微信时额外需要：

```text
curl
```

### 7.2 全集群扫描

```bash
chmod +x pod-start-time-check.sh
./pod-start-time-check.sh
```

### 7.3 指定 Namespace

```bash
./pod-start-time-check.sh -n pro-yunfan
```

### 7.4 Dry-run

```bash
./pod-start-time-check.sh --dry-run
```

Dry-run 会执行：

- RBAC Preflight
- Pod/ReplicaSet 查询
- Deployment 映射
- 启动耗时计算
- 排序和终端输出

但不会：

- 持久化 HTML
- 调用企业微信机器人

### 7.5 自定义阈值

```bash
./pod-start-time-check.sh \
  --warn-seconds 120 \
  --critical-seconds 180
```

### 7.6 企业微信

生产环境建议使用环境变量，避免 Webhook 出现在 shell history 和进程参数：

```bash
export WECHAT_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REDACTED'
./pod-start-time-check.sh
```

仍保留 `--webhook-url` 兼容能力，但脚本会输出安全提示。

## 8. 参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `-n, --namespace` | ALL | 指定单 Namespace |
| `--dry-run` | false | 不生成 HTML、不通知企业微信 |
| `--warn-seconds` | 120 | 黄色阈值 |
| `--critical-seconds` | 180 | 红色阈值 |
| `--request-timeout` | 30s | kubectl 单次 API Request Timeout |
| `--command-timeout` | 45s | 整体 kubectl Command Timeout |
| `--webhook-url` | 空 | 企业微信机器人 Webhook；推荐环境变量 |
| `--log-dir` | `/data/logs/pod-start-time-check` | 日志目录 |
| `--report-dir` | `<log-dir>/reports` | HTML 目录 |
| `--lock-file` | `/tmp/pod-start-time-check.lock` | flock 锁文件 |

环境变量：

```text
WARN_SECONDS
CRITICAL_SECONDS
KUBECTL_REQUEST_TIMEOUT
KUBECTL_COMMAND_TIMEOUT
LOG_DIR
REPORT_DIR
LOCK_FILE
WECHAT_WEBHOOK_URL
KUBECONFIG
```

## 9. 日志与报告

默认日志：

```text
/data/logs/pod-start-time-check/
└── pod-start-time-check-YYYYMMDD.log
```

HTML：

```text
/data/logs/pod-start-time-check/reports/
└── pod-start-time-report-YYYYMMDD-HHMMSS.html
```

脚本设置：

```bash
umask 077
```

新建日志、临时文件和报告默认只允许当前执行用户访问，降低信息泄露风险。

## 10. Exit / Fail-Closed 行为

以下情况直接失败，不继续产生业务报告：

- 缺少必需命令。
- GNU `date -d` 不可用。
- Timeout 参数格式无效。
- `kubectl` Client 不可用。
- `pods:list` 权限不足。
- `replicasets.apps:list` 权限不足。
- Kubernetes API 请求失败。
- kubectl 整体命令超时。
- Namespace 不存在。

企业微信发送失败**不会改变巡检计算结果**；HTML 已生成时会保留本地报告并记录错误日志。

## 11. 输出示例

```text
Pod 启动耗时巡检结果
NAMESPACE                    DEPLOYMENT                                       POD                                                                     STARTUP(s)
pro-yunfan                   yunfan-order                                     yunfan-order-7d6c9b8b56-abcde                                               235s
pro-yunfan                   yunfan-app-api                                   yunfan-app-api-78cb5f7d9-xabcd                                              160s
pro-yunfan                   yunfan-user                                      yunfan-user-6f98c5c8cc-xyz12                                                48s
```

颜色规则：

```text
<= 120s    默认
> 120s     黄色
> 180s     红色
```

## 12. v2.1.0 变更

与 v2.0.0 相比：

1. 新增 `check_rbac_permissions()`。
2. 最小权限固定为 `pods:list`、`replicasets.apps:list`。
3. 删除 Namespace `get` 预检查和 `namespaces:get` 权限依赖。
4. 新增 `kubectl_safe()`，统一包装所有 Kubernetes API 调用。
5. 新增 `KUBECTL_COMMAND_TIMEOUT=45s`。
6. 保留 `KUBECTL_REQUEST_TIMEOUT=30s`，形成双层 Timeout。
7. 新增 `--request-timeout`、`--command-timeout` 参数。
8. 新增独立 `rbac.yaml`。
9. 增加 `umask 077`。
10. 原 Pod 启动耗时计算、排序、阈值、HTML、企业微信业务逻辑不变。
