#!/usr/bin/env bash
# =============================================================================
# install-uv.sh — 一键安装 uv + 最新稳定版 Python
#
# 1. 从 GitHub 下载最新 uv 二进制包，安装到 /usr/local/bin
# 2. 用 uv python install 获取最新稳定版 CPython
# 3. 创建 /usr/local/bin/python3 → uv 托管 Python 的软链接
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 用法:
#   sudo bash install-uv.sh             # 安装最新版
#   sudo bash install-uv.sh --dry-run   # 预览模式
#   sudo bash install-uv.sh --force     # 强制覆盖安装
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
FORCE=false
UV_INSTALL_DIR="/usr/local/bin"

# ── 颜色 ─────────────────────────────────────────────────────────────────────

if [ -t 1 ] && command -v tput &>/dev/null; then
    C_R="$(tput sgr0)"     C_B="$(tput bold)"
    C_RED="$(tput setaf 1)" C_GRN="$(tput setaf 2)"
    C_YEL="$(tput setaf 3)" C_BLU="$(tput setaf 4)"
    C_CYN="$(tput setaf 6)"
else
    C_R=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi

log() {
    local lv="$1"; shift
    local c=""
    case "$lv" in
        INFO) c="$C_GRN" ;; WARN) c="$C_YEL" ;; ERROR) c="$C_RED" ;;
        STEP) c="$C_CYN" ;; *) c="" ;;
    esac
    printf "%s[%s] [%s] %s%s\n" "$c" "$(date '+%H:%M:%S')" "$lv" "$*" "$C_R" >&2
}

die() { log ERROR "$@"; exit 1; }
dry() { if [ "$DRY_RUN" = true ]; then log WARN "[DRY] $*"; else "$@"; fi; }

# ── 参数解析 ──

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true; shift ;;
        -h|--help)
            cat <<EOF
用法: sudo bash $SCRIPT_NAME [选项]

无参数      安装最新 uv + 最新稳定 Python（已安装则跳过）
--dry-run   预览模式，仅显示操作不执行
--force     强制覆盖安装，不检查已有版本
-h, --help  显示此帮助

安装后:
  uv       → /usr/local/bin/uv
  python3  → /usr/local/bin/python3 → uv 托管 Python
  python   → /usr/local/bin/python  → /usr/local/bin/python3
  pip3     → /usr/local/bin/pip3    → uv 托管 Python 自带 pip
  pip      → /usr/local/bin/pip     → /usr/local/bin/pip3
EOF
            exit 0
            ;;
        *) log ERROR "未知选项: $1"; exit 1 ;;
    esac
done

[ "$EUID" -ne 0 ] && die "请以 root 权限运行: sudo bash $SCRIPT_NAME"

# ── 检查依赖 ─────────────────────────────────────────────────────────────────

for cmd in curl tar; do
    command -v "$cmd" &>/dev/null || die "缺少必要命令: ${cmd}，请先安装"
done

# ── 检测系统架构 ─────────────────────────────────────────────────────────────

detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "x86_64"   ;;
        aarch64|arm64)  echo "aarch64"  ;;
        armv7l)         echo "armv7"    ;;
        ppc64le)        echo "powerpc64le" ;;
        s390x)          echo "s390x"    ;;
        *) die "不支持的硬件架构: ${arch}" ;;
    esac
}

UNAME_ARCH=$(detect_arch)
log INFO "系统架构: ${UNAME_ARCH}"

# ══════════════════════════════════════════════════════════════════════════════
#  步骤 1: 安装 uv
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 安装 uv..."

UV_TARBALL="uv-${UNAME_ARCH}-unknown-linux-gnu.tar.gz"
UV_URL="https://github.com/astral-sh/uv/releases/latest/download/${UV_TARBALL}"

