# kubelet-resource-governance

> v2.4.5 仅调整 Memory Profile 分档：继续直接使用 `/proc/meminfo` 的 `MemTotal` 原始 KiB 与 16/32/48/64/128GiB 阈值比较，不再先换算 GiB 后取整。`kubectl optional`、`crictl` Static Pod Check、`/configz`、快照和 rollback 逻辑保持不变。


Kubernetes v1.34+ Kubelet 资源治理工具。该工具面向 kubeadm 节点，通过 `--config-dir` + KubeletConfiguration drop-in 管理企业级 kubelet 基线，不直接修改 `/var/lib/kubelet/config.yaml`。

当前版本：**v2.4.5**。

## v2.4.5 变更说明

v2.4.5 **只调整 Memory Eviction Profile 分档**，不改 `kubectl optional`、`crictl` Static Pod Check、`/configz` Effective Config 校验、快照与 rollback 逻辑。

v2.4.4 已经采用 `/proc/meminfo` 的 `MemTotal` 原始 KiB 直接判档；v2.4.5 在此基础上新增 `48Gi` 档：

```text
MemTotal KiB
   │
   ├─ <= 16 * 1048576  -> 16Gi Profile
   ├─ <= 32 * 1048576  -> 32Gi Profile
   ├─ <= 48 * 1048576  -> 48Gi Profile
   ├─ <= 64 * 1048576  -> 64Gi Profile
   └─ >  64 * 1048576  -> 128Gi Profile
                              └─ >128Gi 仍按 128Gi 档封顶
```

例如标称 64GiB、Linux 实际可见内存约 63GiB 的节点，会稳定进入：

```text
detected=63Gi profile=64Gi soft=3072Mi hard=1536Mi
```

其中 `detected` 仅用于日志展示，`profile` 才是实际治理档位。

## 1. 设计目标

核心目标：

- 不直接修改 kubeadm 管理的 `/var/lib/kubelet/config.yaml`。
- 使用 `/etc/kubernetes/kubelet.conf.d/99-resource-governance.conf` 保存受管配置。
- 仅在 kubelet 尚未启用 `--config-dir` 时，按需创建 `/etc/systemd/system/kubelet.service.d/20-resource-governance.conf`。
- apply 前创建快照；写文件使用同目录临时文件 + `mv` 原子替换。
- kubelet 重启或校验失败时自动回滚本次快照。
- 不实现 Resume / Abort / 断点续跑，保持单节点事务模型简单。
- Memory Eviction Profile 只动态覆盖两个字段：
  - `evictionSoft.memory.available`
  - `evictionHard.memory.available`
- `kubectl` 不再是 apply 的硬依赖；Kubernetes API 仅作为增强校验。

## 2. 目录与职责

```text
/usr/lib/systemd/system/kubelet.service.d/
└── 10-kubeadm.conf
    └── RPM / kubeadm 管理，不由本工具修改

/etc/systemd/system/kubelet.service.d/
└── 20-resource-governance.conf
    └── 本工具按需创建，仅用于给 kubelet 注入 --config-dir

/var/lib/kubelet/config.yaml
└── kubeadm 主 KubeletConfiguration，本工具只读和备份

/etc/kubernetes/kubelet.conf.d/
└── 99-resource-governance.conf
    └── 本工具最终安装的企业资源治理 drop-in
```

## 3. 总体架构拓扑

```text
                         kubelet-resource-governance.sh
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
           Source YAML           Local Runtime          Snapshot
                │                     │                     │
                │               systemd / /proc             │
                │               healthz / crictl             │
                │                     │                     │
                ▼                     ▼                     ▼
      Memory Eviction Profile    Core Validation        backup/
                │                     │
                ▼                     │
       Effective Template             │
                │                     │
                └──────────┬──────────┘
                           ▼
            99-resource-governance.conf
                           │
                           ▼
                   systemctl restart kubelet
                           │
                  ┌────────┴────────┐
                  │                 │
                  ▼                 ▼
            Local Verify      Optional API Verify
                  │                 │
         active/config-dir          ├── Node Ready
         healthz/file hash          └── /configz
         CRI static pods
                  │
            ┌─────┴─────┐
            │           │
          PASS         FAIL
            │           │
            ▼           ▼
          COMMIT      ROLLBACK
```

## 4. 验证分层

### 4.1 本地核心校验（硬门禁）

这些检查不依赖 Kubernetes API：

```text
systemctl is-active kubelet
        ↓
/proc/<MainPID>/cmdline
        ↓
--config-dir 是否正确
        ↓
managed drop-in 是否与 Effective Template 一致
        ↓
healthz
        ↓
成功 / 失败回滚
```

正式 apply 的核心安全性由这层保证。

### 4.2 Control Plane Static Pod Health Check

仅当本机 `/etc/kubernetes/manifests` 存在 control-plane static pod manifest 时执行。

优先且仅使用 `crictl` 检查真实 Running 容器：

