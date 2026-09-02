#!/usr/bin/env bash
# ==============================================================================
# provision-kubeconfig.sh
# One-time provisioning helper for pod-start-time-check v2.3.0
#
# This script is ADMIN/PROVISIONING only. The runtime checker never reads
# ADMIN_KUBECONFIG and never creates or refreshes ServiceAccount tokens.
# ==============================================================================

set -Eeuo pipefail
umask 077
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SA_NAMESPACE="${SA_NAMESPACE:-pod-start-time-check-system}"
readonly SA_NAME="${SA_NAME:-pod-start-time-check}"
readonly OUTPUT_KUBECONFIG="${KUBECONFIG_FILE:-/data/pod-start-time-check/kubeconfig}"
readonly TOKEN_DURATION="${TOKEN_DURATION:-24h}"
ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-}"
TMP_DIR=""

log() {
    printf '%s %s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SCRIPT_NAME}" "$1" "$2" >&2
}

fatal() {
    log ERROR "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "缺少依赖命令: $1"
}

cleanup() {
    local rc=$?
    [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
    return "${rc}"
}

validate_admin_kubeconfig() {
    [[ -n "${ADMIN_KUBECONFIG}" ]] || \
        fatal "必须显式设置 ADMIN_KUBECONFIG；禁止默认使用 ~/.kube/config"
    [[ "${ADMIN_KUBECONFIG}" == /* ]] || fatal "ADMIN_KUBECONFIG 必须是绝对路径"
    [[ -f "${ADMIN_KUBECONFIG}" && ! -L "${ADMIN_KUBECONFIG}" ]] || \
        fatal "ADMIN_KUBECONFIG 必须是普通文件且不能是符号链接: ${ADMIN_KUBECONFIG}"
    [[ -r "${ADMIN_KUBECONFIG}" ]] || fatal "ADMIN_KUBECONFIG 不可读: ${ADMIN_KUBECONFIG}"
}

validate_output_path() {
    local dir mode group_digit other_digit

    [[ "${OUTPUT_KUBECONFIG}" == /* ]] || fatal "KUBECONFIG_FILE 必须是绝对路径"
    dir="$(dirname -- "${OUTPUT_KUBECONFIG}")"

    [[ ! -L "${dir}" ]] || fatal "输出目录不能是符号链接: ${dir}"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p -m 0700 "${dir}" || fatal "无法创建输出目录: ${dir}"
    fi
    [[ -d "${dir}" && ! -L "${dir}" ]] || fatal "输出目录不是安全目录: ${dir}"

    mode="$(stat -c '%a' "${dir}")" || fatal "无法读取输出目录权限"
    group_digit="${mode: -2:1}"
    other_digit="${mode: -1}"
    if (( (10#${group_digit} & 2) != 0 || (10#${other_digit} & 2) != 0 )); then
        fatal "输出目录不能 group/world writable: dir=${dir}, mode=${mode}"
    fi

    if [[ -e "${OUTPUT_KUBECONFIG}" || -L "${OUTPUT_KUBECONFIG}" ]]; then
        [[ -f "${OUTPUT_KUBECONFIG}" && ! -L "${OUTPUT_KUBECONFIG}" ]] || \
            fatal "输出 kubeconfig 必须是普通文件且不能是符号链接: ${OUTPUT_KUBECONFIG}"
    fi
}

get_cluster_material() {
    local config_json ca_file

    config_json="$(kubectl --kubeconfig="${ADMIN_KUBECONFIG}" config view --raw --minify -o json)" || \
        fatal "无法读取 ADMIN_KUBECONFIG 当前 context"

    API_SERVER="$(jq -r '.clusters[0].cluster.server // empty' <<< "${config_json}")"
    CA_DATA="$(jq -r '.clusters[0].cluster["certificate-authority-data"] // empty' <<< "${config_json}")"
    ca_file="$(jq -r '.clusters[0].cluster["certificate-authority"] // empty' <<< "${config_json}")"

    [[ "${API_SERVER}" == https://* && "${API_SERVER}" != *[[:space:]]* ]] || \
        fatal "无法从 ADMIN_KUBECONFIG 获取有效 https API Server"

    if [[ -z "${CA_DATA}" && -n "${ca_file}" ]]; then
        if [[ "${ca_file}" != /* ]]; then
            ca_file="$(dirname -- "${ADMIN_KUBECONFIG}")/${ca_file}"
        fi
        [[ -f "${ca_file}" && -r "${ca_file}" ]] || fatal "certificate-authority 文件不可读: ${ca_file}"
        CA_DATA="$(base64 < "${ca_file}" | tr -d '\n')"
    fi

    [[ -n "${CA_DATA}" ]] || fatal "ADMIN_KUBECONFIG 缺少 certificate-authority-data/certificate-authority"
    [[ "${CA_DATA}" =~ ^[A-Za-z0-9+/=]+$ ]] || fatal "CA data 格式异常"
}

request_runtime_token() {
    TOKEN="$(kubectl \
        --kubeconfig="${ADMIN_KUBECONFIG}" \
        create token "${SA_NAME}" \
        -n "${SA_NAMESPACE}" \
        --duration="${TOKEN_DURATION}")" || \
        fatal "请求 ServiceAccount Token 失败；请先应用 rbac.yaml 并确认 ADMIN_KUBECONFIG 有 TokenRequest 权限"

    [[ "${TOKEN}" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "ServiceAccount Token 格式异常"
}

write_runtime_kubeconfig() {
    local candidate
    candidate="${TMP_DIR}/kubeconfig"

    cat > "${candidate}" <<EOF_KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: pod-start-time-check-cluster
  cluster:
    server: "${API_SERVER}"
    certificate-authority-data: "${CA_DATA}"
users:
- name: pod-start-time-check
  user:
    token: "${TOKEN}"
contexts:
- name: pod-start-time-check
  context:
    cluster: pod-start-time-check-cluster
    user: pod-start-time-check
current-context: pod-start-time-check
EOF_KUBECONFIG

    chmod 0600 "${candidate}"

    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i list pods -A)" == "yes" ]] || \
        fatal "新 kubeconfig 缺少 pods:list"
    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i list replicasets.apps -A)" == "yes" ]] || \
        fatal "新 kubeconfig 缺少 replicasets.apps:list"

    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i '*' '*' -A)" == "no" ]] || \
        fatal "新 kubeconfig 权限过大: wildcard */*"
    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i get secrets -A)" == "no" ]] || \
        fatal "新 kubeconfig 权限过大: secrets:get"
    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i delete pods -A)" == "no" ]] || \
        fatal "新 kubeconfig 权限过大: pods:delete"
    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i patch deployments.apps -A)" == "no" ]] || \
        fatal "新 kubeconfig 权限过大: deployments.apps:patch"
    [[ "$(kubectl --kubeconfig="${candidate}" auth can-i create clusterrolebindings.rbac.authorization.k8s.io)" == "no" ]] || \
        fatal "新 kubeconfig 权限过大: clusterrolebindings:create"

    mv -f "${candidate}" "${OUTPUT_KUBECONFIG}"
    chmod 0600 "${OUTPUT_KUBECONFIG}"
}

main() {
    local cmd
    for cmd in kubectl jq date dirname mkdir stat id base64 tr mktemp rm mv chmod; do
        require_cmd "${cmd}"
    done

    validate_admin_kubeconfig
    validate_output_path

    TMP_DIR="$(mktemp -d /tmp/pod-start-time-check-kubeconfig.XXXXXX)"
    trap cleanup EXIT

    get_cluster_material
    request_runtime_token
    write_runtime_kubeconfig

    log INFO "专用 kubeconfig 已生成: ${OUTPUT_KUBECONFIG}"
    log WARN "该 kubeconfig 使用 TokenRequest 有期限 Token；请求 duration=${TOKEN_DURATION}，实际有效期由 apiserver 决定。到期前需重新执行本 provisioning 脚本。"
    log INFO "运行时只需: KUBECONFIG_FILE=${OUTPUT_KUBECONFIG} ./pod-start-time-check.sh --dry-run"
}

main "$@"
