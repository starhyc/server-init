#!/usr/bin/env bash
# =============================================================================
# install-latest-nodejs.sh — 交互式安装最新版 Node.js
#
# 从 nodejs.org 官方源下载最新稳定版二进制包，解压到 /usr/local，
# 支持交互式配置 npm 镜像、全局工具安装。
# 适用于所有主流 Linux 发行版。
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 用法:
#   sudo bash install-latest-nodejs.sh             # 交互式安装
#   curl -fsSL <url> | sudo bash                   # 管道运行（自动读取 /dev/tty）
#   sudo bash install-latest-nodejs.sh --batch     # 非交互模式
#   sudo bash install-latest-nodejs.sh --dry-run   # 预览模式
#   sudo bash install-latest-nodejs.sh --force     # 强制覆盖安装
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
FORCE=false
BATCH_MODE=false
NPM_MIRROR=""
INSTALL_GLOBALS=""
TTY=/dev/tty; [ -e /dev/tty ] || TTY=/dev/stdin

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

# ── 参数解析 ─────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true; shift ;;
        --batch)   BATCH_MODE=true; shift ;;
        --mirror)  NPM_MIRROR="$2"; shift 2 ;;
        --globals) INSTALL_GLOBALS="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
用法: sudo bash install-latest-nodejs.sh [选项]

无参数       交互式安装（会提示 npm 镜像、全局工具等配置）
--batch      非交互模式，跳过所有提示，仅安装 Node.js
--dry-run    预览模式，仅显示操作不执行
--force      强制覆盖安装，不检查已有版本
--mirror URL 指定 npm 镜像地址（如 https://registry.npmmirror.com）
--globals PKG 额外安装的全局 npm 包（空格分隔，如 "yarn pnpm pm2"）
-h, --help   显示此帮助

安装内容: Node.js (最新稳定版) + npm + npx + corepack
安装位置: /usr/local (通过 nodejs.org 官方 Linux 二进制包)
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
        x86_64|amd64) echo "x64"     ;;
        aarch64|arm64) echo "arm64"  ;;
        armv7l)        echo "armv7l" ;;
        ppc64le)       echo "ppc64le" ;;
        s390x)         echo "s390x"   ;;
        *) die "不支持的硬件架构: ${arch}" ;;
    esac
}

NODE_ARCH=$(detect_arch)
log INFO "系统架构: ${NODE_ARCH}"

# ── 检测包管理器（用于安装运行时依赖）────────────────────────────────────────

_detect_pkg_manager() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|raspbian) echo "apt" ;;
            centos|rhel|rocky|almalinux|ol|fedora|amzn)
                command -v dnf &>/dev/null && echo "dnf" || echo "yum" ;;
            opensuse*|sles) echo "zypper" ;;
            arch|manjaro|endeavouros) echo "pacman" ;;
            *) echo "unknown" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        command -v dnf &>/dev/null && echo "dnf" || echo "yum"
    else
        echo "unknown"
    fi
}

_install_pkg() {
    case "$PKG_MGR" in
        apt)    apt-get install -y "$1" ;;
        dnf)    dnf install -y "$1" ;;
        yum)    yum install -y "$1" ;;
        zypper) zypper install -y "$1" ;;
        pacman) pacman -S --noconfirm "$1" ;;
    esac
}

# ── 获取最新版本号 ───────────────────────────────────────────────────────────

log STEP "── 获取最新 Node.js 版本..."

LATEST_VERSION=$(curl -fsSL "https://nodejs.org/dist/latest/SHASUMS256.txt" 2>/dev/null \
    | head -1 \
    | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1)

[ -z "$LATEST_VERSION" ] && die "无法获取最新版本号，请检查网络连接"

log INFO "最新稳定版: ${C_GRN}v${LATEST_VERSION}${C_R}"

# ── 检查已有版本 ─────────────────────────────────────────────────────────────

