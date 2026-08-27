#!/usr/bin/env bash
# ============================================================
# kubelet-resource-governance.sh
# Kubernetes v1.34+ Kubelet 资源治理工具
# v2.4.3 - Local Core Validation + Optional Kubernetes API Verify
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
VERSION="2.4.3"
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

# Memory Eviction Profile：仅覆盖 evictionSoft/evictionHard 的 memory.available。
NODE_MEMORY_GIB=0
EVICTION_SOFT_MEMORY=""
EVICTION_HARD_MEMORY=""
EFFECTIVE_TEMPLATE_FILE="$TEMPLATE_FILE"
PROFILE_WORKDIR=""

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
  diff        根据本机内存 Profile 显示受管 drop-in 与期望配置差异
  backup      创建独立快照；默认仅保留最近 ${SNAPSHOT_RETENTION_COUNT} 个有效快照
  apply       precheck -> 健康门禁 -> backup -> install -> restart -> verify
  apply --dry-run  完整预演，不写文件、不 reload/restart、不创建正式快照
  status      查看 kubelet、Memory Profile、healthz、config-dir、漂移；API 可用时附加 Node Ready
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
get_systemd_environment() { systemctl show kubelet -p Environment --value 2>/dev/null || true; }
get_unit_text() { systemctl cat kubelet 2>/dev/null || true; }

# 获取运行中 kubelet 的真实 argv。systemd 的 ExecStart 可能仍显示 $KUBELET_CONFIG_ARGS，
# 因此 apply 后验证优先读取 /proc/<MainPID>/cmdline。
get_kubelet_runtime_cmdline() {
    local pid
    pid="$(systemctl show kubelet -p MainPID --value 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    (( pid > 0 )) || return 1
    [[ -r "/proc/${pid}/cmdline" ]] || return 1
    tr '\0' ' ' <"/proc/${pid}/cmdline"
    printf '\n'
}

extract_config_dir_from_text() {
    local text="$1" token
    token="$(grep -oE -- '--config-dir(=|[[:space:]])[^[:space:];}]+' <<<"$text" | head -n1 || true)"
    [[ -n "$token" ]] || return 1
    token="${token#--config-dir=}"; token="${token#--config-dir }"
    token="${token%\"}"; token="${token%\'}"
    [[ -n "$token" ]] || return 1
    printf '%s\n' "$token"
}

# kubelet --config-dir 检测优先级：
# 1. 运行中 kubelet 的真实 argv；2. systemd Environment；3. systemd ExecStart。
get_effective_config_dir() {
    local value
    value="$(get_kubelet_runtime_cmdline 2>/dev/null || true)"
    [[ -n "$value" ]] && extract_config_dir_from_text "$value" && return 0

    value="$(get_systemd_environment)"
    [[ -n "$value" ]] && extract_config_dir_from_text "$value" && return 0

    value="$(get_execstart)"
    [[ -n "$value" ]] && extract_config_dir_from_text "$value" && return 0
    return 1
}

get_kubelet_effective_cli_text() {
    {
        get_kubelet_runtime_cmdline 2>/dev/null || true
        get_systemd_environment 2>/dev/null || true
        get_execstart 2>/dev/null || true
    }
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
    local execstart="$(get_kubelet_effective_cli_text)" conflict=0 flag
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
    if effective_dir="$(get_effective_config_dir 2>/dev/null)"; then
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
    select_memory_eviction_profile
    info "CHECK 完成：未修改系统配置"
}

