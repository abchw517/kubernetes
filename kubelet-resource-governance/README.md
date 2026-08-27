# kubelet-resource-governance

面向 Kubernetes **v1.34+** 的 Kubelet 资源治理工具，用于在 kubeadm 集群中以 **Kubelet Configuration Drop-in** 的方式管理资源、驱逐、Image GC、容器日志和 cgroup 等参数。

当前版本：**v2.3.1 Production Hardening**

> 设计目标：单节点事务可靠、配置与执行逻辑分离、失败自动回滚、适合 50 节点以内集群通过 Jenkins / Ansible / Salt 等外部编排器进行灰度批量发布。
>
> 明确不实现 Resume / Abort / 断点续跑；批量编排属于上层发布系统职责。

---

## 1. 文件说明

```text
kubelet-resource-governance.sh
kubelet-resource-governance.yaml
README.md
```

默认运行后涉及：

```text
/var/lib/kubelet/config.yaml                    # kubeadm 主配置，只读/备份，不修改
/etc/kubernetes/kubelet.conf.d/
└── 99-resource-governance.conf                # 本工具管理的 kubelet drop-in

/etc/systemd/system/kubelet.service.d/
└── 20-resource-governance.conf                # 按需注入 --config-dir

/data/logs/kubelet-resource-governance/         # 运行日志
<脚本目录>/backup/                              # 快照，默认保留最近 5 个
/run/lock/kubelet-resource-governance.lock      # 写操作全局锁
```

---

## 2. Kubernetes v1.34 / v1.35 / v1.36 兼容矩阵

| 项目 | v1.34 | v1.35 | v1.36 | 本工具策略 |
|---|---|---|---|---|
| `KubeletConfiguration` API | `kubelet.config.k8s.io/v1beta1` | `v1beta1` | `v1beta1` | 固定校验 `v1beta1` |
| `--config-dir` | Beta（自 v1.30 Beta） | GA | GA | v1.34+ 允许执行 |
| `*.conf` partial drop-in | 支持 | 支持 | 支持 | 使用 `99-resource-governance.conf` |
| drop-in 合并顺序 | 文件名字典序 | 文件名字典序 | 文件名字典序 | 检测是否存在高于 `99-*` 的覆盖文件 |
| CLI 覆盖 config/config-dir | 是 | 是 | 是 | 对模板管理字段执行 CLI 冲突检查 |
| `/configz` 查看最终合并配置 | 支持 | 支持 | 支持 | 有 API 凭据时进行字段级强校验 |
| `mergeDefaultEvictionSettings` | 支持 | 支持 | 支持 | 模板显式设置 `true` |
| `evictionSoftGracePeriod` | Soft Eviction 必需配套 | 同左 | 同左 | 脚本进行 signal 一一对应检查 |

官方参考：

- https://v1-34.docs.kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/
- https://kubernetes.io/blog/2025/12/22/kubernetes-v1-35-kubelet-config-drop-in-directory-ga/
- https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/

### 兼容性结论

```text
v1.34  : 可用，--config-dir 处于 Beta，建议严格灰度
v1.35  : 推荐，--config-dir 已 GA
v1.36  : 推荐，KubeletConfiguration 仍为 v1beta1
```

升级到后续 Kubernetes 大版本前，应重新核对 Kubelet Configuration API、字段废弃情况以及 kubelet CLI。

---

## 3. v2.3.0 修复的 P0 / P1

### P0-1：Soft Eviction 缺少 Grace Period

旧模板存在：

```yaml
evictionSoft:
  memory.available: "1024Mi"
  nodefs.available: "15%"
```

但没有 `evictionSoftGracePeriod`。

v2.3.0 已补充：

```yaml
evictionSoftGracePeriod:
  memory.available: "1m"
  nodefs.available: "2m"
  imagefs.available: "2m"
  nodefs.inodesFree: "2m"
```

脚本新增 cross-field 校验：

```text
evictionSoft keys
        ==
evictionSoftGracePeriod keys
```

