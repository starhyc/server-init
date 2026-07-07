#!/usr/bin/env bash
# =============================================================================
# secure-server-init.sh — 通用 Linux 服务器安全初始化脚本
#
# 核心 5 项：
#   1. 创建管理员用户 + sudo
#   2. SSH 加固（禁用 root/密码，仅密钥认证）
#   3. fail2ban 防暴力破解
#   4. 防火墙最小化开放端口
#   5. 自动安全更新
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 两种运行模式:
#   【交互模式】默认，无参数运行时进入菜单向导，逐步选择并配置
#   【配置模式】--config 指定配置文件，适合批量/无人值守部署
#
# 用法:
#   sudo bash secure-server-init.sh                   # 交互向导
#   sudo bash secure-server-init.sh --dry-run         # 预览模式
#   sudo bash secure-server-init.sh --config my.conf  # 配置文件模式
#   sudo bash secure-server-init.sh --generate-config # 生成示例配置
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/var/log/secure-server-init-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
BATCH_MODE=false
CONFIG_FILE=""
STEP_RESULTS=()
OVERALL_SUCCESS=true

# ── 步骤定义（顺序不可变，与菜单/执行顺序一致） ──────────────────────────────

# 格式: "step_id|var_name|label|desc"
STEPS=(
    "00|SECURE_STEP_00_ENABLED|系统软件包更新|更新所有已安装的软件包到最新版本"
    "01|SECURE_STEP_01_ENABLED|管理员用户 + sudo|创建非 root 管理员用户，配置 sudo 权限"
    "02|SECURE_STEP_02_ENABLED|SSH 加固|禁用 root/密码登录，仅允许密钥认证"
    "03|SECURE_STEP_03_ENABLED|fail2ban 防暴力破解|安装 fail2ban，SSH 试错 3 次自动封禁"
    "04|SECURE_STEP_04_ENABLED|防火墙|仅开放必要端口（SSH/HTTP/HTTPS），默认拒绝入站"
    "05|SECURE_STEP_05_ENABLED|自动安全更新|配置无人值守安全更新，漏洞修复自动完成"
)

# ── 默认参数 ──────────────────────────────────────────────────────────────────

ADMIN_USER="deploy"
SSH_PORT=22
SSH_ALLOW_USERS=""
FAIL2BAN_BANTIME=3600
FAIL2BAN_FINDTIME=600
FAIL2BAN_MAXRETRY=3
UFW_PORTS="22/tcp 80/tcp 443/tcp"

for entry in "${STEPS[@]}"; do
    IFS='|' read -r _ var _ _ <<< "$entry"
    eval "${var}=true"
done

# ── 颜色 ──────────────────────────────────────────────────────────────────────

if [ -t 1 ] && command -v tput &>/dev/null; then
    C_R="$(tput sgr0)"     C_B="$(tput bold)"
    C_RED="$(tput setaf 1)" C_GRN="$(tput setaf 2)"
    C_YEL="$(tput setaf 3)" C_BLU="$(tput setaf 4)"
    C_CYN="$(tput setaf 6)" C_WHT="$(tput setaf 7)"
else
    C_R=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_WHT=""
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

step_header() { echo "" | tee -a "$LOG_FILE"; log STEP "── 步骤 $1: $2"; }

mark_step_ok()   { local n="$1"; log INFO "  ✅ 步骤 ${n} 完成";         STEP_RESULTS["${n}"]="OK"; }
mark_step_fail() { local n="$1" m="$2"; log ERROR "  ❌ 步骤 ${n} 失败: ${m}"; STEP_RESULTS["${n}"]="FAILED"; OVERALL_SUCCESS=false; }
skip_step()      { local n="$1" r="$2"; log WARN "  ⏭  步骤 ${n} 已跳过: ${r}"; STEP_RESULTS["${n}"]="SKIPPED"; }

step_enabled() {
    local val; val=$(eval "echo \${${1}:-}")
    case "$val" in true) return 0 ;; *) return 1 ;; esac
}


# ══════════════════════════════════════════════════════════════════════════════
#  系统探测
# ══════════════════════════════════════════════════════════════════════════════

detect_os() {
    OS_FAMILY=""; PKG_MANAGER=""; FIREWALL_TOOL=""; OS_PRETTY=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_PRETTY="${PRETTY_NAME:-$NAME}"
        case "$ID" in
            ubuntu|debian|raspbian) OS_FAMILY="debian"; PKG_MANAGER="apt"; FIREWALL_TOOL="ufw" ;;
            centos|rhel|rocky|almalinux|ol|fedora|amzn)
                OS_FAMILY="rhel"; FIREWALL_TOOL="firewalld"
                command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum" ;;
            opensuse*|sles) OS_FAMILY="suse"; PKG_MANAGER="zypper"; FIREWALL_TOOL="firewalld" ;;
            arch|manjaro|endeavouros) OS_FAMILY="arch"; PKG_MANAGER="pacman"; FIREWALL_TOOL="iptables" ;;
            *) OS_FAMILY="unknown"; PKG_MANAGER="unknown"; FIREWALL_TOOL="unknown" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_FAMILY="rhel"; FIREWALL_TOOL="firewalld"; OS_PRETTY="$(cat /etc/redhat-release)"
        command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
    else
        OS_FAMILY="unknown"; PKG_MANAGER="unknown"; FIREWALL_TOOL="unknown"
    fi
    [ "$OS_FAMILY" = "unknown" ] && die "无法识别当前操作系统"
}