# 根据 /proc/meminfo 选择 Memory Eviction Profile。
# 仅设置 evictionSoft.memory.available / evictionHard.memory.available。
select_memory_eviction_profile() {
    local mem_kib
    mem_kib="$(awk '$1=="MemTotal:" {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [[ "$mem_kib" =~ ^[1-9][0-9]*$ ]] || {
        error "无法从 /proc/meminfo 获取有效 MemTotal"
        return 1
    }

    # KiB -> GiB，向上取整，避免标称 16/32/64/128G 因保留内存误入较小档。
    NODE_MEMORY_GIB=$(( (mem_kib + 1048575) / 1048576 ))

    if (( NODE_MEMORY_GIB <= 16 )); then
        EVICTION_SOFT_MEMORY="1024Mi"; EVICTION_HARD_MEMORY="500Mi"
    elif (( NODE_MEMORY_GIB <= 32 )); then
        EVICTION_SOFT_MEMORY="1536Mi"; EVICTION_HARD_MEMORY="750Mi"
    elif (( NODE_MEMORY_GIB <= 64 )); then
        EVICTION_SOFT_MEMORY="2048Mi"; EVICTION_HARD_MEMORY="1024Mi"
    else
        EVICTION_SOFT_MEMORY="4096Mi"; EVICTION_HARD_MEMORY="2024Mi"
    fi

    info "Memory Profile: node=${NODE_MEMORY_GIB}Gi soft=${EVICTION_SOFT_MEMORY} hard=${EVICTION_HARD_MEMORY}"
    (( NODE_MEMORY_GIB <= 128 )) || warn "Node Memory >128Gi，Memory Eviction Profile 按 128Gi 档封顶"
}

# 渲染本节点期望配置。只允许改两个 memory.available 字段；源 YAML 永不修改。
render_memory_profile_template() {
    local src="$1" dst="$2"
    awk -v soft="$EVICTION_SOFT_MEMORY" -v hard="$EVICTION_HARD_MEMORY" '
        /^evictionSoft:[[:space:]]*$/ { section="soft"; print; next }
        /^evictionHard:[[:space:]]*$/ { section="hard"; print; next }
        /^[^[:space:]#][^:]*:/ { section="" }
        section=="soft" && /^[[:space:]]+memory\.available:[[:space:]]*/ {
            print "  memory.available: \"" soft "\""; soft_count++; next
        }
        section=="hard" && /^[[:space:]]+memory\.available:[[:space:]]*/ {
            print "  memory.available: \"" hard "\""; hard_count++; next
        }
        { print }
        END { if (soft_count != 1 || hard_count != 1) exit 42 }
    ' "$src" >"$dst" || {
        rm -f -- "$dst"
        error "Memory Profile 渲染失败：必须且只能找到 evictionSoft/evictionHard 各一个 memory.available"
        return 1
    }
}

prepare_effective_template() {
    local dir="${1:-}"
    select_memory_eviction_profile
    if [[ -z "$dir" ]]; then
        PROFILE_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kubelet-resource-governance.profile.XXXXXX")"
        dir="$PROFILE_WORKDIR"
    fi
    EFFECTIVE_TEMPLATE_FILE="${dir}/99-resource-governance.conf"
    render_memory_profile_template "$TEMPLATE_FILE" "$EFFECTIVE_TEMPLATE_FILE"
    chmod 0600 "$EFFECTIVE_TEMPLATE_FILE"
}

cleanup_profile_workdir() {
    if [[ -n "$PROFILE_WORKDIR" && -d "$PROFILE_WORKDIR" ]]; then
        rm -rf -- "$PROFILE_WORKDIR"
    fi
    PROFILE_WORKDIR=""
    EFFECTIVE_TEMPLATE_FILE="$TEMPLATE_FILE"
}

render_systemd_dropin() {
    cat <<EOF_SYSTEMD
[Service]
Environment="KUBELET_CONFIG_ARGS=--config=${BASE_CONFIG} --config-dir=${DROPIN_DIR}"
EOF_SYSTEMD
}

