# Kubernetes 灰度 Deployment 副本归零工具

## 1. 项目简介

`k8s-gray-scale-zero.sh` 是一个用于 **Kubernetes 灰度 Deployment
安全归零** 的生产辅助脚本。

脚本的核心目标是：筛选满足保护条件的 Gray Deployment，在确认对应 Formal
Deployment 健康、没有 HPA 干预、执行基线未发生变化后，将 Gray Deployment
的 `spec.replicas` 分批设置为 `0`。

当前版本：**v3.1.0 Simplified Production Hardened Edition**

设计原则：

-   一次执行、一次确认、执行结束即结束。
-   不实现 Resume、Abort、Pause、Status 等任务状态机。
-   对关键安全条件采用 **fail-closed**：无法证明安全时停止执行。
-   任何已进入实际变更流程的 Deployment 都纳入自动 Rollback 保护。
-   Rollback 不盲目覆盖执行期间由人工、HPA 或其他系统产生的并发修改。

------------------------------------------------------------------------

## 2. 核心安全能力

脚本保留以下生产保护机制：

1.  **全局任务锁**：使用 `flock`
    防止同一日志目录下并发执行多个灰度归零任务。
2.  **固定 Kubernetes Context**：启动后记录 `current-context`，后续
    Kubernetes API 操作统一通过 `kctl()` 使用该 Context。
3.  **统一 API Timeout**：通过 `KUBECTL_TIMEOUT` 为 Kubernetes API
    请求设置 `--request-timeout`。
4.  **标签强校验**：Deployment 必须满足 `module_name=gray` 和指定的
    `language_type`。
5.  **名称保护**：只处理以 `-gray` 结尾的 Deployment，并排除名称中包含
    `frontend` 的对象。
6.  **业务类型过滤**：支持 `all`、`api`、`service`、`api,service`。
7.  **HPA fail-closed**：HPA 查询失败时直接停止；检测到 HPA 时跳过对应
    Gray Deployment。
8.  **Formal 健康门禁**：Formal Deployment 必须满足
    `desired == ready == available` 且 desired 不为 0。
9.  **执行前基线 Snapshot**：记录 Gray / Formal 原始副本数以及运行环境。
10. **人工确认**：正式执行前必须输入 `YES`。
11. **并发变更保护**：`kubectl scale` 使用
    `--current-replicas`，避免覆盖执行期间发生的副本变更。
12. **分批执行与观察复核**：每批完成后等待观察时间，并重新检查所有已成功处理的
    Gray / Formal。
13. **自动 Rollback**：关键异常、最终复核失败、INT/TERM
    等情况下恢复本次进入修改流程的 Gray Deployment。
14. **Rollback 冲突保护**：仅在当前副本仍为 `0`
    时自动恢复基线；如果已经被其他系统修改，则记录冲突，不盲目覆盖。
15. **企业微信通知**：可选；通知失败不会改变主业务执行结果。

------------------------------------------------------------------------

## 3. 环境要求

### 3.1 Bash

要求：

``` text
Bash >= 4
```

脚本使用了：

-   `set -Eeuo pipefail`
-   普通数组
-   关联数组 `declare -A`
-   `mapfile`
-   动态文件描述符
-   `flock`

### 3.2 必需命令

默认需要：

``` text
kubectl
flock
awk
sed
grep
```

只有配置 `WECHAT_WEBHOOK_URL` 时才额外要求：

``` text
curl
```

### 3.3 Kubernetes 权限

执行账号至少需要能够：

-   获取 Namespace；
-   list/get Deployment；
-   get Deployment labels/status；
-   list/get HPA；
-   修改 Deployment scale 子资源。

建议使用专用 ServiceAccount / kubeconfig，并遵循最小权限原则。

------------------------------------------------------------------------

## 4. 默认配置

