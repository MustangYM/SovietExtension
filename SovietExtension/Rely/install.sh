#!/bin/bash

# 如果用户用 sh install.sh 执行，自动切换到 bash
# If user runs this script with sh, re-exec with bash.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

set -euo pipefail

# ==============================
# SovietExtension installer
# ==============================

APP_NAME="WeChat"
FRAMEWORK_NAME="${FRAMEWORK_NAME:-SovietExtension}"
APP_PATH="/Applications/${APP_NAME}.app"
FORCE=0
NON_INTERACTIVE=0
RUN_SUDO=0

# Runtime vars
APP_SHORT_VERSION=""
APP_BUILD_VERSION=""
MATCHED_DISPLAY_VERSION=""
MATCHED_LINE=""
BACKUP_PATH=""
HOST_ARCH=""
INSERT_DYLIB_PATH=""
INSERT_DYLIB_RUNNER=""
INSERT_DYLIB_RUN_MODE=""

# ------------------------------
# log helpers
# ------------------------------

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
    cat <<EOF_USAGE
Usage:
  ./install.sh
  sh install.sh
  ./install.sh --force
  ./install.sh --app=/Applications/WeChat.app

Options:
  --force              Ignore version check and install anyway / 忽略版本检查，强制安装
  --non-interactive    Exit on version mismatch instead of prompting / 版本不匹配时直接退出，不交互确认
  --app=PATH           Specify WeChat.app path / 指定 WeChat.app 路径
  --framework=NAME     Specify framework name, default: SovietExtension / 指定插件名，默认 SovietExtension
  --insert-dylib=PATH  Specify insert_dylib path / 指定 insert_dylib 路径
  -h, --help           Show help / 显示帮助

Supported tool layout / 推荐工具文件布局：
  Rely/insert_dylib                  universal, best / universal 版，最推荐
  Rely/insert_dylib_arm64            Apple Silicon 专用
  Rely/insert_dylib_x86_64           Intel 专用
  Rely/insert-dylib                  Rust rewrite 版也可，脚本会尝试识别

EOF_USAGE
}

run_cmd() {
    if [ "${RUN_SUDO}" -eq 1 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=1
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            ;;
        --app=*)
            APP_PATH="${arg#--app=}"
            ;;
        --framework=*)
            FRAMEWORK_NAME="${arg#--framework=}"
            ;;
        --insert-dylib=*)
            INSERT_DYLIB_PATH="${arg#--insert-dylib=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument / 未知参数: ${arg}"
            ;;
    esac
done

APP_PATH="${APP_PATH%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MACOS_PATH="${APP_PATH}/Contents/MacOS"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE_PATH="${MACOS_PATH}/${APP_NAME}"

PLUGIN_SRC_PATH="${SCRIPT_DIR}/Plugin/${FRAMEWORK_NAME}.framework"
PLUGIN_SRC_BINARY_PATH="${PLUGIN_SRC_PATH}/${FRAMEWORK_NAME}"
FRAMEWORK_DST_PATH="${MACOS_PATH}/${FRAMEWORK_NAME}.framework"
FRAMEWORK_DST_BINARY_PATH="${FRAMEWORK_DST_PATH}/${FRAMEWORK_NAME}"

SUPPORTED_FILE="${SCRIPT_DIR}/supported_versions.txt"
LOAD_DYLIB_PATH="@executable_path/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
STATE_FILE="${MACOS_PATH}/.${FRAMEWORK_NAME}.install_state"
LOG_PATH="/tmp/YMWeChatAntiRevokePatch.log"

# ------------------------------
# utilities
# ------------------------------

read_plist() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" 2>/dev/null || true
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

command_required() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || die "Command not found / 命令不存在: ${cmd}"
}