show_diff() {
    validate_template
    prepare_effective_template
    info "========== Kubelet Resource Governance Diff =========="
    if [[ -f "$MANAGED_DROPIN" ]]; then
        diff -u --label "current:${MANAGED_DROPIN}" --label "desired:memory-profile" \
            "$MANAGED_DROPIN" "$EFFECTIVE_TEMPLATE_FILE" || true
    else
        diff -u --label "current:/dev/null" --label "desired:memory-profile" \
            /dev/null "$EFFECTIVE_TEMPLATE_FILE" || true
    fi
    local effective_dir
    if effective_dir="$(get_effective_config_dir 2>/dev/null)"; then
        printf '\n[systemd]\n已启用 --config-dir=%s\n' "$effective_dir"
    else
        printf '\n[systemd planned change]\n'; render_systemd_dropin
    fi
    printf '\n[profile]\nnode memory: %sGi\nsoft       : %s\nhard       : %s\n' \
        "$NODE_MEMORY_GIB" "$EVICTION_SOFT_MEMORY" "$EVICTION_HARD_MEMORY"
    printf '\n[hash]\ndesired : %s\n' "$(sha256_of "$EFFECTIVE_TEMPLATE_FILE")"
    if [[ -f "$MANAGED_DROPIN" ]]; then printf 'current : %s\n' "$(sha256_of "$MANAGED_DROPIN")"
    else printf 'current : absent\n'; fi
    cleanup_profile_workdir
    info "DIFF 完成：未修改系统配置"
}

dry_run_apply() {
    cat >&2 <<'EOF_DRY'
============================================================
 DRY-RUN MODE - NO PERSISTENT MODIFICATION / NO RESTART
============================================================
EOF_DRY
    precheck
    prepare_effective_template
    info "[DRY-RUN] Memory Profile: node=${NODE_MEMORY_GIB}Gi soft=${EVICTION_SOFT_MEMORY} hard=${EVICTION_HARD_MEMORY}"
    info "[DRY-RUN] would snapshot: $BASE_CONFIG $MANAGED_DROPIN $SYSTEMD_DROPIN_FILE $TEMPLATE_FILE"
    if [[ -f "$MANAGED_DROPIN" ]]; then diff -u "$MANAGED_DROPIN" "$EFFECTIVE_TEMPLATE_FILE" || true
    else diff -u /dev/null "$EFFECTIVE_TEMPLATE_FILE" || true; fi
    local effective_dir
    if ! effective_dir="$(get_effective_config_dir 2>/dev/null)"; then
        printf '\n[DRY-RUN systemd]\n'; render_systemd_dropin
    fi
    info "[DRY-RUN] would atomically install $MANAGED_DROPIN"
    info "[DRY-RUN] would daemon-reload + restart kubelet"
    info "[DRY-RUN] would verify systemd + healthz + Node Ready/API（可用时）+ /configz（可用时）"
    cleanup_profile_workdir
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
    local effective_dir=""
    info "原子安装治理 Drop-in: $MANAGED_DROPIN"
    atomic_copy "$EFFECTIVE_TEMPLATE_FILE" "$MANAGED_DROPIN" 0644

    effective_dir="$(get_effective_config_dir 2>/dev/null || true)"
    if [[ -z "$effective_dir" ]]; then
        info "当前 kubelet 未检测到 --config-dir，按需创建 systemd Drop-in: $SYSTEMD_DROPIN_FILE"
        info "注入 --config-dir=${DROPIN_DIR}"
        atomic_render_systemd_dropin
        return 0
    fi

    if [[ "$(canonical_path "$effective_dir")" != "$(canonical_path "$DROPIN_DIR")" ]]; then
        error "现有 --config-dir 与治理目录不一致: actual=${effective_dir} expected=${DROPIN_DIR}"
        return 1
    fi
    info "kubelet 已启用目标 --config-dir=${effective_dir}，无需新增 systemd Drop-in"
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
    local flag="$1" token execstart="$(get_kubelet_effective_cli_text)"
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

get_local_node_name() {
    local override cli
    cli="$(get_kubelet_effective_cli_text)"
    override="$(grep -oE -- '--hostname-override(=|[[:space:]])[^[:space:];}]+' <<<"$cli" | head -n1 || true)"
    override="${override#--hostname-override=}"; override="${override#--hostname-override }"
    if [[ -n "$override" ]]; then printf '%s\n' "$override"; else hostname; fi
}

# Kubernetes API 仅用于增强验证；kubectl 存在但没有可用 kubeconfig 时视为不可用，不影响核心 apply。
kubernetes_api_available() {
    command -v kubectl >/dev/null 2>&1 || return 1
    kubectl get --raw='/readyz' --request-timeout=5s >/dev/null 2>&1
}

resolve_node_name() {
    kubernetes_api_available || return 1
    local candidate override cli="$(get_kubelet_effective_cli_text)"
    override="$(grep -oE -- '--hostname-override(=|[[:space:]])[^[:space:];}]+' <<<"$cli" | head -n1 || true)"
    override="${override#--hostname-override=}"; override="${override#--hostname-override }"
    for candidate in "$override" "$(hostname)" "$(hostname -s)" "$(hostname -f 2>/dev/null || true)"; do
        [[ -n "$candidate" ]] || continue
        kubectl get node "$candidate" --request-timeout=5s >/dev/null 2>&1 && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

node_ready_once() {
    if ! kubernetes_api_available; then warn "Kubernetes API 不可用，Node Ready 门禁降级为本地 healthz"; return 2; fi
    local node ready
    if ! node="$(resolve_node_name)"; then warn "Kubernetes API 可用但无法定位本机 Node，跳过 Node Ready 增强检查"; return 2; fi
    ready="$(kubectl get node "$node" --request-timeout=5s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$ready" == "True" ]] || { error "Node 当前非 Ready: $node status=${ready:-unknown}"; return 1; }
}