脚本内置默认值：

  ----------------------------------------------------------------------------------
  配置                    默认值                             含义
  ----------------------- ---------------------------------- -----------------------
  `NAMESPACE`             `dev-xxx`                       目标 Namespace

  `LANGUAGE_TYPE`         `java`                             `language_type` 标签值

  `BUSINESS_TYPE`         `all`                              业务类型过滤

  `BATCH_SIZE`            `5`                                每批成功归零数量

  `OBSERVE_SECONDS`       `60`                               每批观察等待时间

  `KUBECTL_TIMEOUT`       `30s`                              Kubernetes API 请求超时

  `LOG_ROOT`              `/data/logs/k8s-gray-scale-zero`   日志及 Snapshot 根目录

  `WECHAT_WEBHOOK_URL`    空                                 企业微信机器人 Webhook
  ----------------------------------------------------------------------------------

命令行参数会覆盖对应的环境变量默认值。

------------------------------------------------------------------------

## 5. 命令行参数

``` text
用法：
  ./k8s-gray-scale-zero.sh [options]

参数：
  --namespace NAME
  --language NAME
  --business all|api|service|api,service
  --deployment NAME
  --batch-size N
  --observe-seconds N
  --dry-run
  -h|--help
```

### 5.1 `--namespace`

指定目标 Kubernetes Namespace。

示例：

``` bash
./k8s-gray-scale-zero.sh --namespace dev-xxx
```

等价环境变量：

``` bash
export NAMESPACE=dev-xxx
```

### 5.2 `--language`

指定 Gray Deployment 必须匹配的：

``` text
language_type=<value>
```

例如：

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java
```

发现 Deployment 时使用：

``` bash
kubectl get deployments.apps \
  -n dev-xxx \
  -l module_name=gray,language_type=java
```

即使使用 `--deployment`
指定单个对象，脚本仍会重新校验标签，不能绕过保护条件。

### 5.3 `--business`

支持：

``` text
all
api
service
api,service
service,api
```

匹配规则：

  参数            名称匹配
  --------------- ----------------------------------
  `all`           所有通过其他规则的 `*-gray`
  `api`           `*-api-gray`
  `service`       `*-service-gray`
  `api,service`   `*-api-gray` 或 `*-service-gray`

示例：

``` bash
./k8s-gray-scale-zero.sh \
  --business api,service
```

### 5.4 `--deployment`

只处理指定 Deployment。

例如：

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --deployment dev-xxx-app-gray
```

该参数不会绕过：

``` text
*-gray
非 frontend
business 规则
module_name=gray
language_type=<指定值>
replicas > 0
HPA 检查
Formal 健康检查
```

### 5.5 `--batch-size`

设置每批归零的成功 Deployment 数量。

例如：

``` bash
--batch-size 3
```

表示每成功处理 3 个 Deployment 后进入一次观察与安全复核。

必须为正整数。

### 5.6 `--observe-seconds`

每批执行完成后的观察时间。

例如：

``` bash
--observe-seconds 120
```

表示等待 120 秒后重新检查：

``` text
已处理 Gray replicas 是否仍为 0
Formal desired 是否仍等于执行前基线
Formal ready 是否等于 desired
Formal available 是否等于 desired
```

可以设置为：

``` bash
--observe-seconds 0
```

此时不 sleep，但仍会执行批次安全复核。

### 5.7 `--dry-run`

执行演练，不真正调用 scale 修改 Deployment。

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business all \
  --dry-run
```

Dry Run 仍会执行：

``` text
参数检查
Kubernetes 连通性检查
Deployment 发现
标签过滤
HPA 检查
Formal 健康检查
基线采集
Snapshot
执行计划输出
```

但不会执行实际 `replicas=0`。

------------------------------------------------------------------------

## 6. 环境变量

支持：

``` bash
export NAMESPACE="dev-xxx"
export LANGUAGE_TYPE="java"
export BUSINESS_TYPE="all"
export BATCH_SIZE="5"
export OBSERVE_SECONDS="60"
export KUBECTL_TIMEOUT="30s"
export LOG_ROOT="/data/logs/k8s-gray-scale-zero"
export WECHAT_WEBHOOK_URL="..."
```

然后直接：

``` bash
./k8s-gray-scale-zero.sh
```

生产环境更建议将 Webhook 通过环境变量或安全凭据注入，不要硬编码到脚本。

------------------------------------------------------------------------

## 7. 常用执行示例

### 7.1 Java 灰度应用全部归零

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business all
```

