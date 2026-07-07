#!/usr/bin/env bash
# =============================================================================
# dev-env-init.sh — 开发环境一键配置脚本
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 两种运行模式:
#   【交互模式】默认，方向键选择要安装的工具
#   【批量模式】--config 指定配置文件
#
# 用法:
#   sudo bash dev-env-init.sh                   # 交互向导
#   sudo bash dev-env-init.sh --dry-run         # 预览模式
#   sudo bash dev-env-init.sh --config my.conf  # 配置文件模式
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/var/log/dev-env-init-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
BATCH_MODE=false
CONFIG_FILE=""
STEP_RESULTS=()
OVERALL_SUCCESS=true

# ── 步骤定义 ─────────────────────────────────────────────────────────────────

STEPS=(
    "00|DEV_STEP_00_ENABLED|基础构建工具|build-essential/gcc/make 等编译依赖"
    "01|DEV_STEP_01_ENABLED|Git|版本控制"
    "02|DEV_STEP_02_ENABLED|Python 3|Python + pip + venv 虚拟环境"
    "03|DEV_STEP_03_ENABLED|Node.js|Node.js LTS + npm，通过 NodeSource 源安装"
    "04|DEV_STEP_04_ENABLED|JDK|OpenJDK，可选版本 8/11/17/21"
    "05|DEV_STEP_05_ENABLED|Nginx|高性能 Web 服务器 / 反向代理"
    "06|DEV_STEP_06_ENABLED|MySQL|MySQL Server，安装后自动执行安全初始化"
    "07|DEV_STEP_07_ENABLED|Redis|内存缓存数据库"
    "08|DEV_STEP_08_ENABLED|Docker|容器运行时 (docker-ce)"
)

# ── 默认参数 ─────────────────────────────────────────────────────────────────

JDK_VERSION=17
NODE_VERSION=22
INSTALL_DOCKER_COMPOSE=true

for entry in "${STEPS[@]}"; do
    IFS='|' read -r _ var _ _ <<< "$entry"
    eval "${var}=true"
done

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
        STEP) c="$C_CYN" ;; CHECK) c="$C_BLU" ;; *) c="" ;;
    esac
    printf "%s[%s] [%s] %s%s\n" "$c" "$(date '+%H:%M:%S')" "$lv" "$*" "$C_R" \
        | tee -a "$LOG_FILE" >&2
}

die() { log ERROR "$@"; exit 1; }
dry() { if [ "$DRY_RUN" = true ]; then log WARN "[DRY] $*"; else "$@"; fi; }

step_header() { echo "" | tee -a "$LOG_FILE"; log STEP "── $1: $2"; }
mark_step_ok()   { log INFO "  ✅ $1 完成";         STEP_RESULTS["$1"]="OK"; }
mark_step_fail() { log ERROR "  ❌ $1 失败: $2";    STEP_RESULTS["$1"]="FAILED"; OVERALL_SUCCESS=false; }
skip_step()      { log WARN "  ⏭  $1 已跳过: $2";  STEP_RESULTS["$1"]="SKIPPED"; }

step_enabled() {
    local val; val=$(eval "echo \${${1}:-}")
    case "$val" in true) return 0 ;; *) return 1 ;; esac
}


# ══════════════════════════════════════════════════════════════════════════════
#  系统探测
# ══════════════════════════════════════════════════════════════════════════════

detect_os() {
    OS_FAMILY=""; PKG_MANAGER=""; OS_PRETTY=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_PRETTY="${PRETTY_NAME:-$NAME}"
        case "$ID" in
            ubuntu|debian|raspbian) OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
            centos|rhel|rocky|almalinux|ol|fedora|amzn)
                OS_FAMILY="rhel"
                command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum" ;;
            opensuse*|sles) OS_FAMILY="suse"; PKG_MANAGER="zypper" ;;
            arch|manjaro|endeavouros) OS_FAMILY="arch"; PKG_MANAGER="pacman" ;;
            *) OS_FAMILY="unknown"; PKG_MANAGER="unknown" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_FAMILY="rhel"
        command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
    else
        OS_FAMILY="unknown"; PKG_MANAGER="unknown"
    fi
    [ "$OS_FAMILY" = "unknown" ] && die "无法识别当前操作系统"
}

