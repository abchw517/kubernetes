#!/usr/bin/env python3
"""
pod_migrate.py — Kubernetes Pod 平滑迁移 CLI(生产级,适合 CI/CD 集成)

用法:
  python pod_migrate.py -d app -n 10.0.1.5              # 单 Pod 迁移(自动发现)
  python pod_migrate.py -d app -n 10.0.1.5 --dry-run     # 试运行
  python pod_migrate.py --batch pods.txt                  # 批量迁移(每行: deploy,node_ip)

退出码: 0=成功, 1=迁移失败(已 rollback), 2=pre-flight 失败
"""
import argparse
import subprocess
import sys
import time
import json
import logging

# ============================================================
# 日志配置
# ============================================================
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    level=logging.INFO,
)
log = logging.getLogger("pod-migrate")


# ============================================================
# kubectl 工具函数
# ============================================================

def kubectl(*args, check=True, timeout=30, dry_run=False):
    """执行 kubectl 命令。dry_run 时只跳过写操作,读操作始终实际执行。"""
    cmd = ["kubectl", *args]
    # 非 wait 类命令加 API 请求超时(防止 API server 不可达时挂死;wait 自带 --timeout)
    if "wait" not in args and "--request-timeout" not in args:
        cmd = ["kubectl", "--request-timeout=10s", *args]
    # 写操作关键字:dry_run 时只打印不执行
    WRITE_OPS = {"cordon", "uncordon", "annotate", "scale", "patch",
                 "rollout", "delete", "apply", "label", "taint", "drain"}
    if dry_run and any(a in WRITE_OPS for a in args):
        log.warning(f"[DRY-RUN] {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0, "", "")
    log.debug(f"执行: {' '.join(cmd)}")
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=check, timeout=timeout
        )
    except subprocess.CalledProcessError as e:
        log.error(f"命令失败: {' '.join(cmd)}\nstderr: {e.stderr.strip()}")
        raise
    except subprocess.TimeoutExpired:
        log.error(f"命令超时({timeout}s): {' '.join(cmd)}")
        raise


def kubectl_jsonpath(args, path, **kw):
    """取 jsonpath 值,失败返回空串(check 恒为 False)。
    弹出调用方可能误传的 check,避免与下方硬编码 check=False 重复冲突(TypeError)。"""
    kw.pop("check", None)
    r = kubectl(*args, "-o", f"jsonpath={path}", check=False, **kw)
    return r.stdout.strip()


def derive_label_selector(deploy, ns, dry_run=False):
    """从 Deployment spec.selector.matchLabels 反推 label selector。
    解析失败或无 matchLabels 时兜底 app=<deploy>。读操作始终实际执行。"""
    r = kubectl("get", "deploy", deploy, "-n", ns, "-o", "json", dry_run=dry_run)
    try:
        ml = json.loads(r.stdout).get("spec", {}).get("selector", {}).get("matchLabels", {})
        return ",".join(f"{k}={v}" for k, v in ml.items()) or f"app={deploy}"
    except Exception:
        return f"app={deploy}"


def retry(fn, attempts=3, delay=5):
    """指数退避重试(attempts 次,delay 秒起,每次翻倍)。"""
    for i in range(attempts):
        try:
            return fn()
        except Exception as e:
            if i == attempts - 1:
                raise
            wait = delay * (2 ** i)
            log.warning(f"第 {i+1} 次失败({e}),{wait}s 后重试...")
            time.sleep(wait)


# ============================================================
# PodMigrator:单 Pod 迁移状态机
# ============================================================

