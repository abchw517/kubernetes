# Terminating Resource Production Runbook

用于 Pod / PVC / PV / VolumeAttachment 长时间 `Terminating` 的生产处置。

## 1. 固定处理顺序

```text
check
  ↓
diagnose
  ↓
修复 kubelet / containerd / CSI / Controller / Node
  ↓
重新 diagnose
  ↓
force-check
  ↓
人工 Break-Glass 审批
```

不要把 `patch finalizers=[]` 作为默认路径。

## 2. Pod

```bash
./terminating-diagnose.sh diagnose pod \
  -n <namespace> \
  --name <pod>
```

优先检查：

- `deletionTimestamp` 和删除时长；
- `terminationGracePeriodSeconds` / PreStop；
- Owner 是否为 StatefulSet；
- Node 是否 Ready；
- PVC / PV / VolumeAttachment 链路；
- kubelet / containerd 是否仍能完成 KillPod、Unmount。

StatefulSet + RWO 场景，在确认原实例已停止和完成 fencing 前禁止无条件 Force Delete。

## 3. PVC

```bash
./terminating-diagnose.sh diagnose pvc \
  -n <namespace> \
  --name <pvc>
```

如果仍有 Pod 引用 PVC，`kubernetes.io/pvc-protection` 属于正常保护，不应绕过。

## 4. PV

```bash
./terminating-diagnose.sh diagnose pv \
  --name <pv>
```

必须确认：

- phase / claimRef；
- reclaimPolicy；
- CSI driver / volumeHandle；
- `pv-protection`；
- `external-provisioner.volume.kubernetes.io/finalizer`；
- VolumeAttachment；
- 真实 Storage Backend 状态。

`reclaimPolicy=Delete` 时，仅凭 Kubernetes API 不能证明后端 Volume 已经删除。

## 5. VolumeAttachment

```bash
./terminating-diagnose.sh diagnose volumeattachment \
  --name <volumeattachment>
```

重点确认：

- `status.attached`；
- `spec.nodeName`；
- Node Ready；
- `spec.source.persistentVolumeName`；
- CSI attacher；
- 存储后端真实 Attach/Detach 状态。

本工具对 VolumeAttachment 的 `force-check` 永远不会自动返回 Break-Glass Ready。

## 6. Break-Glass 前置清单

```text
[ ] deletionTimestamp 已超过治理阈值
[ ] 关联扫描完整，没有 RBAC/API error
[ ] 已确认业务 owner / 数据 owner
[ ] StatefulSet 原实例已确认停止
[ ] Node 故障已区分网络分区与永久关机
[ ] 必要时已完成 fencing
[ ] PVC 不再被 Pod 使用
[ ] PV 不再 Bound
[ ] VolumeAttachment 不再 attached
[ ] volumeHandle 已在真实存储后端核验
[ ] Delete reclaimPolicy 已确认后端 Volume 状态
[ ] 已确认 Snapshot / Backup
[ ] 已保存 diagnose/report 输出
```

任一关键项无法确认，保持 fail-closed。

## 7. 自动化平台约定

```text
exit 0  -> SAFE
exit 10 -> WARNING / 继续诊断
exit 20 -> DANGEROUS / 禁止强制处理
exit 30 -> 人工 Break-Glass Review
exit 64 -> Tool / API / RBAC Error
```

`exit 30` 不得直接映射成自动 Finalizer Patch、Force Delete 或 VolumeAttachment Delete。