wait_node_ready() {
    if ! kubernetes_api_available; then warn "Kubernetes API 不可用，跳过 Node Ready 增强检查"; return 0; fi
    local node elapsed=0 ready
    if ! node="$(resolve_node_name)"; then warn "Kubernetes API 可用但无法定位本机 Node，跳过 Node Ready 增强检查"; return 0; fi
    while (( elapsed < NODE_READY_TIMEOUT )); do
        ready="$(kubectl get node "$node" --request-timeout=5s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        [[ "$ready" == "True" ]] && { info "Node Ready 增强检查通过: $node"; return 0; }
        sleep "$HEALTH_INTERVAL"; elapsed=$((elapsed + HEALTH_INTERVAL))
    done
    error "Node ${node} 在 ${NODE_READY_TIMEOUT}s 内未恢复 Ready"; return 1
}

# /configz 字段级校验：Kubernetes API 可用时执行增强验证；不可用时明确降级。
# Duration 字段按 Go/Kubernetes 时长语义比较，例如 5m == 5m0s == 300s。
verify_effective_config() {
    if ! kubernetes_api_available; then
        warn "Kubernetes API 不可用，跳过 /configz Effective Config 增强校验"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
        warn "缺少 python3+PyYAML，跳过 /configz Effective Config 校验"
        return 0
    fi

    local node configz
    if ! node="$(resolve_node_name)"; then
        warn "无法定位本机 Node，跳过 /configz Effective Config 增强校验"
        return 0
    fi

    if ! configz="$(kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" --request-timeout=5s 2>/dev/null)"; then
        warn "无法通过 Kubernetes API 获取 ${node}/configz，跳过增强校验"
        return 0
    fi
    [[ -n "$configz" ]] || { warn "${node}/configz 返回空内容，跳过增强校验"; return 0; }

    # JSON 通过 stdin 传入；Python 源码使用 FD 3，避免临时文件及 heredoc 占用 stdin。
    if ! printf '%s' "$configz" | python3 /dev/fd/3 "$EFFECTIVE_TEMPLATE_FILE" 3<<'PY_CONFIGZ'
import json
import re
import sys
from decimal import Decimal, InvalidOperation

import yaml