### 7.2 只处理 API

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business api
```

### 7.3 同时处理 API 和 Service

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business api,service \
  --batch-size 5 \
  --observe-seconds 60
```

### 7.4 指定单个 Deployment

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --deployment dev-xxx-app-gray
```

### 7.5 Dry Run

建议首次运行先执行：

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business all \
  --dry-run
```

确认筛选结果后再执行正式任务。

------------------------------------------------------------------------

## 8. Deployment 筛选逻辑

批量模式首先执行标签发现：

``` text
module_name=gray
        +
language_type=<LANGUAGE_TYPE>
```

随后逐个进行二次过滤。

``` text
发现 Deployment
       │
       ▼
是否以 -gray 结尾？
       │
   NO ─┴─> SKIP: NOT_GRAY_SUFFIX
       │ YES
       ▼
名称是否包含 frontend？
       │
  YES ─┴─> SKIP: FRONTEND
       │ NO
       ▼
是否满足 BUSINESS_TYPE？
       │
   NO ─┴─> SKIP: BUSINESS
       │ YES
       ▼
重新读取标签
       │
       ├─ module_name != gray
       │
       └─ language_type != 指定语言
               │
               └─> SKIP: LABEL
       │
       ▼
读取 replicas
       │
       ├─ 无法确认 -> SKIP: REPLICAS_UNKNOWN
       │
       └─ replicas=0 -> SKIP: ALREADY_ZERO
       │
       ▼
进入 Candidate
```

------------------------------------------------------------------------

## 9. HPA 保护机制

脚本对 HPA 采用 **fail-closed**。

### 9.1 基线采集阶段

``` text
Candidate
   │
   ▼
查询 HPA
   │
   ├─ 查询失败
   │     └─> 整体停止
   │
   ├─ HPA 存在
   │     └─> SKIP
   │
   └─ 无 HPA
         ↓
      继续
```

HPA 匹配：

``` text
scaleTargetRef.kind == Deployment
scaleTargetRef.name == 当前 Gray Deployment
```

### 9.2 实际 scale 前

实际修改前会再次执行 HPA 检查，并在真正调用 `scale`
前再执行一次最终门禁。

拓扑：

``` text
第一次 HPA 检查
      ↓
Gray baseline 检查
      ↓
Formal 健康检查
      ↓
第二次 HPA 最终门禁
      ↓
scale
```

这样可以尽可能缩小"检查完成后突然创建 HPA"的竞态窗口。

------------------------------------------------------------------------

## 10. Gray 与 Formal 映射

脚本采用名称规则：

``` text
<name>-gray
     ↓
<name>
```

例如：

``` text
dev-xxx-app-gray
        ↓
dev-xxx-app
```

``` text
order-service-gray
        ↓
order-service
```

因此运行脚本前必须保证 Gray 与 Formal 的命名符合该约定。

------------------------------------------------------------------------

## 11. Formal 健康门禁

Formal 不仅要求 `spec.replicas > 0`。

必须满足：

``` text
desired == ready == available
```

例如：

``` text
spec.replicas           = 5
status.readyReplicas    = 5
status.availableReplicas= 5
```

才允许继续。

以下状态会停止：

``` text
desired=5 ready=4 available=4
desired=5 ready=5 available=3
desired=0
无法读取状态
desired 与执行前 baseline 不一致
```

这可以避免在 Formal 本身已经异常时继续关闭 Gray。

------------------------------------------------------------------------

## 12. Snapshot 机制

Snapshot 仅用于：

``` text
执行前基线记录
+
运行事件审计
+
故障排查
```

它不承担 Resume / Abort 状态机。

默认目录：

``` text
/data/logs/k8s-gray-scale-zero/snapshot/
```

文件格式：

``` text
gray-scale-zero-<RUN_ID>.snapshot
```

示例：

``` text
gray-scale-zero-20260826-160000-12345.snapshot
```

### 12.1 基线内容

示例：

