# main-production-gate 验收记录

本文件用于记录 `abchw517/kubernetes` 默认分支 `main` 的生产准入规则。

当前 Ruleset：`main-production-gate`。

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
- 当前单人维护阶段 Required Approvals 为 `0`，且不要求 latest-push approval。

本记录由一次真实的 `feature branch -> PR -> CI blocked -> CI success -> merge` 验收链路生成。
