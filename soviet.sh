#!/bin/bash
#
# SovietExtension one-click installer / 苏维埃助手一键安装脚本
#
# Usage / 用法:
#   curl -fsSL https://raw.githubusercontent.com/MustangYM/SovietExtension/main/soviet.sh | bash -s install
#   curl -fsSL https://raw.githubusercontent.com/MustangYM/SovietExtension/main/soviet.sh | bash -s uninstall
#
# Or download and run / 或下载后执行:
#   bash soviet.sh install
#   bash soviet.sh uninstall
#   bash soviet.sh status
#   bash soviet.sh version
#

if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

set -euo pipefail

INSTALLER_VERSION="1.0.0"
FRAMEWORK_NAME="${FRAMEWORK_NAME:-SovietExtension}"
APP_NAME="WeChat"
DEFAULT_APP_PATH="/Applications/${APP_NAME}.app"

REPO_URL="${SOVIET_REPO:-https://github.com/MustangYM/SovietExtension.git}"
REPO_BRANCH="${SOVIET_BRANCH:-main}"
RAW_BASE="${SOVIET_RAW_BASE:-https://raw.githubusercontent.com/MustangYM/SovietExtension/${REPO_BRANCH}}"
RELY_SUBPATH="SovietExtension/Rely"

WORKDIR=""
SELF_PATH=""
LOCAL_REPO_ROOT=""
SKIP_SELF_DELETE=0
TEMP_SUPPORTED_FILE=""

die() {
    echo ""
    echo "❌ [ERROR] $*" >&2
    echo ""
    exit 1
}

warn() {
    echo "⚠️  [WARN] $*"
}

ok() {
    echo "✅ [OK] $*"
}

info() {
    echo "👉 [INFO] $*"
}

usage() {
    cat <<EOF
SovietExtension one-click installer v${INSTALLER_VERSION}
苏维埃助手一键安装脚本 v${INSTALLER_VERSION}

Usage / 用法:
  bash soviet.sh install [options]
  bash soviet.sh uninstall [options]
  bash soviet.sh status [--app=PATH]
  bash soviet.sh version
  bash soviet.sh help

Commands / 命令:
  install     Clone repo, run install.sh, clean up / 克隆仓库、安装、清理临时文件
  uninstall   Clone repo, run uninstall.sh, clean up / 克隆仓库、卸载、清理临时文件
  status      Show installation status / 查看安装状态
  version     Show installer and supported WeChat versions / 查看安装器与支持版本
  help        Show this help / 显示帮助

Install options / 安装选项:
  --force              Ignore WeChat version check / 忽略微信版本检查
  --app=PATH           WeChat.app path, default: ${DEFAULT_APP_PATH}
  --framework=NAME     Framework name, default: ${FRAMEWORK_NAME}

Uninstall options / 卸载选项:
  --force              Allow restoring from non-current backup / 允许使用非当前版本备份恢复
  --remove-backup      Remove backup files after uninstall / 卸载后删除备份
  --app=PATH           WeChat.app path
  --framework=NAME     Framework name

Environment / 环境变量:
  SOVIET_REPO          Git repository URL
  SOVIET_BRANCH        Git branch, default: main
  SOVIET_RAW_BASE      Raw GitHub base URL for version pre-check

One-liner / 一键命令:
  curl -fsSL ${RAW_BASE}/soviet.sh | bash -s install
  curl -fsSL ${RAW_BASE}/soviet.sh | bash -s uninstall

EOF
}

cleanup() {
    if [ -n "${TEMP_SUPPORTED_FILE}" ] && [ -f "${TEMP_SUPPORTED_FILE}" ]; then
        rm -f "${TEMP_SUPPORTED_FILE}"
        TEMP_SUPPORTED_FILE=""
    fi

    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
        WORKDIR=""
    fi

    if [ "${SKIP_SELF_DELETE}" -eq 1 ]; then
        return 0
    fi

    if [ -n "${SELF_PATH}" ] && [ -f "${SELF_PATH}" ]; then
        rm -f "${SELF_PATH}" 2>/dev/null || true
    fi
}

resolve_self_path() {
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    fi
}

detect_local_repo() {
    local candidate=""

    if [ -n "${SELF_PATH}" ]; then
        candidate="$(cd "$(dirname "${SELF_PATH}")" && pwd)"
        if [ -f "${candidate}/${RELY_SUBPATH}/install.sh" ]; then
            LOCAL_REPO_ROOT="${candidate}"
            SKIP_SELF_DELETE=1
            return 0
        fi
    fi

    return 1
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "This installer only supports macOS / 仅支持 macOS"
}

require_command() {
    local cmd="$1"
    local hint="$2"
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command '${cmd}'. ${hint}"
}