if [ "$FORCE" != true ] && command -v node &>/dev/null; then
    CURRENT_VERSION=$(node --version 2>/dev/null | sed 's/^v//')
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        log INFO "Node.js v${CURRENT_VERSION} 已是最新版本，无需安装"
        node --version 2>/dev/null | while IFS= read -r l; do log INFO "  node:  ${l}"; done
        npm --version 2>/dev/null | while IFS= read -r l; do log INFO "  npm:   ${l}"; done
        exit 0
    fi
    log WARN "当前版本: v${CURRENT_VERSION} → 将升级到 v${LATEST_VERSION}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  交互式配置
# ══════════════════════════════════════════════════════════════════════════════

if [ "$BATCH_MODE" = false ] && [ "$DRY_RUN" = false ] && [ -e /dev/tty ]; then
    echo ""
    log STEP "── 交互式配置..."

    # ── 问题 1: npm 镜像 ──
    if [ -z "$NPM_MIRROR" ]; then
        printf "  ${C_B}配置 npm 镜像源？${C_R}\n"
        printf "  ${C_CYN}1)${C_R} 不配置，使用官方源 (registry.npmjs.org)\n"
        printf "  ${C_CYN}2)${C_R} npmmirror.com (中国大陆镜像，加速下载)\n"
        printf "  ${C_CYN}3)${C_R} 自定义地址\n"
        printf "  ${C_B}请选择 [1-3] (默认 1) > ${C_R}"
        read -r mirror_choice < /dev/tty
        case "$mirror_choice" in
            2)
                NPM_MIRROR="https://registry.npmmirror.com"
                log INFO "已选择: npmmirror.com"
                ;;
            3)
                printf "  ${C_B}请输入镜像地址 > ${C_R}"
                read -r custom_mirror < /dev/tty
                [ -n "$custom_mirror" ] && NPM_MIRROR="$custom_mirror"
                ;;
            *)  log INFO "使用 npm 官方源" ;;
        esac
    fi

    # ── 问题 2: 全局工具 ──
    if [ -z "$INSTALL_GLOBALS" ]; then
        printf "  ${C_B}安装常用的全局 npm 包？${C_R}\n"
        printf "  ${C_CYN}1)${C_R} 不安装额外全局包\n"
        printf "  ${C_CYN}2)${C_R} 推荐组合: yarn pnpm pm2\n"
        printf "  ${C_CYN}3)${C_R} 自选\n"
        printf "  ${C_B}请选择 [1-3] (默认 1) > ${C_R}"
        read -r globals_choice < /dev/tty
        case "$globals_choice" in
            2)
                INSTALL_GLOBALS="yarn pnpm pm2"
                log INFO "将安装: ${C_GRN}${INSTALL_GLOBALS}${C_R}"
                ;;
            3)
                printf "  ${C_B}请输入要安装的包名 (空格分隔) > ${C_R}"
                read -r custom_globals < /dev/tty
                [ -n "$custom_globals" ] && INSTALL_GLOBALS="$custom_globals"
                log INFO "将安装: ${C_GRN}${INSTALL_GLOBALS}${C_R}"
                ;;
            *)  log INFO "跳过全局包安装" ;;
        esac
    fi

    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
#  下载 & 安装
# ══════════════════════════════════════════════════════════════════════════════

NODE_DIST="node-v${LATEST_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_URL="https://nodejs.org/dist/v${LATEST_VERSION}/${NODE_DIST}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log STEP "── 下载 ${NODE_DIST}..."
log INFO "${NODE_URL}"

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过下载"
else
    curl -fsSL --progress-bar "$NODE_URL" -o "${TMP_DIR}/${NODE_DIST}" || \
        die "下载失败，请检查网络连接"
    log INFO "下载完成 ✓"
fi

log STEP "── 安装到 /usr/local..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过安装"
else
    dry tar -xJf "${TMP_DIR}/${NODE_DIST}" -C /usr/local --strip-components=1
    log INFO "解压完成 ✓"
fi

# ── 运行时依赖修复 ──────────────────────────────────────────────────────────