pkg_install() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)    dry apt-get install -y "$pkg" ;;  dnf) dry dnf install -y "$pkg" ;;
        yum)    dry yum install -y "$pkg" ;;      zypper) dry zypper install -y "$pkg" ;;
        pacman) dry pacman -S --noconfirm "$pkg" ;;
    esac
}

pkg_update() {
    case "$PKG_MANAGER" in
        apt)    dry apt-get update -y && dry apt-get upgrade -y ;;
        dnf)    dry dnf upgrade -y ;;   yum) dry yum update -y ;;
        zypper) dry zypper refresh && dry zypper update -y ;;
        pacman) dry pacman -Syu --noconfirm ;;
    esac
}


# ══════════════════════════════════════════════════════════════════════════════
#  交 互 式 菜 单 引 擎
# ══════════════════════════════════════════════════════════════════════════════

# ── 单键读取（支持方向键） ──────────────────────────────────────────────────

# 在 stty raw 下读取一个逻辑按键，返回:
#   UP / DOWN / SPACE / ENTER / q
_read_key() {
    local k
    IFS= read -r -n 1 k
    if [ "$k" = $'\033' ]; then
        # 方向键转义序列: \033[A (up), \033[B (down)
        local k2; IFS= read -r -n 1 -t 0.05 k2
        if [ "$k2" = "[" ]; then
            local k3; IFS= read -r -n 1 -t 0.05 k3
            case "$k3" in
                A) echo "UP"    ;;
                B) echo "DOWN"  ;;
            esac
        fi
    elif [ "$k" = " " ]; then
        echo "SPACE"
    elif [ "$k" = $'\n' ] || [ "$k" = "" ]; then
        echo "ENTER"
    elif [ "$k" = "q" ] || [ "$k" = "Q" ]; then
        echo "QUIT"
    fi
}

# 在 raw 模式下渲染菜单；cursor 是当前高亮行号 (0-based)
_render_menu() {
    local cursor="$1"; shift
    local selected=("$@")
    local n=${#STEPS[@]}

    printf '\033[H\033[J'  # 清屏
    echo ""
    echo -e "${C_B}${C_CYN}  ╔══════════════════════════════════════════════════════╗${C_R}"
    echo -e "${C_B}${C_CYN}  ║      服务器安全初始化 — 选择要执行的安全措施        ║${C_R}"
    echo -e "${C_B}${C_CYN}  ╚══════════════════════════════════════════════════════╝${C_R}"
    echo ""
    echo -e "  系统: ${C_GRN}${OS_PRETTY}${C_R}"
    echo -e "  包管理: ${PKG_MANAGER}    防火墙工具: ${FIREWALL_TOOL}"
    echo ""
    printf "  %s\n" "  ↑↓ 移动    Space 勾选/取消    Enter 确认    Q 退出"
    echo ""

    local row=0
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id _ label desc <<< "$entry"

        local mark=" "; for s in "${selected[@]}"; do [ "$s" = "$id" ] && mark="x"; done
        local check=""; [ "$mark" = "x" ] && check="${C_GRN}" || check="${C_BLU}"
        local hl=""; [ "$row" -eq "$cursor" ] && hl="${C_B}${C_CYN}"

        if [ "$row" -eq "$cursor" ]; then
            printf "  ${hl}▸ [${mark}] %s${C_R}\n" "$label"
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

# 使用方向键 + 空格选择步骤
menu_select_steps() {
    local selected=()
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id _ _ _ <<< "$entry"
        selected+=("$id")
    done
    local cursor=0
    local n=${#STEPS[@]}

    # 进入 raw 模式
    local tty_settings; tty_settings=$(stty -g 2>/dev/null)
    stty -echo -icanon min 0 time 0 2>/dev/null

    # 确保退出时恢复终端
    trap 'stty "$tty_settings" 2>/dev/null; printf "\033[?25h"' EXIT

    printf '\033[?25l'  # 隐藏光标
    _render_menu "$cursor" "${selected[@]}"

    while true; do
        local key; key=$(_read_key)
        case "$key" in
            UP)
                [ "$cursor" -gt 0 ] && ((cursor--))
                _render_menu "$cursor" "${selected[@]}"
                ;;
            DOWN)
                [ "$cursor" -lt $((n - 1)) ] && ((cursor++))
                _render_menu "$cursor" "${selected[@]}"
                ;;
            SPACE)
                local target_id=""; local i=0
                for entry in "${STEPS[@]}"; do
                    IFS='|' read -r id _ _ _ <<< "$entry"
                    [ "$i" -eq "$cursor" ] && target_id="$id" && break
                    ((i++))
                done
                local found=false
                local new_sel=()
                for s in "${selected[@]}"; do
                    [ "$s" = "$target_id" ] && found=true || new_sel+=("$s")
                done
                [ "$found" = false ] && new_sel+=("$target_id")
                selected=("${new_sel[@]}")
                _render_menu "$cursor" "${selected[@]}"
                ;;
            ENTER)
                break
                ;;
            QUIT)
                selected=()
                break
                ;;
        esac
    done

    trap - EXIT
    stty "$tty_settings" 2>/dev/null
    printf '\033[?25h'  # 恢复光标

    # 写入变量
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id var _ _ <<< "$entry"
        local enabled=false
        for s in "${selected[@]}"; do [ "$s" = "$id" ] && enabled=true; done
        eval "${var}=${enabled}"
    done
    STEP_IDS="${selected[*]}"
}