trim() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_build_token() {
    local value="$1"

    if [ "${value}" = "*" ]; then
        return 0
    fi

    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    return 1
}

read_plist() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" 2>/dev/null || true
}

fetch_supported_versions_file() {
    local dest="$1"

    if [ -n "${LOCAL_REPO_ROOT}" ]; then
        cp "${LOCAL_REPO_ROOT}/${RELY_SUBPATH}/supported_versions.txt" "${dest}"
        return 0
    fi

    require_command curl "Install curl or clone the repository manually."

    curl -fsSL "${RAW_BASE}/${RELY_SUBPATH}/supported_versions.txt" -o "${dest}" \
        || die "Failed to download supported_versions.txt / 下载版本列表失败"
}

match_wechat_version() {
    local supported_file="$1"
    local app_path="$2"
    local info_plist="${app_path}/Contents/Info.plist"
    local short_version=""
    local build_version=""
    local matched_display=""

    [ -d "${app_path}" ] || die "WeChat.app not found / 找不到微信: ${app_path}"
    [ -f "${info_plist}" ] || die "Info.plist not found / 找不到 Info.plist: ${info_plist}"

    short_version="$(read_plist "${info_plist}" CFBundleShortVersionString)"
    build_version="$(read_plist "${info_plist}" CFBundleVersion)"

    [ -n "${short_version}" ] || die "Failed to read CFBundleShortVersionString / 读取微信版本号失败"
    [ -n "${build_version}" ] || die "Failed to read CFBundleVersion / 读取微信 build 号失败"

    while IFS='|' read -r f1 f2 f3 f4 rest || [ -n "${f1:-}" ]; do
        f1="$(trim "${f1:-}")"
        f2="$(trim "${f2:-}")"
        f3="$(trim "${f3:-}")"
        f4="$(trim "${f4:-}")"

        [ -z "${f1}" ] && continue
        [[ "${f1}" == \#* ]] && continue

        local display_version=""
        local rule_short=""
        local rule_build=""

        if [ -n "${f3}" ] && is_build_token "${f3}"; then
            display_version="${f1}"
            rule_short="${f2}"
            rule_build="${f3}"
        else
            display_version="${f1}"
            rule_short="${f1}"
            rule_build="${f2}"
        fi

        [ -z "${rule_short}" ] && rule_short="*"
        [ -z "${rule_build}" ] && rule_build="*"

        if { [ "${rule_short}" = "${short_version}" ] || [ "${rule_short}" = "*" ]; } && \
           { [ "${rule_build}" = "${build_version}" ] || [ "${rule_build}" = "*" ]; }; then
            matched_display="${display_version}"
            break
        fi
    done < "${supported_file}"

    if [ -z "${matched_display}" ]; then
        echo ""
        warn "WeChat version not supported / 当前微信版本不在支持列表中"
        echo "    CFBundleShortVersionString: ${short_version}"
        echo "    CFBundleVersion:            ${build_version}"
        echo ""
        echo "    Supported versions / 支持版本:"
        grep -v '^[[:space:]]*#' "${supported_file}" | grep -v '^[[:space:]]*$' | sed 's/^/    /' || true
        echo ""
        return 1
    fi

    ok "WeChat version supported / 微信版本检查通过: ${matched_display} (${short_version} / ${build_version})"
    return 0
}

verify_installer_version() {
    local repo_root="$1"
    local version_file="${repo_root}/${RELY_SUBPATH}/installer.version"
    local repo_version=""

    [ -f "${version_file}" ] || return 0

    repo_version="$(trim "$(cat "${version_file}")")"
    [ -n "${repo_version}" ] || return 0

    if [ "${repo_version}" != "${INSTALLER_VERSION}" ]; then
        die "Installer version mismatch / 安装器版本不匹配: script=${INSTALLER_VERSION}, repo=${repo_version}. Please re-download soviet.sh / 请重新下载最新安装脚本"
    fi
}

prepare_workdir() {
    if [ -n "${LOCAL_REPO_ROOT}" ]; then
        echo "${LOCAL_REPO_ROOT}"
        return 0
    fi

    require_command git "Install Xcode Command Line Tools: xcode-select --install"

    WORKDIR="$(mktemp -d)"

    info "Cloning repository / 克隆仓库..."
    git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${WORKDIR}/repo" >/dev/null \
        || die "Failed to clone repository / 克隆仓库失败: ${REPO_URL}"

    echo "${WORKDIR}/repo"
}

parse_app_path() {
    local app_path="${DEFAULT_APP_PATH}"

    for arg in "$@"; do
        case "${arg}" in
            --app=*)
                app_path="${arg#--app=}"
                ;;
        esac
    done

    echo "${app_path%/}"
}

has_force_flag() {
    for arg in "$@"; do
        case "${arg}" in
            --force)
                return 0
                ;;
        esac
    done
    return 1
}