pkg_update() {
    case "$PKG_MANAGER" in
        apt)    dry apt-get update -y ;;
        dnf)    dry dnf check-update 2>/dev/null || true ;;
        yum)    dry yum check-update 2>/dev/null || true ;;
        zypper) dry zypper refresh ;;
        pacman) dry pacman -Sy --noconfirm ;;
    esac
}

pkg_install() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)    dry DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" ;;
        dnf)    dry dnf install -y "$pkg" ;;
        yum)    dry yum install -y "$pkg" ;;
        zypper) dry zypper install -y "$pkg" ;;
        pacman) dry pacman -S --noconfirm "$pkg" ;;
    esac
}

# 检查命令是否已存在（跳过重复安装）
_has() { command -v "$1" &>/dev/null; }


# ══════════════════════════════════════════════════════════════════════════════
#  交互式菜单（精简版，复用 secure-server-init 的模式）
# ══════════════════════════════════════════════════════════════════════════════

_read_key() {
    local k; IFS= read -r -n 1 k
    if [ "$k" = $'\033' ]; then
        local k2; IFS= read -r -n 1 -t 0.05 k2
        if [ "$k2" = "[" ]; then
            local k3; IFS= read -r -n 1 -t 0.05 k3
            case "$k3" in A) echo "UP" ;; B) echo "DOWN" ;; esac
        fi
    elif [ "$k" = " " ]; then echo "SPACE"
    elif [ "$k" = $'\n' ] || [ "$k" = "" ]; then echo "ENTER"
    elif [ "$k" = "q" ] || [ "$k" = "Q" ]; then echo "QUIT"
    fi
}

_render_menu() {
    local cursor="$1"; shift; local selected=("$@")
    printf '\033[H\033[J'
    echo ""
    echo -e "${C_B}${C_CYN}  ╔══════════════════════════════════════════════════════╗${C_R}"
    echo -e "${C_B}${C_CYN}  ║          开发环境配置 — 选择要安装的工具              ║${C_R}"
    echo -e "${C_B}${C_CYN}  ╚══════════════════════════════════════════════════════╝${C_R}"
    echo ""
    echo -e "  系统: ${C_GRN}${OS_PRETTY}${C_R}    包管理: ${PKG_MANAGER}"
    echo ""
    printf "  %s\n" "  ↑↓ 移动    Space 勾选/取消    Enter 确认    Q 退出"
    echo ""

    local row=0
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id _ label desc <<< "$entry"
        local mark=" "
        for s in "${selected[@]}"; do [ "$s" = "$id" ] && mark="x"; done
        local check=""; [ "$mark" = "x" ] && check="${C_GRN}" || check="${C_BLU}"

        if [ "$row" -eq "$cursor" ]; then
            printf "  ${C_B}${C_CYN}▸ [${mark}] %s${C_R}\n" "$label"
        else
            printf "  ${check}   [${mark}] %s${C_R}\n" "$label"
        fi
        printf "        %s\n" "$desc"
        ((row++))
    done

    echo ""
    printf "  ${C_YEL}已选:${C_R}"
    local sel=()
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id _ label _ <<< "$entry"
        for s in "${selected[@]}"; do [ "$s" = "$id" ] && sel+=("$label"); done
    done
    [ ${#sel[@]} -eq 0 ] && printf " (无)" || printf " %s" "${sel[@]}"
    echo ""
}

menu_select_steps() {
    local selected=()
    for entry in "${STEPS[@]}"; do IFS='|' read -r id _ _ _ <<< "$entry"; selected+=("$id"); done
    local cursor=0 n=${#STEPS[@]}

    local ts; ts=$(stty -g 2>/dev/null)
    stty -echo -icanon min 0 time 0 2>/dev/null
    trap 'stty "$ts" 2>/dev/null; printf "\033[?25h"' EXIT
    printf '\033[?25l'
    _render_menu "$cursor" "${selected[@]}"

    while true; do
        local key; key=$(_read_key)
        case "$key" in
            UP)    [ "$cursor" -gt 0 ] && ((cursor--)); _render_menu "$cursor" "${selected[@]}" ;;
            DOWN)  [ "$cursor" -lt $((n-1)) ] && ((cursor++)); _render_menu "$cursor" "${selected[@]}" ;;
            SPACE)
                local tid=""; local i=0
                for entry in "${STEPS[@]}"; do
                    IFS='|' read -r id _ _ _ <<< "$entry"
                    [ "$i" -eq "$cursor" ] && tid="$id" && break; ((i++))
                done
                local found=false ns=()
                for s in "${selected[@]}"; do [ "$s" = "$tid" ] && found=true || ns+=("$s"); done
                [ "$found" = false ] && ns+=("$tid")
                selected=("${ns[@]}")
                _render_menu "$cursor" "${selected[@]}"
                ;;
            ENTER) break ;;
            QUIT)  selected=(); break ;;
        esac
    done

    trap - EXIT; stty "$ts" 2>/dev/null; printf '\033[?25h'

    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id var _ _ <<< "$entry"
        local en=false
        for s in "${selected[@]}"; do [ "$s" = "$id" ] && en=true; done
        eval "${var}=${en}"
    done
}