```text
/etc/kubernetes/manifests/*.yaml
            │
            ▼
       Control Plane?
        /         \
      No           Yes
      │             │
     SKIP       crictl info
                    │
              ┌─────┴─────┐
              │           │
          CRI usable   unavailable
              │           │
              ▼           ▼
          crictl ps       WARN/SKIP
              │
              ▼
        Static Pods Running
```

不会因为 kubelet 重启后短暂出现的 mirror pod `already exists` 日志直接判失败。

### 4.3 Kubernetes API 增强校验（可选）

只有同时满足以下条件时才执行：

```text
kubectl 命令存在
        +
Kubernetes API /readyz 可访问
        +
能够定位本机 Node
```

增强检查包括：

- Node `Ready=True`
- `/api/v1/nodes/<node>/proxy/configz`
- Effective Config 字段级比较

如果 root 没有 kubeconfig、worker 没安装 kubectl、API 临时不可访问：

```text
WARN + SKIP
```

不会因为“kubectl binary 存在但不可用”导致 apply 误失败。

如果 API 明确可访问并且 Node 已定位，但真实 `Ready=False`，则仍视为故障。

## 5. Memory Eviction Profile

Profile 只修改：

```yaml
evictionSoft:
  memory.available:

evictionHard:
  memory.available:
```

其他 eviction signal、`evictionMinimumReclaim`、`kubeReserved`、`systemReserved` 均不随节点内存变化。

| Node 物理内存 | Soft | Hard |
|---|---:|---:|
| `<= 16 GiB` | `1024Mi` | `500Mi` |
| `>16 && <=32 GiB` | `1536Mi` | `750Mi` |
| `>32 && <=48 GiB` | `2048Mi` | `1024Mi` |
| `>48 && <=64 GiB` | `3072Mi` | `1536Mi` |
| `>64 && <=128 GiB` | `4096Mi` | `2024Mi` |
| `>128 GiB` | `4096Mi` | `2024Mi`（封顶） |

节点内存来自：

```text
/proc/meminfo -> MemTotal (KiB)
```

Profile 判断直接使用 `MemTotal` 原始 KiB：

```text
MemTotal <= 16 * 1048576 KiB  -> 16Gi Profile
MemTotal <= 32 * 1048576 KiB  -> 32Gi Profile
MemTotal <= 48 * 1048576 KiB  -> 48Gi Profile
MemTotal <= 64 * 1048576 KiB  -> 64Gi Profile
MemTotal <=128 * 1048576 KiB  -> 128Gi Profile
MemTotal > 128 * 1048576 KiB  -> 128Gi Profile（封顶）
```

`NODE_MEMORY_GIB` 仅用于日志展示，不再参与档位判断。例如标称 64GiB 的节点，Linux 可能只显示约 63GiB；只要原始 `MemTotal` 不超过 64GiB 阈值，就稳定选择 `64Gi Profile / Soft=3072Mi / Hard=1536Mi`。

源 YAML 永远不被运行时修改。脚本会生成临时 Effective Template，然后安装到 managed drop-in。

## 6. 默认 KubeletConfiguration 参数

主要默认值：

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `maxPods` | `110` | 单节点最大 Pod 数 |
| `podPidsLimit` | `8192` | 单 Pod PID 上限 |
| `kubeAPIQPS` | `50` | kubelet API Client QPS |
| `kubeAPIBurst` | `100` | API Client burst |
| `nodeStatusUpdateFrequency` | `10s` | Node 状态更新周期 |
| `kubeReserved.cpu` | `500m` | kube 组件 CPU 预留 |
| `kubeReserved.memory` | `1Gi` | kube 组件内存预留 |
| `systemReserved.cpu` | `500m` | 系统 CPU 预留 |
| `systemReserved.memory` | `1Gi` | 系统内存预留 |
| `evictionSoft.memory.available` | `1024Mi` | 16GiB 及以下默认；由 Profile 动态覆盖 |
| `evictionHard.memory.available` | `500Mi` | 16GiB 及以下默认；由 Profile 动态覆盖 |
| `evictionPressureTransitionPeriod` | `5m` | Pressure 状态切换稳定期 |
| `imageMinimumGCAge` | `5m` | 镜像最小 GC 年龄 |
| `imageGCHighThresholdPercent` | `80` | Image GC 高水位 |
| `imageGCLowThresholdPercent` | `70` | Image GC 目标低水位 |
| `containerLogMaxSize` | `100Mi` | 单日志文件轮转大小 |
| `containerLogMaxFiles` | `5` | 每容器日志文件保留数 |
| `cgroupDriver` | `systemd` | kubelet cgroup driver |
| `cgroupsPerQOS` | `true` | 启用 QoS cgroup 层次 |

完整参数以 `kubelet-resource-governance.yaml` 为准。

## 7. Kubernetes 版本兼容矩阵