check_required_commands() {
    info "Check required commands / 检查必要命令..."

    command_required /usr/libexec/PlistBuddy
    command_required cp
    command_required rm
    command_required chmod
    command_required ditto
    command_required xattr
    command_required otool
    command_required codesign
    command_required file
    command_required grep
    command_required sed
    command_required uname
    command_required pkill
    command_required pgrep
    command_required osascript

    if ! command -v lipo >/dev/null 2>&1; then
        warn "lipo not found. Architecture diagnosis will use file only / 未找到 lipo，将使用 file 做架构诊断"
    fi

    ok "Required commands exist / 必要命令存在"
}

get_archs() {
    local binary_path="$1"
    local info=""
    local archs=""

    if [ ! -f "${binary_path}" ]; then
        echo ""
        return 0
    fi

    if command -v lipo >/dev/null 2>&1; then
        info="$(lipo -info "${binary_path}" 2>/dev/null || true)"

        if echo "${info}" | grep -q "are:"; then
            archs="$(echo "${info}" | sed 's/^.*are:[[:space:]]*//')"
        fi

        if [ -z "${archs}" ] && echo "${info}" | grep -q "architecture:"; then
            archs="$(echo "${info}" | sed 's/^.*architecture:[[:space:]]*//')"
        fi
    fi

    if [ -z "${archs}" ]; then
        info="$(file "${binary_path}" 2>/dev/null || true)"

        echo "${info}" | grep -qw "x86_64" && archs="${archs} x86_64"
        echo "${info}" | grep -qw "arm64" && archs="${archs} arm64"
        echo "${info}" | grep -qw "arm64e" && archs="${archs} arm64e"
    fi

    echo "${archs}" | xargs 2>/dev/null || true
}

arch_matches() {
    local actual_arch="$1"
    local wanted_arch="$2"

    if [ "${actual_arch}" = "${wanted_arch}" ]; then
        return 0
    fi

    # arm64e 可以视作 Apple Silicon 系列，避免误判
    if [ "${wanted_arch}" = "arm64" ] && [ "${actual_arch}" = "arm64e" ]; then
        return 0
    fi

    return 1
}

binary_contains_arch() {
    local binary_path="$1"
    local wanted_arch="$2"
    local archs=""
    local arch=""

    archs="$(get_archs "${binary_path}")"

    for arch in ${archs}; do
        if arch_matches "${arch}" "${wanted_arch}"; then
            return 0
        fi
    done

    return 1
}

print_binary_info() {
    local title="$1"
    local path="$2"

    echo "    ${title}:"
    echo "      Path:  ${path}"
    echo "      Archs: $(get_archs "${path}")"
    echo "      File:  $(file "${path}" 2>/dev/null || true)"

    if command -v lipo >/dev/null 2>&1; then
        echo "      Lipo:  $(lipo -info "${path}" 2>/dev/null || true)"
    fi
}

is_rosetta_available() {
    if [ "$(uname -m)" != "arm64" ]; then
        return 1
    fi

    /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1
}

# ------------------------------
# file checks
# ------------------------------

check_basic_files() {
    info "Check files / 检查文件..."

    [ -d "${APP_PATH}" ] || die "WeChat.app not found / 找不到 WeChat.app: ${APP_PATH}"
    [ -f "${INFO_PLIST}" ] || die "Info.plist not found / 找不到 Info.plist: ${INFO_PLIST}"
    [ -f "${APP_EXECUTABLE_PATH}" ] || die "WeChat executable not found / 找不到微信主可执行文件: ${APP_EXECUTABLE_PATH}"

    [ -d "${PLUGIN_SRC_PATH}" ] || die "Plugin framework not found / 找不到插件 framework: ${PLUGIN_SRC_PATH}"
    [ -f "${PLUGIN_SRC_BINARY_PATH}" ] || die "Framework binary not found / framework 内找不到同名二进制: ${PLUGIN_SRC_BINARY_PATH}"

    [ -f "${SUPPORTED_FILE}" ] || die "supported_versions.txt not found / 找不到版本控制文件: ${SUPPORTED_FILE}"

    ok "Files look good / 文件检查通过"
}