# 交互式参数配置（针对已选中的步骤）
menu_configure_params() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "${C_B}${C_CYN}  ╔══════════════════════════════════════════════════════╗${C_R}"
    echo -e "${C_B}${C_CYN}  ║             参数配置 — 直接回车使用默认值             ║${C_R}"
    echo -e "${C_B}${C_CYN}  ╚══════════════════════════════════════════════════════╝${C_R}"
    echo ""

    # ── 步骤 01: 管理员用户 ──
    if step_enabled SECURE_STEP_01_ENABLED; then
        echo -e "  ${C_B}▸ 管理员用户 + sudo${C_R}"
        printf "    用户名 [${C_GRN}%s${C_R}]: " "$ADMIN_USER"
        read -r input; [ -n "$input" ] && ADMIN_USER="$input"

        if id "$ADMIN_USER" &>/dev/null 2>/dev/null; then
            echo -e "    ${C_YEL}注意: 用户 '${ADMIN_USER}' 已存在，将跳过创建，仅确保 sudo 权限${C_R}"
        fi
        echo ""
    fi

    # ── 步骤 02: SSH 加固 ──
    if step_enabled SECURE_STEP_02_ENABLED; then
        echo -e "  ${C_B}▸ SSH 加固${C_R}"

        # 显示当前状态
        local cur_lvl; cur_lvl=$(_ssh_current_level)
        case "$cur_lvl" in
            full)  echo -e "    ${C_GRN}当前状态: 完全加固（密码登录已禁用）${C_R}" ;;
            basic) echo -e "    ${C_YEL}当前状态: 基础加固（密码登录保留）。上传公钥后重新运行可升级。${C_R}" ;;
            *)     echo -e "    ${C_BLU}当前状态: 未加固${C_R}" ;;
        esac

        printf "    SSH 端口 [${C_GRN}%s${C_R}]: " "$SSH_PORT"
        read -r input; [ -n "$input" ] && SSH_PORT="$input"

        printf "    允许登录的用户 (空格分隔，留空不限制) [${C_GRN}%s${C_R}]: " "${SSH_ALLOW_USERS:-(不限制)}"
        read -r input
        if [ -n "$input" ]; then SSH_ALLOW_USERS="$input"; fi

        if step_enabled SECURE_STEP_01_ENABLED; then
            if _ssh_has_key; then
                echo -e "    ${C_GRN}✓ authorized_keys 已配置 → 将执行完全加固${C_R}"
            else
                echo -e "    ${C_YEL}⚠ ${ADMIN_USER} 未配置 SSH 公钥 → 将执行基础加固（保留密码登录）${C_R}"
                echo -e "    ${C_YEL}  上传公钥后重新运行即可升级: ssh-copy-id ${ADMIN_USER}@<服务器IP>${C_R}"
            fi
        fi
        echo ""
    fi

    # ── 步骤 03: fail2ban ──
    if step_enabled SECURE_STEP_03_ENABLED; then
        echo -e "  ${C_B}▸ fail2ban 防暴力破解${C_R}"
        printf "    封禁时长/秒 [${C_GRN}%s${C_R}]: " "$FAIL2BAN_BANTIME"
        read -r input; [ -n "$input" ] && FAIL2BAN_BANTIME="$input"
        printf "    统计窗口/秒 [${C_GRN}%s${C_R}]: " "$FAIL2BAN_FINDTIME"
        read -r input; [ -n "$input" ] && FAIL2BAN_FINDTIME="$input"
        printf "    最大尝试次数 [${C_GRN}%s${C_R}]: " "$FAIL2BAN_MAXRETRY"
        read -r input; [ -n "$input" ] && FAIL2BAN_MAXRETRY="$input"
        echo ""
    fi

    # ── 步骤 04: 防火墙 ──
    if step_enabled SECURE_STEP_04_ENABLED; then
        echo -e "  ${C_B}▸ 防火墙${C_R}"
        printf "    开放端口 (空格分隔 port/proto) [${C_GRN}%s${C_R}]: " "$UFW_PORTS"
        read -r input; [ -n "$input" ] && UFW_PORTS="$input"
        echo -e "    ${C_YEL}注意: SSH 端口 ${SSH_PORT} 会自动加入白名单${C_R}"
        echo ""
    fi

    # ── 步骤 05: 自动更新 ──
    if step_enabled SECURE_STEP_05_ENABLED; then
        echo -e "  ${C_B}▸ 自动安全更新${C_R}"
        echo -e "    将配置 ${OS_FAMILY} 系自动安全更新机制（无需额外参数）"
        echo ""
    fi
}