menu_configure_params() {
    printf '\033[H\033[J'
    echo ""
    echo -e "${C_B}${C_CYN}  ╔══════════════════════════════════════════════════════╗${C_R}"
    echo -e "${C_B}${C_CYN}  ║             参数配置 — 直接回车使用默认值             ║${C_R}"
    echo -e "${C_B}${C_CYN}  ╚══════════════════════════════════════════════════════╝${C_R}"
    echo ""

    if step_enabled DEV_STEP_04_ENABLED; then
        echo -e "  ${C_B}▸ JDK${C_R}"
        printf "    版本 (8/11/17/21) [${C_GRN}%s${C_R}]: " "$JDK_VERSION"
        read -r input; [ -n "$input" ] && JDK_VERSION="$input"
        echo ""
    fi

    if step_enabled DEV_STEP_03_ENABLED; then
        echo -e "  ${C_B}▸ Node.js${C_R}"
        printf "    主版本 (18/20/22) [${C_GRN}%s${C_R}]: " "$NODE_VERSION"
        read -r input; [ -n "$input" ] && NODE_VERSION="$input"
        echo ""
    fi

    if step_enabled DEV_STEP_08_ENABLED; then
        echo -e "  ${C_B}▸ Docker${C_R}"
        printf "    安装 docker-compose? (y/n) [${C_GRN}%s${C_R}]: " "$([ "$INSTALL_DOCKER_COMPOSE" = true ] && echo y || echo n)"
        read -r input
        case "$input" in n|N|no|NO) INSTALL_DOCKER_COMPOSE=false ;; y|Y|yes|YES) INSTALL_DOCKER_COMPOSE=true ;; esac
        echo ""
    fi
}