``` text
# K8S Gray Scale Zero Snapshot
SNAPSHOT_VERSION=3.1.0
RUN_ID=20260826-160000-12345
START_TIME=2026-08-26 16:00:00
EXECUTOR=root
HOSTNAME=k8s-master
CURRENT_CONTEXT=pro-k8s
NAMESPACE=dev-xxx
LANGUAGE_TYPE=java
BUSINESS_TYPE=all
DEPLOYMENT_COUNT=2

DEPLOYMENT|dev-xxx-app-gray|2|dev-xxx-app|5
DEPLOYMENT|order-service-gray|1|order-service|4
```

字段：

``` text
DEPLOYMENT
GRAY_NAME
GRAY_REPLICAS
FORMAL_NAME
FORMAL_REPLICAS
```

### 12.2 Event

执行过程中追加：

``` text
EVENT|时间|事件|Deployment|附加信息
```

例如：

``` text
EVENT|2026-08-26 16:01:00|APPROVED||operator=root
EVENT|2026-08-26 16:01:03|SCALE_BEGIN|dev-xxx-app-gray|from=2,to=0
EVENT|2026-08-26 16:01:04|SUCCESS|dev-xxx-app-gray|gray=2->0,formal=dev-xxx-app:5
EVENT|2026-08-26 16:02:05|BATCH_VERIFY_OK||completed=1
EVENT|2026-08-26 16:02:06|COMPLETED||success=1,skipped=0
```

------------------------------------------------------------------------

## 13. 正式执行逻辑

整体执行链路：

``` text
main
 │
 ├─ parse_args
 ├─ init_dirs
 ├─ 注册 ERR / INT / TERM trap
 │
 ▼
run_main
 │
 ├─ acquire_lock
 │
 ▼
preflight
 │
 ├─ check_dependencies
 ├─ check_args
 ├─ check_k8s
 ├─ discover_deployments
 ├─ filter_deployments
 └─ collect_baseline
 │
 ▼
是否存在 FINAL_DEPLOYMENTS？
 │
 ├─ NO → Summary → Exit
 │
 └─ YES
       ↓
create_snapshot
       ↓
print_plan
       ↓
DRY_RUN？
 ├─ YES → 模拟 → Summary → Exit
 └─ NO
       ↓
人工输入 YES
       ↓
逐个 scale_one
       ↓
达到 BATCH_SIZE？
       ↓
batch_observe
       ↓
verify_success_deployments
       ↓
下一批
       ↓
最后不足一批也执行 observe + verify
       ↓
final_verify
       ↓
COMPLETED
```

------------------------------------------------------------------------

## 14. 单个 Deployment 执行拓扑

`scale_one()` 是核心变更函数。

``` text
Gray Deployment
       │
       ▼
HPA 查询
       │
       ├─ 查询失败 → FAIL
       ├─ 存在 HPA → SKIP
       └─ 无 HPA
             ↓
读取 Gray 当前 replicas
             │
             ├─ != baseline → FAIL
             └─ == baseline
                    ↓
             Formal 健康检查
                    │
                    ├─ FAIL → 停止
                    └─ PASS
                           ↓
                  最终 HPA 门禁
                           │
                           ├─ 查询失败 → FAIL
                           ├─ HPA 存在 → SKIP
                           └─ 无 HPA
                                  ↓
                    加入 Rollback 集合
                                  ↓
                    SCALE_BEGIN Event
                                  ↓
                  kubectl scale
                  --current-replicas=<baseline>
                  --replicas=0
                                  ↓
                    Gray replicas 二次读取
                                  │
                                  ├─ != 0 → FAIL
                                  └─ == 0
                                         ↓
                                  Formal 再次健康检查
                                         │
                                         ├─ FAIL → Rollback
                                         └─ PASS
                                                ↓
                                            SUCCESS
```

------------------------------------------------------------------------

## 15. `--current-replicas` 并发保护

实际归零：

``` bash
kubectl scale deployment <gray> \
  --current-replicas=<执行前副本数> \
  --replicas=0
```

假设基线：

``` text
Gray replicas = 3
```

执行前有人改成：

``` text
replicas = 5
```

此时：

``` text
expected current = 3
actual current   = 5
```

`kubectl scale --current-replicas=3` 会拒绝修改，而不是直接把 `5` 覆盖成
`0`。

这是防止并发操作的重要保护。