# 显示确认摘要
menu_confirm() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "${C_B}${C_CYN}  ╔══════════════════════════════════════════════════════╗${C_R}"
    echo -e "${C_B}${C_CYN}  ║                  确认执行清单                        ║${C_R}"
    echo -e "${C_B}${C_CYN}  ╚══════════════════════════════════════════════════════╝${C_R}"
    echo ""
    echo -e "  系统: ${C_GRN}${OS_PRETTY}${C_R}"
    echo -e "  模式: ${C_YEL}$([ "$DRY_RUN" = true ] && echo "DRY-RUN (仅预览)" || echo "正式执行")${C_R}"
    echo ""

    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id var label _ <<< "$entry"
        if step_enabled "$var"; then
            echo -e "  ${C_GRN}[x]${C_R} ${label}"
        else
            echo -e "  ${C_BLU}[ ]${C_R} ${label}"
        fi
    done

    echo ""
    echo -e "  ${C_B}参数摘要:${C_R}"
    step_enabled SECURE_STEP_01_ENABLED && echo "    ADMIN_USER        = ${ADMIN_USER}"
    step_enabled SECURE_STEP_02_ENABLED && echo "    SSH_PORT          = ${SSH_PORT}"
    step_enabled SECURE_STEP_02_ENABLED && echo "    SSH_ALLOW_USERS   = ${SSH_ALLOW_USERS:-(不限制)}"
    step_enabled SECURE_STEP_03_ENABLED && echo "    FAIL2BAN_BANTIME  = ${FAIL2BAN_BANTIME}s  MAXRETRY=${FAIL2BAN_MAXRETRY}"
    step_enabled SECURE_STEP_04_ENABLED && echo "    UFW_PORTS         = ${UFW_PORTS}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_YEL}按 Enter 开始预览...${C_R}"
        read -r
        return 0
    fi

    echo -e "  ${C_RED}即将执行以上操作，确认后不可撤销！${C_R}"
    printf "  ${C_B}确认执行？(yes/no) [no] > ${C_R}"
    read -r yn
    case "$yn" in
        yes|YES|y|Y) return 0 ;;
        *) echo -e "  ${C_YEL}已取消${C_R}"; exit 0 ;;
    esac
}


# ══════════════════════════════════════════════════════════════════════════════
#  配置文件加载 (非交互模式)
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
    log INFO "配置加载完成"
}

resolve_config() {
    if [ -n "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] || die "指定的配置文件不存在: ${CONFIG_FILE}"
        load_config "$CONFIG_FILE"
    elif [ -f "./secure-server-init.conf" ]; then
        load_config "./secure-server-init.conf"
    elif [ -f "/etc/secure-server-init.conf" ]; then
        load_config "/etc/secure-server-init.conf"
    else
        log INFO "未发现配置文件，使用内置默认值"
    fi
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤实现
# ══════════════════════════════════════════════════════════════════════════════

step_00_system_update() {
    local SN="00"
    step_header "$SN" "系统软件包更新"
    step_enabled SECURE_STEP_00_ENABLED || { skip_step "$SN" "未选中"; return; }
    command -v "$PKG_MANAGER" &>/dev/null || { skip_step "$SN" "找不到 ${PKG_MANAGER}"; return; }

    local avail; avail=$(df -k --output=avail / 2>/dev/null | tail -1)
    [ "${avail:-0}" -lt 524288 ] && log WARN "  根分区可用 < 500MB，更新可能失败"

    pkg_update || { mark_step_fail "$SN" "系统更新失败"; return; }
    mark_step_ok "$SN"
}

step_01_user_sudo() {
    local SN="01"
    step_header "$SN" "创建管理员用户并配置 sudo"
    step_enabled SECURE_STEP_01_ENABLED || { skip_step "$SN" "未选中"; return; }
    [ "$EUID" -ne 0 ] && { skip_step "$SN" "需要 root 权限"; return; }

    command -v sudo &>/dev/null || pkg_install sudo || { mark_step_fail "$SN" "安装 sudo 失败"; return; }

    if id "$ADMIN_USER" &>/dev/null; then
        log INFO "  用户 '${ADMIN_USER}' 已存在，跳过创建"
    else
        useradd -m -s /bin/bash "$ADMIN_USER" || { mark_step_fail "$SN" "创建用户失败"; return; }
        log WARN "  请为用户 '${ADMIN_USER}' 设置密码:"
        passwd "$ADMIN_USER" || log WARN "  密码设置被跳过"
    fi

    case "$OS_FAMILY" in
        debian|arch) usermod -aG sudo "$ADMIN_USER" ;;
        rhel|suse)   usermod -aG wheel "$ADMIN_USER" ;;
    esac
    log INFO "  已将 '${ADMIN_USER}' 加入管理员组"

    local ag=""
    case "$OS_FAMILY" in debian|arch) ag="sudo" ;; rhel|suse) ag="wheel" ;; esac
    groups "$ADMIN_USER" 2>/dev/null | grep -qw "$ag" \
        && log INFO "  用户属于 '${ag}' 组 ✓" \
        || { mark_step_fail "$SN" "用户不在 ${ag} 组中"; return; }

    mark_step_ok "$SN"
}

# ── SSH 加固辅助：判断是否有密钥 ────────────────────────────────────────────

_ssh_has_key() {
    local ak="/home/${ADMIN_USER}/.ssh/authorized_keys"
    [ -f "$ak" ] && [ -s "$ak" ]
}

