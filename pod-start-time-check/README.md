# pod-start-time-check

Kubernetes Deployment Pod Ready 转换耗时巡检工具。当前版本：**v2.2.1 Production Maintenance**。

项目坚持只读、最小权限、Fail-Closed 和可审计原则；默认扫描全集群，也支持 `-n/--namespace` 限定单 Namespace。

## 1. 指标语义

工具计算：

```text
scheduled_to_current_ready_transition_seconds =
Ready=True.lastTransitionTime
-
PodScheduled.lastTransitionTime
```

这个值适合用于发现 Scheduled 后很晚才进入**当前 Ready 状态**的 Pod，但它是代理指标：如果 Pod 启动后 Readiness 曾经从 True 变成 False，再重新变为 True，`Ready.lastTransitionTime` 会被刷新，因此结果可能大于历史首次 Ready 耗时。

业务算法保持不变，只把名称和报告语义明确为实际含义。

## 2. 版本演进

### v2.2.0 Production Hardening

1. 安全锁目录和 symlink 防护。
2. Strict RBAC 双向预检。
3. `--request-timeout` / `--command-timeout` 禁止配置为 0。
4. 使用 `jq @html` 修复 HTML escaping。
5. 明确 Scheduled -> Current Ready Transition 指标语义。
6. RFC3339 时间转换放入 jq，去掉每 Pod 两次 `date -d`。
7. 增加 contract tests 和专用 GitHub Actions Gate。

### v2.2.1 P2 Maintenance

本版本不扩展业务能力，只修复剩余 P2：

1. 修复 `--log-dir` 修改后默认 `REPORT_DIR` 仍指向旧目录的问题。
2. `REPORT_DIR` 只在参数解析完成后派生为 `<log-dir>/reports`；显式 `REPORT_DIR` 环境变量或 `--report-dir` 仍具有最高优先级。
3. 移除 `--webhook-url` 明文 Secret CLI 通道；企业微信 Webhook 只接受 `WECHAT_WEBHOOK_URL` 环境变量。
4. 删除 `kubectl_scope_args()` 及其 NUL/process-substitution 参数传递层，扫描范围直接使用 Bash 数组。
5. 删除 `rs-deployment.tsv` 和 `pods.tsv` 两个冗余中间文件，ReplicaSet 映射和 Pod 解析直接通过 `jq -> while` 流式处理。
6. 增加以上场景的 contract regression tests。

没有新增 Kubernetes 权限、写操作、扫描对象或业务参数。

## 3. 数据链路

```text
Dedicated Kubernetes Identity
          |
          v
Strict RBAC Preflight
  | required=yes
  | pods:list
  | replicasets:list
  |
  | dangerous=no
  | */*
  | secrets:get
  | pods:delete
  | deployments:patch
  | clusterrolebindings:create
          |
          v
kubectl_safe
  |-- request-timeout=30s
  `-- command-timeout=45s
          |
          +--> get pods       -> pods.json
          `--> get replicasets -> replicasets.json
                    |
                    v
            jq streaming parse
                    |
        Pod -> ReplicaSet -> Deployment
                    |
                    v
        jq fromdateiso8601 conversion
                    |
                    v
Scheduled -> current Ready transition
                    |
                    v
              results.tsv
                    |
              sort DESC
                    |
        <=120   121..180   >180
        NORMAL    WARN    CRITICAL
                    |
                    v
              slow.tsv
                    |
                    v
             HTML / WeCom
```

v2.2.1 不再生成：

```text
rs-deployment.tsv
pods.tsv
```

## 4. RBAC

`rbac.yaml` 的 ClusterRole 精确只有：

| API Group | Resource | Verb |
|---|---|---|
| core | pods | list |
| apps | replicasets | list |

脚本启动时首先确认这两个权限存在，然后执行 Strict RBAC 检查。如果当前身份在扫描范围内拥有以下明显高危权限之一，脚本 Fail Closed：

```text
*/*
secrets:get
pods:delete
deployments.apps:patch
clusterrolebindings.rbac.authorization.k8s.io:create
```