select_insert_dylib() {
    HOST_ARCH="$(uname -m)"

    local explicit_path="${INSERT_DYLIB_PATH:-}"
    local candidates=()
    local candidate=""

    info "Select insert_dylib tool / 选择 insert_dylib 工具..."

    if [ -n "${explicit_path}" ]; then
        candidates+=("${explicit_path}")
    fi

    # 优先选择当前架构专用工具，其次 universal/默认工具，最后兼容 Rust 重写版 insert-dylib
    candidates+=("${SCRIPT_DIR}/insert_dylib_${HOST_ARCH}")

    if [ "${HOST_ARCH}" = "arm64" ]; then
        candidates+=("${SCRIPT_DIR}/insert_dylib_arm64")
    elif [ "${HOST_ARCH}" = "x86_64" ]; then
        candidates+=("${SCRIPT_DIR}/insert_dylib_x86_64")
    fi

    candidates+=("${SCRIPT_DIR}/insert_dylib")
    candidates+=("${SCRIPT_DIR}/insert-dylib")

    INSERT_DYLIB_PATH=""
    INSERT_DYLIB_RUNNER=""
    INSERT_DYLIB_RUN_MODE="native"

    for candidate in "${candidates[@]}"; do
        [ -f "${candidate}" ] || continue

        chmod +x "${candidate}" >/dev/null 2>&1 || true
        xattr -rd com.apple.quarantine "${candidate}" >/dev/null 2>&1 || true

        if binary_contains_arch "${candidate}" "${HOST_ARCH}"; then
            INSERT_DYLIB_PATH="${candidate}"
            INSERT_DYLIB_RUNNER=""
            INSERT_DYLIB_RUN_MODE="native"
            break
        fi

        if [ "${HOST_ARCH}" = "arm64" ] && binary_contains_arch "${candidate}" "x86_64" && is_rosetta_available; then
            INSERT_DYLIB_PATH="${candidate}"
            INSERT_DYLIB_RUNNER="/usr/bin/arch -x86_64"
            INSERT_DYLIB_RUN_MODE="rosetta-x86_64"
            break
        fi
    done

    if [ -z "${INSERT_DYLIB_PATH}" ]; then
        echo ""
        warn "No compatible insert_dylib was found / 没有找到兼容当前机器的 insert_dylib"
        echo "    Host Arch: ${HOST_ARCH}"
        echo ""
        echo "    Checked paths / 已检查路径："

        for candidate in "${candidates[@]}"; do
            echo "      - ${candidate}"
            if [ -f "${candidate}" ]; then
                print_binary_info "candidate" "${candidate}"
            fi
        done

        echo ""
        die "Please provide universal insert_dylib, or put insert_dylib_${HOST_ARCH} in Rely/. / 请提供 universal 版 insert_dylib，或在 Rely/ 下放入 insert_dylib_${HOST_ARCH}"
    fi

    ok "insert_dylib selected / 已选择 insert_dylib"
    echo "    Path:     ${INSERT_DYLIB_PATH}"
    echo "    Run Mode: ${INSERT_DYLIB_RUN_MODE}"
    print_binary_info "insert_dylib" "${INSERT_DYLIB_PATH}"
    echo ""
}

check_arch_compatibility() {
    HOST_ARCH="$(uname -m)"

    info "Check architecture compatibility / 检查架构兼容性..."
    echo "    Host Arch / 当前机器架构: ${HOST_ARCH}"
    print_binary_info "WeChat executable / 微信主程序" "${APP_EXECUTABLE_PATH}"
    print_binary_info "Plugin framework / 插件 framework" "${PLUGIN_SRC_BINARY_PATH}"
    echo ""

    # 插件需要至少支持当前微信主程序能运行的架构。
    # 对普通用户分发时，强烈建议插件做 universal。
    if binary_contains_arch "${APP_EXECUTABLE_PATH}" "${HOST_ARCH}"; then
        if ! binary_contains_arch "${PLUGIN_SRC_BINARY_PATH}" "${HOST_ARCH}"; then
            warn "Plugin framework may not support host arch ${HOST_ARCH} / 插件可能不支持当前机器架构 ${HOST_ARCH}"
            warn "If WeChat fails to launch, rebuild framework as universal / 如果微信启动失败，请把插件重新编译为 universal"
        fi
    fi

    ok "Architecture pre-check finished / 架构预检查完成"
}