# ── SSH 加固辅助：判断当前加固等级 ──────────────────────────────────────────
# 返回: "none" (未加固) / "basic" (基础加固, 密码未关) / "full" (完全加固)
_ssh_current_level() {
    local c="${1:-/etc/ssh/sshd_config.d/99-secure-init.conf}"
    if [ ! -f "$c" ]; then echo "none"; return; fi
    # 检查是否由本脚本生成
    grep -q "secure-server-init" "$c" 2>/dev/null || { echo "none"; return; }
    if grep -q "^PasswordAuthentication no$" "$c" 2>/dev/null; then
        echo "full"
    else
        echo "basic"
    fi
}

step_02_ssh_harden() {
    local SN="02"
    step_header "$SN" "SSH 加固"
    step_enabled SECURE_STEP_02_ENABLED || { skip_step "$SN" "未选中"; return; }

    if ! command -v sshd &>/dev/null && ! systemctl list-unit-files sshd.service &>/dev/null 2>&1; then
        skip_step "$SN" "sshd 未安装"; return
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    [ ! -f "$SSHD_CONFIG" ] && SSHD_CONFIG="/etc/openssh/sshd_config"
    [ ! -f "$SSHD_CONFIG" ] && { skip_step "$SN" "找不到 sshd_config"; return; }

    local SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
    local OUR_CONFIG="${SSHD_CONFIG_D}/99-secure-init.conf"
    local HAS_KEY=false; _ssh_has_key && HAS_KEY=true
    local LEVEL; LEVEL=$(_ssh_current_level "$OUR_CONFIG")

    # ── 情况 1: 已完全加固 ──
    if [ "$LEVEL" = "full" ]; then
        log INFO "  SSH 已完全加固（密码登录已禁用），无需重复操作"
        if [ "$DRY_RUN" = false ]; then
            log INFO "  PermitRootLogin = no ✓"
            log INFO "  PasswordAuthentication = no ✓"
            log INFO "  PubkeyAuthentication = yes ✓"
        fi
        mark_step_ok "$SN"; return
    fi

    # ── 情况 2: 已基础加固，检测是否可以升级 ──
    if [ "$LEVEL" = "basic" ]; then
        log INFO "  检测到现有基础加固（密码登录仍开启）"
        if $HAS_KEY; then
            log INFO "  发现 ${ADMIN_USER} 的 SSH 公钥已配置，可升级到完全加固"
            if [ "$BATCH_MODE" = false ]; then
                printf "  %s" "是否升级为完全加固（禁用密码登录）？(Y/n) > "
                read -r yn
                case "$yn" in [Nn]*) log INFO "  保持基础加固"; mark_step_ok "$SN"; return ;; esac
            fi
        else
            log INFO "  尚未配置 SSH 公钥，保持基础加固（密码登录保留）"
            log WARN "  上传公钥后重新运行本脚本可自动升级到完全加固"
            mark_step_ok "$SN"; return
        fi
    fi

    # ── 备份 ──
    local BACKUP="${SSHD_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
    log INFO "  备份 sshd_config → ${BACKUP}"
    dry cp "$SSHD_CONFIG" "$BACKUP"

    # ── 决定加固等级 ──
    local PASSWORD_AUTH="yes"
    if $HAS_KEY; then
        log INFO "  authorized_keys 已配置 ✓ → 完全加固模式"
        PASSWORD_AUTH="no"
    else
        log WARN "  ⚠ ${ADMIN_USER} 未配置 SSH 公钥 → 基础加固模式（保留密码登录）"
        log WARN "  ⚠ 上传公钥后重新运行本脚本即可升级到完全加固"
        if [ "$BATCH_MODE" = true ]; then
            log INFO "  批量模式: 执行基础加固"
        else
            printf "  %s" "确认执行基础加固？(Y/n) > "
            read -r yn
            case "$yn" in [Nn]*) skip_step "$SN" "用户取消"; return ;; esac
        fi
    fi

    # ── 生成配置 ──
    dry mkdir -p "$SSHD_CONFIG_D"
    cat > /tmp/sshd-secure-init.tmp <<EOF
# 由 secure-server-init.sh 自动生成 — $(date)
# 加固等级: $([ "$PASSWORD_AUTH" = "no" ] && echo "完全" || echo "基础")
# 原始配置备份: ${BACKUP}
PermitRootLogin no
PasswordAuthentication ${PASSWORD_AUTH}
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
EOF
    [ -n "$SSH_ALLOW_USERS" ] && echo "AllowUsers ${SSH_ALLOW_USERS}" >> /tmp/sshd-secure-init.tmp
    [ "$SSH_PORT" != "22" ] && echo "Port ${SSH_PORT}" >> /tmp/sshd-secure-init.tmp

    dry cp /tmp/sshd-secure-init.tmp "$OUR_CONFIG"
    dry chmod 600 "$OUR_CONFIG"

    # ── 语法检查 → 重启 ──
    log INFO "  检查 sshd 配置语法..."
    if ! dry sshd -t; then
        log ERROR "  sshd 配置语法错误！正在恢复备份..."
        dry cp "$BACKUP" "$SSHD_CONFIG"
        rm -f "$OUR_CONFIG"
        mark_step_fail "$SN" "配置语法错误，已恢复备份"; return
    fi

    if command -v systemctl &>/dev/null; then
        dry systemctl restart sshd || dry systemctl restart ssh
    else
        dry service sshd restart || dry service ssh restart
    fi

    # ── 后置检查 ──
    local ok=true
    sshd -T 2>/dev/null | grep -q '^permitrootlogin no$'       && log INFO "  PermitRootLogin = no ✓"         || { log WARN "  PermitRootLogin 未通过"; ok=false; }
    sshd -T 2>/dev/null | grep -q '^pubkeyauthentication yes$' && log INFO "  PubkeyAuthentication = yes ✓"   || { log WARN "  PubkeyAuthentication 未通过"; ok=false; }
    if [ "$PASSWORD_AUTH" = "no" ]; then
        sshd -T 2>/dev/null | grep -q '^passwordauthentication no$' && log INFO "  PasswordAuthentication = no ✓" || { log WARN "  PasswordAuthentication 未通过"; ok=false; }
    else
        log INFO "  PasswordAuthentication = yes (基础模式，密码登录保留)"
    fi
    [ "$ok" = false ] && log WARN "  部分配置可能未生效，请手动检查"

    mark_step_ok "$SN"
}