------------------------------------------------------------------------

## 16. Batch 与观察机制

假设：

``` text
BATCH_SIZE=5
OBSERVE_SECONDS=60
```

执行：

``` text
Gray #1 → 0
Gray #2 → 0
Gray #3 → 0
Gray #4 → 0
Gray #5 → 0
       ↓
等待 60 秒
       ↓
检查全部 SUCCESS Deployment
       │
       ├─ Gray 是否仍为 0
       │
       └─ Formal 是否：
             desired == baseline
             ready == desired
             available == desired
       ↓
PASS
       ↓
继续下一批
```

任何一个对象失败：

``` text
BATCH_VERIFY_FAILED
       ↓
停止下一批
       ↓
自动 Rollback
```

最后不足 `BATCH_SIZE` 的对象也会执行一次观察与复核。

------------------------------------------------------------------------

## 17. Rollback 机制

Rollback 只针对本次执行已经加入：

``` text
MODIFIED_DEPLOYMENTS
```

的 Gray Deployment。

对象在真正执行 scale 前加入该集合，因此即使：

``` text
API Server 已完成 scale
但 kubectl 客户端随后超时
```

也仍然具备 Rollback 保护。

### 17.1 回滚判断

``` text
当前 replicas == baseline
       │
       └─> ROLLBACK_NOOP

当前 replicas == 0
       │
       └─> 尝试恢复 baseline

当前 replicas != 0
且 != baseline
       │
       └─> ROLLBACK_CONFLICT
           不覆盖
```

### 17.2 Rollback 使用并发保护

恢复命令逻辑：

``` bash
kubectl scale deployment <gray> \
  --current-replicas=0 \
  --replicas=<baseline>
```

只有当前仍为 `0` 才允许恢复。

例如：

``` text
baseline = 3
归零后 = 0

人工随后改成 2
```

Rollback 看到：

``` text
current=2
```

不会执行：

``` text
2 → 3
```

而是记录：

``` text
ROLLBACK_CONFLICT
```

避免覆盖其他系统或人工变更。

### 17.3 信号保护

收到：

``` text
SIGINT
SIGTERM
```

脚本会进入自动 Rollback。

Rollback 一旦开始，会忽略普通 INT / TERM，尽最大努力完成恢复流程。

------------------------------------------------------------------------

## 18. 自动 Rollback 触发场景

典型触发条件包括：

``` text
Gray baseline 发生变化
Formal 健康检查失败
HPA 查询失败
scale 后 Gray 无法确认 replicas=0
scale 后 Formal 异常
批次安全复核失败
最终一致性复核失败
脚本 ERR trap
SIGINT
SIGTERM
```

对于执行前发现 HPA：

``` text
HPA 存在
```

则对应 Deployment 直接跳过，不视为失败。

------------------------------------------------------------------------

## 19. 日志

默认：

``` text
/data/logs/k8s-gray-scale-zero/
```

日志文件名根据脚本名生成：

``` text
/data/logs/k8s-gray-scale-zero/k8s-gray-scale-zero.log
```

如果实际脚本文件名为：

``` text
k8s-gray-scale-zero-optimized-v3.1.sh
```

日志对应：

``` text
k8s-gray-scale-zero-optimized-v3.1.log
```

目录权限脚本会尝试设置为：

``` text
750
```

日志：

``` text
640
```

------------------------------------------------------------------------

## 20. 企业微信通知

通过：

``` bash
export WECHAT_WEBHOOK_URL="..."
```

启用。

未配置时：

``` text
不要求 curl
不发送通知
不影响业务执行
```

通知失败也不会使 Kubernetes 操作失败。

建议不要将真实 Webhook Key 直接写入脚本或提交到 Git。

------------------------------------------------------------------------

## 21. Skip 原因

Summary 中可能看到：

  原因                 含义
  -------------------- --------------------------
  `NOT_GRAY_SUFFIX`    Deployment 不是 `*-gray`
  `FRONTEND`           名称包含 `frontend`
  `BUSINESS`           不符合业务类型
  `LABEL`              标签不符合保护规则
  `REPLICAS_UNKNOWN`   无法确认 Gray replicas
  `ALREADY_ZERO`       Gray 已经是 0
  `HPA`                基线阶段发现 HPA
  `HPA_LATE`           实际执行前发现新 HPA