Strict RBAC 是生产防误用保护，重点阻止 cluster-admin 或明显高权限 kubeconfig 被拿来运行巡检工具。它不是 Kubernetes 身份全部权限的数学证明，因此仍应使用 `rbac.yaml` 中的专用 ServiceAccount/凭据。

安装：

```bash
kubectl apply -f rbac.yaml
```

验证：

```bash
SA='system:serviceaccount:pod-start-time-check-system:pod-start-time-check'

kubectl auth can-i list pods -A --as="${SA}"
kubectl auth can-i list replicasets.apps -A --as="${SA}"
kubectl auth can-i get secrets -A --as="${SA}"
```

预期：

```text
yes
yes
no
```

如果只允许某个 Namespace，请保留 ClusterRole，但用目标 Namespace 中的 RoleBinding 绑定该 ServiceAccount，不使用默认 ClusterRoleBinding。

## 5. 安全锁

默认锁文件：

```text
/run/lock/pod-start-time-check/pod-start-time-check.lock
```

打开锁之前会验证：

- 锁目录不是 symlink；
- 锁目录 owner 必须是当前执行用户；
- 锁目录不能 group/world writable；
- 已存在的锁文件必须是普通文件；
- 锁文件不能是 symlink；
- 已存在锁文件 owner 必须是当前执行用户；
- 锁文件权限收敛到 `0600`。

非 root 用户如果不能创建 `/run/lock/pod-start-time-check`，指定一个由该用户独占且不可被其他用户写入的目录：

```bash
./pod-start-time-check.sh \
  --lock-file "$HOME/.local/state/pod-start-time-check/tool.lock"
```

## 6. Timeout

默认：

```text
KUBECTL_REQUEST_TIMEOUT=30s
KUBECTL_COMMAND_TIMEOUT=45s
```

双层保护：

```text
kubectl --request-timeout=30s
GNU timeout --kill-after=5s 45s kubectl ...
```

明确拒绝零超时，例如：

```text
0
0s
0m
0h
0m0s
```

因此不能通过参数误操作关闭 Timeout。

## 7. 日志与报告路径

默认：

```text
LOG_DIR=/data/logs/pod-start-time-check
REPORT_DIR=<LOG_DIR>/reports
```

v2.2.1 修复了路径派生顺序。现在：

```bash
./pod-start-time-check.sh \
  --log-dir /data/logs/custom-pod-check
```

如果没有显式配置 `REPORT_DIR` 或 `--report-dir`，报告自动写入：

```text
/data/logs/custom-pod-check/reports
```

优先级：

```text
--report-dir
或 REPORT_DIR 环境变量
        >
由最终 LOG_DIR 自动派生的 <LOG_DIR>/reports
```

例如：

```bash
REPORT_DIR=/data/reports/pod-check \
./pod-start-time-check.sh \
  --log-dir /data/logs/custom-pod-check
```

报告仍写入：

```text
/data/reports/pod-check
```

## 8. 企业微信安全配置

v2.2.1 不再支持：

```text
--webhook-url <url>
```

原因是 Webhook key 属于 Secret，命令行参数可能暴露在：

```text
shell history
ps / proc process arguments
审计或运维采集系统
```

只允许：

```bash
export WECHAT_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REDACTED'
./pod-start-time-check.sh
```

如果仍传入 `--webhook-url`，脚本会立即 Fail Closed 并提示改用环境变量。

企业微信发送失败仍不会改变巡检计算结果；HTML 已生成时会保留本地报告并记录错误日志。

## 9. 性能与代码简化

Kubernetes API 仍只批量读取：

```bash
kubectl get pods ... -o json
kubectl get replicasets.apps ... -o json
```

时间转换使用 jq：

```jq
fromdateiso8601
```

不再产生每 Pod 两次外部 `date` 进程。

v2.2.1 进一步去掉以下冗余层：

```text
kubectl_scope_args()
rs-deployment.tsv
pods.tsv
```

现在 ReplicaSet 映射与 Pod record extraction 都直接采用：

