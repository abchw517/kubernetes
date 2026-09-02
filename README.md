# kubernetes 生产实践日常工具

沉淀 Kubernetes 生产环境日常运维中反复使用的工具脚本，目标是可以直接"抄作业"落地。

## 工具列表

| 工具 | 说明 |
|------|------|
| [kubelet-resource-governance](./kubelet-resource-governance) | Kubelet 参数调优工具：以 drop-in 方式管理资源、驱逐、Image GC、容器日志等参数，支持 check / diff / apply / rollback，写前快照、失败回滚 |
| [pod-migrate](./pod-migrate) | Pod 平滑迁移工具（Shell / Python 双版本）：不改副本数、不整节点 drain，将指定节点上的 Deployment Pod 平滑迁到其他节点 |
| [k8s-gray-scale-zero](./k8s-gray-scale-zero) | 灰度 Deployment 副本批量安全置零：校验正式 Deployment 健康 / 无 HPA 干预后分批缩容，支持观察窗口与回退 |
| [namespace-terminating-diagnose](./namespace-terminating-diagnose) | Namespace 长时间 `Terminating` 只读诊断工具：自动检查 Conditions、APIService、全部 namespaced resources、Finalizer、Pod、PVC/PV/VolumeAttachment、CR、Webhook/VAP，并输出 SAFE / WARNING / DANGEROUS / FORCE-FINALIZE-READY 四级判定 |

## 工具设计原则

- **生产优先**：工具面向真实 Kubernetes 运维场景，而不是只覆盖实验环境。
- **安全优先**：高风险变更尽量采用 fail-closed、前置校验、快照、回滚或只读诊断机制。
- **根因优先**：优先定位真实 Controller、资源状态和依赖问题，不把强制删除、跳过 Finalizer 等 Break-Glass 手段作为默认路径。
- **可审计**：重要工具尽量保留日志、Snapshot、报告或明确 Exit Code，方便故障复盘和自动化平台接入。

## 环境约定

- Kubernetes v1.34+，kubeadm 部署
- 脚本均面向生产运维场景设计，执行前请先阅读各工具目录内的 README
- 涉及节点、工作负载或资源删除的变更操作，先在测试集群演练
- 只读诊断工具同样需要遵循 Kubernetes RBAC 最小权限原则