menu_confirm() {
    printf '\033[H\033[J'
    echo ""
    echo -e "${C_B}${C_CYN}  ╔══════════════════════════════════════════════════════╗${C_R}"
    echo -e "${C_B}${C_CYN}  ║                  确认安装清单                        ║${C_R}"
    echo -e "${C_B}${C_CYN}  ╚══════════════════════════════════════════════════════╝${C_R}"
    echo ""
    echo -e "  系统: ${C_GRN}${OS_PRETTY}${C_R}"
    echo -e "  模式: ${C_YEL}$([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "正式安装")${C_R}"
    echo ""

    for entry in "${STEPS[@]}"; do
        IFS='|' read -r _ var label _ <<< "$entry"
        if step_enabled "$var"; then
            echo -e "  ${C_GRN}[x]${C_R} ${label}"
        else
            echo -e "  ${C_BLU}[ ]${C_R} ${label}"
        fi
    done

    echo ""
    step_enabled DEV_STEP_04_ENABLED && echo "  JDK_VERSION          = ${JDK_VERSION}"
    step_enabled DEV_STEP_03_ENABLED && echo "  NODE_VERSION         = ${NODE_VERSION}"
    step_enabled DEV_STEP_08_ENABLED && echo "  DOCKER_COMPOSE       = ${INSTALL_DOCKER_COMPOSE}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_YEL}按 Enter 开始预览...${C_R}"; read -r; return 0
    fi

    echo -e "  ${C_RED}即将开始安装！${C_R}"
    printf "  ${C_B}确认执行？(yes/no) [no] > ${C_R}"
    read -r yn
    case "$yn" in yes|YES|y|Y) return 0 ;; *) echo -e "  ${C_YEL}已取消${C_R}"; exit 0 ;; esac
}


# ══════════════════════════════════════════════════════════════════════════════
#  配置文件加载
# ══════════════════════════════════════════════════════════════════════════════

load_config() {
    local conf="$1"
    [ ! -f "$conf" ] && { log WARN "配置文件不存在: ${conf}"; return 1; }
    log INFO "加载配置文件: ${conf}"
    local filtered; filtered=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*="?[^"]*"?$' "$conf" 2>/dev/null)
    [ -n "$filtered" ] && eval "$filtered"
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r _ var _ _ <<< "$entry"
        local val; val=$(eval "echo \${${var}:-}")
        case "$val" in true|false) ;; *) eval "${var}=false" ;; esac
    done
}

resolve_config() {
    if [ -n "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] || die "指定的配置文件不存在: ${CONFIG_FILE}"
        load_config "$CONFIG_FILE"
    elif [ -f "./dev-env-init.conf" ]; then
        load_config "./dev-env-init.conf"
    else
        log INFO "使用内置默认值"
    fi
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤实现
# ══════════════════════════════════════════════════════════════════════════════

step_00_build_tools() {
    local SN="00"; step_header "基础构建工具" "$SN"
    step_enabled DEV_STEP_00_ENABLED || { skip_step "$SN" "未选中"; return; }

    # 已有 gcc 则跳过
    if _has gcc && _has make; then
        log INFO "  构建工具已安装 (gcc $(gcc --version 2>/dev/null | head -1 | awk '{print $NF}'))"
        mark_step_ok "$SN"; return
    fi

    log INFO "  安装 gcc/g++/make 等..."
    case "$PKG_MANAGER" in
        apt)    pkg_install "build-essential curl wget gnupg ca-certificates" ;;
        dnf|yum) pkg_install "gcc gcc-c++ make curl wget gnupg ca-certificates" ;;
        zypper) pkg_install "gcc gcc-c++ make curl wget gnupg ca-certificates" ;;
        pacman) pkg_install "base-devel curl wget gnupg ca-certificates" ;;
    esac || { mark_step_fail "$SN" "安装失败"; return; }
    mark_step_ok "$SN"
}

step_01_git() {
    local SN="01"; step_header "Git" "$SN"
    step_enabled DEV_STEP_01_ENABLED || { skip_step "$SN" "未选中"; return; }
    _has git && { log INFO "  Git 已安装 ($(git --version 2>/dev/null))"; mark_step_ok "$SN"; return; }
    pkg_install git || { mark_step_fail "$SN" "安装失败"; return; }
    git --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    mark_step_ok "$SN"
}