_fix_missing_libs() {
    local err; err=$(LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/node --version 2>&1) || true
    [ -z "$err" ] && return 0

    if echo "$err" | grep -q "libatomic"; then
        log WARN "检测到缺少 libatomic.so.1，正在安装..."
        case "$PKG_MGR" in
            apt)    _install_pkg libatomic1 ;;
            dnf|yum) _install_pkg libatomic ;;
            zypper) _install_pkg libatomic1 ;;
            pacman) log INFO "  Arch: libatomic 由 gcc-libs 提供，通常已预装" ;;
            *)      log WARN "  请手动安装 libatomic (apt: libatomic1 / dnf: libatomic)" ;;
        esac
    fi

    if echo "$err" | grep -q "libstdc++"; then
        log WARN "检测到缺少 libstdc++，正在安装..."
        case "$PKG_MGR" in
            apt)    _install_pkg libstdc++6 ;;
            dnf|yum) _install_pkg libstdc++ ;;
            zypper) _install_pkg libstdc++6 ;;
            pacman) log INFO "  Arch: libstdc++ 由 gcc-libs 提供，通常已预装" ;;
            *)      log WARN "  请手动安装 libstdc++" ;;
        esac
    fi
}

if [ "$DRY_RUN" = false ]; then
    PKG_MGR=$(_detect_pkg_manager)
    log INFO "包管理器: ${PKG_MGR}"

    # 确保 /usr/local/lib 在库搜索路径中
    if ! grep -q '/usr/local/lib' /etc/ld.so.conf.d/*.conf 2>/dev/null; then
        echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
        ldconfig
    fi

    _fix_missing_libs
fi

# ══════════════════════════════════════════════════════════════════════════════
#  配置 npm 镜像
# ══════════════════════════════════════════════════════════════════════════════

if [ -n "$NPM_MIRROR" ] && [ "$DRY_RUN" = false ]; then
    log STEP "── 配置 npm 镜像..."
    /usr/local/bin/npm config set registry "$NPM_MIRROR" 2>/dev/null || true
    log INFO "npm registry: ${C_GRN}${NPM_MIRROR}${C_R}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  安装全局 npm 包
# ══════════════════════════════════════════════════════════════════════════════

if [ -n "$INSTALL_GLOBALS" ] && [ "$DRY_RUN" = false ]; then
    log STEP "── 安装全局 npm 包..."
    for pkg in $INSTALL_GLOBALS; do
        log INFO "安装 ${pkg}..."
        /usr/local/bin/npm install -g "$pkg" 2>&1 | while IFS= read -r l; do
            log INFO "  ${l}"
        done || log WARN "${pkg} 安装可能失败"
    done
fi

# ══════════════════════════════════════════════════════════════════════════════
#  验证
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 验证安装..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过验证"
else
    if ! echo "$PATH" | grep -q '/usr/local/bin'; then
        export PATH="/usr/local/bin:$PATH"
    fi

    echo ""

    if command -v node &>/dev/null; then
        node --version 2>/dev/null | while IFS= read -r l; do log INFO "  node:  ${l}"; done
    else
        die "node 命令不可用，安装可能失败"
    fi

    if command -v npm &>/dev/null; then
        npm --version 2>/dev/null | while IFS= read -r l; do log INFO "  npm:   ${l}"; done
    else
        log WARN "npm 命令不可用"
    fi

    if command -v npx &>/dev/null; then
        npx --version 2>/dev/null | while IFS= read -r l; do log INFO "  npx:   ${l}"; done
    fi

    if command -v corepack &>/dev/null; then
        corepack --version 2>/dev/null | while IFS= read -r l; do log INFO "  corepack: ${l}"; done
    fi
fi

# ── 结果 ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" = true ]; then
    log WARN "预览模式完成。正式安装请运行: sudo bash ${SCRIPT_NAME}"
else
    log STEP "Node.js v${LATEST_VERSION} 安装完成！"
    echo ""
    log INFO "快速开始:"
    log INFO "  node -v               # 查看 Node.js 版本"
    log INFO "  npm -v                # 查看 npm 版本"
    if [ -n "$NPM_MIRROR" ]; then
        log INFO "  npm config get registry  # 查看镜像源"
    fi
fi