任何 signal 缺失都拒绝 `check/apply`。

### P1-1：CLI 覆盖检测补全

新增检测包括：

```text
--max-pods
--pod-max-pids
--eviction-soft
--eviction-soft-grace-period
--eviction-max-pod-grace-period
--image-minimum-gc-age
--cgroup-driver
--cgroups-per-qos
```

以及原有 Image GC、日志、reserved、API QPS 等字段。

由于 kubelet 普通 CLI 参数优先级高于 `--config` / `--config-dir`，发现冲突将拒绝正式应用。

### P1-2：Apply 前健康门禁

正式 `apply` 要求：

```text
kubelet systemd active
        ↓
healthz == ok
        ↓
Node Ready=True（kubectl/API 可用时）
        ↓
允许进入备份与写阶段
```

避免在 kubelet 本身已有故障时执行配置变更，降低故障归因困难。

### P1-3：动态 healthz

不再写死：

```text
127.0.0.1:10248
```

脚本按以下优先级解析：

```text
CLI --healthz-bind-address / --healthz-port
        ↓
base config
        ↓
config-dir *.conf 字典序覆盖
        ↓
默认 127.0.0.1:10248
```

### P1-4：最终 Effective Config 校验

应用成功后：

```text
kubectl get --raw /api/v1/nodes/<node>/proxy/configz
```

当本机同时具备：

```text
kubectl
python3
PyYAML
Kubernetes API 权限
```

脚本会把模板声明的所有顶层字段与 `/configz` 最终值逐项比较。

如果 `kubectl` 不存在，则明确降级为：

```text
systemd + healthz 强校验
Node Ready / configz 跳过并记录 WARN
```

这样兼顾普通 worker 上无管理员 kubeconfig 的实际场景。

### P1-5：NodeName 识别加强

识别顺序：

```text
--hostname-override
hostname
hostname -s
hostname -f
```

### P1-6：路径安全

root 写操作前校验：

```text
路径必须为绝对路径
禁止 /
禁止换行路径
managed drop-in 必须是 DROPIN_DIR 直接子文件
systemd drop-in 必须是 SYSTEMD_DROPIN_DIR 直接子文件
拒绝目标目录/文件符号链接
root 写目录必须由 root 所有
```

锁实现移除了 `eval`，固定使用 FD 200 + `flock`。

### P1-7：快照 GC 时机

旧逻辑：

```text
backup
  ↓
立即 GC
  ↓
apply
```

新逻辑：

```text
backup
  ↓
apply
  ↓
restart
  ↓
verify
  ↓
COMMIT
  ↓
GC，仅保留最近 5 个
```

失败路径：

```text
apply failed
  ↓
rollback current snapshot
  ↓
rollback verify success
  ↓
GC
```

避免事务尚未完成就提前删除旧恢复点。

---

## 4. 核心架构拓扑

```text
                  +----------------------------------+
                  | kubelet-resource-governance.sh   |
                  +----------------+-----------------+
                                   |
             +---------------------+---------------------+
             |                                           |
             v                                           v
   +--------------------+                      +---------------------+
   | Configuration Plane |                      | Transaction Plane   |
   +--------------------+                      +---------------------+
   | YAML syntax         |                      | flock               |
   | API/kind            |                      | backup              |
   | soft/grace pairing  |                      | atomic install      |
   | CLI conflicts       |                      | daemon-reload       |
   | drop-in ordering    |                      | kubelet restart     |
   | path boundary       |                      | auto rollback       |
   +----------+---------+                      +----------+----------+
              |                                           |
              +---------------------+---------------------+
                                    |
                                    v
                         +----------------------+ 
                         | Verification Plane   |
                         +----------------------+
                         | systemd active       |
                         | dynamic healthz      |
                         | Node Ready           |
                         | managed file cmp     |
                         | /configz effective   |
                         +----------+-----------+
                                    |
                         +----------+----------+
                         |                     |
                         v                     v
                    COMMIT SUCCESS         VERIFY FAILED
                         |                     |
                         v                     v
                    Snapshot GC          Auto Rollback
```