step_02_python() {
    local SN="02"; step_header "Python 3" "$SN"
    step_enabled DEV_STEP_02_ENABLED || { skip_step "$SN" "未选中"; return; }

    if _has python3 && _has pip3; then
        log INFO "  Python 已安装 ($(python3 --version 2>/dev/null), $(pip3 --version 2>/dev/null | awk '{print $1,$2}'))"
        mark_step_ok "$SN"; return
    fi

    case "$PKG_MANAGER" in
        apt)    pkg_install "python3 python3-pip python3-venv" ;;
        dnf|yum) pkg_install "python3 python3-pip python3-virtualenv" ;;
        zypper) pkg_install "python3 python3-pip python3-virtualenv" ;;
        pacman) pkg_install "python python-pip python-virtualenv" ;;
    esac || { mark_step_fail "$SN" "安装失败"; return; }

    python3 --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    pip3 --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    mark_step_ok "$SN"
}

step_03_nodejs() {
    local SN="03"; step_header "Node.js" "$SN"
    step_enabled DEV_STEP_03_ENABLED || { skip_step "$SN" "未选中"; return; }

    # 检查已安装版本
    if _has node; then
        local cur; cur=$(node --version 2>/dev/null)
        if echo "$cur" | grep -q "v${NODE_VERSION}\."; then
            log INFO "  Node.js ${cur} 已安装，跳过"; mark_step_ok "$SN"; return
        fi
        log WARN "  已有 Node.js ${cur}，将覆盖安装 v${NODE_VERSION}.x"
        if [ "$BATCH_MODE" = false ]; then
            printf "  %s" "确认覆盖安装？(y/N) > "
            read -r yn; case "$yn" in [Yy]*) ;; *) skip_step "$SN" "用户取消"; return ;; esac
        fi
    fi

    case "$OS_FAMILY" in
        debian)
            log INFO "  通过 NodeSource 安装 Node.js ${NODE_VERSION}.x..."
            dry curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | dry bash -
            pkg_install nodejs || { mark_step_fail "$SN" "安装失败"; return; }
            ;;
        rhel)
            dry curl -fsSL "https://rpm.nodesource.com/setup_${NODE_VERSION}.x" | dry bash -
            pkg_install nodejs || { mark_step_fail "$SN" "安装失败"; return; }
            ;;
        suse)
            dry zypper addrepo "https://download.opensuse.org/repositories/devel:/languages:/nodejs/openSUSE_Tumbleweed/devel:languages:nodejs.repo" 2>/dev/null
            dry zypper refresh
            pkg_install "nodejs${NODE_VERSION}" || pkg_install nodejs
            ;;
        arch)
            pkg_install nodejs npm || { mark_step_fail "$SN" "安装失败"; return; }
            ;;
    esac

    node --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    npm --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    mark_step_ok "$SN"
}

step_04_jdk() {
    local SN="04"; step_header "JDK" "$SN"
    step_enabled DEV_STEP_04_ENABLED || { skip_step "$SN" "未选中"; return; }

    # 检查已安装版本
    if _has java; then
        local cur; cur=$(java -version 2>&1 | head -1)
        if echo "$cur" | grep -q "version \"${JDK_VERSION}\."; then
            log INFO "  JDK ${JDK_VERSION} 已安装，跳过"; mark_step_ok "$SN"; return
        fi
        log WARN "  已有 $(echo "$cur" | head -1)，将安装 JDK ${JDK_VERSION}"
        if [ "$BATCH_MODE" = false ]; then
            printf "  %s" "确认覆盖安装？(y/N) > "
            read -r yn; case "$yn" in [Yy]*) ;; *) skip_step "$SN" "用户取消"; return ;; esac
        fi
    fi

    case "$PKG_MANAGER" in
        apt)
            pkg_install "openjdk-${JDK_VERSION}-jdk" || \
                { log WARN "  openjdk-${JDK_VERSION}-jdk 不可用，尝试默认版本..."; pkg_install default-jdk; }
            ;;
        dnf|yum)
            pkg_install "java-${JDK_VERSION}-openjdk-devel" || \
                { log WARN "  特定版本不可用，安装默认..."; pkg_install java-latest-openjdk-devel; }
            ;;
        zypper) pkg_install "java-${JDK_VERSION}-openjdk-devel" || pkg_install java-17-openjdk-devel ;;
        pacman) pkg_install "jdk${JDK_VERSION}-openjdk" || pkg_install jdk-openjdk ;;
    esac || { mark_step_fail "$SN" "安装失败"; return; }

    java -version 2>&1 | head -2 | while IFS= read -r l; do log INFO "  ${l}"; done
    javac -version 2>&1 | while IFS= read -r l; do log INFO "  ${l}"; done
    mark_step_ok "$SN"
}

