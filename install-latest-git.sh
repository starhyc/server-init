#!/usr/bin/env bash
# =============================================================================
# install-latest-git.sh — 交互式安装最新版 Git
#
# 从 github.com/git/git 获取最新稳定版源码，编译安装到 /usr/local，
# 支持交互式配置 Git 用户信息、默认分支等。
# 适用于所有主流 Linux 发行版。
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 用法:
#   sudo bash install-latest-git.sh             # 交互式安装
#   curl -fsSL <url> | sudo bash                # 管道运行（自动读取 /dev/tty）
#   sudo bash install-latest-git.sh --batch     # 非交互模式
#   sudo bash install-latest-git.sh --dry-run   # 预览模式
#   sudo bash install-latest-git.sh --force     # 强制覆盖安装
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
FORCE=false
BATCH_MODE=false
GIT_USER_NAME=""
GIT_USER_EMAIL=""
GIT_DEFAULT_BRANCH=""
GIT_EDITOR=""
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
        --name)    GIT_USER_NAME="$2"; shift 2 ;;
        --email)   GIT_USER_EMAIL="$2"; shift 2 ;;
        --editor)  GIT_EDITOR="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
用法: sudo bash install-latest-git.sh [选项]

无参数       交互式安装最新 Git（编译源码）+ 交互配置用户信息
--batch      非交互模式，跳过所有提示，仅安装 Git
--dry-run    预览模式，仅显示操作不执行
--force      强制覆盖安装，不检查已有版本
--name NAME  设置 git 全局用户名
--email EMAIL 设置 git 全局邮箱
--editor CMD 设置 git 默认编辑器（如 vim、nano）
-h, --help   显示此帮助

安装方式: 从 github.com/git/git 下载源码编译安装到 /usr/local
交互配置: 用户名、邮箱、默认分支名、编辑器
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

# ── 检查依赖 ─────────────────────────────────────────────────────────────────

for cmd in curl tar make; do
    command -v "$cmd" &>/dev/null || die "缺少必要命令: ${cmd}，请先安装"
done

# ── 检测包管理器并安装编译依赖 ──────────────────────────────────────────────

_detect_pkg_manager() {
    case "$OS_ID" in
        ubuntu|debian) echo "apt" ;;
        fedora|rhel)   command -v dnf &>/dev/null && echo "dnf" || echo "yum" ;;
        suse)          echo "zypper" ;;
        arch)          echo "pacman" ;;
    esac
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

_install_all_pkgs() {
    case "$PKG_MGR" in
        apt)
            dry apt-get update -y
            dry apt-get install -y \
                build-essential libssl-dev libcurl4-openssl-dev \
                libexpat1-dev zlib1g-dev gettext
            ;;
        dnf|yum)
            dry "$PKG_MGR" install -y \
                gcc make curl-devel expat-devel gettext-devel \
                openssl-devel zlib-devel perl-ExtUtils-MakeMaker
            ;;
        zypper)
            dry zypper install -y \
                gcc make libcurl-devel libexpat-devel gettext-tools \
                libopenssl-devel zlib-devel
            ;;
        pacman)
            dry pacman -S --noconfirm \
                base-devel openssl curl expat
            ;;
    esac
}

# ── 获取最新版本号 ───────────────────────────────────────────────────────────

log STEP "── 获取最新 Git 版本..."

# Git 使用普通版本标签 v2.x.x，过滤掉 -rc 等预发布
LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/git/git/tags?per_page=30" 2>/dev/null \
    | grep -oP '"name":\s*"v\K[0-9]+\.[0-9]+\.[0-9]+"' \
    | tr -d '"' \
    | grep -v '\-rc' \
    | head -1)

# 回退：直接解析 git 源码页面
if [ -z "$LATEST_VERSION" ]; then
    LATEST_VERSION=$(curl -fsSL "https://mirrors.edge.kernel.org/pub/software/scm/git/" 2>/dev/null \
        | grep -oP 'git-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' \
        | sort -V | tail -1)
fi

[ -z "$LATEST_VERSION" ] && die "无法获取最新版本号，请检查网络连接"

log INFO "最新稳定版: ${C_GRN}v${LATEST_VERSION}${C_R}"

# ── 检查已有版本 ─────────────────────────────────────────────────────────────