# ------------------------------
# version check
# ------------------------------

check_supported_version() {
    APP_SHORT_VERSION="$(read_plist CFBundleShortVersionString)"
    APP_BUILD_VERSION="$(read_plist CFBundleVersion)"

    [ -n "${APP_SHORT_VERSION}" ] || die "Failed to read CFBundleShortVersionString / 读取微信版本号失败"
    [ -n "${APP_BUILD_VERSION}" ] || die "Failed to read CFBundleVersion / 读取微信 build 号失败"

    MATCHED_DISPLAY_VERSION=""
    MATCHED_LINE=""

    echo ""
    info "Detected WeChat version / 检测到微信版本:"
    echo "    CFBundleShortVersionString: ${APP_SHORT_VERSION}"
    echo "    CFBundleVersion:            ${APP_BUILD_VERSION}"
    echo ""

    while IFS='|' read -r f1 f2 f3 f4 rest || [ -n "${f1:-}" ]; do
        f1="$(trim "${f1:-}")"
        f2="$(trim "${f2:-}")"
        f3="$(trim "${f3:-}")"
        f4="$(trim "${f4:-}")"

        [ -z "${f1}" ] && continue
        [[ "${f1}" == \#* ]] && continue

        local display_version=""
        local short_version=""
        local build_version=""
        local note=""

        # 新格式：DisplayVersion|CFBundleShortVersionString|CFBundleVersion|Note
        # 兼容旧格式：CFBundleShortVersionString|CFBundleVersion|Note
        if [ -n "${f3}" ] && is_build_token "${f3}"; then
            display_version="${f1}"
            short_version="${f2}"
            build_version="${f3}"
            note="${f4}"
        else
            display_version="${f1}"
            short_version="${f1}"
            build_version="${f2}"
            note="${f3}"
        fi

        [ -z "${short_version}" ] && short_version="*"
        [ -z "${build_version}" ] && build_version="*"

        if { [ "${short_version}" = "${APP_SHORT_VERSION}" ] || [ "${short_version}" = "*" ]; } && \
           { [ "${build_version}" = "${APP_BUILD_VERSION}" ] || [ "${build_version}" = "*" ]; }; then
            MATCHED_DISPLAY_VERSION="${display_version}"
            MATCHED_LINE="${display_version}|${short_version}|${build_version}|${note}"
            break
        fi
    done < "${SUPPORTED_FILE}"

    if [ -n "${MATCHED_DISPLAY_VERSION}" ]; then
        ok "Version supported / 版本检查通过"
        echo "    Supported Display Version: ${MATCHED_DISPLAY_VERSION}"
        echo "    Matched Rule:              ${MATCHED_LINE}"
        echo ""

        BACKUP_PATH="${APP_EXECUTABLE_PATH}.backup.${MATCHED_DISPLAY_VERSION}.${APP_BUILD_VERSION}"
        return 0
    fi

    warn "Current WeChat version is not listed in supported_versions.txt / 当前微信版本未在支持列表中"
    echo "    Detected CFBundleShortVersionString: ${APP_SHORT_VERSION}"
    echo "    Detected CFBundleVersion:            ${APP_BUILD_VERSION}"
    echo ""
    echo "    Please add a line like / 请添加类似下面这一行："
    echo "    4.1.9.58|${APP_SHORT_VERSION}|${APP_BUILD_VERSION}|Tested"
    echo ""

    BACKUP_PATH="${APP_EXECUTABLE_PATH}.backup.${APP_SHORT_VERSION}.${APP_BUILD_VERSION}"

    if [ "${FORCE}" -eq 1 ]; then
        warn "Force mode enabled, continue anyway / 已使用 --force，继续安装"
        return 0
    fi

    if [ "${NON_INTERACTIVE}" -eq 1 ]; then
        die "WeChat version not supported / 当前微信版本不在支持列表中，安装已中止"
    fi

    read -r -p "Continue anyway? 是否仍然继续安装？[y/N] " answer
    case "${answer}" in
        y|Y|yes|YES)
            warn "User confirmed, continue installation / 用户确认继续安装"
            ;;
        *)
            die "Installation cancelled / 用户取消安装"
            ;;
    esac
}

