#!/usr/bin/env bash
# ============================================================
# kubelet-resource-governance.sh
# Kubernetes v1.34+ Kubelet 资源治理工具
# v2.3.1 - P0/P1 Production Hardening + P2 Baseline Adjustment
#
# 命令：check / diff / backup / apply [--dry-run] / status / rollback [--backup-id ID]
# 设计：不修改 kubeadm 主配置；使用 --config-dir drop-in；写前快照；原子安装；失败回滚。
# 明确不提供 Resume / Abort / 断点续跑。
# ============================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VERSION="2.3.1"
COMMAND="${1:-help}"
if (($# > 0)); then shift; fi

# 可覆盖路径。生产环境建议脚本及 backup 根目录由 root 管理。
TEMPLATE_FILE="${TEMPLATE_FILE:-${SCRIPT_DIR}/kubelet-resource-governance.yaml}"
BASE_CONFIG="${BASE_CONFIG:-/var/lib/kubelet/config.yaml}"
DROPIN_DIR="${DROPIN_DIR:-/etc/kubernetes/kubelet.conf.d}"
MANAGED_DROPIN="${MANAGED_DROPIN:-${DROPIN_DIR}/99-resource-governance.conf}"
SYSTEMD_DROPIN_DIR="${SYSTEMD_DROPIN_DIR:-/etc/systemd/system/kubelet.service.d}"
SYSTEMD_DROPIN_FILE="${SYSTEMD_DROPIN_FILE:-${SYSTEMD_DROPIN_DIR}/20-resource-governance.conf}"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/backup}"
SNAPSHOT_RETENTION_COUNT="${SNAPSHOT_RETENTION_COUNT:-5}"
LOG_DIR="${LOG_DIR:-/data/logs/kubelet-resource-governance}"
LOCK_FILE="${LOCK_FILE:-/run/lock/kubelet-resource-governance.lock}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-180}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
MIN_KUBELET_MAJOR=1
MIN_KUBELET_MINOR=34

CURRENT_BACKUP_DIR=""
APPLY_IN_PROGRESS="false"
ROLLBACK_IN_PROGRESS="false"
ROLLBACK_ID=""
DRY_RUN="false"

while (($#)); do
    case "$1" in
        --backup-id)
            [[ $# -ge 2 ]] || { echo "--backup-id 缺少值" >&2; exit 2; }
            ROLLBACK_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN="true"; shift ;;
        -h|--help) COMMAND="help"; shift ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

LOG_READY="false"
init_log() {
    LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.sh}-$(date +%Y%m%d).log"
    if [[ "$DRY_RUN" == "true" ]]; then LOG_READY="false"; return 0; fi
    if [[ "$LOG_DIR" != /* || "$LOG_DIR" == "/" || -L "$LOG_DIR" ]]; then
        printf '%s [ERROR] %s 非法 LOG_DIR: %s\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$LOG_DIR" >&2
        return 1
    fi
    if mkdir -p "$LOG_DIR" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
        chmod 640 "$LOG_FILE" 2>/dev/null || true
        LOG_READY="true"
    else
        LOG_READY="false"
        printf '%s [WARN] %s 无法写日志目录 %s，将仅输出到 stderr\n' \
            "$(date '+%F %T')" "$SCRIPT_NAME" "$LOG_DIR" >&2
    fi
}

log() {
    local level="$1"; shift
    local line="$(date '+%F %T') [${level}] ${SCRIPT_NAME} $*"
    if [[ "$LOG_READY" == "true" ]]; then printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
    else printf '%s\n' "$line" >&2; fi
}
info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }

usage() {
    cat <<EOF_USAGE
${SCRIPT_NAME} v${VERSION}

用法：
  ./${SCRIPT_NAME} check
  ./${SCRIPT_NAME} diff
  sudo ./${SCRIPT_NAME} backup
  ./${SCRIPT_NAME} apply --dry-run
  sudo ./${SCRIPT_NAME} apply
  ./${SCRIPT_NAME} status
  sudo ./${SCRIPT_NAME} rollback [--backup-id YYYYMMDD-HHMMSS-PID]

命令：
  check       版本、模板、systemd、CLI 冲突、路径安全检查；不修改系统
  diff        显示受管 drop-in 与模板差异，并预览 systemd 变化
  backup      创建独立快照；默认仅保留最近 ${SNAPSHOT_RETENTION_COUNT} 个有效快照
  apply       precheck -> 健康门禁 -> backup -> install -> restart -> verify
  apply --dry-run  完整预演，不写文件、不 reload/restart、不创建正式快照
  status      查看 kubelet、healthz、Node、config-dir、漂移和快照状态
  rollback    回滚最近或指定快照

主要环境变量：
  TEMPLATE_FILE BASE_CONFIG DROPIN_DIR MANAGED_DROPIN
  SYSTEMD_DROPIN_DIR SYSTEMD_DROPIN_FILE BACKUP_ROOT
  SNAPSHOT_RETENTION_COUNT LOG_DIR LOCK_FILE
  NODE_READY_TIMEOUT HEALTH_INTERVAL
EOF_USAGE
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then error "命令 ${COMMAND} 必须使用 root 权限执行"; return 1; fi
}
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { error "缺少必要命令: $1"; return 1; }
}
canonical_path() { readlink -m -- "$1"; }

# root 写路径边界：绝对路径、目标非符号链接、目标必须落在预期父目录。
validate_runtime_paths() {
    local dropin managed systemd_dir systemd_file backup path owner parent
    dropin="$(canonical_path "$DROPIN_DIR")"
    managed="$(canonical_path "$MANAGED_DROPIN")"
    systemd_dir="$(canonical_path "$SYSTEMD_DROPIN_DIR")"
    systemd_file="$(canonical_path "$SYSTEMD_DROPIN_FILE")"
    backup="$(canonical_path "$BACKUP_ROOT")"

    for path in "$BASE_CONFIG" "$DROPIN_DIR" "$MANAGED_DROPIN" "$SYSTEMD_DROPIN_DIR" \
                "$SYSTEMD_DROPIN_FILE" "$BACKUP_ROOT" "$LOCK_FILE"; do
        [[ "$path" == /* && "$path" != "/" && "$path" != *$'\n'* ]] || {
            error "系统路径必须为安全绝对路径且不能为 /: $path"; return 1;
        }
    done
    for path in "$DROPIN_DIR" "$MANAGED_DROPIN" "$SYSTEMD_DROPIN_DIR" "$SYSTEMD_DROPIN_FILE" "$BACKUP_ROOT"; do
        [[ ! -L "$path" ]] || { error "拒绝符号链接写路径: $path"; return 1; }
    done
    [[ "$(dirname "$managed")" == "$dropin" ]] || {
        error "MANAGED_DROPIN 必须是 DROPIN_DIR 的直接子文件"; return 1;
    }
    [[ "$(dirname "$systemd_file")" == "$systemd_dir" ]] || {
        error "SYSTEMD_DROPIN_FILE 必须是 SYSTEMD_DROPIN_DIR 的直接子文件"; return 1;
    }
    [[ "$backup" != "$dropin" && "$backup" != "$systemd_dir" ]] || {
        error "BACKUP_ROOT 不能与 kubelet/systemd 配置目录相同"; return 1;
    }
    for path in "$DROPIN_DIR" "$SYSTEMD_DROPIN_DIR" "$BACKUP_ROOT"; do
        if [[ -e "$path" ]]; then
            owner="$(stat -c '%u' "$path" 2>/dev/null || echo unknown)"
            [[ "$owner" == "0" ]] || { error "root 写目录必须由 root 所有: $path owner=$owner"; return 1; }
        else
            parent="$(dirname "$path")"
            while [[ ! -e "$parent" && "$parent" != "/" ]]; do parent="$(dirname "$parent")"; done
            owner="$(stat -c '%u' "$parent" 2>/dev/null || echo unknown)"
            [[ "$owner" == "0" ]] || { error "待创建目录的已存在父目录必须由 root 所有: $parent"; return 1; }
        fi
    done
}

acquire_lock() {
    require_cmd flock
    [[ "$LOCK_FILE" == /* && "$LOCK_FILE" != "/" && ! -L "$LOCK_FILE" ]] || {
        error "非法 LOCK_FILE: $LOCK_FILE"; return 1;
    }
    local parent="$(dirname "$LOCK_FILE")" owner
    mkdir -p "$parent"
    owner="$(stat -c '%u' "$parent" 2>/dev/null || echo unknown)"
    [[ "$owner" == "0" ]] || { error "LOCK_FILE 父目录必须由 root 所有: $parent"; return 1; }
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then error "已有实例正在执行: $LOCK_FILE"; return 1; fi
}

sha256_of() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$file" | awk '{print $1}'
    else printf 'unavailable\n'; fi
}
get_execstart() { systemctl show kubelet -p ExecStart --value 2>/dev/null || true; }
get_unit_text() { systemctl cat kubelet 2>/dev/null || true; }

get_config_dir_from_execstart() {
    local token execstart="$(get_execstart)"
    token="$(grep -oE -- '--config-dir(=|[[:space:]])[^[:space:];}]+' <<<"$execstart" | head -n1 || true)"
    [[ -n "$token" ]] || return 1
    token="${token#--config-dir=}"; token="${token#--config-dir }"
    printf '%s\n' "$token"
}

version_ge_134() {
    local version raw major minor
    version="$(kubelet --version 2>/dev/null || true)"
    raw="$(awk '{print $2}' <<<"$version" | sed 's/^v//')"
    major="${raw%%.*}"; minor="${raw#*.}"; minor="${minor%%.*}"; minor="${minor//[^0-9]/}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || {
        error "无法解析 kubelet 版本: ${version:-unknown}"; return 1;
    }
    info "检测到 kubelet 版本: $version"
    if (( major < MIN_KUBELET_MAJOR || (major == MIN_KUBELET_MAJOR && minor < MIN_KUBELET_MINOR) )); then
        error "kubelet 版本低于 v1.34，拒绝执行"; return 1
    fi
}

extract_scalar_from_file() {
    local file="$1" key="$2"
    awk -v key="$key" '$0 ~ "^" key ":[[:space:]]*" {
        sub("^" key ":[[:space:]]*", ""); gsub(/[[:space:]]+#.*/, ""); gsub(/^"|"$/, ""); print; exit
    }' "$file" 2>/dev/null
}
extract_top_scalar() { extract_scalar_from_file "$TEMPLATE_FILE" "$1"; }

extract_map_keys() {
    local section="$1"
    awk -v section="$section" '
        $0 ~ "^" section ":[[:space:]]*$" {inside=1; next}
        inside && /^[^[:space:]#][^:]*:/ {exit}
        inside && /^[[:space:]]+[^#[:space:]][^:]*:/ {
            line=$0; sub(/^[[:space:]]+/, "", line); sub(/:.*/, "", line); print line
        }
    ' "$TEMPLATE_FILE" | LC_ALL=C sort -u
}

validate_yaml_parser_if_available() {
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - "$TEMPLATE_FILE" <<'PY_YAML'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f: data=yaml.safe_load(f)
if not isinstance(data, dict): raise SystemExit("YAML 顶层必须为 mapping/object")
if data.get("apiVersion") != "kubelet.config.k8s.io/v1beta1": raise SystemExit("apiVersion 错误")
if data.get("kind") != "KubeletConfiguration": raise SystemExit("kind 错误")
PY_YAML
        info "YAML 语法解析检查通过（python3 + PyYAML）"
    else
        warn "未发现 python3+PyYAML；仅执行脚本内置结构/交叉字段检查"
    fi
}

# P0：soft threshold 与 grace period 必须按 signal 一一对应。
validate_eviction_soft_pair() {
    local soft grace
    soft="$(extract_map_keys evictionSoft)"
    [[ -z "$soft" ]] && return 0
    grace="$(extract_map_keys evictionSoftGracePeriod)"
    [[ -n "$grace" ]] || { error "配置 evictionSoft 时必须配置 evictionSoftGracePeriod"; return 1; }
    if [[ "$soft" != "$grace" ]]; then
        error "evictionSoft 与 evictionSoftGracePeriod 的 signal 必须一一对应"
        error "soft=[$(tr '\n' ',' <<<"$soft" | sed 's/,$//')] grace=[$(tr '\n' ',' <<<"$grace" | sed 's/,$//')]"
        return 1
    fi
}

validate_template() {
    [[ -r "$TEMPLATE_FILE" ]] || { error "模板不存在或不可读: $TEMPLATE_FILE"; return 1; }
    grep -Eq '^apiVersion:[[:space:]]*kubelet\.config\.k8s\.io/v1beta1[[:space:]]*$' "$TEMPLATE_FILE" || {
        error "模板 apiVersion 必须为 kubelet.config.k8s.io/v1beta1"; return 1;
    }
    grep -Eq '^kind:[[:space:]]*KubeletConfiguration[[:space:]]*$' "$TEMPLATE_FILE" || {
        error "模板 kind 必须为 KubeletConfiguration"; return 1;
    }
    validate_yaml_parser_if_available
    validate_eviction_soft_pair

    local high low files ro
    high="$(extract_top_scalar imageGCHighThresholdPercent)"
    low="$(extract_top_scalar imageGCLowThresholdPercent)"
    files="$(extract_top_scalar containerLogMaxFiles)"
    ro="$(extract_top_scalar readOnlyPort)"
    [[ "$high" =~ ^[0-9]+$ && "$low" =~ ^[0-9]+$ ]] || {
        error "imageGCHighThresholdPercent / imageGCLowThresholdPercent 必须为整数"; return 1;
    }
    (( high > low && high <= 100 && low >= 0 )) || {
        error "Image GC 阈值要求 0 <= Low < High <= 100，当前 Low=${low} High=${high}"; return 1;
    }
    [[ "$files" =~ ^[0-9]+$ ]] && (( files >= 2 )) || {
        error "containerLogMaxFiles 必须为 >=2 的整数"; return 1;
    }
    [[ -z "$ro" || "$ro" == "0" ]] || warn "readOnlyPort=${ro}；生产建议 0"
    grep -Eq '^mergeDefaultEvictionSettings:[[:space:]]*true[[:space:]]*$' "$TEMPLATE_FILE" || \
        warn "未启用 mergeDefaultEvictionSettings: true；请确认 evictionHard 未遗漏默认阈值"
    info "资源治理模板检查通过: $TEMPLATE_FILE"
}

check_base_config() {
    [[ -r "$BASE_CONFIG" ]] || { error "Kubelet 主配置不存在或不可读: $BASE_CONFIG"; return 1; }
    grep -Eq '^apiVersion:[[:space:]]*kubelet\.config\.k8s\.io/v1beta1[[:space:]]*$' "$BASE_CONFIG" || {
        error "主配置不是 kubelet.config.k8s.io/v1beta1: $BASE_CONFIG"; return 1;
    }
    grep -Eq '^kind:[[:space:]]*KubeletConfiguration[[:space:]]*$' "$BASE_CONFIG" || {
        error "主配置缺少 kind: KubeletConfiguration"; return 1;
    }
    info "主配置检查通过: $BASE_CONFIG"
}

# CLI 参数优先级高于 config/config-dir；覆盖模板字段时拒绝 apply。
check_cli_conflicts() {
    local execstart="$(get_execstart)" conflict=0 flag
    local flags=(
        --max-pods --pod-max-pids
        --eviction-soft --eviction-soft-grace-period --eviction-hard
        --eviction-minimum-reclaim --eviction-pressure-transition-period --eviction-max-pod-grace-period
        --image-minimum-gc-age --image-gc-high-threshold --image-gc-low-threshold
        --container-log-max-size --container-log-max-files
        --kube-reserved --system-reserved --enforce-node-allocatable
        --kube-api-qps --kube-api-burst --node-status-update-frequency
        --cgroup-driver --cgroups-per-qos --read-only-port --anonymous-auth --authorization-mode
    )
    for flag in "${flags[@]}"; do
        if grep -Eq -- "(^|[[:space:]])${flag}(=|[[:space:]])" <<<"$execstart"; then
            error "检测到会覆盖治理模板的 kubelet CLI 参数: $flag"; conflict=1
        fi
    done
    (( conflict == 0 )) || { error "请先清理上述高优先级 CLI 参数"; return 1; }
    info "未检测到治理项 CLI 优先级冲突"
}

# 不允许 MANAGED_DROPIN 后面仍有更高字典序 *.conf 覆盖治理配置。
check_dropin_order() {
    [[ -d "$DROPIN_DIR" ]] || return 0
    local managed_name="$(basename "$MANAGED_DROPIN")" name conflict=0
    while IFS= read -r name; do
        [[ "$name" == "$managed_name" ]] && continue
        if [[ "$name" > "$managed_name" ]]; then
            error "存在优先级高于 ${managed_name} 的 kubelet drop-in: $name"; conflict=1
        fi
    done < <(find "$DROPIN_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    (( conflict == 0 )) || return 1
}

check_systemd_compatibility() {
    local unit="$(get_unit_text)" effective_dir config_args
    [[ -n "$unit" ]] || { error "无法读取 kubelet systemd unit"; return 1; }
    if effective_dir="$(get_config_dir_from_execstart 2>/dev/null)"; then
        [[ "$(canonical_path "$effective_dir")" == "$(canonical_path "$DROPIN_DIR")" ]] || {
            error "kubelet 已使用其他 --config-dir: $effective_dir"; return 1;
        }
        info "kubelet 已启用目标 --config-dir: $effective_dir"; return 0
    fi
    grep -q '\$KUBELET_CONFIG_ARGS' <<<"$unit" || {
        error "当前 kubelet unit 未通过 \$KUBELET_CONFIG_ARGS 启动，拒绝自动注入 --config-dir"; return 1;
    }
    config_args="$(sed -nE 's/^[[:space:]]*Environment="KUBELET_CONFIG_ARGS=([^"]*)"[[:space:]]*$/\1/p' <<<"$unit" | tail -n1)"
    if [[ -n "$config_args" && "$config_args" != "--config=${BASE_CONFIG}" ]]; then
        error "KUBELET_CONFIG_ARGS 不是标准单一 --config 形式: $config_args"; return 1
    fi
    info "systemd unit 可安全启用 --config-dir"
}

precheck() {
    info "开始 CHECK"
    local cmd
    for cmd in kubelet systemctl grep awk sed cp diff mktemp readlink stat find sort; do require_cmd "$cmd"; done
    validate_runtime_paths
    validate_snapshot_retention
    version_ge_134
    validate_template
    check_base_config
    systemctl list-unit-files kubelet.service >/dev/null 2>&1 || { error "未发现 kubelet.service"; return 1; }
    check_systemd_compatibility
    check_cli_conflicts
    check_dropin_order
    if systemctl is-active --quiet kubelet; then info "kubelet 当前状态: active"
    else warn "kubelet 当前非 active；check 仅报告，正式 apply 将拒绝执行"; fi
    info "CHECK 完成：未修改系统配置"
}

render_systemd_dropin() {
    cat <<EOF_SYSTEMD
[Service]
Environment="KUBELET_CONFIG_ARGS=--config=${BASE_CONFIG} --config-dir=${DROPIN_DIR}"
EOF_SYSTEMD
}

show_diff() {
    validate_template
    info "========== Kubelet Resource Governance Diff =========="
    if [[ -f "$MANAGED_DROPIN" ]]; then
        diff -u --label "current:${MANAGED_DROPIN}" --label "desired:${TEMPLATE_FILE}" "$MANAGED_DROPIN" "$TEMPLATE_FILE" || true
    else
        diff -u --label "current:/dev/null" --label "desired:${TEMPLATE_FILE}" /dev/null "$TEMPLATE_FILE" || true
    fi
    local effective_dir
    if effective_dir="$(get_config_dir_from_execstart 2>/dev/null)"; then
        printf '\n[systemd]\n已启用 --config-dir=%s\n' "$effective_dir"
    else
        printf '\n[systemd planned change]\n'; render_systemd_dropin
    fi
    printf '\n[hash]\ntemplate: %s\n' "$(sha256_of "$TEMPLATE_FILE")"
    if [[ -f "$MANAGED_DROPIN" ]]; then printf 'current : %s\n' "$(sha256_of "$MANAGED_DROPIN")"
    else printf 'current : absent\n'; fi
    info "DIFF 完成：未修改系统配置"
}

dry_run_apply() {
    cat >&2 <<'EOF_DRY'
============================================================
 DRY-RUN MODE - NO PERSISTENT MODIFICATION / NO RESTART
============================================================
EOF_DRY
    precheck
    info "[DRY-RUN] would snapshot: $BASE_CONFIG $MANAGED_DROPIN $SYSTEMD_DROPIN_FILE $TEMPLATE_FILE"
    local workdir="$(mktemp -d "${TMPDIR:-/tmp}/kubelet-resource-governance.XXXXXX")" rendered effective_dir
    trap 'rm -rf -- "$workdir"' RETURN
    rendered="${workdir}/99-resource-governance.conf"
    cp -- "$TEMPLATE_FILE" "$rendered"; chmod 0644 "$rendered"
    if [[ -f "$MANAGED_DROPIN" ]]; then diff -u "$MANAGED_DROPIN" "$rendered" || true
    else diff -u /dev/null "$rendered" || true; fi
    if ! effective_dir="$(get_config_dir_from_execstart 2>/dev/null)"; then
        printf '\n[DRY-RUN systemd]\n'; render_systemd_dropin
    fi
    info "[DRY-RUN] would atomically install $MANAGED_DROPIN"
    info "[DRY-RUN] would daemon-reload + restart kubelet"
    info "[DRY-RUN] would verify systemd + effective healthz + Node Ready/API（可用时）+ /configz（可用时）"
    rm -rf -- "$workdir"; trap - RETURN
}

validate_snapshot_retention() {
    [[ "$SNAPSHOT_RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]] || {
        error "SNAPSHOT_RETENTION_COUNT 必须为大于 0 的整数"; return 1;
    }
}
backup_path_if_exists() {
    local src="$1" rel dest
    [[ -e "$src" ]] || return 0
    rel="${src#/}"; dest="${CURRENT_BACKUP_DIR}/files/${rel}"
    mkdir -p "$(dirname "$dest")"; cp -a -- "$src" "$dest"
}
record_state() {
    if [[ -e "$1" ]]; then printf 'present\n' >"${CURRENT_BACKUP_DIR}/$2"
    else printf 'absent\n' >"${CURRENT_BACKUP_DIR}/$2"; fi
}

cleanup_old_snapshots() {
    local retention="$SNAPSHOT_RETENTION_COUNT" line snapshot name index
    local -a snapshots=()
    validate_snapshot_retention
    [[ -d "$BACKUP_ROOT" ]] || return 0
    while IFS= read -r line; do
        snapshot="${line#* }"; name="$(basename -- "$snapshot")"
        [[ "$name" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -f "${snapshot}/metadata.env" ]] || continue
        snapshots+=("$snapshot")
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr)
    (( ${#snapshots[@]} > retention )) || { info "快照保留检查：${#snapshots[@]}/${retention}，无需清理"; return 0; }
    for ((index=retention; index<${#snapshots[@]}; index++)); do
        snapshot="${snapshots[$index]}"
        [[ "$snapshot" == "$BACKUP_ROOT/"* && "$(dirname -- "$snapshot")" == "$BACKUP_ROOT" ]] || {
            warn "拒绝删除异常快照路径: $snapshot"; continue;
        }
        [[ -z "$CURRENT_BACKUP_DIR" || "$snapshot" != "$CURRENT_BACKUP_DIR" ]] || continue
        rm -rf -- "$snapshot"; info "已清理过期快照: $snapshot"
    done
}

create_backup() {
    local reason="${1:-manual}" id
    validate_snapshot_retention
    mkdir -p "$BACKUP_ROOT"; chmod 700 "$BACKUP_ROOT"
    id="$(date +%Y%m%d-%H%M%S)-$$"; CURRENT_BACKUP_DIR="${BACKUP_ROOT}/${id}"
    mkdir -p "${CURRENT_BACKUP_DIR}/files"; chmod 700 "$CURRENT_BACKUP_DIR"
    record_state "$BASE_CONFIG" base.state
    record_state "$MANAGED_DROPIN" managed-dropin.state
    record_state "$SYSTEMD_DROPIN_FILE" systemd-dropin.state
    backup_path_if_exists "$BASE_CONFIG"
    backup_path_if_exists "$MANAGED_DROPIN"
    backup_path_if_exists "$SYSTEMD_DROPIN_FILE"
    backup_path_if_exists "$TEMPLATE_FILE"
    systemctl show kubelet -p ExecStart -p Environment >"${CURRENT_BACKUP_DIR}/kubelet.systemd.txt" 2>/dev/null || true
    systemctl cat kubelet >"${CURRENT_BACKUP_DIR}/kubelet.unit.txt" 2>/dev/null || true
    kubelet --version >"${CURRENT_BACKUP_DIR}/kubelet.version.txt" 2>/dev/null || true
    cat >"${CURRENT_BACKUP_DIR}/metadata.env" <<EOF_META
BACKUP_ID=${id}
CREATED_AT=$(date '+%F %T %z')
REASON=${reason}
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
BASE_CONFIG=${BASE_CONFIG}
MANAGED_DROPIN=${MANAGED_DROPIN}
SYSTEMD_DROPIN_FILE=${SYSTEMD_DROPIN_FILE}
TEMPLATE_SHA256=$(sha256_of "$TEMPLATE_FILE")
EOF_META
    info "备份创建完成: $CURRENT_BACKUP_DIR"
    # apply 的 GC 延迟到事务 commit/成功回滚后。
    [[ "$reason" == "apply" ]] || cleanup_old_snapshots
    printf '%s\n' "$CURRENT_BACKUP_DIR"
}

atomic_copy() {
    local src="$1" target="$2" mode="$3" dir tmp
    dir="$(dirname "$target")"; mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.kubelet-resource-governance.XXXXXX")"
    if ! cp -- "$src" "$tmp" || ! chown root:root "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"; return 1
    fi
}
atomic_render_systemd_dropin() {
    local dir="$(dirname "$SYSTEMD_DROPIN_FILE")" tmp
    mkdir -p "$dir"; tmp="$(mktemp "${dir}/.kubelet-resource-governance.XXXXXX")"
    if ! render_systemd_dropin >"$tmp" || ! chown root:root "$tmp" || ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$SYSTEMD_DROPIN_FILE"; then
        rm -f -- "$tmp"; return 1
    fi
}
install_desired_config() {
    info "原子安装治理 Drop-in: $MANAGED_DROPIN"; atomic_copy "$TEMPLATE_FILE" "$MANAGED_DROPIN" 0644
    if ! get_config_dir_from_execstart >/dev/null 2>&1; then
        info "创建 systemd Drop-in，启用 --config-dir=${DROPIN_DIR}"; atomic_render_systemd_dropin
    else info "kubelet 已启用 --config-dir，无需新增 systemd Drop-in"; fi
}

# 用 base + *.conf 字典序解析简单顶层 scalar，动态确定 healthz 地址。
effective_top_scalar() {
    local key="$1" default="$2" value file name candidate
    value="$(extract_scalar_from_file "$BASE_CONFIG" "$key")"; [[ -n "$value" ]] || value="$default"
    if [[ -d "$DROPIN_DIR" ]]; then
        while IFS= read -r name; do
            file="${DROPIN_DIR}/${name}"; candidate="$(extract_scalar_from_file "$file" "$key")"
            [[ -n "$candidate" ]] && value="$candidate"
        done < <(find "$DROPIN_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    fi
    printf '%s\n' "$value"
}
get_cli_flag_value() {
    local flag="$1" token execstart="$(get_execstart)"
    token="$(grep -oE -- "${flag}(=|[[:space:]])[^[:space:];}]+" <<<"$execstart" | head -n1 || true)"
    [[ -n "$token" ]] || return 1
    token="${token#${flag}=}"; token="${token#${flag} }"
    printf '%s\n' "$token"
}
healthz_url() {
    local address port
    address="$(get_cli_flag_value --healthz-bind-address 2>/dev/null || effective_top_scalar healthzBindAddress 127.0.0.1)"
    port="$(get_cli_flag_value --healthz-port 2>/dev/null || effective_top_scalar healthzPort 10248)"
    case "$address" in 0.0.0.0|'') address="127.0.0.1" ;; ::) address="::1" ;; esac
    [[ "$address" == *:* ]] && address="[${address}]"
    printf 'http://%s:%s/healthz\n' "$address" "$port"
}
check_local_health_once() {
    command -v curl >/dev/null 2>&1 || { error "正式 apply 需要 curl 执行 healthz 门禁"; return 1; }
    local url="$(healthz_url)" result
    result="$(curl -fsS --max-time 2 "$url" 2>/dev/null || true)"
    [[ "$result" == "ok" ]] || { error "kubelet healthz 不健康: $url result=${result:-unreachable}"; return 1; }
}
wait_local_health() {
    require_cmd curl
    local elapsed=0 result url="$(healthz_url)"
    while (( elapsed < NODE_READY_TIMEOUT )); do
        result="$(curl -fsS --max-time 2 "$url" 2>/dev/null || true)"
        [[ "$result" == "ok" ]] && { info "kubelet healthz 检查通过: $url"; return 0; }
        sleep "$HEALTH_INTERVAL"; elapsed=$((elapsed + HEALTH_INTERVAL))
    done
    error "kubelet healthz 在 ${NODE_READY_TIMEOUT}s 内未恢复: $url"; return 1
}

resolve_node_name() {
    local candidate override execstart="$(get_execstart)"
    command -v kubectl >/dev/null 2>&1 || return 1
    override="$(grep -oE -- '--hostname-override(=|[[:space:]])[^[:space:];}]+' <<<"$execstart" | head -n1 || true)"
    override="${override#--hostname-override=}"; override="${override#--hostname-override }"
    for candidate in "$override" "$(hostname)" "$(hostname -s)" "$(hostname -f 2>/dev/null || true)"; do
        [[ -n "$candidate" ]] || continue
        kubectl get node "$candidate" >/dev/null 2>&1 && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}
node_ready_once() {
    command -v kubectl >/dev/null 2>&1 || { warn "kubectl 不可用，Node Ready 门禁降级"; return 2; }
    local node ready; node="$(resolve_node_name)" || { error "kubectl 可用但无法定位本机 Node"; return 1; }
    ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$ready" == "True" ]] || { error "Node 当前非 Ready: $node status=${ready:-unknown}"; return 1; }
}
wait_node_ready() {
    if ! command -v kubectl >/dev/null 2>&1; then warn "kubectl 不可用，跳过 Node Ready API 检查"; return 0; fi
    local node elapsed=0 ready; node="$(resolve_node_name)" || { error "kubectl 可用但无法定位本机 Node"; return 1; }
    while (( elapsed < NODE_READY_TIMEOUT )); do
        ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        [[ "$ready" == "True" ]] && { info "Node Ready 检查通过: $node"; return 0; }
        sleep "$HEALTH_INTERVAL"; elapsed=$((elapsed + HEALTH_INTERVAL))
    done
    error "Node ${node} 在 ${NODE_READY_TIMEOUT}s 内未恢复 Ready"; return 1
}

# /configz 字段级校验：kubectl + python3/PyYAML 可用时为强校验；否则明确降级。
verify_effective_config() {
    if ! command -v kubectl >/dev/null 2>&1; then warn "kubectl 不可用，跳过 /configz 校验"; return 0; fi
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
        warn "缺少 python3+PyYAML，跳过 /configz 字段级校验"; return 0
    fi
    local node tmp; node="$(resolve_node_name)" || { error "无法定位 Node，不能执行 /configz 校验"; return 1; }
    tmp="$(mktemp "${TMPDIR:-/tmp}/kubelet-configz.XXXXXX")"
    if ! kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp"; error "无法通过 Kubernetes API 获取 ${node}/configz"; return 1
    fi
    if ! python3 - "$TEMPLATE_FILE" "$tmp" <<'PY_CONFIGZ'
import json, sys, yaml
with open(sys.argv[1], encoding='utf-8') as f: desired=yaml.safe_load(f)
with open(sys.argv[2], encoding='utf-8') as f: raw=json.load(f)
effective=raw.get('kubeletconfig', raw.get('kubeletConfig', raw))
failed=[]
for key, want in desired.items():
    if key in {'apiVersion','kind'}: continue
    got=effective.get(key, '<missing>')
    if got != want: failed.append((key, want, got))
if failed:
    for key,want,got in failed: print(f"mismatch {key}: desired={want!r} actual={got!r}", file=sys.stderr)
    raise SystemExit(1)
PY_CONFIGZ
    then
        rm -f -- "$tmp"; error "Effective Config 与模板声明字段不一致"; return 1
    fi
    rm -f -- "$tmp"; info "Effective Config (/configz) 校验通过: $node"
}

preapply_health_gate() {
    systemctl is-active --quiet kubelet || { error "kubelet 当前非 active，拒绝 apply"; return 1; }
    check_local_health_once
    if node_ready_once; then
        :
    else
        local rc=$?
        (( rc == 2 )) || return "$rc"
    fi
    info "apply 前健康门禁通过"
}

verify_applied() {
    systemctl is-active --quiet kubelet || {
        error "kubelet service 非 active"; journalctl -u kubelet -n 80 --no-pager >&2 || true; return 1;
    }
    local effective_dir="$(get_config_dir_from_execstart 2>/dev/null || true)"
    [[ "$(canonical_path "${effective_dir:-/nonexistent}")" == "$(canonical_path "$DROPIN_DIR")" ]] || {
        error "实际 --config-dir 不符合预期: ${effective_dir:-absent}"; return 1;
    }
    [[ -f "$MANAGED_DROPIN" ]] || { error "受管 Drop-in 不存在: $MANAGED_DROPIN"; return 1; }
    cmp -s "$MANAGED_DROPIN" "$TEMPLATE_FILE" || { error "受管 Drop-in 与模板不一致"; return 1; }
    wait_local_health
    wait_node_ready
    verify_effective_config
    info "应用后验证全部通过"
}

latest_backup_dir() {
    local line snapshot name
    [[ -d "$BACKUP_ROOT" ]] || return 0
    while IFS= read -r line; do
        snapshot="${line#* }"; name="$(basename -- "$snapshot")"
        [[ "$name" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -f "${snapshot}/metadata.env" ]] || continue
        printf '%s\n' "$snapshot"; return 0
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr)
}
select_backup_dir() {
    local selected
    if [[ -n "$ROLLBACK_ID" ]]; then
        [[ "$ROLLBACK_ID" != */* && "$ROLLBACK_ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || {
            error "非法 --backup-id: $ROLLBACK_ID"; return 1;
        }
        selected="${BACKUP_ROOT}/${ROLLBACK_ID}"
    else selected="$(latest_backup_dir)"; fi
    [[ -n "$selected" && -d "$selected" && -f "$selected/metadata.env" ]] || {
        error "未找到有效备份快照: ${ROLLBACK_ID:-latest}"; return 1;
    }
    printf '%s\n' "$selected"
}
restore_from_snapshot() {
    local snapshot="$1" target="$2" state_name="$3" backup_file="${1}/files/${2#/}"
    if [[ -f "${snapshot}/${state_name}" ]] && grep -qx present "${snapshot}/${state_name}"; then
        [[ -e "$backup_file" ]] || { error "快照实体缺失: $backup_file"; return 1; }
        mkdir -p "$(dirname "$target")"; cp -a -- "$backup_file" "$target"; info "已恢复: $target"
    else
        rm -f -- "$target"; info "已删除快照时不存在的受管文件: $target"
    fi
}
rollback_snapshot() {
    local snapshot="$1"; ROLLBACK_IN_PROGRESS="true"; warn "开始回滚快照: $snapshot"
    restore_from_snapshot "$snapshot" "$MANAGED_DROPIN" managed-dropin.state || return 1
    restore_from_snapshot "$snapshot" "$SYSTEMD_DROPIN_FILE" systemd-dropin.state || return 1
    if ! systemctl daemon-reload; then error "rollback daemon-reload 失败"; return 1; fi
    if ! systemctl restart kubelet; then error "rollback restart kubelet 失败"; return 1; fi
    if ! systemctl is-active --quiet kubelet; then
        error "回滚后 kubelet 仍非 active"; journalctl -u kubelet -n 100 --no-pager >&2 || true; return 1
    fi
    wait_local_health || return 1
    wait_node_ready || return 1
    ROLLBACK_IN_PROGRESS="false"; warn "回滚完成: $snapshot"
}
rollback_current_after_failure() {
    [[ -n "$CURRENT_BACKUP_DIR" && -d "$CURRENT_BACKUP_DIR" ]] || {
        error "apply 已失败，但没有可用本次快照"; return 1;
    }
    rollback_snapshot "$CURRENT_BACKUP_DIR" || return 1
    cleanup_old_snapshots || warn "回滚成功，但快照 GC 失败"
}
rollback_command() {
    require_root; require_cmd readlink; require_cmd stat; validate_runtime_paths; acquire_lock
    local snapshot
    snapshot="$(select_backup_dir)"
    rollback_snapshot "$snapshot"
}

apply_command() {
    if [[ "$DRY_RUN" == "true" ]]; then dry_run_apply; return 0; fi
    require_root; acquire_lock
    precheck
    preapply_health_gate
    create_backup apply >/dev/null
    APPLY_IN_PROGRESS="true"
    info "再次校验模板，防止 backup 后模板变化"; validate_template
    install_desired_config
    info "执行 systemctl daemon-reload"; systemctl daemon-reload
    info "执行 systemctl restart kubelet"; systemctl restart kubelet
    verify_applied
    APPLY_IN_PROGRESS="false"
    cleanup_old_snapshots
    info "APPLY 成功；本次可回滚快照: $CURRENT_BACKUP_DIR"
}

status_command() {
    local rc=0 effective_dir="" node="" ready="unknown" health="unknown" latest="" hurl=""
    printf '=== kubelet-resource-governance status ===\nversion             : %s\n' "$VERSION"
    printf 'template            : %s\nmanaged drop-in      : %s\nbackup root          : %s\n' "$TEMPLATE_FILE" "$MANAGED_DROPIN" "$BACKUP_ROOT"
    if command -v kubelet >/dev/null 2>&1; then printf 'kubelet version      : %s\n' "$(kubelet --version 2>/dev/null || echo unknown)"
    else printf 'kubelet version      : missing\n'; rc=1; fi
    if systemctl is-active --quiet kubelet 2>/dev/null; then printf 'kubelet service      : active\n'
    else printf 'kubelet service      : NOT ACTIVE\n'; rc=1; fi
    effective_dir="$(get_config_dir_from_execstart 2>/dev/null || true)"
    printf 'effective config-dir : %s\n' "${effective_dir:-absent}"
    [[ -n "$effective_dir" && "$(canonical_path "$effective_dir" 2>/dev/null || true)" == "$(canonical_path "$DROPIN_DIR" 2>/dev/null || true)" ]] || rc=1
    if [[ -f "$MANAGED_DROPIN" ]]; then
        printf 'managed sha256       : %s\ntemplate sha256      : %s\n' "$(sha256_of "$MANAGED_DROPIN")" "$(sha256_of "$TEMPLATE_FILE")"
        if cmp -s "$MANAGED_DROPIN" "$TEMPLATE_FILE"; then printf 'config drift         : no\n'
        else printf 'config drift         : YES\n'; rc=1; fi
    else printf 'managed config       : absent\n'; rc=1; fi
    if command -v curl >/dev/null 2>&1 && [[ -r "$BASE_CONFIG" ]]; then
        hurl="$(healthz_url)"; health="$(curl -fsS --max-time 2 "$hurl" 2>/dev/null || true)"
        printf 'kubelet healthz      : %s (%s)\n' "${health:-unreachable}" "$hurl"; [[ "$health" == "ok" ]] || rc=1
    else printf 'kubelet healthz      : skipped/unavailable\n'; fi
    if command -v kubectl >/dev/null 2>&1 && node="$(resolve_node_name 2>/dev/null)"; then
        ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        printf 'node                 : %s\nnode Ready           : %s\n' "$node" "${ready:-unknown}"; [[ "$ready" == "True" ]] || rc=1
    else printf 'node Ready           : skipped/unavailable\n'; fi
    latest="$(latest_backup_dir)"; printf 'latest backup        : %s\n' "${latest:-none}"
    local count=0
    if [[ -d "$BACKUP_ROOT" ]]; then
        count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec test -f '{}/metadata.env' ';' -print 2>/dev/null | wc -l | tr -d ' ')"
    fi
    printf 'snapshot retention   : %s\nvalid snapshots      : %s\n' "$SNAPSHOT_RETENTION_COUNT" "$count"
    return "$rc"
}

on_error() {
    local line="$1" cmd="$2" rc="$3"
    trap - ERR
    error "执行异常: rc=${rc} line=${line} command=${cmd}"
    if [[ "$COMMAND" == "apply" && "$DRY_RUN" != "true" && "$APPLY_IN_PROGRESS" == "true" && "$ROLLBACK_IN_PROGRESS" != "true" ]]; then
        error "APPLY 失败，触发自动 rollback"
        rollback_current_after_failure || error "自动 rollback 失败，请立即人工处理"
    fi
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

main() {
    [[ "$DRY_RUN" != "true" || "$COMMAND" == "apply" ]] || { error "--dry-run 仅支持 apply"; exit 2; }
    [[ -z "$ROLLBACK_ID" || "$COMMAND" == "rollback" ]] || { error "--backup-id 仅支持 rollback"; exit 2; }
    case "$COMMAND" in
        help|-h|--help) usage ;;
        check) init_log; precheck ;;
        diff) init_log; show_diff ;;
        backup)
            init_log; require_root; require_cmd readlink; require_cmd stat; validate_runtime_paths; acquire_lock
            require_cmd systemctl; require_cmd kubelet; create_backup manual >/dev/null ;;
        apply) init_log; apply_command ;;
        status) init_log; status_command ;;
        rollback) init_log; rollback_command ;;
        *) usage >&2; error "未知命令: $COMMAND"; exit 2 ;;
    esac
}
main "$@"