class PodMigrator:
    """管理单个 Pod 的完整迁移生命周期。

    状态流转: pending → running → success / failed → rolled_back
    任何步骤失败自动触发 rollback(逆序恢复)。
    """

    def __init__(self, deploy, pod, node, ns="default", timeout=300,
                 dry_run=False, uncordon=True, health_url=""):
        """初始化迁移参数。

        Args:
            deploy:    目标 Deployment 名称
            pod:       目标 Pod 名称(已通过自动发现或手动指定)
            node:      目标节点名(已从 IP 解析)
            ns:        命名空间(默认 default)
            timeout:   等待 Pod Ready 的超时秒数
            dry_run:   试运行模式(只打印不执行)
            uncordon:  迁移完成后是否自动 uncordon 节点
            health_url: 迁移后 HTTP 健康探针 URL(可选)
        """
        self.deploy = deploy       # Deployment 名称
        self.pod = pod             # 目标 Pod 名称
        self.node = node           # 目标节点名
        self.ns = ns               # 命名空间
        self.timeout = timeout     # Ready 超时秒数
        self.dry_run = dry_run     # 试运行开关
        self.uncordon = uncordon   # 是否自动 uncordon
        self.health_url = health_url  # HTTP 探针 URL

        # 原始值快照(preflight 阶段填充,rollback 时恢复)
        self.orig_replicas = None  # Deployment 原始副本数
        self.hpa_name = None       # HPA 名称(None = 无 HPA)
        self.hpa_min = None        # HPA 原始 minReplicas
        self.hpa_max = None        # HPA 原始 maxReplicas
        self.old_pods = ""         # scale_up 前的 Pod 名快照(用于精确发现新 Pod)
        self.label_selector = ""   # 从 Deployment spec 反推的 label selector

        # 操作状态标记(rollback 按逆序检查)
        self._state = {
            "cordoned": False,      # 是否已 cordon
            "annotated": False,     # 是否已设 PodDeletionCost
            "paused": False,        # 是否已 pause rollout
            "scaled_up": False,     # 是否已 scale +1(无 HPA)
            "hpa_patched": False,   # 是否已 patch HPA min/max
        }

    def _k(self, *args, **kw):
        """内部 kubectl 封装(自动传入 dry_run)。"""
        return kubectl(*args, check=kw.pop("check", True), dry_run=self.dry_run, **kw)

    # ============================================================
    # Step 0:前置检查
    # ============================================================

    def preflight(self):
        """迁移前置检查:Deployment/Pod/Node 存在性、策略、HPA。
        成功返回 True,失败返回 False。"""
        log.info("=" * 40)
        log.info("Pre-flight 检查")

        # Deployment 存在
        if not kubectl_jsonpath(
            ["get", "deploy", self.deploy, "-n", self.ns],
            "{.metadata.name}", dry_run=self.dry_run,
        ):
            log.error(f"Deployment '{self.deploy}' 不存在")
            return False

        # Pod 在目标节点上
        pod_node = kubectl_jsonpath(
            ["get", "pod", self.pod, "-n", self.ns],
            "{.spec.nodeName}", dry_run=self.dry_run,
        )
        if pod_node != self.node:
            log.error(f"Pod 不在 {self.node}(实际: {pod_node})")
            return False

        # 记录原始副本数
        self.orig_replicas = kubectl_jsonpath(
            ["get", "deploy", self.deploy, "-n", self.ns],
            "{.spec.replicas}", dry_run=self.dry_run,
        )
        # ponytail: spec.replicas 在 etcd 缺失时返回空串,按 1 处理足够覆盖单副本场景
        if not self.orig_replicas or not self.orig_replicas.isdigit():
            log.warning(f"spec.replicas 为空或非数字('{self.orig_replicas}'),按 1 处理")
            self.orig_replicas = "1"
        log.info(f"当前 replicas={self.orig_replicas}")

        # HPA 检测:用 scaleTargetRef 反查(避免同名 HPA 误匹配)
        hpa_r = kubectl("get", "hpa", "-n", self.ns,
                        "-o", f"jsonpath={{range .items[?(@.spec.scaleTargetRef.name=='{self.deploy}')}}}}{{.metadata.name}}{{end}}",
                        check=False, dry_run=self.dry_run)
        self.hpa_name = hpa_r.stdout.strip()
        if self.hpa_name:
            self.hpa_min = kubectl_jsonpath(
                ["get", "hpa", self.hpa_name, "-n", self.ns],
                "{.spec.minReplicas}", check=False, dry_run=self.dry_run)
            self.hpa_max = kubectl_jsonpath(
                ["get", "hpa", self.hpa_name, "-n", self.ns],
                "{.spec.maxReplicas}", check=False, dry_run=self.dry_run)
            if not self.hpa_max or not self.hpa_max.isdigit():
                log.error(f"HPA maxReplicas 不可解析: '{self.hpa_max}'")
                return False
            if not self.hpa_min or not self.hpa_min.isdigit():
                log.error(f"HPA minReplicas 不可解析: '{self.hpa_min}'")
                return False
            if int(self.hpa_min) + 1 > int(self.hpa_max):
                log.error(f"HPA min+1({int(self.hpa_min)+1}) > max({self.hpa_max}),无法扩容")
                return False
            log.info(f"检测到 HPA '{self.hpa_name}'(min={self.hpa_min}, max={self.hpa_max}) — 将用 patch min+1 调整")

        # 从 Deployment spec 反推 label selector(用 -o json 而非 jsonpath)
        self.label_selector = derive_label_selector(self.deploy, self.ns, dry_run=self.dry_run)
        log.info(f"Label selector: {self.label_selector}")

        # Pod 健康状态检查
        pod_phase = kubectl_jsonpath(
            ["get", "pod", self.pod, "-n", self.ns],
            "{.status.phase}", check=False, dry_run=self.dry_run)
        if pod_phase != "Running":
            log.error(f"目标 Pod 状态={pod_phase}(非 Running),拒绝迁移")
            return False
        pod_ready = kubectl_jsonpath(
            ["get", "pod", self.pod, "-n", self.ns],
            "{.status.containerStatuses[0].ready}", check=False, dry_run=self.dry_run)
        if pod_ready != "true":
            log.warning(f"目标 Pod ready={pod_ready}(NotReady 会被 RS 优先删除,cost 可能无效)")
        # Node 健康检查
        node_ready = kubectl_jsonpath(
            ["get", "node", self.node],
            "{.status.conditions[?(@.type=='Ready')].status}", check=False, dry_run=self.dry_run)
        if node_ready != "True":
            log.error(f"节点 {self.node} NotReady(status={node_ready}),请用 drain 代替")
            return False
        # Finalizer 检查
        has_fin = kubectl_jsonpath(
            ["get", "pod", self.pod, "-n", self.ns],
            "{.metadata.finalizers}", check=False, dry_run=self.dry_run)
        if has_fin:
            log.warning(f"目标 Pod 有 finalizer({has_fin}),删除后可能卡 Terminating")

        # PDB 检查:RS scaling 绕过 PDB
        try:
            import subprocess as _sp
            r = _sp.run(["kubectl", "get", "pdb", "-n", self.ns, "-o", "json"],
                        capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout:
                import json as _j
                pdbs = _j.loads(r.stdout).get("items", [])
                for pdb in pdbs:
                    sel = pdb.get("spec", {}).get("selector", {})
                    if sel and self.deploy in str(sel):
                        log.warning(f"存在匹配的 PDB: {pdb['metadata']['name']}(RS scaling 不受 PDB 约束)")
        except Exception:
            pass  # PDB 查询失败不阻塞

        # 进行中 rollout 检测
        updated = kubectl_jsonpath(
            ["get", "deploy", self.deploy, "-n", self.ns],
            "{.status.updatedReplicas}", check=False, dry_run=self.dry_run)
        total = kubectl_jsonpath(
            ["get", "deploy", self.deploy, "-n", self.ns],
            "{.status.replicas}", check=False, dry_run=self.dry_run)
        if updated and total and updated != total:
            log.error(f"Deployment 有进行中的 rollout(updated={updated}/total={total}),请等滚动完成再迁移")
            return False

        # 脏状态检测:拒绝在残留状态上运行(上次崩溃可能留下 paused/cordoned)
        is_paused = kubectl_jsonpath(
            ["get", "deploy", self.deploy, "-n", self.ns],
            "{.spec.paused}", check=False, dry_run=self.dry_run)
        if is_paused == "true":
            log.error("Deployment 已 paused(上次崩溃残留?),拒绝运行")
            return False
        is_cordoned = kubectl_jsonpath(
            ["get", "node", self.node],
            "{.spec.unschedulable}", check=False, dry_run=self.dry_run)
        if is_cordoned == "true":
            log.error(f"节点 {self.node} 已 Cordoned(上次残留?),拒绝运行")
            return False

        log.info("Pre-flight 通过")
        return True

    # ============================================================
    # Step 1-9:迁移主流程(每步一个方法)
    # ============================================================

    def step_cordon(self):
        """Step 1: Cordon 目标节点,阻止新 Pod 调度。"""
        log.info(f"[1/9] Cordon {self.node}")
        self._k("cordon", self.node)
        self._state["cordoned"] = True

    def step_set_cost(self):
        """Step 3: 给目标 Pod 设置 PodDeletionCost=-1000。
        RS 缩容时优先删除 cost 最低的 Pod。"""
        log.info("[3/9] 设 PodDeletionCost=-1000")
        self._k(
            "annotate", "pod", self.pod, "-n", self.ns,
            "controller.kubernetes.io/pod-deletion-cost=-1000", "--overwrite",
        )
        self._state["annotated"] = True

    def step_pause(self):
        """Step 4: 暂停 Deployment rollout(冻结滚动更新)。
        注意:pause 不影响 scale 和 HPA patch。"""
        log.info("[4/9] Pause Deployment")
        self._k("rollout", "pause", "deploy", self.deploy, "-n", self.ns)
        self._state["paused"] = True

    def step_scale_up(self):
        """Step 5: 扩容 +1。
        有 HPA:只 patch minReplicas+1(不动 max,避免过度扩容)。
        无 HPA:kubectl scale replicas+1。"""
        # 快照当前 Pod 列表(scale_up 执行前,最小化竞态窗口)
        self.old_pods = set(kubectl_jsonpath(
            ["get", "pods", "-n", self.ns, "-l", self.label_selector],
            "{.items[*].metadata.name}", check=False).split())
        log.info(f"快照旧 Pod: {len(self.old_pods)} 个")

        if self.hpa_name:
            if not self.hpa_min or not self.hpa_min.isdigit():
                log.error(f"HPA minReplicas 不可解析: '{self.hpa_min}'")
                raise ValueError(f"HPA minReplicas invalid: {self.hpa_min}")
            # 用 HPA【当前副本数+1】而非 min+1:负载下 current>min 时,min+1 不改 desired,
            # HPA 不会扩容、无新 Pod 产生,迁移必失败
            cur = kubectl_jsonpath(
                ["get", "hpa", self.hpa_name, "-n", self.ns],
                "{.status.currentReplicas}", dry_run=self.dry_run)
            cur = int(cur) if cur.isdigit() else int(self.hpa_min)
            new_min = cur + 1
            if self.hpa_max and self.hpa_max.isdigit() and new_min > int(self.hpa_max):
                raise ValueError(f"HPA current+1({new_min}) > max({self.hpa_max}),无法扩容")
            log.info(f"[5/9] HPA patch: min→{new_min}(current={cur})")
            self._k(
                "patch", "hpa", self.hpa_name, "-n", self.ns,
                "--type", "merge",
                f"-p={json.dumps({'spec': {'minReplicas': new_min}})}",
            )
            self._state["hpa_patched"] = True
        else:
            new_r = int(self.orig_replicas) + 1
            log.info(f"[5/9] Scale → {new_r}")
            self._k("scale", "deploy", self.deploy, "-n", self.ns, f"--replicas={new_r}")
            self._state["scaled_up"] = True

    def step_wait_ready(self):
        """Step 6: 等待新 Pod Ready。
        先轮询发现新 Pod 名(不在 old_pods 快照里的),再精确 wait 该 Pod。"""
        log.info(f"[6/9] 等待新 Pod Ready(超时 {self.timeout}s)")
        if self.dry_run:
            return
        # 轮询发现新 Pod(scale_up 后新 Pod 进入 API server 有延迟)
        new_pod = ""
        for _ in range(30):
            current = set(kubectl_jsonpath(
                ["get", "pods", "-n", self.ns, "-l", self.label_selector],
                "{.items[*].metadata.name}", check=False).split())
            diff = current - self.old_pods
            if diff:
                new_pod = diff.pop()
                break
            time.sleep(2)
        if not new_pod:
            raise RuntimeError("60s 内未发现新 Pod(scale_up 可能失败)")
        log.info(f"发现新 Pod: {new_pod}")
        # 精确等待该 Pod Ready(不用 label selector,避免旧 Pod 干扰)
        self._k("wait", "--for=condition=Ready", f"pod/{new_pod}",
                "-n", self.ns, f"--timeout={self.timeout}s",
                timeout=self.timeout + 30)  # subprocess timeout 给足余量

    def step_health_check(self):
        """可选:HTTP 健康探针(确认迁移后服务可用)。"""
        if not self.health_url or self.dry_run:
            return
        import urllib.request
        try:
            urllib.request.urlopen(self.health_url, timeout=10)
            log.info("健康探针通过")
        except Exception:
            log.warning("健康探针失败(非致命)")

    def step_confirm_hpa(self):
        """Step 7: 确认 HPA 状态(仅打印 desiredReplicas,HPA 已通过 patch 管理)。"""
        log.info("[7/9] HPA 确认")
        if self.hpa_name and not self.dry_run:
            desired = kubectl_jsonpath(
                ["get", "hpa", self.hpa_name, "-n", self.ns],
                "{.status.desiredReplicas}", check=False,
            )
            log.info(f"HPA desiredReplicas={desired}(扩容由 HPA 驱动)")

    def step_scale_down(self):
        """Step 8: 缩容 -1。
        有 HPA:恢复原始 min + 强制 scale(绕过 stabilization window,RS 按 cost 删旧 Pod)。
        无 HPA:kubectl scale 回原始副本数。"""
        if self.hpa_name:
            log.info(f"[8/9] HPA 恢复 min→{self.hpa_min} + 强制 scale 缩容")
            # 先恢复 HPA min
            self._k("patch", "hpa", self.hpa_name, "-n", self.ns,
                    "--type", "merge",
                    f"-p={json.dumps({'spec': {'minReplicas': int(self.hpa_min)}})}")
            # 再直接 scale 强制缩容(绕过 HPA stabilization window,RS 立即按 cost 删 Pod)
            self._k("scale", "deploy", self.deploy, "-n", self.ns,
                    f"--replicas={self.orig_replicas}")
            self._state["scaled_up"] = False  # 标记已缩回,rollback 不再重复 scale
        else:
            log.info(f"[8/9] Scale → {self.orig_replicas}(RS 删低 cost Pod)")
            self._k("scale", "deploy", self.deploy, "-n", self.ns,
                    f"--replicas={self.orig_replicas}")

    def step_wait_terminate(self):
        """等待旧 Pod 完全终止(轮询,最长 90s);超时则判失败。"""
        if self.dry_run:
            return
        log.info(f"等待旧 Pod {self.pod} 终止...")
        for _ in range(45):
            if not kubectl_jsonpath(
                ["get", "pod", self.pod, "-n", self.ns],
                "{.metadata.name}", check=False,
            ):
                log.info(f"旧 Pod {self.pod} 已终止")
                return
            time.sleep(2)
        raise TimeoutError(f"旧 Pod {self.pod} 90s 未终止(finalizer/preStop 过长),需手动确认")

    def step_cleanup(self):
        """Step 9: Resume rollout + Uncordon 节点(收尾)。
        resume 释放 pause 期间 hold 的 template 变更;
        uncordon 失败不阻断整体成功,只 warning 并提示手动恢复。"""
        log.info("[9/9] Resume + Uncordon 收尾")
        self._k("rollout", "resume", "deploy", self.deploy, "-n", self.ns)
        if self.uncordon:
            if not self.dry_run:
                try:
                    self._k("uncordon", self.node)
                    log.info(f"节点 {self.node} 已 Uncordon")
                except Exception:
                    log.warning(f"Uncordon {self.node} 失败!请手动执行: kubectl uncordon {self.node}")
            else:
                log.warning(f"[DRY-RUN] uncordon {self.node}")

    # ============================================================
    # 失败回滚
    # ============================================================

    def rollback(self):
        """失败回滚:按操作逆序恢复集群到迁移前状态。
        每步独立 try/except:一步失败不阻塞其它恢复。"""
        log.error("开始 Rollback...")
        rb_failures = []

        def _rb(label, fn):
            """执行单个恢复步骤,失败记录但不阻塞后续。"""
            try:
                fn()
            except Exception as e:
                log.error(f"Rollback 失败: {label} — {e}")
                rb_failures.append(label)

        if self._state.get("hpa_patched") and self.hpa_min:
            _rb("HPA min/max", lambda: self._k(
                "patch", "hpa", self.hpa_name, "-n", self.ns,
                "--type", "merge",
                f"-p={json.dumps({'spec': {'minReplicas': int(self.hpa_min)}})}",
                check=False))
        if self._state["scaled_up"] and self.orig_replicas is not None:
            _rb("Scale", lambda: self._k("scale", "deploy", self.deploy, "-n", self.ns,
                f"--replicas={self.orig_replicas}", check=False))
        if self._state.get("paused"):
            _rb("Resume", lambda: self._k("rollout", "resume", "deploy", self.deploy,
                "-n", self.ns, check=False))
        if self._state["annotated"]:
            _rb("Annotation", lambda: self._k("annotate", "pod", self.pod, "-n", self.ns,
                "controller.kubernetes.io/pod-deletion-cost-", check=False))
        if self._state["cordoned"] and self.uncordon:
            _rb("Uncordon", lambda: self._k("uncordon", self.node, check=False))

        if rb_failures:
            log.error(f"Rollback 部分失败,需人工处理: {rb_failures}")
        else:
            log.error("Rollback 完成(全部成功)")

    # ============================================================
    # 编排:执行完整迁移流程
    # ============================================================

    def migrate(self):
        """执行完整迁移:preflight → 9 步 → 成功/失败。
        返回退出码:0=成功, 1=失败(已 rollback), 2=pre-flight 失败。"""
        if not self.preflight():
            return 2
        try:
            self._run_all_steps()
            log.info("=" * 40)
            log.info(f"✓ 迁移完成: {self.pod} 已从 {self.node} 迁出")
            return 0
        except (Exception, KeyboardInterrupt) as e:
            if isinstance(e, KeyboardInterrupt):
                log.error("用户中断(Ctrl+C),触发 rollback...")
            else:
                log.error(f"迁移失败: {e}")
            self.rollback()
            return 1

    def _run_all_steps(self):
        """按顺序执行 9 个迁移步骤。任何步骤抛异常 → migrate 捕获并 rollback。"""
        self.step_cordon()         # Step 1: Cordon
        log.info(f"[2/9] 目标 Pod: {self.pod} @ {self.node}")  # Step 2: 确认(已在 preflight)
        self.step_set_cost()       # Step 3: PodDeletionCost
        self.step_pause()          # Step 4: Pause(防 CI/CD 干扰)
        self.step_scale_up()       # Step 5: 扩容 +1
        self.step_wait_ready()     # Step 6: 等待 Ready(kubectl wait,不受 pause 影响)
        self.step_health_check()   # 可选:健康探针
        self.step_confirm_hpa()    # Step 7: HPA 确认
        self.step_scale_down()     # Step 8: 缩容 -1
        self.step_wait_terminate() # 等待旧 Pod 终止
        self.step_cleanup()        # Step 9: Resume + Uncordon


# ============================================================
# 批量迁移
# ============================================================

def batch_migrate(file_path, **kw):
    """从文件批量迁移。文件格式:每行 deploy,node_ip[,namespace](逗号分隔)。
    逐个迁移,单个失败不影响后续。支持 UTF-8 BOM 与每行第三列指定 namespace。"""
    default_ns = kw.pop("ns", "default")
    with open(file_path, encoding="utf-8-sig") as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    total, success = len(lines), 0
    for i, line in enumerate(lines, 1):
        parts = line.split(",")
        if len(parts) < 2:
            log.warning(f"跳过无效行: {line}")
            continue
        deploy = parts[0].strip()
        node_ip = parts[1].strip()
        line_ns = parts[2].strip() if len(parts) > 2 else default_ns
        log.info(f"\n{'='*50}")
        log.info(f"批量迁移 [{i}/{total}]: {deploy} @ {node_ip} (ns={line_ns})")

        # 自动发现 Pod 和节点名(每行从 Deployment spec 反推 label selector,与单 Pod 模式一致)
        ls = derive_label_selector(deploy, line_ns, kw.get("dry_run", False))
        pod, node = _discover(deploy, node_ip, line_ns, kw.get("dry_run", False),
                               label_selector=ls)
        if not pod:
            log.error(f"第 {i} 个迁移:无法发现 Pod,跳过")
            continue

        migrator = PodMigrator(deploy, pod, node, ns=line_ns, **kw)
        rc = migrator.migrate()
        if rc == 0:
            success += 1
        else:
            log.error(f"第 {i} 个迁移失败(rc={rc}),继续下一个")
        if i < total:
            time.sleep(5)  # 批次间隔,避免资源抖动
    log.info(f"\n批量完成: {success}/{total} 成功")
    return 0 if success == total else 1


# ============================================================
# 自动发现:节点 IP → 节点名 + Pod
# ============================================================

def _discover(deploy, node_ip, ns, dry_run=False, label_selector=None):
    """从节点 IP 精确解析节点名,并在该节点上精确查找 Deployment 的 Pod。
    使用 jsonpath/field-selector 替代子串匹配,避免误匹配。
    返回 (pod_name, node_name),失败返回 (None, None)。"""
    # 节点 IP → 节点名(jsonpath 精确匹配 InternalIP)
    r = kubectl("get", "nodes", "-o",
                "jsonpath={range .items[*]}{.metadata.name}{'\\t'}"
                "{.status.addresses[?(@.type=='InternalIP')].address}{'\\n'}{end}",
                dry_run=dry_run)
    node_name = ""
    for line in r.stdout.strip().split("\n"):
        parts = line.split("\t")
        if len(parts) == 2 and parts[1] == node_ip:
            node_name = parts[0]
            break
    if not node_name:
        log.error(f"无法从 IP '{node_ip}' 精确匹配到节点")
        return None, None
    log.info(f"节点 IP {node_ip} → 节点名 {node_name}")

    # 在该节点上找 Deployment 的 Pod(field-selector + label 精确匹配)
    sel = label_selector or f"app={deploy}"
    r = kubectl("get", "pods", "-n", ns,
                "--field-selector", f"spec.nodeName={node_name}",
                "-l", sel,
                "-o", "jsonpath={.items[0].metadata.name}",
                dry_run=dry_run)
    pod_name = r.stdout.strip()
    if pod_name:
        # 检测同节点多 Pod
        r2 = kubectl("get", "pods", "-n", ns,
                      "--field-selector", f"spec.nodeName={node_name}",
                      "-l", sel,
                      "-o", "jsonpath={.items[*].metadata.name}",
                      dry_run=dry_run)
        count = len([p for p in r2.stdout.strip().split() if p])
        if count > 1:
            log.warning(f"节点 {node_name} 上有 {count} 个同 Deployment Pod,仅处理第一个: {pod_name}")
    if not pod_name:
        log.error(f"在节点 {node_name} 上未找到 '{deploy}' 的 Pod(label app={deploy})")
        return None, None
    log.info(f"发现 Pod: {pod_name} @ {node_name}")
    return pod_name, node_name


# ============================================================
# CLI 入口
# ============================================================

def main():
    """命令行入口:解析参数 → 单 Pod 迁移 或 批量迁移。"""
    p = argparse.ArgumentParser(
        description="Kubernetes Pod 平滑迁移工具(生产级)"
    )
    # 必选参数
    p.add_argument("-d", "--deployment", help="Deployment 名称")
    p.add_argument("-n", "--node-ip", dest="node_ip", help="Pod 所在节点 IP")
    # 可选参数
    p.add_argument("--pod", help="(可选)直接指定 Pod 名,跳过自动发现")
    p.add_argument("-N", "--namespace", default=None, help="Namespace(可选,未指定时自动查找)")
    p.add_argument("--timeout", type=int, default=300, help="等待 Ready 超时秒数(默认 300)")
    p.add_argument("--dry-run", action="store_true", help="试运行(只打印不执行)")
    p.add_argument("--no-uncordon", action="store_true", help="不 uncordon 节点")
    p.add_argument("--health", default="", help="HTTP 健康探针 URL")
    p.add_argument("--batch", help="批量迁移文件(每行: deploy,node_ip)")
    p.add_argument("--yes", action="store_true", help="跳过交互确认(CI/CD 用)")
    p.add_argument("-v", "--verbose", action="store_true", help="详细日志")
    args = p.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # 命名空间:未用 -N 指定时,自动从集群查找 Deployment 所在的 namespace
    # batch 模式除外(每行自带 ns,无需全局 -d/-N)
    ns = args.namespace
    if not ns and not args.batch:
        if not args.deployment:
            p.error("未指定 -N 且未指定 -d,无法自动查找 namespace")
        r = kubectl("get", "deployment", "-A",
                     "-o", f"jsonpath={{range .items[?(@.metadata.name=='{args.deployment}')}}{{.metadata.namespace}}{{'\\n'}}{{end}}",
                     dry_run=False)  # 只读操作,不走 dry_run
        ns_list = [n for n in r.stdout.strip().split("\n") if n]
        if not ns_list:
            p.error(f"集群中未找到 Deployment '{args.deployment}'")
        if len(ns_list) > 1:
            p.error(f"Deployment '{args.deployment}' 在多个 namespace: {ns_list},请用 -N 指定")
        ns = ns_list[0]
        log.info(f"自动发现 namespace: {ns}")
    elif not ns:
        # batch 模式且未指定 -N:行内无 namespace 时用 default
        ns = "default"

    # 公共参数(传给 PodMigrator)
    kw = dict(
        ns=ns, timeout=args.timeout, dry_run=args.dry_run,
        uncordon=not args.no_uncordon, health_url=args.health,
    )

    # ---- 批量模式 ----
    if args.batch:
        sys.exit(batch_migrate(args.batch, **kw))

    # ---- 单 Pod 模式 ----
    if not all([args.deployment, args.node_ip]):
        p.error("需要 -d <deployment> -n <node_ip>(或用 --batch 批量模式)")

    # 自动发现 Pod 和节点名(用户未指定 --pod 时)
    pod_name = args.pod
    node_name = ""
    # 先反推 label selector(用于 _discover,与 preflight 中逻辑一致)
    ls = derive_label_selector(args.deployment, ns, dry_run=False)
    if not pod_name:
        pod_name, node_name = _discover(
            args.deployment, args.node_ip, ns, args.dry_run,
            label_selector=ls,
        )
        if not pod_name:
            sys.exit(2)
    else:
        # 用户指定了 pod,仍需从 IP 解析节点名
        _, node_name = _discover(
            args.deployment, args.node_ip, ns, args.dry_run,
            label_selector=ls,
        )
        if not node_name:
            sys.exit(2)

    migrator = PodMigrator(args.deployment, pod_name, node_name, **kw)
    sys.exit(migrator.migrate())


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.error("已中断")
        sys.exit(130)