# ------------------------------
# install steps
# ------------------------------

prepare_sudo() {
    RUN_SUDO=0

    if [ ! -w "${MACOS_PATH}" ] || [ ! -w "${APP_EXECUTABLE_PATH}" ]; then
        RUN_SUDO=1
        info "Administrator permission required / 需要管理员权限，准备申请 sudo..."
        sudo -v
    fi
}

quit_wechat() {
    info "Quit WeChat / 退出微信..."

    osascript -e 'tell application "WeChat" to quit' >/dev/null 2>&1 || true
    sleep 1

    pkill -x WeChat >/dev/null 2>&1 || true

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x WeChat >/dev/null 2>&1; then
            ok "WeChat is not running / 微信已退出"
            return 0
        fi
        sleep 0.5
    done

    if pgrep -x WeChat >/dev/null 2>&1; then
        warn "WeChat is still running, force kill / 微信仍在运行，强制结束"
        pkill -9 -x WeChat >/dev/null 2>&1 || true
    fi
}

remove_quarantine() {
    info "Remove quarantine attribute / 移除 quarantine 属性..."

    xattr -rd com.apple.quarantine "${INSERT_DYLIB_PATH}" >/dev/null 2>&1 || true
    xattr -rd com.apple.quarantine "${PLUGIN_SRC_PATH}" >/dev/null 2>&1 || true
    run_cmd xattr -rd com.apple.quarantine "${APP_PATH}" >/dev/null 2>&1 || true

    ok "Quarantine handled / quarantine 属性已处理"
}

is_executable_injected() {
    local executable="$1"

    [ -f "${executable}" ] || return 1

    otool -l "${executable}" 2>/dev/null | grep -q "${LOAD_DYLIB_PATH}" && return 0
    otool -l "${executable}" 2>/dev/null | grep -q "${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" && return 0

    return 1
}

backup_executable() {
    info "Backup original executable / 备份微信主可执行文件..."

    if [ -f "${BACKUP_PATH}" ]; then
        if is_executable_injected "${BACKUP_PATH}"; then
            die "Backup exists but already injected / 备份文件已存在，但看起来已经被注入过。请删除错误备份或重新安装微信: ${BACKUP_PATH}"
        fi

        ok "Backup already exists / 备份已存在: ${BACKUP_PATH}"
        return 0
    fi

    if is_executable_injected "${APP_EXECUTABLE_PATH}"; then
        die "WeChat executable is already injected, but clean backup is missing / 当前微信主程序已被注入，但没有干净备份。请先重新安装微信或恢复原版"
    fi

    run_cmd cp -p "${APP_EXECUTABLE_PATH}" "${BACKUP_PATH}"
    ok "Backup created / 已创建备份: ${BACKUP_PATH}"
}

restore_clean_executable() {
    info "Restore clean executable from backup / 从备份恢复干净主程序..."

    [ -f "${BACKUP_PATH}" ] || die "Backup not found / 备份不存在: ${BACKUP_PATH}"

    if is_executable_injected "${BACKUP_PATH}"; then
        die "Backup is already injected / 备份文件不干净，已包含插件注入项: ${BACKUP_PATH}"
    fi

    run_cmd cp -p "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}"
    run_cmd chmod +x "${APP_EXECUTABLE_PATH}"

    ok "Executable restored / 主程序已恢复为干净版本"
}

