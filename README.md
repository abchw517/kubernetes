# kubernetes 生产实践日常工具

沉淀 Kubernetes 生产环境日常运维中反复使用的工具脚本，目标是可以直接"抄作业"落地。

## 工具列表

| 工具 | 说明 |
|------|------|
| [kubelet-resource-governance](./kubelet-resource-governance) | Kubelet 参数调优工具：以 drop-in 方式管理资源、驱逐、Image GC、容器日志等参数，支持 check / diff / apply / rollback，写前快照、失败回滚 |
| pods 优雅删除迁移 | 按节点逐步驱逐并迁移 Pod，用于节点维护 / 腾挪场景，控制中断窗口 |

## 环境约定

- Kubernetes v1.34+，kubeadm 部署
- 脚本均在生产环境验证过，执行前请先阅读各工具目录内的 README
- 涉及节点变更的操作，先在测试集群演练
