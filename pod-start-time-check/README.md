# pod-start-time-check

Kubernetes Deployment Pod Ready 转换耗时巡检工具。当前版本：**v2.3.0 Identity Hardening**。

v2.3.0 不扩展业务扫描范围，重点把 **Authentication / Authorization / Runtime** 三层真正闭环：运行脚本不再使用本机默认 kubeconfig，而是强制使用专用低权限身份。

## 1. Runtime Identity

默认专用 kubeconfig：

```text
/data/pod-start-time-check/kubeconfig
```

环境变量：

```bash
KUBECONFIG_FILE=/data/pod-start-time-check/kubeconfig
```

运行时所有 Kubernetes CLI 调用都固定为：

```bash
kubectl \
  --kubeconfig="${KUBECONFIG_FILE}" \
  --request-timeout="${KUBECTL_REQUEST_TIMEOUT}" \
  ...
```

即使主机存在：

```text
/root/.kube/config
$KUBECONFIG
/etc/kubernetes/admin.conf
```

脚本也不会 fallback 使用这些凭据。

### Fail Closed

运行前要求 dedicated kubeconfig：

- 必须存在；
- 必须是 regular file；
- 不能是 symlink；
- 必须可读；
- owner 必须等于当前执行 UID；
- mode 必须是 `0400` 或 `0600`；
- 所在目录不能是 symlink；
- 所在目录不能 group/world writable。

任何条件不满足直接退出，不执行集群扫描。

## 2. Provisioning Identity 与 Runtime Identity 分离

```text
ADMIN / Provisioning
        |
        | ADMIN_KUBECONFIG
        v
rbac.yaml + TokenRequest
        |
        v
ServiceAccount: pod-start-time-check
        |
        v
/data/pod-start-time-check/kubeconfig
        |
        | 0600
        v
---------------- Security Boundary ----------------
        |
        v
pod-start-time-check.sh
        |
        | kubectl --kubeconfig=dedicated
        v
Strict RBAC
        |
        +-- pods:list                  = yes
        +-- replicasets.apps:list      = yes
        +-- */*                        = no
        +-- secrets:get                = no
        +-- pods:delete                = no
        +-- deployments.apps:patch     = no
        `-- clusterrolebindings:create = no
```

运行脚本本身不会读取 `ADMIN_KUBECONFIG`，也不会创建或刷新 ServiceAccount Token。

## 3. RBAC

`rbac.yaml` 仍然严格只有：

| API Group | Resource | Verb |
|---|---|---|
| core | pods | list |
| apps | replicasets | list |

没有 `get secrets`、`exec`、`logs`、`create/update/patch/delete`。

v2.3.0 同时为 ServiceAccount 设置：

```yaml
automountServiceAccountToken: false
```

因为当前外部运行模式使用显式 provision 的 dedicated kubeconfig，不依赖 Pod 自动挂载 ServiceAccount Token。

管理员部署：

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f rbac.yaml
```

## 4. 生成 dedicated kubeconfig

v2.3.0 新增：

```text
provision-kubeconfig.sh
```

它只允许在 **Provisioning 阶段** 使用管理员 kubeconfig。

示例：

```bash
sudo env \
  ADMIN_KUBECONFIG=/etc/kubernetes/admin.conf \
  KUBECONFIG_FILE=/data/pod-start-time-check/kubeconfig \
  TOKEN_DURATION=24h \
  ./provision-kubeconfig.sh
```

脚本会：

1. 要求显式设置 `ADMIN_KUBECONFIG`，不默认使用 `~/.kube/config`；
2. 从 admin kubeconfig 获取 API Server 和 CA；
3. 执行 `kubectl create token pod-start-time-check` 请求 ServiceAccount Token；
4. 生成 `/data/pod-start-time-check/kubeconfig`；
5. 设置 `0600`；
6. 用新 kubeconfig 验证 required RBAC；
7. 用新 kubeconfig 验证危险权限必须为 `no`；
8. 验收通过后才原子替换正式 kubeconfig。

### Token 生命周期

`kubectl create token` 使用 Kubernetes TokenRequest API，得到的是有期限 Token。

```bash
TOKEN_DURATION=24h
```

这是“请求的 duration”，实际有效期可以由 kube-apiserver 调整。