| Kubernetes | `KubeletConfiguration` | `--config-dir` | 建议 |
|---|---|---|---|
| v1.34 | `kubelet.config.k8s.io/v1beta1` | Beta，可使用 | 先 Canary |
| v1.35 | `kubelet.config.k8s.io/v1beta1` | GA | 推荐 |
| v1.36 | `kubelet.config.k8s.io/v1beta1` | GA | 推荐 |

本工具拒绝 kubelet `< v1.34`。

## 8. 命令接口

```bash
./kubelet-resource-governance.sh check
./kubelet-resource-governance.sh diff
sudo ./kubelet-resource-governance.sh backup
./kubelet-resource-governance.sh apply --dry-run
sudo ./kubelet-resource-governance.sh apply
./kubelet-resource-governance.sh status
sudo ./kubelet-resource-governance.sh rollback
sudo ./kubelet-resource-governance.sh rollback --backup-id YYYYMMDD-HHMMSS-PID
```

### `check`

只读检查：

- kubelet 版本
- YAML 结构与语义
- Soft Eviction / GracePeriod signal 配对
- systemd 启动兼容性
- CLI 高优先级覆盖冲突
- drop-in 字典序冲突
- 路径、owner、symlink 安全边界
- 当前检测内存（detected）与治理 Profile 档位

不修改系统。

### `diff`

根据当前 Node 内存渲染 Effective Template，再与现有：

```text
/etc/kubernetes/kubelet.conf.d/99-resource-governance.conf
```

执行 diff。

### `backup`

独立创建快照，默认只保留最近 5 个有效快照。

### `apply --dry-run`

模拟：

```text
precheck
  ↓
Memory Profile
  ↓
Effective Template
  ↓
diff
  ↓
systemd planned change
```

不会写持久化文件、不会重启 kubelet、不会创建正式 snapshot。

### `apply`

正式事务链：

```text
precheck
   ↓
local health gate
   ↓
Memory Profile
   ↓
backup
   ↓
atomic install
   ↓
systemctl daemon-reload
   ↓
systemctl restart kubelet
   ↓
local verify
   ↓
Control Plane CRI verify（如适用）
   ↓
Kubernetes API enhanced verify（可用时）
   ↓
COMMIT
```

任一硬门禁失败：

```text
ERR trap -> rollback current snapshot
```

### `status`

显示：

- 工具版本
- Node Memory Profile
- kubelet 版本 / service 状态
- Effective `--config-dir`
- managed/desired SHA256
- config drift
- healthz
- Kubernetes API 可用时显示 Node Ready
- 最近 snapshot 和 snapshot 数量

### `rollback`

回滚 managed kubelet drop-in 和 systemd drop-in。

不会覆盖 `/var/lib/kubelet/config.yaml`，因为该文件属于 kubeadm 生命周期管理范围。

## 9. 推荐生产执行流程

单节点：

```bash
chmod 750 kubelet-resource-governance.sh

./kubelet-resource-governance.sh check
./kubelet-resource-governance.sh diff
./kubelet-resource-governance.sh apply --dry-run
sudo ./kubelet-resource-governance.sh apply
./kubelet-resource-governance.sh status
```

集群建议：

```text
1 台 Worker Canary
       ↓
2 台 Worker
       ↓
约 10%~20% Batch
       ↓
剩余 Worker
       ↓
Control Plane 一次一台
```

不要并行重启多个 Control Plane kubelet。

## 10. apply 后人工复核

```bash
systemctl status kubelet --no-pager

PID=$(systemctl show kubelet -p MainPID --value)
tr '\0' ' ' <"/proc/${PID}/cmdline"
echo

ls -lah /etc/kubernetes/kubelet.conf.d/
ls -lah /etc/systemd/system/kubelet.service.d/

curl -fsS http://127.0.0.1:10248/healthz
```

Control Plane：

```bash
crictl info
crictl ps | grep -E 'kube-apiserver|kube-controller-manager|kube-scheduler|etcd'
```

如果当前 shell 有有效 kubeconfig，可额外检查：

```bash
kubectl get node "$(hostname)"
kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz"
```

## 11. 安全边界

工具明确保持：

- `set -Eeuo pipefail`
- `umask 027`
- root 写路径 canonical path 校验
- symlink 拒绝
- systemd/vendor 文件隔离
- `flock` 单节点写锁
- backup-before-write
- atomic file replacement
- 自动 rollback
- 不通过 kubectl 执行任何写操作
- Kubernetes API 只做 GET / readyz / configz 只读验证
- 不提供 Resume / Abort

## 12. 文件清单

```text
kubelet-resource-governance-v2.4.5/
├── kubelet-resource-governance.sh
├── kubelet-resource-governance.yaml
├── README.md
└── SHA256SUMS
```

如果放入 `kube-aiops` 仓库，建议目录：

```text
tools/kubelet-resource-governance/
```

避免覆盖仓库根目录用于 K8sGPT Phase 1.1 的主 README。