cmd_install() {
    local app_path=""
    local repo_root=""
    local install_args=(--non-interactive)

    require_macos

    app_path="$(parse_app_path "$@")"
    TEMP_SUPPORTED_FILE="$(mktemp)"

    echo ""
    echo "=============================="
    echo " SovietExtension Install"
    echo " 苏维埃助手 一键安装"
    echo "=============================="
    echo ""

    fetch_supported_versions_file "${TEMP_SUPPORTED_FILE}"

    if ! has_force_flag "$@"; then
        match_wechat_version "${TEMP_SUPPORTED_FILE}" "${app_path}" \
            || die "Installation aborted due to unsupported WeChat version / 微信版本不支持，安装已中止。使用 --force 可强制安装"
    else
        warn "Force mode enabled, skipping WeChat version pre-check / 已启用 --force，跳过微信版本预检"
        install_args+=(--force)
    fi

    for arg in "$@"; do
        case "${arg}" in
            --force)
                ;;
            *)
                install_args+=("${arg}")
                ;;
        esac
    done

    repo_root="$(prepare_workdir)"
    verify_installer_version "${repo_root}"

    info "Running install.sh / 执行安装脚本..."
    bash "${repo_root}/${RELY_SUBPATH}/install.sh" "${install_args[@]}"

    ok "Install finished, cleaning up temporary files / 安装完成，正在清理临时文件"
}

cmd_uninstall() {
    local repo_root=""

    require_macos

    echo ""
    echo "=============================="
    echo " SovietExtension Uninstall"
    echo " 苏维埃助手 一键卸载"
    echo "=============================="
    echo ""

    repo_root="$(prepare_workdir)"
    verify_installer_version "${repo_root}"

    info "Running uninstall.sh / 执行卸载脚本..."
    bash "${repo_root}/${RELY_SUBPATH}/uninstall.sh" "$@"

    ok "Uninstall finished, cleaning up temporary files / 卸载完成，正在清理临时文件"
}

cmd_status() {
    local app_path=""
    local macos_path=""
    local framework_path=""
    local state_file=""
    local info_plist=""
    local short_version=""
    local build_version=""

    require_macos

    app_path="$(parse_app_path "$@")"
    macos_path="${app_path}/Contents/MacOS"
    framework_path="${macos_path}/${FRAMEWORK_NAME}.framework"
    state_file="${macos_path}/.${FRAMEWORK_NAME}.install_state"
    info_plist="${app_path}/Contents/Info.plist"

    echo ""
    echo "=============================="
    echo " SovietExtension Status"
    echo "=============================="
    echo ""

    [ -d "${app_path}" ] || die "WeChat.app not found / 找不到微信: ${app_path}"

    short_version="$(read_plist "${info_plist}" CFBundleShortVersionString)"
    build_version="$(read_plist "${info_plist}" CFBundleVersion)"

    info "WeChat / 微信: ${short_version} (${build_version})"
    info "App path / 应用路径: ${app_path}"

    if [ -d "${framework_path}" ]; then
        ok "Plugin framework installed / 插件已安装: ${framework_path}"
    else
        warn "Plugin framework not found / 未检测到插件: ${framework_path}"
    fi

    if [ -f "${state_file}" ]; then
        ok "Install state file found / 找到安装状态文件:"
        sed 's/^/    /' "${state_file}"
    else
        warn "Install state file not found / 未找到安装状态文件: ${state_file}"
    fi

    echo ""
}

cmd_version() {
    echo ""
    echo "Installer version / 安装器版本: ${INSTALLER_VERSION}"
    echo "Repository / 仓库: ${REPO_URL} (${REPO_BRANCH})"
    echo ""

    TEMP_SUPPORTED_FILE="$(mktemp)"

    fetch_supported_versions_file "${TEMP_SUPPORTED_FILE}"

    echo "Supported WeChat versions / 支持的微信版本:"
    grep -v '^[[:space:]]*#' "${TEMP_SUPPORTED_FILE}" | grep -v '^[[:space:]]*$' | sed 's/^/  /' || true
    echo ""
}

main() {
    local command="${1:-install}"

    resolve_self_path
    detect_local_repo || true

    trap cleanup EXIT INT TERM

    case "${command}" in
        install)
            shift || true
            cmd_install "$@"
            ;;
        uninstall)
            shift || true
            cmd_uninstall "$@"
            ;;
        status)
            shift || true
            cmd_status "$@"
            ;;
        version|versions)
            cmd_version
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            die "Unknown command / 未知命令: ${command}. Run 'bash soviet.sh help' for usage."
            ;;
    esac
}

main "$@"