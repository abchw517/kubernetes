# kubernetes 生产实践日常工具

沉淀 Kubernetes 生产环境日常运维中反复使用的工具脚本，目标是可以直接“抄作业”落地。

## 工具列表

| 工具 | 说明 |
|------|------|
| [kubelet-resource-governance](./kubelet-resource-governance) | Kubelet 参数调优工具：以 drop-in 方式管理资源、驱逐、Image GC、容器日志等参数，支持 check / diff / apply / rollback，写前快照、失败回滚 |
| [pod-migrate](./pod-migrate) | Pod 平滑迁移工具（Shell / Python 双版本）：不改副本数、不整节点 drain，将指定节点上的 Deployment Pod 平滑迁到其他节点 |
| [k8s-gray-scale-zero](./k8s-gray-scale-zero) | 灰度 Deployment 副本批量安全置零：校验正式 Deployment 健康 / 无 HPA 干预后分批缩容，支持观察窗口与回退 |
| [namespace-terminating-diagnose](./namespace-terminating-diagnose) | Namespace 长时间 `Terminating` 生产级只读诊断 CLI：支持 `check / diagnose / report / force-check`，自动检查 Conditions、APIService、全部 namespaced resources、Finalizer、Pod、PVC/PV/VolumeAttachment、CR、Webhook/VAP，并提供 JSON、Prometheus 指标及 `>10m` 集群巡检入口 |

## namespace-terminating-diagnose v2.0.0

`namespace-terminating-diagnose` 已从单一诊断脚本升级为可接 Jenkins、运维平台和 AIOps 的模块化 CLI：

```text
check
├── 单 Namespace 轻量检查
└── --all-terminating
    └── NamespaceTerminating > 10m 集群巡检

diagnose
└── 全链路根因诊断

report
└── TXT + JSON + Prometheus 报告

force-check
└── FORCE-FINALIZE-READY 人工 Break-Glass 门禁
```

机器接口：

```text
--json
--prometheus-output <file>
```

集群巡检入口：

```bash
./namespace-terminating-diagnose/namespace-terminating-patrol.sh
```

默认：

```text
Namespace Terminating >= 600s
→ WARNING / exit 10
```

Prometheus textfile collector：

```bash
./namespace-terminating-diagnose/namespace-terminating-patrol.sh \
  --prometheus-output \
  /var/lib/node_exporter/textfile_collector/namespace_terminating.prom
```

详细参数、安全边界、JSON Schema、Prometheus 指标和 Jenkins 示例见：

[namespace-terminating-diagnose/README.md](./namespace-terminating-diagnose/README.md)

## 工具设计原则

- **生产优先**：工具面向真实 Kubernetes 运维场景，而不是只覆盖实验环境。
- **安全优先**：高风险变更尽量采用 fail-closed、前置校验、快照、回滚或只读诊断机制。
- **根因优先**：优先定位真实 Controller、资源状态和依赖问题，不把强制删除、跳过 Finalizer 等 Break-Glass 手段作为默认路径。
- **可审计**：重要工具尽量保留日志、Snapshot、报告或明确 Exit Code，方便故障复盘和自动化平台接入。
- **平台友好**：逐步统一 JSON、Prometheus、Exit Code 等机器接口，便于 Jenkins、运维门户和 AIOps 直接集成。

## 环境约定

- Kubernetes v1.34+，kubeadm 部署
- 脚本均面向生产运维场景设计，执行前请先阅读各工具目录内的 README
- 涉及节点、工作负载或资源删除的变更操作，先在测试集群演练
- 只读诊断工具同样需要遵循 Kubernetes RBAC 最小权限原则