step_03_fail2ban() {
    local SN="03"
    step_header "$SN" "安装并配置 fail2ban（防 SSH 暴力破解）"
    step_enabled SECURE_STEP_03_ENABLED || { skip_step "$SN" "未选中"; return; }

    command -v iptables &>/dev/null || { log WARN "  安装 iptables..."; pkg_install iptables; }

    pkg_install fail2ban || { mark_step_fail "$SN" "fail2ban 安装失败"; return; }
    sleep 1
    command -v fail2ban-client &>/dev/null || { mark_step_fail "$SN" "fail2ban 不可用"; return; }

    local JAIL="/etc/fail2ban/jail.local"
    if ! dry grep -q "secure-server-init" "$JAIL" 2>/dev/null; then
        # ── 检测日志来源 ──
        local AL="" F2B_BACKEND="auto"
        # 优先检测 syslog 文件
        if [ -f "/var/log/auth.log" ]; then
            AL="/var/log/auth.log"
        elif [ -f "/var/log/secure" ]; then
            AL="/var/log/secure"
        fi

        # 无 syslog 文件 → 使用 systemd-journald
        if [ -z "$AL" ] && command -v journalctl &>/dev/null; then
            F2B_BACKEND="systemd"
            log INFO "  未检测到 syslog 日志文件，使用 systemd-journald 后端"
        elif [ -z "$AL" ]; then
            log WARN "  未找到 SSH 日志来源，fail2ban 配置可能不完整"
            AL="/var/log/auth.log"  # 回退默认值
        else
            log INFO "  日志文件: ${AL}"
        fi

        dry mkdir -p /etc/fail2ban
        cat > /tmp/f2b-jail.local <<EOF
# 由 secure-server-init.sh 自动生成 — $(date)
[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
ignoreip = 127.0.0.1/8 ::1
backend  = ${F2B_BACKEND}
banaction = iptables-multiport
[sshd]
enabled  = true
port     = ${SSH_PORT}
mode     = aggressive
maxretry = ${FAIL2BAN_MAXRETRY}
EOF
        # systemd 后端不需要 logpath，auto 后端需要
        if [ "$F2B_BACKEND" != "systemd" ]; then
            echo "logpath  = ${AL}" >> /tmp/f2b-jail.local
        fi
        dry cp /tmp/f2b-jail.local "$JAIL"
    else
        log INFO "  jail.local 已配置过，跳过"
    fi

    if command -v systemctl &>/dev/null; then
        dry systemctl enable fail2ban && dry systemctl restart fail2ban
    else
        dry service fail2ban restart
    fi

    sleep 2
    fail2ban-client ping &>/dev/null && log INFO "  fail2ban 运行中 ✓" || log WARN "  fail2ban 可能未正常启动"
    fail2ban-client status sshd &>/dev/null 2>&1 && log INFO "  sshd jail 已启用 ✓" \
        || { log WARN "  sshd jail 未找到，尝试添加..."; fail2ban-client add sshd 2>/dev/null || true; }

    mark_step_ok "$SN"
}

step_04_firewall() {
    local SN="04"
    step_header "$SN" "防火墙（最小化开放端口）"
    step_enabled SECURE_STEP_04_ENABLED || { skip_step "$SN" "未选中"; return; }

    case "$FIREWALL_TOOL" in
        ufw)
            command -v ufw &>/dev/null || pkg_install ufw || { mark_step_fail "$SN" "ufw 安装失败"; return; }

            # 检查是否已激活：已激活则只补充端口，不 reset
            # (状态检查始终真实执行，不受 dry-run 影响)
            if ufw status 2>/dev/null | grep -q "^Status: active"; then
                log INFO "  ufw 已处于激活状态，仅补充缺失端口..."

                if ! ufw status 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
                    dry ufw allow "${SSH_PORT}/tcp" comment "SSH"
                    log INFO "    已添加 SSH 端口 ${SSH_PORT}/tcp"
                else
                    log INFO "    SSH 端口 ${SSH_PORT}/tcp 已开放"
                fi

                for e in $UFW_PORTS; do
                    local p="${e%/*}" proto="${e##*/}"
                    [ "$e" = "${SSH_PORT}/tcp" ] && continue
                    if ! ufw status 2>/dev/null | grep -q "${p}/${proto}"; then
                        dry ufw allow "$e" 2>/dev/null || log WARN "    端口 ${e} 添加失败"
                        log INFO "    已添加端口 ${e}"
                    else
                        log INFO "    端口 ${e} 已开放"
                    fi
                done

                log INFO "  防火墙状态:"
                ufw status numbered 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
                mark_step_ok "$SN"; return
            fi

            # 首次配置：完整初始化
            dry ufw --force reset
            dry ufw default deny incoming
            dry ufw default allow outgoing
            dry ufw allow "${SSH_PORT}/tcp" comment "SSH"
            for e in $UFW_PORTS; do
                [ "$e" != "${SSH_PORT}/tcp" ] && dry ufw allow "$e" 2>/dev/null || true
            done
            echo "y" | dry ufw enable
            dry ufw status verbose 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
            ;;

        firewalld)
            command -v firewall-cmd &>/dev/null || {
                pkg_install firewalld || { mark_step_fail "$SN" "firewalld 安装失败"; return; }
                command -v systemctl &>/dev/null && dry systemctl enable --now firewalld
            }

            # 检查是否已运行：已运行则只补充端口
            # (状态检查始终真实执行)
            if firewall-cmd --state &>/dev/null 2>&1; then
                log INFO "  firewalld 已运行，仅补充缺失端口..."
                local cur_ports; cur_ports=$(firewall-cmd --list-ports 2>/dev/null)
                for e in $UFW_PORTS; do
                    if ! echo "$cur_ports" | grep -qw "$e"; then
                        dry firewall-cmd --permanent --add-port="$e" 2>/dev/null || true
                        log INFO "    已添加端口 ${e}"
                    else
                        log INFO "    端口 ${e} 已开放"
                    fi
                done
                if ! echo "$cur_ports" | grep -qw "${SSH_PORT}/tcp"; then
                    dry firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null
                fi
                dry firewall-cmd --reload
                dry firewall-cmd --list-all 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
                mark_step_ok "$SN"; return
            fi

            # 首次配置
            dry firewall-cmd --set-default-zone=public
            for e in $UFW_PORTS; do
                dry firewall-cmd --permanent --add-port="$e" 2>/dev/null || true
            done
            dry firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null
            dry firewall-cmd --reload
            dry firewall-cmd --list-all 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
            ;;

        iptables)
            # iptables 检查是否已有规则 (状态检查始终真实执行)
            if iptables -L INPUT -n 2>/dev/null | grep -q "DROP\|REJECT"; then
                log INFO "  iptables 已有规则，跳过自动配置，请手动检查"
                iptables -L INPUT -n --line-numbers 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
                mark_step_ok "$SN"; return
            fi

            log WARN "  Arch 系 — 将应用以下 iptables 规则:"
            log WARN "    iptables -P INPUT DROP"
            log WARN "    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT"
            log WARN "    iptables -A INPUT -i lo -j ACCEPT"
            for e in $UFW_PORTS; do log WARN "    iptables -A INPUT -p ${e##*/} --dport ${e%/*} -j ACCEPT"; done
            if [ "$BATCH_MODE" = true ]; then
                log WARN "  批量模式: 自动应用 iptables 规则"
            else
                printf "  %s" "确认执行？(y/N) > "
                read -r yn
                case "$yn" in [Yy]*) ;; *) skip_step "$SN" "用户取消"; return ;; esac
            fi
            dry iptables -P INPUT DROP
            dry iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            dry iptables -A INPUT -i lo -j ACCEPT
            for e in $UFW_PORTS; do
                dry iptables -A INPUT -p "${e##*/}" --dport "${e%/*}" -j ACCEPT
            done
            command -v iptables-save &>/dev/null && { dry mkdir -p /etc/iptables; dry iptables-save > /etc/iptables/rules.v4 2>/dev/null; }
            log INFO "  iptables 规则已应用 ✓"
            ;;
        *) skip_step "$SN" "未知防火墙工具"; return ;;
    esac
    mark_step_ok "$SN"
}