---

## 5. 单节点业务逻辑

### `check`

```text
依赖检查
  ↓
路径安全
  ↓
版本 >= v1.34
  ↓
YAML 语法/结构
  ↓
Soft Eviction 交叉字段
  ↓
base config
  ↓
systemd 兼容性
  ↓
CLI conflict
  ↓
drop-in priority
  ↓
只报告 kubelet 当前状态
```

不修改系统。

### `apply`

```text
ROOT + LOCK
    ↓
CHECK
    ↓
PRE-APPLY HEALTH GATE
    ↓
SNAPSHOT
    ↓
RE-VALIDATE TEMPLATE
    ↓
ATOMIC INSTALL
    ↓
SYSTEMD DAEMON-RELOAD
    ↓
RESTART KUBELET
    ↓
VERIFY
    ├── service active
    ├── config-dir
    ├── managed file == template
    ├── healthz
    ├── Node Ready（可用时）
    └── /configz（可用时）
    ↓
COMMIT
    ↓
SNAPSHOT GC
```

任一写阶段失败：

```text
ERR trap
   ↓
仅恢复本工具管理的：
   ├── 99-resource-governance.conf
   └── 20-resource-governance.conf
   ↓
daemon-reload
   ↓
restart kubelet
   ↓
health verify
```

`/var/lib/kubelet/config.yaml` 只用于快照审计，rollback **不会覆盖它**，避免覆盖 kubeadm 升级后的合法变化。

---

## 6. 集群级发布架构

本脚本只解决：

```text
Node Transaction
```

集群层应由 Jenkins / Ansible / Salt 等负责：

```text
                 Cluster Orchestrator
                        |
            +-----------+-----------+
            |                       |
       Canary Worker             Control Plane
            |                       |
       1 Node First             One By One
            |
      verify / observe
            |
       2 Nodes / 5 Nodes
            |
       10% -> 20%
            |
        Remaining
```

50 节点以内建议发布节奏：

```text
1 台 worker
  ↓
观察 10~30 分钟
  ↓
2 台
  ↓
5 台
  ↓
20%
  ↓
剩余 worker
  ↓
Control Plane 永远一次 1 台
```

不建议：

```text
salt '*' cmd.run '... apply'
```

直接全量并行重启所有 kubelet。

---

## 7. YAML 基线说明

v2.3.1 在 v2.3.0 的 P0/P1 修复基础上，仅落地两项已确认的 P2 基线调整，不改变脚本命令接口和事务模型：

```yaml
maxPods: 110
podPidsLimit: 8192
containerLogMaxSize: "100Mi"
```

调整含义：

- `maxPods: 110`：作为普通业务节点的保守通用基线，降低过高 Pod 密度对 CNI、conntrack、kube-proxy、磁盘 inode 和 kubelet housekeeping 的压力。
- `podPidsLimit: 8192`：相比原来的 16384 收紧单 Pod PID/线程上限，同时兼顾高线程 JVM 工作负载，避免直接降到 4096 后对部分 Java 服务过于激进。
- `containerLogMaxSize` 本次保持 `100Mi` 不变，不额外扩大此次变更范围。

这些值仍然不是所有节点规格下的唯一最优值。后续建议按节点池拆 Profile：

```text
profiles/
├── general.conf
├── high-density.conf
└── memory-intensive.conf
```

需要结合：

```text
节点 CPU / Memory
PodCIDR / CNI IP 容量
Pod 密度
Java 线程规模
nodefs/imagefs 容量
日志采集链路
```

再决定 `maxPods`、`podPidsLimit`、reserved、日志和 eviction threshold。

---

## 8. 安装

```bash
mkdir -p /opt/kubelet-resource-governance
cd /opt/kubelet-resource-governance

chmod +x kubelet-resource-governance.sh
chown -R root:root /opt/kubelet-resource-governance
chmod 755 /opt/kubelet-resource-governance
```