if [ "$FORCE" != true ] && command -v git &>/dev/null; then
    CURRENT_VERSION=$(git --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        log INFO "Git v${CURRENT_VERSION} 已是最新版本，无需安装"
        git --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
        exit 0
    fi
    log WARN "当前版本: v${CURRENT_VERSION} → 将升级到 v${LATEST_VERSION}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  交互式配置
# ══════════════════════════════════════════════════════════════════════════════

if [ "$BATCH_MODE" = false ] && [ "$DRY_RUN" = false ] && [ -e /dev/tty ]; then
    echo ""
    log STEP "── Git 全局配置..."

    # ── 用户名 ──
    if [ -z "$GIT_USER_NAME" ]; then
        printf "  ${C_B}Git 全局用户名${C_R} (用于 commit 签名)\n"
        printf "  ${C_B}> ${C_R}"
        read -r user_name < /dev/tty
        [ -n "$user_name" ] && GIT_USER_NAME="$user_name"
    fi

    # ── 邮箱 ──
    if [ -z "$GIT_USER_EMAIL" ]; then
        printf "  ${C_B}Git 全局邮箱${C_R}\n"
        printf "  ${C_B}> ${C_R}"
        read -r user_email < /dev/tty
        [ -n "$user_email" ] && GIT_USER_EMAIL="$user_email"
    fi

    # ── 默认分支名 ──
    if [ -z "$GIT_DEFAULT_BRANCH" ]; then
        printf "  ${C_B}默认分支名？${C_R}\n"
        printf "  ${C_CYN}1)${C_R} main (推荐)\n"
        printf "  ${C_CYN}2)${C_R} master\n"
        printf "  ${C_CYN}3)${C_R} 自定义\n"
        printf "  ${C_B}请选择 [1-3] (默认 1) > ${C_R}"
        read -r branch_choice < /dev/tty
        case "$branch_choice" in
            2) GIT_DEFAULT_BRANCH="master" ;;
            3)
                printf "  ${C_B}请输入默认分支名 > ${C_R}"
                read -r custom_branch < /dev/tty
                [ -n "$custom_branch" ] && GIT_DEFAULT_BRANCH="$custom_branch"
                ;;
            *) GIT_DEFAULT_BRANCH="main" ;;
        esac
    fi

    # ── 编辑器 ──
    if [ -z "$GIT_EDITOR" ]; then
        printf "  ${C_B}Git 默认编辑器？${C_R}\n"
        # 检测系统可用编辑器
        for e in vim nano vi; do
            if command -v "$e" &>/dev/null; then
                DETECTED_EDITOR="$e"
                break
            fi
        done
        [ -z "$DETECTED_EDITOR" ] && DETECTED_EDITOR="vim"

        printf "  ${C_CYN}1)${C_R} ${DETECTED_EDITOR} (检测到)\n"
        printf "  ${C_CYN}2)${C_R} nano\n"
        printf "  ${C_CYN}3)${C_R} 自定义\n"
        printf "  ${C_B}请选择 [1-3] (默认 1) > ${C_R}"
        read -r editor_choice < /dev/tty
        case "$editor_choice" in
            2) GIT_EDITOR="nano" ;;
            3)
                printf "  ${C_B}请输入编辑器命令 > ${C_R}"
                read -r custom_editor < /dev/tty
                [ -n "$custom_editor" ] && GIT_EDITOR="$custom_editor"
                ;;
            *) GIT_EDITOR="$DETECTED_EDITOR" ;;
        esac
    fi

    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
#  安装编译依赖
# ══════════════════════════════════════════════════════════════════════════════

PKG_MGR=$(_detect_pkg_manager)
log INFO "包管理器: ${PKG_MGR}"

log STEP "── 安装编译依赖..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过依赖安装"
else
    _install_all_pkgs
    log INFO "编译依赖安装完成 ✓"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  下载源码
# ══════════════════════════════════════════════════════════════════════════════

GIT_TARBALL="git-${LATEST_VERSION}.tar.xz"
GIT_URL="https://mirrors.edge.kernel.org/pub/software/scm/git/${GIT_TARBALL}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log STEP "── 下载 ${GIT_TARBALL}..."
log INFO "${GIT_URL}"

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过下载"
else
    curl -fsSL --progress-bar "$GIT_URL" -o "${TMP_DIR}/${GIT_TARBALL}" || \
        die "下载失败，请检查网络连接"
    log INFO "下载完成 ✓"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  编译安装
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 编译安装 Git v${LATEST_VERSION}..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过编译安装"
else
    cd "${TMP_DIR}"
    dry tar -xJf "${GIT_TARBALL}"
    cd "git-${LATEST_VERSION}"

    log INFO "正在配置 (make configure)..."
    make configure &>/dev/null || die "make configure 失败"
    log INFO "configure..."

    ./configure --prefix=/usr/local 2>&1 | while IFS= read -r l; do
        log INFO "  ${l}"
    done || die "./configure 失败"

    log INFO "正在编译 (make -j\$(nproc))... 可能需要几分钟"

    # 使用 CPU 核心数并行编译
    CPU_COUNT=$(nproc 2>/dev/null || echo 1)
    make -j"$CPU_COUNT" 2>&1 | while IFS= read -r l; do
        # 仅打印关键输出，减少日志量
        case "$l" in
            *error*|*Error*) log ERROR "  ${l}" ;;
            *warning*|*Warning*) log WARN "  ${l}" ;;
            *) : ;;
        esac
    done
    [ "${PIPESTATUS[0]}" -ne 0 ] && die "make 编译失败"

    log INFO "正在安装 (make install)..."
    dry make install 2>&1 | while IFS= read -r l; do
        case "$l" in
            *install*) log INFO "  ${l}" ;;
        esac
    done || die "make install 失败"

    log INFO "编译安装完成 ✓"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  配置 Git 全局设置