step_05_nginx() {
    local SN="05"; step_header "Nginx" "$SN"
    step_enabled DEV_STEP_05_ENABLED || { skip_step "$SN" "未选中"; return; }

    if _has nginx; then
        log INFO "  Nginx 已安装 ($(nginx -v 2>&1))"
        if command -v systemctl &>/dev/null && ! systemctl is-active nginx &>/dev/null 2>&1; then
            dry systemctl start nginx && log INFO "  nginx 已启动 ✓"
        fi
        mark_step_ok "$SN"; return
    fi

    pkg_install nginx || { mark_step_fail "$SN" "安装失败"; return; }
    nginx -v 2>&1 | while IFS= read -r l; do log INFO "  ${l}"; done

    if command -v systemctl &>/dev/null; then
        dry systemctl enable nginx && dry systemctl start nginx
        systemctl is-active nginx &>/dev/null && log INFO "  nginx 已启动 ✓" || log WARN "  nginx 启动失败，请检查配置"
    fi
    mark_step_ok "$SN"
}

step_06_mysql() {
    local SN="06"; step_header "MySQL" "$SN"
    step_enabled DEV_STEP_06_ENABLED || { skip_step "$SN" "未选中"; return; }

    if _has mysql || _has mariadb; then
        local ver; ver=$(mysql --version 2>/dev/null || mariadb --version 2>/dev/null)
        log INFO "  MySQL/MariaDB 已安装 ($ver)"
        if command -v systemctl &>/dev/null; then
            systemctl is-active mysql &>/dev/null 2>&1 && log INFO "  服务运行中 ✓" || \
                systemctl is-active mariadb &>/dev/null 2>&1 && log INFO "  服务运行中 ✓" || \
                { log WARN "  服务未运行，尝试启动..."; dry systemctl start mysql 2>/dev/null || dry systemctl start mariadb 2>/dev/null; }
        fi
        mark_step_ok "$SN"; return
    fi

    case "$PKG_MANAGER" in
        apt)    pkg_install "mysql-server" ;;
        dnf|yum) pkg_install "mysql-server" ;;
        zypper) pkg_install "mariadb" ;;
        pacman) pkg_install "mariadb" ;;
    esac || { mark_step_fail "$SN" "安装失败"; return; }

    # 启动
    if command -v systemctl &>/dev/null; then
        dry systemctl enable mysql 2>/dev/null || dry systemctl enable mariadb 2>/dev/null
        dry systemctl start mysql 2>/dev/null || dry systemctl start mariadb 2>/dev/null
    fi

    # 安全初始化（仅首次，通过标记文件判断）
    local SECURED_MARKER="/etc/mysql/.dev-env-init-secured"
    if [ "$DRY_RUN" = false ] && [ ! -f "$SECURED_MARKER" ]; then
        if _has mysql_secure_installation; then
            log INFO "  执行 MySQL 安全初始化（首次）..."
            # 使用 expect 式输入，兼容 MySQL 8.0+ VALIDATE PASSWORD 组件
            # 回答: 不使用 VALIDATE, 不设 root 密码(n), 移除匿名用户(y), 禁止远程 root(y), 移除 test 库(y), 重载权限(y)
            mysql --user=root 2>/dev/null <<'EOSQL' || true
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
            dry touch "$SECURED_MARKER"
            log INFO "  MySQL 安全初始化完成 ✓"
        elif _has mariadb-secure-installation; then
            log INFO "  执行 MariaDB 安全初始化（首次）..."
            mysql --user=root 2>/dev/null <<'EOSQL' || true
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
            dry touch "$SECURED_MARKER"
            log INFO "  MariaDB 安全初始化完成 ✓"
        fi
    elif [ "$DRY_RUN" = false ]; then
        log INFO "  MySQL 已初始化过，跳过安全配置"
    fi

    mysql --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    mark_step_ok "$SN"
}

