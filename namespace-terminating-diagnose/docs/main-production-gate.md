# main-production-gate 验收记录

本文件用于记录 `abchw517/kubernetes` 默认分支 `main` 的生产准入规则及真实 E2E 验收结果。

## 验收状态

| 项目 | 状态 |
|---|---|
| `main-production-gate` Production Ruleset | **Active** |
| Production Ruleset E2E Validation | **Completed** |
| 验收日期 | `2026-09-02` |
| 验收 PR | `#1` |
| Squash Merge Commit | `e4fe6b19b1ec73a9573e6d984d613ad61feb6ec3` |

> **结论：`main-production-gate` Production Ruleset E2E Validation 已标记为 Completed。**

## 当前 Ruleset

Ruleset：`main-production-gate`

Required Status Checks：

- `Shell, Python and YAML checks`
- `Bash syntax and ShellCheck`
- `JSON, mock E2E and exit-code contracts`
- `Secret Scan`

保护目标：

- 所有变更通过 Pull Request 进入 `main`；
- Required Checks 全部成功后才允许合并；
- PR 分支必须基于最新 `main`；
- 禁止删除 `main`；
- 禁止 non-fast-forward / force push；
- 保持 Linear History；
- 当前单人维护阶段 Required Approvals 为 `0`；
- 不要求 latest-push approval；
- 无 Ruleset bypass actor。

## Production Ruleset E2E Validation

真实验收链路：

```text
feature branch
    ↓
Pull Request #1
    ↓
故意注入 Bash syntax failure
    ↓
Required Checks failure
    ↓
服务端 Squash Merge 尝试
    ↓
405 Repository rule violations
    ↓
Merge Blocked ✅
    ↓
删除故障文件
    ↓
4 Required Checks 全部 SUCCESS
    ↓
PR mergeable=true
    ↓
Squash Merge
    ↓
main
    ↓
merge 后 main CI 再次 SUCCESS
```

### Blocked Path 验收

故障阶段：

- `Repository CI`：`failure`；
- `Namespace Terminating Diagnose Gate`：`failure`；
- GitHub 服务端实际拒绝 Merge；
- 返回：`Repository rule violations found`；
- 返回：`2 of 4 required status checks are failing`；
- HTTP Status：`405`。

结论：

```text
Required Check Failure
→ Ruleset 服务端强制阻断 Merge
→ PASS
```

### Allowed Path 验收

修复后：

- `Shell, Python and YAML checks`：`success`；
- `Bash syntax and ShellCheck`：`success`；
- `JSON, mock E2E and exit-code contracts`：`success`；
- `Secret Scan`：`success`；
- PR：`mergeable=true`；
- Squash Merge：成功；
- Merge Commit：`e4fe6b19b1ec73a9573e6d984d613ad61feb6ec3`；
- Merge 后 `Repository CI`：`success`；
- Merge 后 `Namespace Terminating Diagnose Gate`：`success`。

结论：

```text
4 Required Checks SUCCESS
→ Ruleset 允许 Squash Merge
→ main CI SUCCESS
→ PASS
```

## 最终判定

```text
main-production-gate
Production Ruleset E2E Validation
STATUS: COMPLETED
```

该 Ruleset 已通过真实的：

```text
feature branch
→ PR
→ CI failure
→ server-side merge blocked
→ CI recovery
→ 4 Required Checks success
→ Squash Merge success
→ main post-merge CI success
```

因此可以作为当前 `abchw517/kubernetes` 仓库 `main` 分支的生产准入基线。