step_05_auto_updates() {
    local SN="05"
    step_header "$SN" "配置自动安全更新"
    step_enabled SECURE_STEP_05_ENABLED || { skip_step "$SN" "未选中"; return; }

    case "$OS_FAMILY" in
        debian)
            pkg_install unattended-upgrades
            dry dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
            cat > /tmp/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
            dry cp /tmp/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
            log INFO "  unattended-upgrades 已启用 ✓"
            ;;
        rhel)
            pkg_install dnf-automatic
            [ -f /etc/dnf/automatic.conf ] && {
                dry sed -i 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf
                dry sed -i 's/^upgrade_type = .*/upgrade_type = security/' /etc/dnf/automatic.conf
            }
            command -v systemctl &>/dev/null && dry systemctl enable --now dnf-automatic.timer 2>/dev/null || true
            log INFO "  dnf-automatic 已启用 ✓"
            ;;
        suse)   log INFO "  openSUSE: 请手动配置 yast2-online-update" ;;
        arch)   log INFO "  Arch: 请参考 wiki.archlinux.org 手动配置自动更新" ;;
        *)      mark_step_fail "$SN" "不支持的发行版"; return ;;
    esac
    mark_step_ok "$SN"
}


# ══════════════════════════════════════════════════════════════════════════════
#  结果汇总
# ══════════════════════════════════════════════════════════════════════════════