# Duration 按语义比较；Memory Profile 统一使用 Mi，仅兼容 /configz 的 Gi 规范化输出。
DURATION_FIELDS = {
    "nodeStatusUpdateFrequency",
    "evictionPressureTransitionPeriod",
    "imageMinimumGCAge",
    "imageMaximumGCAge",
}
DURATION_MAP_FIELDS = {"evictionSoftGracePeriod"}
MEMORY_PATHS = {
    "evictionSoft.memory.available",
    "evictionHard.memory.available",
}
TOKEN = re.compile(r"([0-9]+(?:\.[0-9]+)?)(ns|us|µs|μs|ms|s|m|h)")
MEMORY_TOKEN = re.compile(r"([0-9]+)(Mi|Gi)")
FACTORS = {
    "ns": Decimal(1), "us": Decimal(1_000), "µs": Decimal(1_000), "μs": Decimal(1_000),
    "ms": Decimal(1_000_000), "s": Decimal(1_000_000_000),
    "m": Decimal(60_000_000_000), "h": Decimal(3_600_000_000_000),
}


def duration_ns(value):
    if not isinstance(value, str) or not value:
        return None
    pos, total = 0, Decimal(0)
    try:
        for match in TOKEN.finditer(value):
            if match.start() != pos:
                return None
            total += Decimal(match.group(1)) * FACTORS[match.group(2)]
            pos = match.end()
    except InvalidOperation:
        return None
    return total if pos == len(value) and pos > 0 else None


def memory_mib(value):
    # Profile/template 始终使用 Mi；仅兼容 kubelet /configz 可能规范化成 Gi。
    if not isinstance(value, str):
        return None
    match = MEMORY_TOKEN.fullmatch(value)
    if not match:
        return None
    number = int(match.group(1))
    return number if match.group(2) == "Mi" else number * 1024


def compare(path, root, desired, actual):
    if isinstance(desired, dict):
        if not isinstance(actual, dict):
            return [(path, desired, actual)]
        failed = []
        for key, want in desired.items():
            child = f"{path}.{key}" if path else key
            if key not in actual:
                failed.append((child, want, "<missing>"))
            else:
                failed.extend(compare(child, root, want, actual[key]))
        return failed

    if isinstance(desired, list):
        return [] if desired == actual else [(path, desired, actual)]

    if root in DURATION_FIELDS or root in DURATION_MAP_FIELDS:
        want_ns, got_ns = duration_ns(desired), duration_ns(actual)
        if want_ns is not None and got_ns is not None:
            return [] if want_ns == got_ns else [(path, desired, actual)]
        # Duration 无法解析时回落到严格比较，避免静默放过异常值。

    if path in MEMORY_PATHS:
        want_mib, got_mib = memory_mib(desired), memory_mib(actual)
        if want_mib is not None and got_mib is not None:
            return [] if want_mib == got_mib else [(path, desired, actual)]
        # 无法识别的容量格式回落到严格比较。

    return [] if desired == actual else [(path, desired, actual)]


try:
    with open(sys.argv[1], encoding="utf-8") as f:
        desired = yaml.safe_load(f)
    raw = json.load(sys.stdin)
except (OSError, ValueError, TypeError, yaml.YAMLError) as exc:
    print(f"configz validation input error: {exc}", file=sys.stderr)
    raise SystemExit(1)

effective = raw.get("kubeletconfig", raw.get("kubeletConfig", raw))
if not isinstance(desired, dict) or not isinstance(effective, dict):
    print("invalid desired/effective kubelet configuration structure", file=sys.stderr)
    raise SystemExit(1)

failed = []
for key, want in desired.items():
    if key in {"apiVersion", "kind"}:
        continue
    if key not in effective:
        failed.append((key, want, "<missing>"))
    else:
        failed.extend(compare(key, key, want, effective[key]))

if failed:
    for path, want, got in failed:
        print(f"mismatch {path}: desired={want!r} actual={got!r}", file=sys.stderr)
    raise SystemExit(1)
PY_CONFIGZ
    then
        error "Effective Config 与模板声明字段不一致"
        return 1
    fi

    info "Effective Config (/configz) 语义校验通过: ${node}"
}