step_07_redis() {
    local SN="07"; step_header "Redis" "$SN"
    step_enabled DEV_STEP_07_ENABLED || { skip_step "$SN" "未选中"; return; }

    if _has redis-cli; then
        log INFO "  Redis 已安装 ($(redis-cli --version 2>/dev/null))"
        if command -v systemctl &>/dev/null; then
            systemctl is-active redis-server &>/dev/null 2>&1 && log INFO "  服务运行中 ✓" || \
            systemctl is-active redis &>/dev/null 2>&1 && log INFO "  服务运行中 ✓" || \
            { log WARN "  服务未运行，尝试启动..."; dry systemctl start redis-server 2>/dev/null || dry systemctl start redis 2>/dev/null; }
        fi
        redis-cli ping 2>/dev/null | grep -q PONG && log INFO "  Redis PING → PONG ✓" || log WARN "  Redis 未响应"
        mark_step_ok "$SN"; return
    fi

    pkg_install redis-server || pkg_install redis || { mark_step_fail "$SN" "安装失败"; return; }

    if command -v systemctl &>/dev/null; then
        dry systemctl enable redis-server 2>/dev/null || dry systemctl enable redis 2>/dev/null
        dry systemctl start redis-server 2>/dev/null || dry systemctl start redis 2>/dev/null
        log INFO "  Redis 已启动 ✓"
    fi

    redis-cli --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
    redis-cli ping 2>/dev/null | grep -q PONG && log INFO "  Redis PING → PONG ✓" || log WARN "  Redis 未响应 PING"
    mark_step_ok "$SN"
}

step_08_docker() {
    local SN="08"; step_header "Docker" "$SN"
    step_enabled DEV_STEP_08_ENABLED || { skip_step "$SN" "未选中"; return; }

    if _has docker; then
        log INFO "  Docker 已安装 ($(docker --version 2>/dev/null))"
    else
        log INFO "  安装 Docker..."
        case "$OS_FAMILY" in
            debian)
                dry curl -fsSL https://get.docker.com | dry bash
                ;;
            rhel)
                pkg_install "docker-ce docker-ce-cli containerd.io" 2>/dev/null || \
                    dry curl -fsSL https://get.docker.com | dry bash
                ;;
            arch)
                pkg_install docker
                ;;
            *)
                dry curl -fsSL https://get.docker.com | dry bash
                ;;
        esac || { mark_step_fail "$SN" "Docker 安装失败"; return; }
    fi

    if command -v systemctl &>/dev/null; then
        dry systemctl enable docker && dry systemctl start docker
    fi

    docker --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done

    if [ "$INSTALL_DOCKER_COMPOSE" = true ]; then
        if _has docker-compose; then
            log INFO "  docker-compose 已安装 ($(docker-compose --version 2>/dev/null))"
        elif docker compose version &>/dev/null 2>&1; then
            log INFO "  docker compose (plugin) 已可用"
        elif [ -f /usr/local/bin/docker-compose ]; then
            log INFO "  docker-compose 二进制已存在"
        else
            log INFO "  安装 docker-compose..."
            dry curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            dry chmod +x /usr/local/bin/docker-compose
        fi
    fi
    mark_step_ok "$SN"
}


# ══════════════════════════════════════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════════════════════════════════════