print_summary() {
    echo ""
    log STEP "════════════════════════════════════════════════════"
    log STEP "  执行摘要"
    log STEP "════════════════════════════════════════════════════"

    local all_ok=true
    local labels=("系统更新" "管理员用户+sudo" "SSH 加固" "fail2ban" "防火墙" "自动安全更新")
    local ids=("00" "01" "02" "03" "04" "05")

    for i in "${!ids[@]}"; do
        local status="${STEP_RESULTS[${ids[$i]}]:-NOT_RUN}"
        case "$status" in
            OK)      log INFO "  ✅ ${ids[$i]} ${labels[$i]}: 成功"    ;;
            SKIPPED) log WARN "  ⏭  ${ids[$i]} ${labels[$i]}: 已跳过" ;;
            FAILED)  log ERROR "  ❌ ${ids[$i]} ${labels[$i]}: 失败"   ; all_ok=false ;;
            NOT_RUN) log WARN "  ⬚  ${ids[$i]} ${labels[$i]}: 未执行"  ; all_ok=false ;;
        esac
    done

    echo ""
    log INFO "日志文件: ${LOG_FILE}"
    [ "$all_ok" = true ] && [ "$OVERALL_SUCCESS" = true ] \
        && log STEP "  服务器安全初始化完成！" \
        || log WARN "  ⚠ 部分步骤未完成，请检查日志"
}


# ══════════════════════════════════════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════════════════════════════════════

print_banner() {
    echo ""
    log STEP "╔════════════════════════════════════════════════════╗"
    log STEP "║     服务器安全初始化脚本                           ║"
    log STEP "║     Ubuntu/Debian/CentOS/Rocky/Fedora/Arch/SUSE    ║"
    log STEP "╚════════════════════════════════════════════════════╝"
}

generate_config() {
    cat <<'CONFEOF'
# =============================================================================
# secure-server-init.conf — 服务器安全初始化配置
# 使用: sudo bash secure-server-init.sh --config ./secure-server-init.conf
# =============================================================================
SECURE_STEP_00_ENABLED=true   # 系统更新
SECURE_STEP_01_ENABLED=true   # 管理员用户 + sudo
SECURE_STEP_02_ENABLED=true   # SSH 加固
SECURE_STEP_03_ENABLED=true   # fail2ban
SECURE_STEP_04_ENABLED=true   # 防火墙
SECURE_STEP_05_ENABLED=true   # 自动安全更新

ADMIN_USER=deploy
SSH_PORT=22
SSH_ALLOW_USERS=""
FAIL2BAN_BANTIME=3600
FAIL2BAN_FINDTIME=600
FAIL2BAN_MAXRETRY=3
UFW_PORTS="22/tcp 80/tcp 443/tcp"
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

无参数        交互式菜单向导（推荐）
--dry-run    预览模式，仅显示将执行的操作
--config F   配置文件模式，适合批量/无人值守
--generate-config  生成示例配置文件
-h, --help   显示此帮助
EOF
            exit 0 ;;
        *) log ERROR "未知选项: $1"; exit 1 ;;
    esac
done

# ── 权限检查 ──

[ "$EUID" -ne 0 ] && die "请以 root 权限运行: sudo bash $SCRIPT_NAME"

# ── 初始化 ──

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
log INFO "日志文件: ${LOG_FILE}"

print_banner
detect_os

# ── 分支：交互模式 vs 批量模式 ──

if [ "$BATCH_MODE" = true ]; then
    # ── 配置文件模式 ──
    resolve_config
    echo ""
    log INFO "批量模式 — 当前配置:"
    log INFO "  ADMIN_USER=${ADMIN_USER}  SSH_PORT=${SSH_PORT}"
    log INFO "  FAIL2BAN_MAXRETRY=${FAIL2BAN_MAXRETRY}  UFW_PORTS=${UFW_PORTS}"

    step_00_system_update
    step_01_user_sudo
    step_02_ssh_harden
    step_03_fail2ban
    step_04_firewall
    step_05_auto_updates
    print_summary
else
    # ── 交互式菜单模式 ──
    menu_select_steps

    # 检查是否有选中步骤（Q 退出时全部取消）
    local any_enabled=false
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r _ var _ _ <<< "$entry"
        step_enabled "$var" && any_enabled=true
    done
    if [ "$any_enabled" = false ]; then
        echo ""
        log WARN "未选择任何安全措施，已退出。"
        exit 0
    fi

    menu_configure_params
    menu_confirm

    # 执行选中的步骤
    echo ""
    log STEP "开始执行..."

    for entry in "${STEPS[@]}"; do
        IFS='|' read -r id var _ _ <<< "$entry"
        step_enabled "$var" || continue
        case "$id" in
            00) step_00_system_update ;;
            01) step_01_user_sudo     ;;
            02) step_02_ssh_harden    ;;
            03) step_03_fail2ban      ;;
            04) step_04_firewall      ;;
            05) step_05_auto_updates  ;;
        esac
    done
    print_summary
fi

[ "$OVERALL_SUCCESS" = false ] && exit 1