# 检查已有版本
if [ "$FORCE" != true ] && command -v uv &>/dev/null; then
    CURRENT_UV=$(uv --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    LATEST_UV=$(curl -fsSL "https://api.github.com/repos/astral-sh/uv/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [ -n "$LATEST_UV" ] && [ "$CURRENT_UV" = "$LATEST_UV" ]; then
        log INFO "uv ${CURRENT_UV} 已是最新版本，跳过安装"
    elif [ -n "$LATEST_UV" ]; then
        log WARN "当前 uv: ${CURRENT_UV} → 将升级到 ${LATEST_UV}"
    else
        log WARN "无法检查最新版本，将重新下载安装"
    fi
fi

log INFO "下载: ${UV_URL}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过 uv 下载"
else
    curl -fsSL --progress-bar "$UV_URL" -o "${TMP_DIR}/${UV_TARBALL}" || \
        die "uv 下载失败，请检查网络连接"
    log INFO "下载完成 ✓"

    tar -xzf "${TMP_DIR}/${UV_TARBALL}" -C "${TMP_DIR}"
    # tarball 内结构: uv-{arch}-unknown-linux-gnu/uv  (二元文件)
    #             或:  uv-{arch}-unknown-linux-gnu/uvx (工具)
    for bin in uv uvx; do
        local src; src=$(find "${TMP_DIR}" -name "$bin" -type f 2>/dev/null | head -1)
        [ -n "$src" ] && dry cp "$src" "${UV_INSTALL_DIR}/${bin}" && dry chmod +x "${UV_INSTALL_DIR}/${bin}"
    done
    log INFO "uv 安装到 ${UV_INSTALL_DIR}/uv ✓"
fi

# 确保 /usr/local/bin 在 PATH
if ! echo "$PATH" | grep -q '/usr/local/bin'; then
    export PATH="/usr/local/bin:$PATH"
fi

# 验证 uv
if [ "$DRY_RUN" = false ]; then
    if command -v uv &>/dev/null; then
        uv --version 2>/dev/null | while IFS= read -r l; do log INFO "  uv:    ${l}"; done
    else
        die "uv 安装后不可用，请检查"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  步骤 2: 安装 Python
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 安装最新稳定版 Python..."

PYTHON_VERSION=""
PYTHON_PATH=""

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过 Python 安装"
else
    # 获取 uv 托管的最新稳定版 CPython 版本号
    PYTHON_VERSION=$(uv python list --all-versions 2>/dev/null \
        | grep 'cpython-' \
        | grep -v '+freethreaded' \
        | grep -vE '[0-9][abrc][0-9]' \
        | grep -oP 'cpython-\K[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1)

    if [ -z "$PYTHON_VERSION" ]; then
        # 回退：安装已知稳定版本
        PYTHON_VERSION="3.14"
        log WARN "无法自动获取最新版本，使用回退版本: ${PYTHON_VERSION}"
    fi

    log INFO "目标版本: ${C_GRN}${PYTHON_VERSION}${C_R}"

    # 安装
    if uv python install "$PYTHON_VERSION" 2>&1 | while IFS= read -r l; do log INFO "  ${l}"; done; then
        log INFO "Python ${PYTHON_VERSION} 安装完成 ✓"
    else
        die "uv python install 失败"
    fi

    # 查找 uv 安装的 Python 路径
    PYTHON_PATH=$(uv python find "$PYTHON_VERSION" 2>/dev/null)
    if [ -z "$PYTHON_PATH" ] || [ ! -x "$PYTHON_PATH" ]; then
        die "找不到 uv 托管的 Python 可执行文件"
    fi
    log INFO "Python 路径: ${PYTHON_PATH}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  步骤 3: 创建 python3 / python 软链接
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 创建 python3 / python / pip3 / pip 系统链接..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过软链接创建"
else
    dry ln -sf "$PYTHON_PATH" /usr/local/bin/python3
    dry ln -sf /usr/local/bin/python3 /usr/local/bin/python
    log INFO "  /usr/local/bin/python3 → ${PYTHON_PATH}"
    log INFO "  /usr/local/bin/python  → /usr/local/bin/python3"

    # pip3 和 python3 在 uv 托管的同一目录中
    PYTHON_BIN_DIR=$(dirname "$PYTHON_PATH")
    PIP3_PATH="${PYTHON_BIN_DIR}/pip3"
    if [ -x "$PIP3_PATH" ]; then
        dry ln -sf "$PIP3_PATH" /usr/local/bin/pip3
        dry ln -sf /usr/local/bin/pip3 /usr/local/bin/pip
        log INFO "  /usr/local/bin/pip3    → ${PIP3_PATH}"
        log INFO "  /usr/local/bin/pip     → /usr/local/bin/pip3"
    else
        # 部分 Python 构建不带 pip（极少数情况），用 ensurepip 补救
        log WARN "pip3 未找到，尝试通过 ensurepip 安装..."
        "$PYTHON_PATH" -m ensurepip --upgrade 2>&1 | while IFS= read -r l; do log INFO "  ${l}"; done || true
        if [ -x "$PIP3_PATH" ]; then
            dry ln -sf "$PIP3_PATH" /usr/local/bin/pip3
            dry ln -sf /usr/local/bin/pip3 /usr/local/bin/pip
            log INFO "  /usr/local/bin/pip3    → ${PIP3_PATH}"
            log INFO "  /usr/local/bin/pip     → /usr/local/bin/pip3"
        else
            log WARN "pip 安装失败，请使用 'uv pip' 代替"
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  验证
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 验证..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过验证"
else
    echo ""
    if command -v uv &>/dev/null; then
        uv --version 2>/dev/null | while IFS= read -r l; do log INFO "  uv:      ${l}"; done
    fi
    if command -v python3 &>/dev/null; then
        python3 --version 2>/dev/null | while IFS= read -r l; do log INFO "  python3: ${l}"; done
    fi
    if command -v python &>/dev/null; then
        python --version 2>/dev/null | while IFS= read -r l; do log INFO "  python:  ${l}"; done
    fi
    if command -v pip3 &>/dev/null; then
        pip3 --version 2>/dev/null | while IFS= read -r l; do log INFO "  pip3:    ${l}"; done
    fi
fi

# ── 结果 ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" = true ]; then
    log WARN "预览模式完成。正式安装请运行: sudo bash ${SCRIPT_NAME}"
else
    log STEP "安装完成！"
    echo ""
    log INFO "快速开始:"
    log INFO "  python3 --version           # 查看 Python 版本"
    log INFO "  pip3 install <pkg>          # 安装 Python 包"
    log INFO "  uv pip install <pkg>        # 或使用 uv pip（更快）"
    log INFO "  uv init                     # 创建新项目"
fi