**不要**为了省事改回旧式长期 ServiceAccount token Secret。长期周期执行如果需要自动轮换身份，优先考虑把工具改成集群内 CronJob + projected ServiceAccount Token；该模式不属于本次 v2.3.0 范围。

## 5. Runtime 使用

首次建议 dry-run：

```bash
KUBECONFIG_FILE=/data/pod-start-time-check/kubeconfig \
./pod-start-time-check.sh --dry-run
```

正式全集群：

```bash
./pod-start-time-check.sh
```

指定 Namespace：

```bash
./pod-start-time-check.sh -n pro-yunfan
```

默认 `KUBECONFIG_FILE` 已是：

```text
/data/pod-start-time-check/kubeconfig
```

因此正确部署后无需每次显式传入。

## 6. Strict RBAC

Dedicated kubeconfig 只是身份载体，运行时仍继续执行 Strict RBAC：

```text
required:
  pods:list
  replicasets.apps:list

forbidden:
  */*
  secrets:get
  pods:delete
  deployments.apps:patch
  clusterrolebindings:create
```

因此：

```text
Dedicated kubeconfig
        |
        v
File Security Validation
        |
        v
kubectl --kubeconfig
        |
        v
Strict RBAC
        |
        v
Scan
```

## 7. Timeout

保持 v2.2：

```text
KUBECTL_REQUEST_TIMEOUT=30s
KUBECTL_COMMAND_TIMEOUT=45s
```

```text
GNU timeout 45s
      |
      v
kubectl --kubeconfig=... --request-timeout=30s
```

`0 / 0s / 0m / 0h` 等零 timeout 继续被拒绝。

## 8. 安全锁

默认：

```text
/run/lock/pod-start-time-check/pod-start-time-check.lock
```

继续验证 owner、mode、regular file 和 symlink 安全。

## 9. 指标语义

实际指标保持不变：

```text
scheduled_to_current_ready_transition_seconds =
Ready=True.lastTransitionTime
-
PodScheduled.lastTransitionTime
```

如果 Pod 启动后 Readiness 再次发生 True/False 转换，`Ready.lastTransitionTime` 会刷新，因此它是当前 Ready transition 的代理耗时，不等于历史首次 Ready 时间。

## 10. 阈值

规则保持不变：

```text
<=120s   NORMAL
>120s    WARN
>180s    CRITICAL
```

结果按 duration 降序；只有 `>120s` 进入 HTML。

## 11. 企业微信

Webhook 只允许环境变量：

```bash
export WECHAT_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REDACTED'
./pod-start-time-check.sh
```

不支持 `--webhook-url`，避免 key 暴露在 shell history / process args。

## 12. 目录

```text
pod-start-time-check/
├── pod-start-time-check.sh
├── provision-kubeconfig.sh
├── rbac.yaml
├── README.md
└── tests/
    ├── run-tests.sh
    ├── mock-kubectl
    └── fixtures/
        ├── pods.json
        ├── replicasets.json
        └── admin-config-view.json
```

## 13. Contract Tests

v2.3.0 在 v2.2.x 测试基础上增加身份边界回归：

```text
missing dedicated kubeconfig       -> FAIL CLOSED
symlink kubeconfig                 -> FAIL CLOSED
0644 kubeconfig                    -> FAIL CLOSED
$KUBECONFIG poison                 -> ignored
all runtime kubectl                -> must contain --kubeconfig=<dedicated>
Strict RBAC privileged identity    -> rejected
provision without ADMIN_KUBECONFIG -> rejected
provision output                   -> 0600 dedicated kubeconfig
provision RBAC validation          -> required yes / dangerous no
```

同时继续覆盖：

```text
120/121/180/181 threshold
Ready=False skip
non-Deployment skip
HTML escaping
safe lock symlink
zero timeout
REPORT_DIR derivation
no per-Pod date -d
```

本地：

```bash
bash tests/run-tests.sh
```

## 14. v2.3.0 Identity Hardening 结论

```text
Authentication
  Dedicated ServiceAccount credential
        +
Authorization
  exact RBAC + Strict RBAC
        +
Runtime
  forced --kubeconfig
  no fallback
        +
File Security
  owner + 0400/0600 + non-symlink
        =
Identity Boundary Closed
```