# ══════════════════════════════════════════════════════════════════════════════

if [ "$DRY_RUN" = false ]; then
    if ! echo "$PATH" | grep -q '/usr/local/bin'; then
        export PATH="/usr/local/bin:$PATH"
    fi

    CONFIGURED=false

    if [ -n "$GIT_USER_NAME" ]; then
        log STEP "── 配置 Git 全局用户名..."
        su -c "git config --global user.name '${GIT_USER_NAME}'" "${SUDO_USER:-root}" 2>/dev/null || \
            git config --global user.name "$GIT_USER_NAME"
        log INFO "  user.name = ${C_GRN}${GIT_USER_NAME}${C_R}"
        CONFIGURED=true
    fi

    if [ -n "$GIT_USER_EMAIL" ]; then
        log STEP "── 配置 Git 全局邮箱..."
        su -c "git config --global user.email '${GIT_USER_EMAIL}'" "${SUDO_USER:-root}" 2>/dev/null || \
            git config --global user.email "$GIT_USER_EMAIL"
        log INFO "  user.email = ${C_GRN}${GIT_USER_EMAIL}${C_R}"
        CONFIGURED=true
    fi

    if [ -n "$GIT_DEFAULT_BRANCH" ]; then
        log STEP "── 配置 Git 默认分支名..."
        su -c "git config --global init.defaultBranch '${GIT_DEFAULT_BRANCH}'" "${SUDO_USER:-root}" 2>/dev/null || \
            git config --global init.defaultBranch "$GIT_DEFAULT_BRANCH"
        log INFO "  init.defaultBranch = ${C_GRN}${GIT_DEFAULT_BRANCH}${C_R}"
    fi

    if [ -n "$GIT_EDITOR" ]; then
        log STEP "── 配置 Git 默认编辑器..."
        su -c "git config --global core.editor '${GIT_EDITOR}'" "${SUDO_USER:-root}" 2>/dev/null || \
            git config --global core.editor "$GIT_EDITOR"
        log INFO "  core.editor = ${C_GRN}${GIT_EDITOR}${C_R}"
    fi

    # ── 有用的全局配置 ──
    log STEP "── 应用推荐配置..."

    # 避免 Windows 换行符问题
    git config --global core.autocrlf input 2>/dev/null || true
    # 长路径支持
    git config --global core.longpaths true 2>/dev/null || true
    # 彩色输出
    git config --global color.ui auto 2>/dev/null || true
    # 合并策略
    git config --global pull.ff only 2>/dev/null || true

    log INFO "推荐配置已应用 ✓"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  验证
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 验证安装..."

if [ "$DRY_RUN" = true ]; then
    log WARN "[DRY] 跳过验证"
else
    echo ""
    if command -v git &>/dev/null; then
        git --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    else
        die "git 命令不可用，安装可能失败"
    fi

    # 验证编译的 Git 路径
    GIT_PATH=$(command -v git)
    log INFO "  Git 路径: ${GIT_PATH}"
fi

# ── 结果 ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" = true ]; then
    log WARN "预览模式完成。正式安装请运行: sudo bash ${SCRIPT_NAME}"
else
    log STEP "Git v${LATEST_VERSION} 安装完成！"
    echo ""
    log INFO "快速开始:"
    log INFO "  git --version         # 查看版本"
    log INFO "  git config --list     # 查看当前配置"
    echo ""
    if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
        log INFO "已配置用户信息: ${C_GRN}${GIT_USER_NAME} <${GIT_USER_EMAIL}>${C_R}"
    else
        log WARN "未配置用户信息，请手动设置:"
        log WARN "  git config --global user.name  \"Your Name\""
        log WARN "  git config --global user.email \"your@email.com\""
    fi
fi