copy_framework() {
    info "Copy plugin framework / 拷贝插件 framework..."

    run_cmd rm -rf "${FRAMEWORK_DST_PATH}"
    run_cmd ditto "${PLUGIN_SRC_PATH}" "${FRAMEWORK_DST_PATH}"

    [ -f "${FRAMEWORK_DST_BINARY_PATH}" ] || die "Copied framework binary missing / 拷贝后的 framework 二进制不存在: ${FRAMEWORK_DST_BINARY_PATH}"

    run_cmd chmod +x "${FRAMEWORK_DST_BINARY_PATH}" || true
    run_cmd xattr -rd com.apple.quarantine "${FRAMEWORK_DST_PATH}" >/dev/null 2>&1 || true

    ok "Framework copied / 插件 framework 已拷贝"
}

run_insert_dylib_tool() {
    if [ -n "${INSERT_DYLIB_RUNNER}" ]; then
        /usr/bin/arch -x86_64 "${INSERT_DYLIB_PATH}" --all-yes "${LOAD_DYLIB_PATH}" "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}"
    else
        "${INSERT_DYLIB_PATH}" --all-yes "${LOAD_DYLIB_PATH}" "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}"
    fi
}

insert_framework() {
    info "Insert LC_LOAD_DYLIB / 注入 LC_LOAD_DYLIB..."
    echo "    ${LOAD_DYLIB_PATH}"

    chmod +x "${INSERT_DYLIB_PATH}" || true
    xattr -rd com.apple.quarantine "${INSERT_DYLIB_PATH}" >/dev/null 2>&1 || true

    local output=""
    local status=0

    set +e
    if [ "${RUN_SUDO}" -eq 1 ]; then
        if [ -n "${INSERT_DYLIB_RUNNER}" ]; then
            output="$(sudo /usr/bin/arch -x86_64 "${INSERT_DYLIB_PATH}" --all-yes "${LOAD_DYLIB_PATH}" "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}" 2>&1)"
            status="$?"
        else
            output="$(sudo "${INSERT_DYLIB_PATH}" --all-yes "${LOAD_DYLIB_PATH}" "${BACKUP_PATH}" "${APP_EXECUTABLE_PATH}" 2>&1)"
            status="$?"
        fi
    else
        output="$(run_insert_dylib_tool 2>&1)"
        status="$?"
    fi
    set -e

    if [ -n "${output}" ]; then
        echo "${output}"
    fi

    if [ "${status}" -ne 0 ]; then
        if echo "${output}" | grep -qi "Bad CPU type"; then
            echo ""
            echo "    Host Arch: ${HOST_ARCH}"
            print_binary_info "insert_dylib" "${INSERT_DYLIB_PATH}"
            echo ""
            die "insert_dylib failed: Bad CPU type in executable / insert_dylib 架构不匹配。请把 Rely/insert_dylib 换成 universal，或放入 insert_dylib_${HOST_ARCH}"
        fi

        die "insert_dylib failed with exit code ${status} / insert_dylib 执行失败，退出码 ${status}"
    fi

    run_cmd chmod +x "${APP_EXECUTABLE_PATH}"
    ok "Dylib inserted / 注入完成"
}

sign_app() {
    info "Code sign plugin framework / 签名插件 framework..."
    run_cmd codesign --force --deep --sign - --timestamp=none "${FRAMEWORK_DST_PATH}"

    info "Code sign WeChatAppEx if exists / 如果存在则签名 WeChatAppEx..."
    APP_EX_PATH="${MACOS_PATH}/WeChatAppEx.app"

    if [ -d "${APP_EX_PATH}" ]; then
        run_cmd xattr -rd com.apple.quarantine "${APP_EX_PATH}" >/dev/null 2>&1 || true
        run_cmd codesign --force --deep --sign - --timestamp=none "${APP_EX_PATH}" || true

        WEAPP_PATH="${APP_EX_PATH}/Contents/Frameworks/WeChatAppEx Framework.framework/Versions/C/Helpers/WeApp.app"
        if [ -d "${WEAPP_PATH}" ]; then
            run_cmd codesign --force --deep --sign - --timestamp=none "${WEAPP_PATH}" || true
        fi
    fi

    info "Code sign main WeChat.app / 签名主 WeChat.app..."
    run_cmd codesign --force --deep --sign - --timestamp=none "${APP_PATH}"

    ok "Code sign finished / 签名完成"
}