# Control Plane Static Pod 健康检查：仅检查本机实际存在的 kubeadm static pod manifest。
# 仅使用可用的 CRI 检查真实运行容器；crictl 不可用时明确降级跳过。
check_control_plane_static_pods() {
    local manifest_dir="/etc/kubernetes/manifests" component container_ids elapsed=0
    local component_list failed_list
    local -a components=() failed=()

    for component in kube-apiserver kube-controller-manager kube-scheduler etcd; do
        [[ -f "${manifest_dir}/${component}.yaml" ]] && components+=("$component")
    done

    ((${#components[@]} > 0)) || {
        info "未检测到 kubeadm Control Plane static pod manifest，跳过 Control Plane 健康检查"
        return 0
    }

    component_list="$(IFS=,; printf '%s' "${components[*]}")"
    info "检测到 Control Plane static pods: ${component_list}"

    if ! command -v crictl >/dev/null 2>&1 || ! crictl info >/dev/null 2>&1; then
        warn "crictl 不可用或无法连接 CRI，跳过 Control Plane Static Pod 增强检查"
        return 0
    fi

    info "Control Plane 健康检查方式: CRI runtime"
    while (( elapsed < NODE_READY_TIMEOUT )); do
        failed=()
        for component in "${components[@]}"; do
            container_ids="$(crictl ps --state Running --name "$component" -q 2>/dev/null || true)"
            [[ -n "$container_ids" ]] || failed+=("$component")
        done
        if ((${#failed[@]} == 0)); then
            info "Control Plane Static Pod 健康检查通过: ${component_list}"
            return 0
        fi
        sleep "$HEALTH_INTERVAL"; elapsed=$((elapsed + HEALTH_INTERVAL))
    done

    failed_list="$(IFS=,; printf '%s' "${failed[*]}")"
    error "Control Plane Static Pod 在 ${NODE_READY_TIMEOUT}s 内未全部恢复 Running: ${failed_list}"
    return 1
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
    local effective_dir="$(get_effective_config_dir 2>/dev/null || true)"
    if [[ -z "$effective_dir" ]]; then
        error "无法从 kubelet Runtime argv / systemd Environment / ExecStart 获取 --config-dir"
        error "期望 --config-dir=${DROPIN_DIR}"
        error "Runtime argv: $(get_kubelet_runtime_cmdline 2>/dev/null || echo unavailable)"
        error "systemd Environment: $(get_systemd_environment 2>/dev/null || echo unavailable)"
        error "systemd ExecStart: $(get_execstart 2>/dev/null || echo unavailable)"
        return 1
    fi
    [[ "$(canonical_path "$effective_dir")" == "$(canonical_path "$DROPIN_DIR")" ]] || {
        error "实际 --config-dir 不符合预期: actual=${effective_dir} expected=${DROPIN_DIR}"; return 1;
    }
    info "kubelet --config-dir 验证通过: ${effective_dir}"
    [[ -f "$MANAGED_DROPIN" ]] || { error "受管 Drop-in 不存在: $MANAGED_DROPIN"; return 1; }
    cmp -s "$MANAGED_DROPIN" "$EFFECTIVE_TEMPLATE_FILE" || { error "受管 Drop-in 与本节点 Memory Profile 期望配置不一致"; return 1; }
    wait_local_health
    wait_node_ready
    verify_effective_config
    check_control_plane_static_pods
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
    prepare_effective_template
    create_backup apply >/dev/null
    APPLY_IN_PROGRESS="true"
    info "再次校验源模板，防止 backup 后模板变化"; validate_template
    # 重新渲染，确保 backup 后源模板变化不会绕过 Profile 计算。
    render_memory_profile_template "$TEMPLATE_FILE" "$EFFECTIVE_TEMPLATE_FILE"
    install_desired_config
    info "执行 systemctl daemon-reload"; systemctl daemon-reload
    info "执行 systemctl restart kubelet"; systemctl restart kubelet
    verify_applied
    APPLY_IN_PROGRESS="false"
    cleanup_old_snapshots
    info "APPLY 成功；Memory Profile node=${NODE_MEMORY_GIB}Gi soft=${EVICTION_SOFT_MEMORY} hard=${EVICTION_HARD_MEMORY}"
    info "本次可回滚快照: $CURRENT_BACKUP_DIR"
    cleanup_profile_workdir
}

status_command() {
    local rc=0 effective_dir="" node="" ready="unknown" health="unknown" latest="" hurl="" profile_ready="false"
    printf '=== kubelet-resource-governance status ===\nversion             : %s\n' "$VERSION"
    printf 'template            : %s\nmanaged drop-in      : %s\nbackup root          : %s\n' "$TEMPLATE_FILE" "$MANAGED_DROPIN" "$BACKUP_ROOT"

    if prepare_effective_template; then
        profile_ready="true"
        printf 'node memory          : %sGi\neviction soft memory : %s\neviction hard memory : %s\n' \
            "$NODE_MEMORY_GIB" "$EVICTION_SOFT_MEMORY" "$EVICTION_HARD_MEMORY"
    else
        printf 'memory profile       : unavailable\n'; rc=1
    fi

    if command -v kubelet >/dev/null 2>&1; then printf 'kubelet version      : %s\n' "$(kubelet --version 2>/dev/null || echo unknown)"
    else printf 'kubelet version      : missing\n'; rc=1; fi
    if systemctl is-active --quiet kubelet 2>/dev/null; then printf 'kubelet service      : active\n'
    else printf 'kubelet service      : NOT ACTIVE\n'; rc=1; fi
    effective_dir="$(get_effective_config_dir 2>/dev/null || true)"
    printf 'effective config-dir : %s\n' "${effective_dir:-absent}"
    [[ -n "$effective_dir" && "$(canonical_path "$effective_dir" 2>/dev/null || true)" == "$(canonical_path "$DROPIN_DIR" 2>/dev/null || true)" ]] || rc=1

    if [[ "$profile_ready" == "true" && -f "$MANAGED_DROPIN" && -f "$EFFECTIVE_TEMPLATE_FILE" ]]; then
        printf 'managed sha256       : %s\ndesired sha256       : %s\n' "$(sha256_of "$MANAGED_DROPIN")" "$(sha256_of "$EFFECTIVE_TEMPLATE_FILE")"
        if cmp -s "$MANAGED_DROPIN" "$EFFECTIVE_TEMPLATE_FILE"; then printf 'config drift         : no\n'
        else printf 'config drift         : YES\n'; rc=1; fi
    else printf 'managed config       : absent/unavailable\n'; rc=1; fi

    if command -v curl >/dev/null 2>&1 && [[ -r "$BASE_CONFIG" ]]; then
        hurl="$(healthz_url)"; health="$(curl -fsS --max-time 2 "$hurl" 2>/dev/null || true)"
        printf 'kubelet healthz      : %s (%s)\n' "${health:-unreachable}" "$hurl"; [[ "$health" == "ok" ]] || rc=1
    else printf 'kubelet healthz      : skipped/unavailable\n'; fi
    if kubernetes_api_available && node="$(resolve_node_name 2>/dev/null)"; then
        ready="$(kubectl get node "$node" --request-timeout=5s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        printf 'node                 : %s\nnode Ready           : %s\n' "$node" "${ready:-unknown}"; [[ "$ready" == "True" ]] || rc=1
    else printf 'node Ready           : skipped (Kubernetes API unavailable/unresolved)\n'; fi
    latest="$(latest_backup_dir)"; printf 'latest backup        : %s\n' "${latest:-none}"
    local count=0
    if [[ -d "$BACKUP_ROOT" ]]; then
        count="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec test -f '{}/metadata.env' ';' -print 2>/dev/null | wc -l | tr -d ' ')"
    fi
    printf 'snapshot retention   : %s\nvalid snapshots      : %s\n' "$SNAPSHOT_RETENTION_COUNT" "$count"
    cleanup_profile_workdir
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
    cleanup_profile_workdir
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