这些对象不会执行 Gray 归零。

------------------------------------------------------------------------

## 22. 关键函数关系

``` text
main
 └─ run_main
     ├─ acquire_lock
     ├─ preflight
     │   ├─ check_dependencies
     │   ├─ check_args
     │   ├─ check_k8s
     │   ├─ discover_deployments
     │   ├─ filter_deployments
     │   └─ collect_baseline
     │       ├─ get_hpa_info
     │       ├─ get_replicas
     │       └─ get_deployment_health
     │
     ├─ create_snapshot
     ├─ print_plan
     ├─ confirm_start
     │
     ├─ scale_one
     │   ├─ get_hpa_info
     │   ├─ get_replicas
     │   ├─ verify_formal_health
     │   └─ kctl scale
     │
     ├─ batch_observe
     │   └─ verify_success_deployments
     │       ├─ get_replicas
     │       └─ verify_formal_health
     │
     ├─ final_verify
     │   └─ verify_success_deployments
     │
     └─ summary

ERR / INT / TERM
        │
        └─ rollback
            ├─ get_replicas
            └─ kctl scale
```

------------------------------------------------------------------------

## 23. 生产使用注意事项

### 23.1 强烈建议先 Dry Run

第一次执行：

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business all \
  --dry-run
```

重点确认：

``` text
Context
Namespace
FINAL_DEPLOYMENTS
Gray / Formal 映射
Gray baseline
Formal baseline
Skipped 对象
```

### 23.2 确认 Context

正式输入 `YES` 前必须确认输出：

``` text
Context=<目标集群>
Namespace=<目标命名空间>
```

脚本启动后 Kubernetes 业务请求会固定使用该 Context。

### 23.3 确认 Gray / Formal 命名规范

必须满足：

``` text
xxx-gray
   ↓
xxx
```

否则脚本无法正确识别 Formal。

### 23.4 HPA 对象会跳过

如果 Gray Deployment 存在 HPA：

``` text
不会自动修改 HPA
不会删除 HPA
不会修改 minReplicas
不会 scale=0
```

而是直接跳过。

这是有意的安全设计。

### 23.5 Formal 必须完全健康

脚本要求：

``` text
desired == ready == available
```

如果 Deployment 正在 RollingUpdate、Pod 尚未
Ready、节点异常、探针失败等，都可能导致任务停止。

建议等待 Formal 完全稳定后再执行。

### 23.6 不要与发布系统并发执行

虽然 `--current-replicas` 能保护副本并发变更，但仍建议执行期间避免：

``` text
Helm upgrade
Argo CD Sync
Jenkins Deployment 发布
人工 kubectl scale
HPA 新建/修改
Deployment rollout
```

否则可能触发基线变化、Rollback Conflict 或任务停止。

### 23.7 `flock` 只保护本工具实例

全局锁：

``` text
${LOG_ROOT}/k8s-gray-scale-zero.lock
```

只能防止使用相同 `LOG_ROOT` 的该工具并发运行。

它不能阻止：

``` text
人工 kubectl
Helm
Argo CD
其他 Shell
其他发布平台
```

修改 Deployment。

### 23.8 不要随意修改 LOG_ROOT 规避锁

如果两个进程分别配置不同 `LOG_ROOT`，会使用不同锁文件。

生产环境建议统一固定：

``` text
LOG_ROOT=/data/logs/k8s-gray-scale-zero
```

### 23.9 Snapshot 不是 Resume 文件

当前版本明确不支持：

``` text
--resume
--abort
--status
--rollback <snapshot>
```

Snapshot 主要用于基线和审计。

脚本进程退出后，不应假设可以通过 Snapshot 自动续跑。

### 23.10 Rollback 可能出现 Conflict

例如：

``` text
Gray baseline=3
脚本归零=0
人工随后改为=1
任务发生异常
```

Rollback 不会：

``` text
1 → 3
```

而会记录：

``` text
ROLLBACK_CONFLICT
```

这种情况必须人工确认实际业务状态后处理。

### 23.11 不建议用 kill -9

`SIGKILL`：

``` bash
kill -9 <pid>
```

无法被 Bash trap 捕获。

因此脚本无法执行自动 Rollback。

需要终止时，应优先：

``` bash
kill -TERM <pid>
```

或正常 `Ctrl+C`。

### 23.12 主机异常无法保证自动回滚

以下场景 Bash 无法可靠处理：

``` text
主机宕机
内核崩溃
进程被 SIGKILL
文件系统严重故障
容器/虚拟机被强制销毁
```

因此 Snapshot 仍然必须保留，便于人工核对：

``` text
哪些 Gray 原来是多少副本
哪些对象产生了 SCALE_BEGIN
哪些对象产生了 SUCCESS
```

------------------------------------------------------------------------

## 24. 推荐生产执行流程

建议标准 SOP：

``` text
1. 确认发布窗口
       ↓
