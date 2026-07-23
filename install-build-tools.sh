#!/usr/bin/env bash
# =============================================================================
# install-build-tools.sh — 交互式安装基础构建工具
#
# 一键安装 C/C++ 编译工具链（gcc/g++/make 等）+ 常用开发工具，
# 适用于从零开始的服务器 / 容器环境。
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 用法:
#   sudo bash install-build-tools.sh             # 交互式安装（选择模式）
#   curl -fsSL <url> | sudo bash                 # 管道运行（自动读取 /dev/tty）
#   sudo bash install-build-tools.sh --batch     # 非交互模式（安装完整工具集）
#   sudo bash install-build-tools.sh --minimal   # 非交互模式（仅安装编译工具链）
#   sudo bash install-build-tools.sh --dry-run   # 预览模式
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
MODE="ask"   # ask | full | minimal
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
        --batch)   MODE="full"; shift ;;
        --minimal) MODE="minimal"; shift ;;
        -h|--help)
            cat <<'EOF'
用法: sudo bash install-build-tools.sh [选项]

无参数       交互式选择安装模式（完整 / 最小化）
--batch      非交互模式，安装完整工具集（编译 + 开发辅助 + Git + curl）
--minimal    非交互模式，仅安装编译工具链（gcc/g++/make）
--dry-run    预览模式，仅显示将安装的包不执行
-h, --help   显示此帮助

完整工具集: 编译工具链 + cmake + autoconf/automake + pkg-config + libtool
           + curl/wget + git + 解压工具
最小化:     gcc/g++/make/binutils (build-essential / base-devel)
EOF
            exit 0
            ;;
        *) log ERROR "未知选项: $1"; exit 1 ;;
    esac
done

[ "$EUID" -ne 0 ] && die "请以 root 权限运行: sudo bash $SCRIPT_NAME"

# ── 系统探测 ─────────────────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu)       echo "ubuntu"   ;;
            debian)       echo "debian"   ;;
            raspbian)     echo "debian"   ;;
            fedora)       echo "fedora"   ;;
            centos|rhel|rocky|almalinux|ol|amzn) echo "rhel" ;;
            opensuse*|sles) echo "suse"   ;;
            arch|manjaro|endeavouros) echo "arch" ;;
            *)            echo "unknown"  ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

OS_ID=$(detect_os)
[ "$OS_ID" = "unknown" ] && die "无法识别当前操作系统"
log INFO "系统: ${OS_ID} ($(uname -m))"

# ══════════════════════════════════════════════════════════════════════════════
#  交互式选择
# ══════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "ask" ] && [ "$DRY_RUN" = false ] && [ -e /dev/tty ]; then
    echo ""
    log STEP "── 选择安装模式..."

    echo ""
    echo "  ${C_B}┌─────────────────────────────────────────┐${C_R}"
    echo "  ${C_B}│  基础构建工具安装                        │${C_R}"
    echo "  ${C_B}├─────────────────────────────────────────┤${C_R}"
    echo "  ${C_B}│                                         │${C_R}"
    echo "  ${C_B}│  ${C_CYN}1)${C_R} 完整工具集${C_R}                            │"
    echo "  ${C_B}│     gcc/g++ make cmake autoconf          │${C_R}"
    echo "  ${C_B}│     pkg-config libtool curl git ...      │${C_R}"
    echo "  ${C_B}│                                         │${C_R}"
    echo "  ${C_B}│  ${C_CYN}2)${C_R} 最小化（仅编译工具链）${C_R}               │"
    echo "  ${C_B}│     gcc/g++ make binutils                │${C_R}"
    echo "  ${C_B}│                                         │${C_R}"
    echo "  ${C_B}└─────────────────────────────────────────┘${C_R}"
    echo ""
    printf "  ${C_B}请选择 [1-2] (默认 1) > ${C_R}"
    read -r mode_choice < /dev/tty
    case "$mode_choice" in
        2) MODE="minimal" ; log INFO "已选择: 最小化安装" ;;
        *) MODE="full"    ; log INFO "已选择: 完整工具集" ;;
    esac
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
#  包列表定义
# ══════════════════════════════════════════════════════════════════════════════

# 编译工具链（所有模式都需要）
get_base_pkgs() {
    case "$OS_ID" in
        ubuntu|debian) echo "build-essential binutils" ;;
        fedora|rhel)
            if command -v dnf &>/dev/null; then
                echo "gcc gcc-c++ make binutils glibc-devel kernel-headers"
            else
                echo "gcc gcc-c++ make binutils glibc-devel kernel-headers"
            fi
            ;;
        suse)   echo "gcc gcc-c++ make binutils glibc-devel linux-glibc-devel" ;;
        arch)   echo "base-devel" ;;
    esac
}