建议确认：

```bash
bash -n kubelet-resource-governance.sh
./kubelet-resource-governance.sh check
./kubelet-resource-governance.sh diff
./kubelet-resource-governance.sh apply --dry-run
```

正式执行：

```bash
sudo ./kubelet-resource-governance.sh apply
```

---

## 9. 命令示例

### 检查

```bash
./kubelet-resource-governance.sh check
```

### Diff

```bash
./kubelet-resource-governance.sh diff
```

### Dry-run

```bash
./kubelet-resource-governance.sh apply --dry-run
```

### 手工快照

```bash
sudo ./kubelet-resource-governance.sh backup
```

### 正式应用

```bash
sudo ./kubelet-resource-governance.sh apply
```

### 状态

```bash
./kubelet-resource-governance.sh status
```

### 最近快照回滚

```bash
sudo ./kubelet-resource-governance.sh rollback
```

### 指定快照

```bash
sudo ./kubelet-resource-governance.sh rollback \
  --backup-id 20260827-101500-12345
```

---

## 10. 推荐上线步骤

```text
1. Git 保存脚本 + YAML
2. 目标节点执行 check
3. 执行 diff
4. 执行 apply --dry-run
5. Canary 1 台 worker
6. 确认：
   - systemctl status kubelet
   - Node Ready
   - Pod 稳定
   - Disk/Memory/PID Pressure
   - kubelet 日志
   - /configz（有权限时）
7. 批量扩展
8. Control Plane 一次一台
```

---

## 11. 重要注意事项

1. v1.34 的 `--config-dir` 仍是 Beta，生产使用必须先 Canary；v1.35+ 已 GA。
2. drop-in 文件按文件名字典序合并；本工具会拒绝存在优先级高于 `99-resource-governance.conf` 的其他 `*.conf`。
3. kubelet CLI 参数可以覆盖配置文件；发现管理字段 CLI 冲突会拒绝应用。
4. `evictionSoft` 与 `evictionSoftGracePeriod` 必须一一匹配。
5. 如果 worker 没有 `kubectl` 或 kubeconfig，Node Ready 与 `/configz` 会降级，但 systemd + healthz 仍是强校验。
6. 如果安装了 `kubectl`，但权限不足以读取本节点或 `/configz`，验证会失败并触发回滚；应提供正确只读权限或在无 kubectl 的执行节点运行。
7. 不要在同一节点并发运行多个 apply/rollback；工具使用 `flock` 拒绝并发写。
8. 不要把 `BACKUP_ROOT`、drop-in 或 systemd 目录放到非 root 可写目录。
9. 快照默认只保留最近 5 个有效快照；apply 事务结束前不会提前 GC。
10. 本工具不负责集群级并发控制，批量发布必须由外层 Orchestrator 控制批次。

---

## 12. 版本变更

### v2.3.1

- 保持 v2.3.0 的全部 P0/P1 修复和命令接口不变。
- 将通用基线 `maxPods` 从 `143` 调整为 `110`。
- 将通用基线 `podPidsLimit` 从 `16384` 调整为 `8192`。
- 不引入 Resume / Abort，不修改 apply / rollback 事务模型。

### v2.3.0

- 修复 `evictionSoft` 缺失 `evictionSoftGracePeriod`。
- 新增 Soft Eviction signal 交叉校验。
- 补齐受管参数 CLI conflict 检测。
- 新增 drop-in 高优先级覆盖检测。
- 正式 apply 增加健康节点前置门禁。
- healthz 地址/端口动态解析。
- NodeName 支持 `--hostname-override`。
- 有条件通过 `/configz` 校验最终 Effective Config。
- 加强 root 写路径、owner、symlink 安全边界。
- 移除 `eval` 锁实现。
- 原子写失败清理临时文件。
- rollback 关键命令显式检查返回码。
- 快照 GC 推迟到事务成功或成功回滚之后。
- 保持原命令接口，不增加 Resume / Abort。