write_state_file() {
    info "Write install state / 写入安装状态..."

    {
        echo "framework=${FRAMEWORK_NAME}"
        echo "display_version=${MATCHED_DISPLAY_VERSION:-unknown}"
        echo "short_version=${APP_SHORT_VERSION}"
        echo "build_version=${APP_BUILD_VERSION}"
        echo "host_arch=${HOST_ARCH}"
        echo "insert_dylib=${INSERT_DYLIB_PATH}"
        echo "insert_dylib_run_mode=${INSERT_DYLIB_RUN_MODE}"
        echo "backup=${BACKUP_PATH}"
        echo "load_dylib=${LOAD_DYLIB_PATH}"
        echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S')"
    } | run_cmd tee "${STATE_FILE}" >/dev/null

    ok "Install state saved / 安装状态已保存: ${STATE_FILE}"
}

verify_install() {
    info "Verify inserted dylib / 检查注入结果..."

    if is_executable_injected "${APP_EXECUTABLE_PATH}"; then
        ok "LC_LOAD_DYLIB found / 已检测到 ${FRAMEWORK_NAME}"
        otool -l "${APP_EXECUTABLE_PATH}" | grep -A3 "${FRAMEWORK_NAME}" || true
    else
        die "LC_LOAD_DYLIB not found / 未检测到 ${FRAMEWORK_NAME}，注入可能失败"
    fi

    echo ""
    info "Verify code signature / 检查签名..."

    if codesign -vvv --deep --strict "${APP_PATH}" >/dev/null 2>&1; then
        ok "Code signature verified / 签名验证通过"
    else
        warn "Code signature verification failed, but app may still run for debugging / 签名验证未完全通过，但调试运行不一定受影响"
        echo "    Debug command / 调试命令："
        echo "      codesign -vvv --deep --strict \"${APP_PATH}\""
    fi
}

print_done() {
    echo ""
    echo "=============================="
    echo "✅ ${FRAMEWORK_NAME} installed successfully"
    echo "✅ ${FRAMEWORK_NAME} 安装完成"
    echo "=============================="
    echo ""
    echo "Detected / 检测信息："
    echo "  WeChat:      ${APP_SHORT_VERSION} (${APP_BUILD_VERSION})"
    echo "  Display:     ${MATCHED_DISPLAY_VERSION:-unknown}"
    echo "  Host Arch:   ${HOST_ARCH}"
    echo "  Tool:        ${INSERT_DYLIB_PATH}"
    echo "  Tool Mode:   ${INSERT_DYLIB_RUN_MODE}"
    echo "  Backup:      ${BACKUP_PATH}"
    echo ""
    echo "Run WeChat and watch log / 启动微信并查看日志："
    echo "  rm -f ${LOG_PATH}"
    echo "  open -a WeChat"
    echo "  tail -f ${LOG_PATH}"
    echo ""
    echo "Uninstall / 卸载："
    echo "  ${SCRIPT_DIR}/uninstall.sh"
    echo ""
}

# ------------------------------
# main
# ------------------------------

echo "=============================="
echo " Install ${FRAMEWORK_NAME}"
echo "=============================="
echo "APP_PATH=${APP_PATH}"
echo "PLUGIN_SRC_PATH=${PLUGIN_SRC_PATH}"
echo "FRAMEWORK_DST_PATH=${FRAMEWORK_DST_PATH}"
echo "SUPPORTED_FILE=${SUPPORTED_FILE}"
echo "LOAD_DYLIB_PATH=${LOAD_DYLIB_PATH}"
echo ""

check_required_commands
check_basic_files
select_insert_dylib
check_arch_compatibility
check_supported_version
prepare_sudo
quit_wechat
remove_quarantine
backup_executable
restore_clean_executable
copy_framework
insert_framework
write_state_file
sign_app
verify_install
print_done