```text
jq producer
    |
    v
while read consumer
```

Shell 只保留必要的关联映射、统计、排序、报告和通知逻辑。

临时目录中核心文件收敛为：

```text
pods.json
replicasets.json
results.tsv
slow.tsv
```

## 10. 阈值和输出

规则保持不变：

```text
<=120s   NORMAL
>120s    WARN / 黄色
>180s    CRITICAL / 红色
```

终端输出：

```text
NAMESPACE
DEPLOYMENT
POD
TRANSITION(s)
```

结果按 duration 从高到低排序。

只有 `>120s` 的记录进入 HTML 报告。

## 11. HTML 安全

动态字段统一使用：

```bash
jq -nr --arg value "$value" '$value | @html'
```

Namespace、Deployment、Pod、扫描范围等字段写入 HTML 前都会 escape。

## 12. 使用

全集群：

```bash
./pod-start-time-check.sh
```

指定 Namespace：

```bash
./pod-start-time-check.sh -n pro-yunfan
```

Dry-run：

```bash
./pod-start-time-check.sh --dry-run
```

自定义阈值：

```bash
./pod-start-time-check.sh \
  --warn-seconds 120 \
  --critical-seconds 180
```

自定义双层 Timeout：

```bash
./pod-start-time-check.sh \
  --request-timeout 20s \
  --command-timeout 30s
```

企业微信：

```bash
export WECHAT_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REDACTED'
./pod-start-time-check.sh
```

## 13. 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-n, --namespace` | ALL | 指定扫描 Namespace |
| `--dry-run` | false | 不生成 HTML、不通知企业微信 |
| `--warn-seconds` | 120 | WARN 阈值 |
| `--critical-seconds` | 180 | CRITICAL 阈值 |
| `--request-timeout` | 30s | 单 API Request Timeout |
| `--command-timeout` | 45s | 整个 kubectl Command Timeout |
| `--log-dir` | `/data/logs/pod-start-time-check` | 日志目录 |
| `--report-dir` | `<log-dir>/reports` | HTML 报告目录 |
| `--lock-file` | `/run/lock/pod-start-time-check/pod-start-time-check.lock` | 安全锁文件 |

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

## 14. Contract Tests

目录：

```text
tests/
├── run-tests.sh
├── mock-kubectl
└── fixtures/
    ├── pods.json
    └── replicasets.json
```

覆盖：

```text
120s  -> NORMAL
121s  -> WARN
180s  -> WARN
181s  -> CRITICAL

结果按耗时降序
Ready=False 跳过
非 Deployment Pod 跳过
Strict RBAC 拒绝高权限身份
request-timeout=0 拒绝
command-timeout=0 拒绝
symlink lock 拒绝且不截断目标文件
HTML escaping 正确
HTML 包含准确指标语义
脚本不存在 per-Pod date -d
--log-dir 正确派生默认 report 目录
显式 REPORT_DIR 不被 --log-dir 覆盖
--webhook-url 命令行通道被拒绝
无 kubectl_scope_args 冗余 helper
无 rs-deployment.tsv / pods.tsv 中间文件
```

本地：

```bash
bash tests/run-tests.sh
```

## 15. 专用 CI

`.github/workflows/pod-start-time-check-ci.yml` 包含：

```text
bash -n
ShellCheck --severity=error
yamllint
RBAC exact baseline validation
contract tests
```

RBAC CI 使用 exact-set 校验，只接受：

```text
('', 'pods', 'list')
('apps', 'replicasets', 'list')
```

任何新增 Kubernetes 权限都会导致 Gate 失败。

## 16. Production Ready 基线

v2.2.1 完成 P1 + P2 收口后的基线：

```text
Read Only
+ Least Privilege RBAC
+ Strict RBAC Guard
+ Safe Lock
+ Non-zero Timeout
+ Correct HTML Escape
+ Accurate Metric Semantics
+ No per-Pod date fork
+ Correct LOG_DIR/REPORT_DIR derivation
+ No Webhook Secret CLI
+ Reduced intermediate files
+ Contract CI
```