print_summary() {
    echo ""
    log STEP "════════════════════════════════════════════════════"
    log STEP "  安装摘要"
    log STEP "════════════════════════════════════════════════════"

    local labels=("基础构建工具" "Git" "Python 3" "Node.js" "JDK" "Nginx" "MySQL" "Redis" "Docker")
    local ids=("00" "01" "02" "03" "04" "05" "06" "07" "08")
    local all_ok=true

    for i in "${!ids[@]}"; do
        local st="${STEP_RESULTS[${ids[$i]}]:-NOT_RUN}"
        case "$st" in
            OK)      log INFO "  ✅ ${labels[$i]}: 成功"   ;;
            SKIPPED) log WARN "  ⏭  ${labels[$i]}: 已跳过" ;;
            FAILED)  log ERROR "  ❌ ${labels[$i]}: 失败"   ; all_ok=false ;;
            NOT_RUN) all_ok=false ;;
        esac
    done

    echo ""
    log INFO "日志文件: ${LOG_FILE}"
    [ "$all_ok" = true ] && [ "$OVERALL_SUCCESS" = true ] \
        && log STEP "  开发环境配置完成！" \
        || log WARN "  ⚠ 部分安装未完成，请检查日志"
}

print_banner() {
    echo ""
    log STEP "╔════════════════════════════════════════════════════╗"
    log STEP "║     开发环境配置脚本                                ║"
    log STEP "║     Ubuntu/Debian/CentOS/Rocky/Fedora/Arch/SUSE    ║"
    log STEP "╚════════════════════════════════════════════════════╝"
}

generate_config() {
    cat <<'CONFEOF'
# dev-env-init.conf — 开发环境配置
DEV_STEP_00_ENABLED=true   # 基础构建工具
DEV_STEP_01_ENABLED=true   # Git
DEV_STEP_02_ENABLED=true   # Python 3
DEV_STEP_03_ENABLED=true   # Node.js
DEV_STEP_04_ENABLED=true   # JDK
DEV_STEP_05_ENABLED=true   # Nginx
DEV_STEP_06_ENABLED=true   # MySQL
DEV_STEP_07_ENABLED=true   # Redis
DEV_STEP_08_ENABLED=true   # Docker

JDK_VERSION=17
NODE_VERSION=22
INSTALL_DOCKER_COMPOSE=true
CONFEOF
    exit 0
}

# ── 参数解析 ──

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --config)         BATCH_MODE=true; CONFIG_FILE="$2"; shift 2 ;;
        --generate-config) generate_config ;;
        -h|--help)
            cat <<EOF
用法: sudo bash $SCRIPT_NAME [选项]

无参数        交互式菜单向导
--dry-run    预览模式
--config F   配置文件批量模式
--generate-config  生成示例配置
-h           帮助
EOF
            exit 0 ;;
        *) log ERROR "未知选项: $1"; exit 1 ;;
    esac
done

[ "$EUID" -ne 0 ] && die "请以 root 权限运行: sudo bash $SCRIPT_NAME"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
log INFO "日志文件: ${LOG_FILE}"

print_banner
detect_os

if [ "$BATCH_MODE" = true ]; then
    resolve_config
    echo ""
    log INFO "批量模式 — 当前配置:"
    log INFO "  JDK_VERSION=${JDK_VERSION}  NODE_VERSION=${NODE_VERSION}"
else
    menu_select_steps
    local any_enabled=false
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r _ var _ _ <<< "$entry"
        step_enabled "$var" && any_enabled=true
    done
    [ "$any_enabled" = false ] && { echo ""; log WARN "未选择任何工具，已退出。"; exit 0; }
    menu_configure_params
    menu_confirm
fi

echo ""
log STEP "开始安装..."

step_00_build_tools
step_01_git
step_02_python
step_03_nodejs
step_04_jdk
step_05_nginx
step_06_mysql
step_07_redis
step_08_docker

print_summary
[ "$OVERALL_SUCCESS" = false ] && exit 1
