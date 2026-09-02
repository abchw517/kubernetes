# pod-start-time-check

Kubernetes Deployment Pod Ready 转换耗时巡检工具。当前版本：**v2.2.0 Production Hardening**。

项目坚持只读、最小权限、Fail-Closed 和可审计原则；默认扫描全集群，也支持 `-n/--namespace` 限定单 Namespace。

## 1. 指标语义

v2.2.0 明确不再把当前 Condition 时间差描述成“严格的首次启动耗时”。工具实际计算：

```text
scheduled_to_current_ready_transition_seconds =
Ready=True.lastTransitionTime
-
PodScheduled.lastTransitionTime
```

这个值适合用于发现 Scheduled 后很晚才进入**当前 Ready 状态**的 Pod，但它是代理指标：如果 Pod 启动后 Readiness 曾经从 True 变成 False，再重新变为 True，`Ready.lastTransitionTime` 会被刷新，因此结果可能大于历史首次 Ready 耗时。

业务算法本身保持 v2.1.0 不变，只把名称和报告语义修正为准确描述。

## 2. v2.2.0 只做七项 Production Hardening

1. 安全锁目录和 symlink 防护。
2. Strict RBAC 双向预检。
3. `--request-timeout` / `--command-timeout` 禁止配置为 0。
4. 使用 `jq @html` 修复 HTML escaping。
5. 明确 Scheduled -> Current Ready Transition 指标语义。
6. RFC3339 时间转换放入 jq，去掉每 Pod 两次 `date -d`。
7. 增加 contract tests 和专用 GitHub Actions Gate。

没有新增业务扫描目标，没有增加 Kubernetes 写操作，也没有修改 120/180 秒阈值规则、HTML 报告触发条件或企业微信发送流程。

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
          +--> get pods
          `--> get replicasets
                    |
                    v
          Local JSON processing
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
              sort DESC
                    |
        <=120   121..180   >180
        NORMAL    WARN    CRITICAL
                    |
                    v
             HTML / WeCom
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

v2.1.0 默认锁文件位于 `/tmp`。v2.2.0 默认改为：

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

这用于避免高权限 cron/systemd 执行时通过 `/tmp` 预置 symlink 导致文件覆盖。

非 root 用户如果不能创建 `/run/lock/pod-start-time-check`，使用现有参数指定一个由该用户独占且不可被其他用户写入的目录：

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

v2.2.0 明确拒绝零超时，例如：

```text
0
0s
0m
0h
0m0s
```

因此不能通过参数误操作关闭 Timeout。

## 7. 性能

Kubernetes API 仍只批量读取：

```bash
kubectl get pods ... -o json
kubectl get replicasets.apps ... -o json
```

v2.1.0 在每个有效 Pod 上执行：

```text
date -d scheduled
date -d ready
```

v2.2.0 改为一次 jq pipeline 使用：

```jq
fromdateiso8601
```

计算两个 RFC3339 timestamp 的 epoch 和 duration，不再产生每 Pod 两次外部 `date` 进程。

`date` 仍用于日志时间和报告文件名，这部分与 Pod 数量无关。

## 8. 阈值和输出

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

结果仍按 duration 从高到低排序。

只有 `>120s` 的记录进入 HTML 报告。

## 9. HTML 安全

v2.2.0 删除 Bash parameter replacement 版本的 HTML escape，统一使用：

```bash
jq -nr --arg value "$value" '$value | @html'
```

Namespace、Deployment、Pod、扫描范围等动态字段写入 HTML 前都会 escape。

## 10. 使用

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

企业微信：

```bash
export WECHAT_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REDACTED'
./pod-start-time-check.sh
```

`--webhook-url` 为兼容 v2.1.0 保留，但生产仍推荐环境变量，避免 URL/key 进入 shell history。

## 11. 参数

| 参数 | 默认值 |
|---|---|
| `-n, --namespace` | ALL |
| `--dry-run` | false |
| `--warn-seconds` | 120 |
| `--critical-seconds` | 180 |
| `--request-timeout` | 30s |
| `--command-timeout` | 45s |
| `--webhook-url` | empty |
| `--log-dir` | `/data/logs/pod-start-time-check` |
| `--report-dir` | `<log-dir>/reports` |
| `--lock-file` | `/run/lock/pod-start-time-check/pod-start-time-check.lock` |

## 12. Contract Tests

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
```

本地：

```bash
bash tests/run-tests.sh
```

## 13. 专用 CI

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

## 14. Production Hardening 结论

v2.2.0 不试图扩大工具能力，而是收紧运行边界：

```text
Read Only
+ Least Privilege RBAC
+ Strict RBAC Guard
+ Safe Lock
+ Non-zero Timeout
+ Correct HTML Escape
+ Accurate Metric Semantics
+ No per-Pod date fork
+ Contract CI
```