# 完整工具集额外的包
get_extra_pkgs() {
    case "$OS_ID" in
        ubuntu|debian)
            echo "cmake autoconf automake pkg-config libtool patch curl wget git ca-certificates xz-utils bzip2 unzip"
            ;;
        fedora|rhel)
            if command -v dnf &>/dev/null; then
                echo "cmake autoconf automake pkgconf libtool patch curl wget git ca-certificates xz bzip2 unzip"
            else
                # RHEL 7 需要 EPEL 才有 cmake
                echo "autoconf automake pkgconfig libtool patch curl wget git ca-certificates xz bzip2 unzip"
            fi
            ;;
        suse)
            echo "cmake autoconf automake pkgconf libtool patch curl wget git ca-certificates xz bzip2 unzip"
            ;;
        arch)
            echo "cmake pkgconf patch curl wget git ca-certificates xz bzip2 unzip"
            ;;
    esac
}

# 获取 EPEL（RHEL 7 需要，为了 cmake）
_ensure_epel() {
    case "$OS_ID" in
        fedora|rhel)
            if command -v dnf &>/dev/null; then
                dry dnf install -y epel-release 2>/dev/null || true
            else
                rpm -q epel-release &>/dev/null || \
                    dry yum install -y epel-release 2>/dev/null || true
            fi
            ;;
    esac
}

# ── 检查已有安装 ─────────────────────────────────────────────────────────────

_check_installed() {
    local missing=0
    for cmd in gcc g++ make; do
        if command -v "$cmd" &>/dev/null; then
            log INFO "  ${cmd}: $(command -v "$cmd")"
        else
            missing=1
        fi
    done
    if [ "$missing" -eq 0 ] && [ "$MODE" = "minimal" ]; then
        log INFO "编译工具链已就绪 ✓"
        echo ""
        if [ "$DRY_RUN" = false ]; then
            gcc --version 2>/dev/null | head -1 | while IFS= read -r l; do log INFO "  ${l}"; done
            make --version 2>/dev/null | head -1 | while IFS= read -r l; do log INFO "  ${l}"; done
        fi
        # 不退出，允许继续安装完整模式
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  安装
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 安装构建工具..."

_install_pkgs() {
    local pkgs="$1"
    case "$OS_ID" in
        ubuntu|debian)
            dry apt-get update -y
            # shellcheck disable=SC2086
            dry apt-get install -y $pkgs
            ;;
        fedora|rhel)
            if command -v dnf &>/dev/null; then
                # shellcheck disable=SC2086
                dry dnf install -y $pkgs
            else
                # shellcheck disable=SC2086
                dry yum install -y $pkgs
            fi
            ;;
        suse)
            dry zypper refresh
            # shellcheck disable=SC2086
            dry zypper install -y $pkgs
            ;;
        arch)
            dry pacman -Sy --noconfirm
            # shellcheck disable=SC2086
            dry pacman -S --noconfirm $pkgs
            ;;
    esac
}

BASE_PKGS=$(get_base_pkgs)
EXTRA_PKGS=$(get_extra_pkgs)

log INFO "编译工具链: ${C_GRN}${BASE_PKGS}${C_R}"

if [ "$MODE" = "full" ]; then
    log INFO "开发辅助:   ${C_CYN}${EXTRA_PKGS}${C_R}"
fi

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过安装"
else
    _ensure_epel
    _install_pkgs "$BASE_PKGS"
    log INFO "编译工具链安装完成 ✓"

    if [ "$MODE" = "full" ]; then
        _install_pkgs "$EXTRA_PKGS"
        log INFO "开发辅助工具安装完成 ✓"
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
    for cmd in gcc g++ make; do
        if command -v "$cmd" &>/dev/null; then
            case "$cmd" in
                gcc)  gcc --version 2>/dev/null  | head -1 | while IFS= read -r l; do log INFO "  gcc:   ${l}"; done ;;
                g++)  g++ --version 2>/dev/null  | head -1 | while IFS= read -r l; do log INFO "  g++:   ${l}"; done ;;
                make) make --version 2>/dev/null | head -1 | while IFS= read -r l; do log INFO "  make:  ${l}"; done ;;
            esac
        else
            log WARN "  ${cmd}: 未找到"
        fi
    done

    if [ "$MODE" = "full" ]; then
        for cmd in cmake autoconf pkg-config git curl; do
            if command -v "$cmd" &>/dev/null; then
                case "$cmd" in
                    cmake)     cmake --version 2>/dev/null     | head -1 | while IFS= read -r l; do log INFO "  cmake:     ${l}"; done ;;
                    autoconf)  autoconf --version 2>/dev/null  | head -1 | while IFS= read -r l; do log INFO "  autoconf:  ${l}"; done ;;
                    pkg-config) pkg-config --version 2>/dev/null          | while IFS= read -r l; do log INFO "  pkg-config: ${l}"; done ;;
                    git)       git --version 2>/dev/null                  | while IFS= read -r l; do log INFO "  git:       ${l}"; done ;;
                    curl)      curl --version 2>/dev/null      | head -1 | while IFS= read -r l; do log INFO "  curl:      ${l}"; done ;;
                esac
            else
                log WARN "  ${cmd}: 未找到"
            fi
        done
    fi
fi

# ── 结果 ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" = true ]; then
    log WARN "预览模式完成。正式安装请运行: sudo bash ${SCRIPT_NAME}"
else
    log STEP "构建工具安装完成！"
    echo ""
    log INFO "快速验证:"
    log INFO "  gcc --version && g++ --version && make --version"
fi