2. 确认无 Helm / Argo CD / Jenkins 并发发布
       ↓
3. Dry Run
       ↓
4. 检查 Context / Namespace
       ↓
5. 检查 Gray / Formal 映射
       ↓
6. 检查 Skipped / HPA
       ↓
7. 正式运行
       ↓
8. 核对执行计划
       ↓
9. 输入 YES
       ↓
10. 观察每批执行结果
       ↓
11. 等待 COMPLETED
       ↓
12. 检查 Summary / Snapshot / 日志
```

------------------------------------------------------------------------

## 25. 推荐执行命令

生产 Java 环境示例：

``` bash
export WECHAT_WEBHOOK_URL="${WECHAT_WEBHOOK_URL}"

./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business api,service \
  --batch-size 5 \
  --observe-seconds 60
```

首次上线建议：

``` bash
./k8s-gray-scale-zero.sh \
  --namespace dev-xxx \
  --language java \
  --business api,service \
  --batch-size 5 \
  --observe-seconds 60 \
  --dry-run
```

------------------------------------------------------------------------

## 26. 设计边界

该工具定位是：

> **安全地执行 Kubernetes Gray Deployment
> replicas=0，而不是任务编排平台。**

因此当前版本有意不提供：

``` text
Resume
Abort
Pause
Status
断点续跑
Snapshot 状态机
跨进程任务恢复
```

核心执行模型保持：

``` text
发现
 ↓
过滤
 ↓
安全门禁
 ↓
基线 Snapshot
 ↓
人工审批
 ↓
分批归零
 ↓
批次复核
 ↓
最终复核
 ↓
完成

关键异常
 ↓
自动精准 Rollback
 ↓
退出
```

这使脚本在安全性、健壮性和维护复杂度之间保持相对清晰的边界。

------------------------------------------------------------------------

## 27. 故障排查建议

如果任务失败，建议按以下顺序检查：

``` text
1. 查看控制台 ERROR
2. 查看主日志
3. 查看本次 RUN_ID
4. 打开对应 Snapshot
5. 搜索 SCALE_BEGIN / SUCCESS
6. 搜索 ROLLED_BACK / ROLLBACK_CONFLICT / ROLLBACK_FAILED
7. kubectl 实际检查 Gray replicas
8. kubectl 检查 Formal desired / ready / available
9. 检查 HPA
10. 检查是否存在 Helm / Argo CD / Jenkins / 人工并发操作
```

常用检查：

``` bash
kubectl -n dev-xxx get deployment <gray>
kubectl -n dev-xxx get deployment <formal>
kubectl -n dev-xxx get hpa
kubectl -n dev-xxx describe deployment <formal>
```

------------------------------------------------------------------------

## 28. 版本说明

### v3.1.0

核心特性：

``` text
Simplified Production Hardened Edition
```

保留：

``` text
日志
全局锁
预检查
标签保护
HPA fail-closed
基线 Snapshot
人工确认
分批执行
批次安全复核
Formal 健康保护
--current-replicas 并发保护
自动 Rollback
企业微信通知
```

删除：

``` text
Resume
Abort
Pause
Status
Snapshot 状态机
```

目标是让脚本保持"一次性安全执行工具"的职责边界，避免演化为复杂任务编排系统。
