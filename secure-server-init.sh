#!/usr/bin/env bash
# =============================================================================
# secure-server-init.sh — 通用 Linux 服务器安全初始化脚本
#
# 支持的发行版：Ubuntu, Debian, CentOS, Rocky, Alma, Fedora, RHEL, openSUSE, Arch
#
# 配置优先级（高→低）:
#   1. 运行时环境变量    (export SSH_PORT=2222)
#   2. 命令行指定配置文件  (--config /path/to/conf)
#   3. 当前目录配置文件    (./secure-server-init.conf)
#   4. 系统全局配置文件    (/etc/secure-server-init.conf)
#   5. 脚本内置默认值
#
# 用法:
#   sudo bash secure-server-init.sh                     # 完整运行
#   sudo bash secure-server-init.sh --dry-run           # 仅探测
#   sudo bash secure-server-init.sh --step 3            # 仅执行第 3 步
#   sudo bash secure-server-init.sh --generate-config   # 生成示例配置文件
#   sudo bash secure-server-init.sh --config my.conf    # 指定配置文件
#
# 每一步都包含: 预校验 → 操作(带日志) → 后置检查 → 错误处理
# =============================================================================

set -o pipefail

# ── 全局变量 ──────────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/var/log/secure-server-init-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
SINGLE_STEP=""
CONFIG_FILE=""
STEP_RESULTS=()
OVERALL_SUCCESS=true

# ── 内置默认值（最低优先级，可被配置文件和环境变量覆盖） ────────────────────
#   注意：这些变量在 load_config 之前定义，load_config 会覆盖它们
#   环境变量优先于配置文件 —— 如果用户 export 了某个变量，配置文件中同名项会被忽略

_DEFAULT_SSH_PORT=22
_DEFAULT_ADMIN_USER="deploy"
_DEFAULT_SSH_ALLOW_USERS=""
_DEFAULT_FAIL2BAN_BANTIME=3600
_DEFAULT_FAIL2BAN_FINDTIME=600
_DEFAULT_FAIL2BAN_MAXRETRY=3
_DEFAULT_UFW_PORTS="22/tcp 80/tcp 443/tcp"

# ── 步骤开关默认值 ──────────────────────────────────────────────────────────
_DEFAULT_SECURE_STEP_00_ENABLED=true    # 系统软件包更新
_DEFAULT_SECURE_STEP_01_ENABLED=true    # 创建管理员用户 & sudo
_DEFAULT_SECURE_STEP_02_ENABLED=true    # SSH 加固
_DEFAULT_SECURE_STEP_03_ENABLED=true    # fail2ban
_DEFAULT_SECURE_STEP_04_ENABLED=true    # 防火墙
_DEFAULT_SECURE_STEP_05_ENABLED=true    # 自动安全更新
_DEFAULT_SECURE_STEP_06_ENABLED=true    # /tmp 加固
_DEFAULT_SECURE_STEP_07_ENABLED=true    # sysctl 内核参数
_DEFAULT_SECURE_STEP_08_ENABLED=true    # 日志管理
_DEFAULT_SECURE_STEP_09_ENABLED=true    # 审查开放端口和服务
_DEFAULT_SECURE_STEP_10_ENABLED=true    # NTP 时间同步
_DEFAULT_SECURE_STEP_11_ENABLED=false   # rkhunter (默认关闭，可选)
# =============================================================================


# ── 工具函数 ──────────────────────────────────────────────────────────────────

# 颜色输出
if [ -t 1 ] && command -v tput &>/dev/null; then
    COLOR_RESET="$(tput sgr0)"
    COLOR_BOLD="$(tput bold)"
    COLOR_RED="$(tput setaf 1)"
    COLOR_GREEN="$(tput setaf 2)"
    COLOR_YELLOW="$(tput setaf 3)"
    COLOR_BLUE="$(tput setaf 4)"
    COLOR_CYAN="$(tput setaf 6)"
else
    COLOR_RESET=""; COLOR_BOLD=""; COLOR_RED=""; COLOR_GREEN=""
    COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""
fi

log() {
    local level="$1"; shift
    local color=""
    case "$level" in
        INFO)  color="$COLOR_GREEN"  ;;
        WARN)  color="$COLOR_YELLOW" ;;
        ERROR) color="$COLOR_RED"    ;;
        STEP)  color="$COLOR_CYAN"   ;;
        CHECK) color="$COLOR_BLUE"   ;;
        *)     color=""              ;;
    esac
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo -e "${color}${msg}${COLOR_RESET}" | tee -a "$LOG_FILE" >&2
}

step_header() {
    local num="$1"; local title="$2"
    echo "" | tee -a "$LOG_FILE"
    log STEP "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log STEP "步骤 ${num}: ${title}"
    log STEP "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

die() {
    log ERROR "$@"
    exit 1
}

dry() {
    if [ "$DRY_RUN" = true ]; then
        log WARN "[DRY-RUN] 将执行: $*"
    else
        "$@"
    fi
}

skip_step() {
    local num="$1"; local reason="$2"
    log WARN "步骤 ${num} 已跳过: ${reason}"
    STEP_RESULTS["${num}"]="SKIPPED"
}

mark_step_ok() {
    local num="$1"
    log INFO "✅ 步骤 ${num} 完成并通过后置检查"
    STEP_RESULTS["${num}"]="OK"
}

mark_step_fail() {
    local num="$1"; local msg="$2"
    log ERROR "❌ 步骤 ${num} 失败: ${msg}"
    STEP_RESULTS["${num}"]="FAILED"
    OVERALL_SUCCESS=false
}

confirm() {
    local prompt="$1"; local default="${2:-}"
    if [ "$DRY_RUN" = true ]; then return 0; fi
    local yn=""
    case "$default" in
        Y) yn="Y/n" ;;
        N) yn="y/N" ;;
        *) yn="y/n"; default="Y" ;;
    esac
    read -r -p "$(log INFO "${prompt} [${yn}]: ")" yn
    : "${yn:=$default}"
    case "$yn" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}


# ── 配置加载 ──────────────────────────────────────────────────────────────────

# 加载顺序：内置默认 → 配置文件 → 环境变量覆盖
# 环境变量已经存在于当前 shell，所以如果设置了就不会被配置覆盖
load_config() {
    local conf_file="$1"

    if [ ! -f "$conf_file" ]; then
        log WARN "配置文件不存在: ${conf_file}"
        return 1
    fi

    log INFO "加载配置文件: ${conf_file}"

    # 安全地 source 配置文件（仅允许简单赋值，禁止命令注入）
    # 使用 grep 过滤出合法的 VAR=value 行
    local filtered
    filtered=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*="?[^"]*"?$' "$conf_file" 2>/dev/null)
    if [ -n "$filtered" ]; then
        # source 过滤后的内容，但 safest 是 eval 已知安全的变量
        eval "$filtered"
    fi

    # 步骤开关布尔值规范化
    local steps=(
        SECURE_STEP_00_ENABLED SECURE_STEP_01_ENABLED SECURE_STEP_02_ENABLED
        SECURE_STEP_03_ENABLED SECURE_STEP_04_ENABLED SECURE_STEP_05_ENABLED
        SECURE_STEP_06_ENABLED SECURE_STEP_07_ENABLED SECURE_STEP_08_ENABLED
        SECURE_STEP_09_ENABLED SECURE_STEP_10_ENABLED SECURE_STEP_11_ENABLED
    )
    for var in "${steps[@]}"; do
        local val
        val=$(eval "echo \${${var}:-}")
        case "$val" in
            true|false) ;;  # 合法值
            *) eval "${var}=false" ;;  # 其他一律算 false
        esac
    done

    log INFO "配置加载完成"
    return 0
}

# 确定最终使用的配置文件
resolve_config() {
    if [ -n "$CONFIG_FILE" ]; then
        # 用户通过 --config 指定
        if [ -f "$CONFIG_FILE" ]; then
            load_config "$CONFIG_FILE"
        else
            die "指定的配置文件不存在: ${CONFIG_FILE}"
        fi
    elif [ -f "./secure-server-init.conf" ]; then
        load_config "./secure-server-init.conf"
    elif [ -f "/etc/secure-server-init.conf" ]; then
        load_config "/etc/secure-server-init.conf"
    else
        log INFO "未发现配置文件，使用内置默认值 + 环境变量"
    fi
}

# 获取最终配置值：环境变量 > 配置文件 > 内置默认
# 用法: get_conf VAR_NAME default_value
get_conf() {
    local var="$1"; local default="$2"
    local val
    val=$(eval "echo \${${var}:-}")
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# 获取步骤开关值 (true/false)
step_enabled() {
    local step_var="$1"
    local val
    val=$(eval "echo \${${step_var}:-}")
    case "$val" in
        true)  return 0 ;;
        false) return 1 ;;
        *)     return 1 ;;
    esac
}


# ── 系统探测 ──────────────────────────────────────────────────────────────────

detect_os() {
    log CHECK "探测操作系统类型..."
    OS_FAMILY=""
    PKG_MANAGER=""
    FIREWALL_TOOL=""

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|raspbian)
                OS_FAMILY="debian"
                PKG_MANAGER="apt"
                FIREWALL_TOOL="ufw"
                ;;
            centos|rhel|rocky|almalinux|ol|fedora|amzn)
                OS_FAMILY="rhel"
                FIREWALL_TOOL="firewalld"
                if command -v dnf &>/dev/null; then PKG_MANAGER="dnf"
                else PKG_MANAGER="yum"; fi
                ;;
            opensuse*|sles)
                OS_FAMILY="suse"
                PKG_MANAGER="zypper"
                FIREWALL_TOOL="firewalld"
                ;;
            arch|manjaro|endeavouros)
                OS_FAMILY="arch"
                PKG_MANAGER="pacman"
                FIREWALL_TOOL="iptables"
                ;;
            *)
                OS_FAMILY="unknown"
                PKG_MANAGER="unknown"
                FIREWALL_TOOL="unknown"
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_FAMILY="rhel"
        FIREWALL_TOOL="firewalld"
        if command -v dnf &>/dev/null; then PKG_MANAGER="dnf"; else PKG_MANAGER="yum"; fi
    else
        OS_FAMILY="unknown"
        PKG_MANAGER="unknown"
        FIREWALL_TOOL="unknown"
    fi

    log INFO "  检测结果: OS_FAMILY=${OS_FAMILY}  PKG_MANAGER=${PKG_MANAGER}  FIREWALL_TOOL=${FIREWALL_TOOL}"

    if [ "$OS_FAMILY" = "unknown" ]; then
        die "无法识别当前操作系统。请手动检查 /etc/os-release"
    fi
}

pkg_install() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)    dry apt-get install -y "$pkg" ;;
        dnf)    dry dnf install -y "$pkg"     ;;
        yum)    dry yum install -y "$pkg"     ;;
        zypper) dry zypper install -y "$pkg"  ;;
        pacman) dry pacman -S --noconfirm "$pkg" ;;
        *)      die "未知包管理器，无法安装 ${pkg}" ;;
    esac
}

pkg_update() {
    case "$PKG_MANAGER" in
        apt)    dry apt-get update -y && dry apt-get upgrade -y ;;
        dnf)    dry dnf upgrade -y ;;
        yum)    dry yum update -y   ;;
        zypper) dry zypper refresh && dry zypper update -y ;;
        pacman) dry pacman -Syu --noconfirm ;;
        *)      die "未知包管理器，无法更新" ;;
    esac
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 0: 系统更新 (前置步骤)
# ══════════════════════════════════════════════════════════════════════════════

step_00_system_update() {
    local STEP_NUM="0"
    step_header "$STEP_NUM" "系统软件包更新"

    # ── 预校验 ──
    log CHECK "[预校验] 检查包管理器可用性..."
    case "$PKG_MANAGER" in
        apt|dnf|yum|zypper|pacman) ;;
        *) skip_step "$STEP_NUM" "未知包管理器"; return ;;
    esac

    if ! command -v "$PKG_MANAGER" &>/dev/null; then
        skip_step "$STEP_NUM" "找不到 ${PKG_MANAGER} 命令"
        return
    fi

    log CHECK "[预校验] 检查磁盘空间..."
    local avail_kb
    avail_kb=$(df -k --output=avail / 2>/dev/null | tail -1)
    if [ "${avail_kb:-0}" -lt 524288 ]; then
        log WARN "  根分区可用空间不足 500MB (约 ${avail_kb}KB)，更新可能失败"
    fi

    # ── 操作 ──
    pkg_update || {
        mark_step_fail "$STEP_NUM" "系统更新失败"
        return
    }

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证包管理器状态..."
    case "$PKG_MANAGER" in
        apt)    apt-get check &>/dev/null && log INFO "  apt 状态正常" || log WARN "  apt 检查有残留问题" ;;
        dnf|yum) dry "$PKG_MANAGER" check-update &>/dev/null || true ;;
    esac
    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 1: 创建管理员用户并配置 sudo
# ══════════════════════════════════════════════════════════════════════════════

step_01_user_sudo() {
    local STEP_NUM="1"
    step_header "$STEP_NUM" "创建管理员用户并配置 sudo"

    # ── 预校验 ──
    log CHECK "[预校验] 检查当前是否为 root..."
    if [ "$EUID" -ne 0 ]; then
        skip_step "$STEP_NUM" "需要 root 权限，当前为普通用户"
        return
    fi

    local ADMIN_USER; ADMIN_USER=$(get_conf ADMIN_USER "$_DEFAULT_ADMIN_USER")

    if id "$ADMIN_USER" &>/dev/null; then
        log INFO "  用户 '${ADMIN_USER}' 已存在，跳过创建"
    fi

    log CHECK "[预校验] 检查 sudo 是否可用..."
    if ! command -v sudo &>/dev/null; then
        log WARN "  sudo 未安装，将尝试安装"
        pkg_install sudo || {
            mark_step_fail "$STEP_NUM" "安装 sudo 失败"
            return
        }
    fi

    # ── 操作 ──
    if ! id "$ADMIN_USER" &>/dev/null; then
        log INFO "  创建用户: ${ADMIN_USER}"
        useradd -m -s /bin/bash "$ADMIN_USER" || {
            mark_step_fail "$STEP_NUM" "创建用户 ${ADMIN_USER} 失败"
            return
        }
        log WARN "  请为用户 '${ADMIN_USER}' 设置密码:"
        passwd "$ADMIN_USER" || log WARN "  密码设置被跳过"
    fi

    case "$OS_FAMILY" in
        debian|arch) dry usermod -aG sudo "$ADMIN_USER"    ;;
        rhel|suse)   dry usermod -aG wheel "$ADMIN_USER"   ;;
    esac
    log INFO "  已将 '${ADMIN_USER}' 加入管理员组"

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证用户和 sudo 权限..."
    if id "$ADMIN_USER" &>/dev/null; then
        log INFO "  用户 '${ADMIN_USER}' 存在 ✓"
    else
        mark_step_fail "$STEP_NUM" "用户 ${ADMIN_USER} 不存在"
        return
    fi

    local admin_group=""
    case "$OS_FAMILY" in
        debian|arch) admin_group="sudo"  ;;
        rhel|suse)   admin_group="wheel" ;;
    esac
    if groups "$ADMIN_USER" | grep -qw "$admin_group"; then
        log INFO "  用户属于 '${admin_group}' 组 ✓"
    else
        mark_step_fail "$STEP_NUM" "用户 ${ADMIN_USER} 不在 ${admin_group} 组中"
        return
    fi

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 2: SSH 加固
# ══════════════════════════════════════════════════════════════════════════════

step_02_ssh_harden() {
    local STEP_NUM="2"
    step_header "$STEP_NUM" "SSH 加固 (禁用 root/密码登录，启用密钥认证)"

    local SSH_PORT;    SSH_PORT=$(get_conf SSH_PORT "$_DEFAULT_SSH_PORT")
    local ADMIN_USER;  ADMIN_USER=$(get_conf ADMIN_USER "$_DEFAULT_ADMIN_USER")
    local SSH_ALLOW_USERS; SSH_ALLOW_USERS=$(get_conf SSH_ALLOW_USERS "$_DEFAULT_SSH_ALLOW_USERS")

    # ── 预校验 ──
    log CHECK "[预校验] 检查 sshd 是否安装..."
    if ! command -v sshd &>/dev/null && ! systemctl list-unit-files sshd.service &>/dev/null 2>&1; then
        skip_step "$STEP_NUM" "sshd 未安装"
        return
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    local SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
    local OUR_CONFIG="${SSHD_CONFIG_D}/99-secure-init.conf"

    if [ ! -f "$SSHD_CONFIG" ]; then
        SSHD_CONFIG="/etc/openssh/sshd_config"
        if [ ! -f "$SSHD_CONFIG" ]; then
            skip_step "$STEP_NUM" "找不到 sshd_config"
            return
        fi
    fi

    local BACKUP="${SSHD_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
    log CHECK "[预校验] 备份当前 sshd_config → ${BACKUP}"
    dry cp "$SSHD_CONFIG" "$BACKUP"

    local AUTH_KEYS="/home/${ADMIN_USER}/.ssh/authorized_keys"
    log CHECK "[预校验] 检查 ${ADMIN_USER} 的 authorized_keys..."
    if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
        log WARN "  ⚠ ${ADMIN_USER} 尚未配置 SSH 公钥 (${AUTH_KEYS} 为空或不存在)"
        log WARN "  ⚠ 如果没有先上传公钥就禁用密码登录，你会被锁在外面！"
        if ! confirm "  是否仍然继续？(建议先上传公钥再执行此步)"; then
            skip_step "$STEP_NUM" "用户选择跳过（未配置公钥）"
            return
        fi
    else
        log INFO "  authorized_keys 已配置 ✓"
    fi

    # ── 操作 ──
    log INFO "  生成安全配置文件: ${OUR_CONFIG}"
    dry mkdir -p "$SSHD_CONFIG_D"
    cat > /tmp/sshd-secure-init.tmp <<EOF
# 由 secure-server-init.sh 自动生成 — $(date)
# 原始配置备份: ${BACKUP}

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
EOF

    if [ -n "$SSH_ALLOW_USERS" ]; then
        echo "AllowUsers ${SSH_ALLOW_USERS}" >> /tmp/sshd-secure-init.tmp
    fi

    if [ "$SSH_PORT" != "22" ]; then
        echo "Port ${SSH_PORT}" >> /tmp/sshd-secure-init.tmp
    fi

    dry cp /tmp/sshd-secure-init.tmp "$OUR_CONFIG"
    dry chmod 600 "$OUR_CONFIG"

    log INFO "  检查 sshd 配置语法..."
    if ! dry sshd -t; then
        log ERROR "  sshd 配置语法错误！正在恢复备份..."
        dry cp "$BACKUP" "$SSHD_CONFIG"
        mark_step_fail "$STEP_NUM" "sshd 配置语法错误，已恢复备份"
        return
    fi

    log INFO "  重启 sshd 服务..."
    if command -v systemctl &>/dev/null; then
        dry systemctl restart sshd || dry systemctl restart ssh
    else
        dry service sshd restart || dry service ssh restart
    fi

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证 SSH 配置生效..."
    local checks_ok=true

    if sshd -T 2>/dev/null | grep -q '^permitrootlogin no$'; then
        log INFO "  PermitRootLogin = no ✓"
    else
        log WARN "  PermitRootLogin 检查未通过"
        checks_ok=false
    fi

    if sshd -T 2>/dev/null | grep -q '^passwordauthentication no$'; then
        log INFO "  PasswordAuthentication = no ✓"
    else
        log WARN "  PasswordAuthentication 检查未通过"
        checks_ok=false
    fi

    if sshd -T 2>/dev/null | grep -q '^pubkeyauthentication yes$'; then
        log INFO "  PubkeyAuthentication = yes ✓"
    else
        log WARN "  PubkeyAuthentication 检查未通过"
        checks_ok=false
    fi

    [ "$checks_ok" = false ] && log WARN "  部分 SSH 配置可能未正确生效，请手动检查"

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 3: fail2ban
# ══════════════════════════════════════════════════════════════════════════════

step_03_fail2ban() {
    local STEP_NUM="3"
    step_header "$STEP_NUM" "安装并配置 fail2ban"

    local SSH_PORT;           SSH_PORT=$(get_conf SSH_PORT "$_DEFAULT_SSH_PORT")
    local FAIL2BAN_BANTIME;   FAIL2BAN_BANTIME=$(get_conf FAIL2BAN_BANTIME "$_DEFAULT_FAIL2BAN_BANTIME")
    local FAIL2BAN_FINDTIME;  FAIL2BAN_FINDTIME=$(get_conf FAIL2BAN_FINDTIME "$_DEFAULT_FAIL2BAN_FINDTIME")
    local FAIL2BAN_MAXRETRY;  FAIL2BAN_MAXRETRY=$(get_conf FAIL2BAN_MAXRETRY "$_DEFAULT_FAIL2BAN_MAXRETRY")

    # ── 预校验 ──
    log CHECK "[预校验] 检查 iptables 可用性..."
    if ! command -v iptables &>/dev/null; then
        log WARN "  iptables 未安装，将尝试安装"
        pkg_install iptables
    fi

    if ! command -v iptables &>/dev/null; then
        skip_step "$STEP_NUM" "iptables 不可用（fail2ban 的依赖）"
        return
    fi

    # ── 操作 ──
    log INFO "  安装 fail2ban..."
    pkg_install fail2ban || {
        case "$PKG_MANAGER" in
            zypper) pkg_install fail2ban ;;
        esac
    }

    sleep 1

    if ! command -v fail2ban-client &>/dev/null; then
        mark_step_fail "$STEP_NUM" "fail2ban 安装失败"
        return
    fi

    local JAIL_LOCAL="/etc/fail2ban/jail.local"
    if ! dry grep -q "secure-server-init" "$JAIL_LOCAL" 2>/dev/null; then
        log INFO "  生成 jail.local 配置..."

        local AUTH_LOG="/var/log/auth.log"
        [ -f "$AUTH_LOG" ] || AUTH_LOG="/var/log/secure"

        cat > /tmp/fail2ban-jail.local <<EOF
# 由 secure-server-init.sh 自动生成 — $(date)

[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
ignoreip = 127.0.0.1/8 ::1
backend  = auto
banaction = iptables-multiport

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = ${AUTH_LOG}
mode     = aggressive
maxretry = ${FAIL2BAN_MAXRETRY}
EOF
        dry mkdir -p /etc/fail2ban
        dry cp /tmp/fail2ban-jail.local "$JAIL_LOCAL"
    else
        log INFO "  jail.local 已由本脚本配置过，跳过"
    fi

    if command -v systemctl &>/dev/null; then
        dry systemctl enable fail2ban
        dry systemctl restart fail2ban
    else
        dry service fail2ban restart
    fi

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证 fail2ban 运行状态..."
    sleep 2

    if command -v fail2ban-client &>/dev/null; then
        if fail2ban-client ping &>/dev/null; then
            log INFO "  fail2ban 服务运行中 ✓"
        else
            log WARN "  fail2ban-client ping 失败"
            case "$OS_FAMILY" in
                rhel) tail -20 /var/log/fail2ban.log 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done ;;
                *)    journalctl -u fail2ban --no-pager -n 10 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done ;;
            esac
        fi

        if fail2ban-client status sshd &>/dev/null; then
            log INFO "  sshd jail 已启用 ✓"
        else
            log WARN "  sshd jail 未找到"
            fail2ban-client add sshd 2>/dev/null || true
        fi
    fi

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 4: 防火墙
# ══════════════════════════════════════════════════════════════════════════════

step_04_firewall() {
    local STEP_NUM="4"
    step_header "$STEP_NUM" "配置防火墙 (最小开放端口)"

    local SSH_PORT; SSH_PORT=$(get_conf SSH_PORT "$_DEFAULT_SSH_PORT")
    local UFW_PORTS; UFW_PORTS=$(get_conf UFW_PORTS "$_DEFAULT_UFW_PORTS")

    # ── 预校验 ──
    log CHECK "[预校验] 检查防火墙状态..."

    case "$FIREWALL_TOOL" in
        ufw)
            if ! command -v ufw &>/dev/null; then
                log INFO "  安装 ufw..."
                pkg_install ufw
            fi
            log INFO "  当前 ufw 状态: $(ufw status 2>/dev/null | head -1)"
            ;;

        firewalld)
            if ! command -v firewall-cmd &>/dev/null; then
                log INFO "  安装 firewalld..."
                pkg_install firewalld
                if command -v systemctl &>/dev/null; then
                    dry systemctl enable firewalld
                    dry systemctl start firewalld
                fi
            fi
            log INFO "  当前 firewalld 状态: $(firewall-cmd --state 2>/dev/null || echo '未运行')"
            ;;

        iptables)
            if ! command -v iptables &>/dev/null; then
                pkg_install iptables
            fi
            log INFO "  当前 iptables 规则数: $(iptables -L -n 2>/dev/null | wc -l)"
            ;;

        *)
            skip_step "$STEP_NUM" "无法确定防火墙工具"
            return
            ;;
    esac

    # ── 操作 ──
    case "$FIREWALL_TOOL" in
        ufw)
            log INFO "  配置 ufw..."
            dry ufw default deny incoming
            dry ufw default allow outgoing

            for port_spec in $UFW_PORTS; do
                dry ufw allow "$port_spec"
                log INFO "  开放端口: ${port_spec}"
            done

            if [ "$SSH_PORT" != "22" ]; then
                dry ufw allow "${SSH_PORT}/tcp"
                log INFO "  开放自定义 SSH 端口: ${SSH_PORT}/tcp"
            fi

            echo "y" | dry ufw enable
            ;;

        firewalld)
            log INFO "  配置 firewalld..."

            if ! systemctl is-active --quiet firewalld 2>/dev/null; then
                dry systemctl start firewalld
                sleep 1
            fi

            for port_spec in $UFW_PORTS; do
                local port="${port_spec%%/*}"
                local proto="${port_spec##*/}"
                dry firewall-cmd --permanent --add-port="${port}/${proto}" 2>/dev/null || true
                log INFO "  开放端口: ${port}/${proto}"
            done

            if [ "$SSH_PORT" != "22" ]; then
                dry firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
            fi

            dry firewall-cmd --reload
            ;;

        iptables)
            log INFO "  配置 iptables..."
            case "$PKG_MANAGER" in
                apt) dry apt-get install -y iptables-persistent ;;
                dnf|yum) dry "$PKG_MANAGER" install -y iptables-services ;;
            esac

            dry iptables -P INPUT DROP
            dry iptables -P FORWARD DROP
            dry iptables -P OUTPUT ACCEPT

            dry iptables -A INPUT -i lo -j ACCEPT
            dry iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

            for port_spec in $UFW_PORTS; do
                local port="${port_spec%%/*}"
                local proto="${port_spec##*/}"
                dry iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
                log INFO "  开放端口: ${port}/${proto}"
            done

            if [ "$SSH_PORT" != "22" ]; then
                dry iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
            fi

            case "$PKG_MANAGER" in
                apt) dry netfilter-persistent save 2>/dev/null || true ;;
                dnf|yum) dry service iptables save 2>/dev/null || true ;;
            esac
            ;;
    esac

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证防火墙规则..."

    case "$FIREWALL_TOOL" in
        ufw)
            dry ufw status verbose 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
            if ufw status 2>/dev/null | grep -q "Status: active"; then
                log INFO "  ufw 已激活 ✓"
            else
                log WARN "  ufw 可能未正确激活"
            fi
            ;;

        firewalld)
            dry firewall-cmd --list-all 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
            if firewall-cmd --state 2>/dev/null | grep -q "running"; then
                log INFO "  firewalld 正在运行 ✓"
            else
                log WARN "  firewalld 可能未运行"
            fi
            ;;

        iptables)
            dry iptables -L -n -v 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
            if iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT.*dpt:${SSH_PORT}"; then
                log INFO "  SSH 端口 ${SSH_PORT} 已开放 ✓"
            else
                log WARN "  未找到 SSH ${SSH_PORT} 的 ACCEPT 规则"
            fi
            ;;
    esac

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 5: 自动安全更新
# ══════════════════════════════════════════════════════════════════════════════

step_05_auto_updates() {
    local STEP_NUM="5"
    step_header "$STEP_NUM" "配置自动安全更新"

    case "$OS_FAMILY" in
        debian)
            log CHECK "[预校验] 检查 unattended-upgrades..."
            if ! dpkg -l unattended-upgrades &>/dev/null 2>&1; then
                log INFO "  安装 unattended-upgrades..."
                dry apt-get install -y unattended-upgrades
            fi

            log INFO "  启用自动安全更新..."
            cat > /tmp/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
            dry cp /tmp/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades

            local CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
            if [ -f "$CONF" ]; then
                dry sed -i 's|//\s*Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";|Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";|' "$CONF"
                dry sed -i 's|//\s*Unattended-Upgrade::Remove-Unused-Dependencies "true";|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' "$CONF"
                if ! grep -q 'Remove-Unused-Kernel-Packages' "$CONF"; then
                    echo 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' | dry tee -a "$CONF"
                fi
                if ! grep -q 'Remove-Unused-Dependencies' "$CONF"; then
                    echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' | dry tee -a "$CONF"
                fi
            fi

            log CHECK "[后置检查] 验证自动更新配置..."
            if dry unattended-upgrades --dry-run --debug 2>&1 | head -5 | while IFS= read -r l; do log INFO "    ${l}"; done; then
                log INFO "  自动更新配置有效 ✓"
            else
                log WARN "  自动更新 dry-run 出现问题"
            fi
            ;;

        rhel)
            log CHECK "[预校验] 检查 dnf-automatic..."
            if ! rpm -q dnf-automatic &>/dev/null 2>&1; then
                dry dnf install -y dnf-automatic
            fi

            log INFO "  配置 dnf-automatic..."
            dry sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
            dry sed -i 's/upgrade_type = default/upgrade_type = security/' /etc/dnf/automatic.conf 2>/dev/null || true

            if command -v systemctl &>/dev/null; then
                dry systemctl enable --now dnf-automatic.timer
            fi

            log CHECK "[后置检查] 验证 dnf-automatic..."
            if systemctl is-active dnf-automatic.timer &>/dev/null 2>&1; then
                log INFO "  dnf-automatic.timer 已激活 ✓"
            else
                log WARN "  dnf-automatic.timer 可能未激活"
            fi
            ;;

        suse)
            log INFO "  启用 zypper 自动补丁..."
            if command -v transactional-update &>/dev/null; then
                dry systemctl enable --now transactional-update.timer 2>/dev/null || true
            else
                pkg_install yast2-online-update-configuration 2>/dev/null || true
                if [ -f /etc/sysconfig/onlineupdate ]; then
                    dry sed -i 's/YAST2_ONLINE_UPDATE_AUTO_UPDATE="no"/YAST2_ONLINE_UPDATE_AUTO_UPDATE="yes"/' /etc/sysconfig/onlineupdate 2>/dev/null || true
                fi
                dry zypper install -y zypper-lifecycle-plugin 2>/dev/null || true
            fi
            log INFO "  openSUSE 自动更新已配置 ✓"
            ;;

        arch)
            log WARN "  Arch 官方不推荐全自动更新，请手动运行 pacman -Syu"
            log INFO "  安装 pacman-contrib..."
            dry pacman -S --noconfirm pacman-contrib 2>/dev/null || true
            ;;

        *)
            skip_step "$STEP_NUM" "不支持当前发行版的自动更新"
            return
            ;;
    esac

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 6: /tmp 加固 (nosuid,nodev)
# ══════════════════════════════════════════════════════════════════════════════

step_06_tmp_harden() {
    local STEP_NUM="6"
    step_header "$STEP_NUM" "/tmp 分区加固 (nosuid,nodev)"

    # ── 预校验 ──
    log CHECK "[预校验] 检查 /tmp 当前挂载状态..."
    mount | grep -E '[[:space:]]/tmp[[:space:]]' | while IFS= read -r l; do log INFO "  ${l}"; done

    local current_opts
    current_opts=$(findmnt -n -o OPTIONS /tmp 2>/dev/null)
    log INFO "  当前挂载选项: ${current_opts}"

    # ── 操作 ──
    local needs_remount=false

    if findmnt /tmp &>/dev/null; then
        log INFO "  /tmp 已单独挂载，修改 /etc/fstab 添加 nosuid,nodev..."
        if grep -E '^[^#].*[[:space:]]/tmp[[:space:]]' /etc/fstab | grep -qv 'nosuid'; then
            dry sed -i.bak-secure-tmp -E \
                's|^([^#].*[[:space:]]/tmp[[:space:]].*defaults)|\1,nosuid,nodev|' \
                /etc/fstab
            dry sed -i.bak-secure-tmp -E \
                's|^([^#].*[[:space:]]/tmp[[:space:]].*)([[:space:]]0[[:space:]]0)$|\1,nosuid,nodev\2|' \
                /etc/fstab
            needs_remount=true
        else
            log INFO "  /tmp 已有安全挂载选项，跳过"
        fi
    else
        if ! grep -qE '^[^#].*[[:space:]]/tmp[[:space:]]' /etc/fstab; then
            log INFO "  在 /etc/fstab 中添加 tmpfs /tmp..."
            echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0" | dry tee -a /etc/fstab
            needs_remount=true
        fi
    fi

    if [ "$needs_remount" = true ]; then
        log INFO "  重新挂载 /tmp..."
        dry mount -o remount /tmp 2>&1 || true
        dry mount -a 2>&1 || log WARN "  mount -a 可能有部分失败（/tmp 正忙），重启后生效"
    fi

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证 /tmp 挂载选项..."
    local new_opts
    new_opts=$(findmnt -n -o OPTIONS /tmp 2>/dev/null)
    log INFO "  最终挂载选项: ${new_opts}"

    echo "$new_opts" | grep -q 'nosuid' && log INFO "  nosuid 已启用 ✓" || log WARN "  nosuid 未生效（可能需要重启）"
    echo "$new_opts" | grep -q 'nodev'  && log INFO "  nodev 已启用 ✓"  || log WARN "  nodev 未生效（可能需要重启）"
    log INFO "  (已跳过 noexec，避免影响 AI agent 等工具的临时脚本执行)"

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 7: sysctl 内核安全参数
# ══════════════════════════════════════════════════════════════════════════════

step_07_sysctl() {
    local STEP_NUM="7"
    step_header "$STEP_NUM" "内核网络参数加固 (sysctl)"

    local SYSCTL_FILE="/etc/sysctl.d/99-security.conf"

    # ── 预校验 ──
    log CHECK "[预校验] 检查 sysctl 是否可用..."
    if ! command -v sysctl &>/dev/null; then
        skip_step "$STEP_NUM" "sysctl 命令不可用"
        return
    fi

    # ── 操作 ──
    if [ -f "$SYSCTL_FILE" ] && grep -q "secure-server-init" "$SYSCTL_FILE" 2>/dev/null; then
        log INFO "  ${SYSCTL_FILE} 已由本脚本配置过，跳过"
    else
        log INFO "  写入内核安全参数到 ${SYSCTL_FILE}..."
        cat > /tmp/99-security.conf <<'EOF'
# 由 secure-server-init.sh 自动生成
# ── IP 欺骗保护 ──
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# ── 不接受源路由包 ──
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# ── 忽略 ICMP 重定向 ──
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# ── 忽略错误的 ICMP 消息 ──
net.ipv4.icmp_ignore_bogus_error_responses = 1
# ── SYN Cookie 防 SYN flood ──
net.ipv4.tcp_syncookies = 1
# ── 记录 martian 包 ──
net.ipv4.conf.all.log_martians = 1
# ── 不充当路由器 ──
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
# ── 不发送 ICMP 重定向 ──
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
        dry cp /tmp/99-security.conf "$SYSCTL_FILE"
        dry chmod 644 "$SYSCTL_FILE"
    fi

    log INFO "  应用 sysctl 参数..."
    dry sysctl -p "$SYSCTL_FILE" 2>&1 | while IFS= read -r l; do log INFO "    ${l}"; done

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证关键参数..."
    local params=(
        "net.ipv4.tcp_syncookies"
        "net.ipv4.conf.all.rp_filter"
        "net.ipv4.conf.all.accept_source_route"
        "net.ipv4.conf.all.accept_redirects"
        "net.ipv4.ip_forward"
    )
    local all_ok=true
    for param in "${params[@]}"; do
        local val
        val=$(sysctl -n "$param" 2>/dev/null)
        if [ -n "$val" ]; then
            log INFO "  ${param} = ${val} ✓"
        else
            log WARN "  无法读取 ${param}"
            all_ok=false
        fi
    done

    [ "$all_ok" = true ] && mark_step_ok "$STEP_NUM" || mark_step_fail "$STEP_NUM" "部分 sysctl 参数读取失败"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 8: 日志管理
# ══════════════════════════════════════════════════════════════════════════════

step_08_logging() {
    local STEP_NUM="8"
    step_header "$STEP_NUM" "日志管理 (logrotate + journald 限制)"

    # ── 预校验 ──
    log CHECK "[预校验] 检查系统日志工具..."
    local has_journald=false

    if command -v journalctl &>/dev/null; then
        has_journald=true
        log INFO "  systemd-journald 可用"
    fi

    if ! command -v logrotate &>/dev/null; then
        log INFO "  安装 logrotate..."
        pkg_install logrotate 2>/dev/null || log WARN "  logrotate 安装失败"
    fi

    # ── 操作：journald ──
    if [ "$has_journald" = true ]; then
        log INFO "  配置 journald 大小限制..."
        local JDROP="/etc/systemd/journald.conf.d"
        dry mkdir -p "$JDROP"
        cat > /tmp/99-secure-journald.conf <<EOF
# 由 secure-server-init.sh 自动生成 — $(date)
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=100M
MaxRetentionSec=2week
ForwardToSyslog=yes
EOF
        dry cp /tmp/99-secure-journald.conf "${JDROP}/99-secure-journald.conf"
        dry systemctl restart systemd-journald 2>/dev/null || true
    fi

    # ── 操作：logrotate ──
    if command -v logrotate &>/dev/null; then
        log INFO "  配置 syslog 日志轮转..."
        local LR_CONF="/etc/logrotate.d/secure-init"
        local SYSLOG_FILES=()
        [ -f /var/log/syslog ]  && SYSLOG_FILES+=("/var/log/syslog")
        [ -f /var/log/messages ] && SYSLOG_FILES+=("/var/log/messages")
        [ -f /var/log/auth.log ] && SYSLOG_FILES+=("/var/log/auth.log")
        [ -f /var/log/secure ]   && SYSLOG_FILES+=("/var/log/secure")
        [ -f /var/log/kern.log ] && SYSLOG_FILES+=("/var/log/kern.log")

        if [ ${#SYSLOG_FILES[@]} -gt 0 ]; then
            {
                printf '# 由 secure-server-init.sh 自动生成 — %s\n' "$(date)"
                printf '%s\n' "${SYSLOG_FILES[@]}"
                cat <<'EOF'
{
    rotate 7
    daily
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || true
    endscript
}
EOF
            } > /tmp/secure-init-logrotate
            dry cp /tmp/secure-init-logrotate "$LR_CONF"
            log INFO "  已配置日志轮转: ${SYSLOG_FILES[*]}"
        else
            log WARN "  未找到常见系统日志文件"
        fi
    fi

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证日志配置..."
    if [ "$has_journald" = true ]; then
        systemctl is-active systemd-journald &>/dev/null 2>&1 \
            && log INFO "  journald 运行中 ✓" \
            || log WARN "  journald 未运行"
    fi
    if command -v logrotate &>/dev/null; then
        logrotate -d /etc/logrotate.conf &>/dev/null 2>&1 \
            && log INFO "  logrotate 配置语法正常 ✓" \
            || log WARN "  logrotate 配置可能有语法问题"
    fi

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 9: 审查开放端口和服务
# ══════════════════════════════════════════════════════════════════════════════

step_09_audit_ports() {
    local STEP_NUM="9"
    step_header "$STEP_NUM" "审查开放端口和运行服务"

    # ── 预校验 ──
    log CHECK "[预校验] 收集当前监听端口..."
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        skip_step "$STEP_NUM" "既没有 ss 也没有 netstat，无法审计"
        return
    fi

    # ── 操作 ──
    log INFO "  当前监听端口 (TCP/UDP):"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
        ss -ulnp 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
    fi

    log INFO ""
    log INFO "  当前已启用的服务 (systemd):"
    if command -v systemctl &>/dev/null; then
        systemctl list-unit-files --type=service --state=enabled 2>/dev/null | \
            grep -v '^$' | while IFS= read -r l; do log INFO "    ${l}"; done
    elif [ -d /etc/rc.d ]; then
        log INFO "  (SysV init 环境，请手动检查 /etc/rc.d/)"
    fi

    # ── 后置检查 ──
    log CHECK "[后置检查] 审计完成 — 请人工审查以上输出，关闭不需要的服务"
    log WARN "  常见可关闭的服务: cups, bluetooth, avahi-daemon, rpcbind, snapd (如不需要)"

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 10: NTP 时间同步
# ══════════════════════════════════════════════════════════════════════════════

step_10_ntp() {
    local STEP_NUM="10"
    step_header "$STEP_NUM" "NTP 时间同步"

    # ── 预校验 ──
    log CHECK "[预校验] 检查当前时间同步状态..."
    if command -v timedatectl &>/dev/null; then
        timedatectl status 2>/dev/null | while IFS= read -r l; do log INFO "    ${l}"; done
    fi

    # ── 操作 ──
    if command -v timedatectl &>/dev/null; then
        log INFO "  启用 systemd-timesyncd..."
        dry timedatectl set-ntp true 2>/dev/null || log WARN "  无法通过 timedatectl 启用 NTP"
    elif command -v chronyd &>/dev/null; then
        log INFO "  chronyd 已存在，确保运行..."
        if command -v systemctl &>/dev/null; then
            dry systemctl enable --now chronyd
        fi
    else
        log INFO "  安装 chrony..."
        pkg_install chrony 2>/dev/null || log WARN "  chrony 安装失败"
        if command -v chronyd &>/dev/null; then
            if command -v systemctl &>/dev/null; then
                dry systemctl enable --now chronyd
            else
                dry service chronyd start
            fi
        fi
    fi

    # ── 后置检查 ──
    log CHECK "[后置检查] 验证时间同步..."
    sleep 2
    local check_ok=false

    if command -v timedatectl &>/dev/null; then
        if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
            log INFO "  NTP 时间已同步 ✓"
            check_ok=true
        fi
    fi

    if [ "$check_ok" = false ] && command -v chronyc &>/dev/null; then
        if chronyc tracking 2>/dev/null | grep -q 'Reference ID'; then
            log INFO "  chrony 正在同步 ✓"
            check_ok=true
        fi
    fi

    [ "$check_ok" = false ] && log WARN "  无法确认时间同步状态，请手动检查"

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  步骤 11: rkhunter (可选)
# ══════════════════════════════════════════════════════════════════════════════

step_11_rkhunter() {
    local STEP_NUM="11"
    step_header "$STEP_NUM" "安装 rkhunter (rootkit 扫描)"

    # ── 预校验 ──
    log CHECK "[预校验] 检查 rkhunter..."
    if command -v rkhunter &>/dev/null; then
        log INFO "  rkhunter 已安装，将更新特征库并运行基线扫描"
    else
        pkg_install rkhunter || {
            log WARN "  rkhunter 安装失败（部分发行版仓库未收录），跳过"
            skip_step "$STEP_NUM" "rkhunter 不可用"
            return
        }
    fi

    # ── 操作 ──
    log INFO "  更新 rkhunter 特征库..."
    dry rkhunter --update 2>&1 | while IFS= read -r l; do log INFO "    ${l}"; done

    log INFO "  运行系统检查..."
    dry rkhunter --check --skip-keypress 2>&1 | while IFS= read -r l; do log INFO "    ${l}"; done

    # ── 后置检查 ──
    log CHECK "[后置检查] rkhunter 扫描完成"
    log WARN "  注意：首次运行会有误报（如 sshd PermitRootLogin 警告），已知即可"
    log INFO "  运行 'rkhunter --propupd' 可存储当前文件基线以减少后续误报"

    mark_step_ok "$STEP_NUM"
}


# ══════════════════════════════════════════════════════════════════════════════
#  生成示例配置文件
# ══════════════════════════════════════════════════════════════════════════════

generate_config() {
    local out_file="${1:-./secure-server-init.conf}"
    if [ -f "$out_file" ]; then
        log WARN "文件已存在: ${out_file}"
        if ! confirm "是否覆盖？" "N"; then
            log INFO "跳过生成"
            return
        fi
    fi

    cat > "$out_file" <<'CONFEOF'
# =============================================================================
# secure-server-init.conf — 服务器安全初始化配置文件
#
# 配置优先级（高→低）：
#   1. 运行时环境变量 (export SSH_PORT=2222)
#   2. 本配置文件
#   3. 脚本内置默认值
#
# 使用方式：
#   - 修改此文件后运行: sudo bash secure-server-init.sh
#   - 指定配置文件:    sudo bash secure-server-init.sh --config /path/to/this.conf
#   - 放置位置:        当前目录 (./secure-server-init.conf) 或 /etc/secure-server-init.conf
# =============================================================================

# ── 步骤开关 (true=执行, false=跳过) ──────────────────────────────────────────

SECURE_STEP_00_ENABLED=true    # 系统软件包更新
SECURE_STEP_01_ENABLED=true    # 创建管理员用户 & sudo
SECURE_STEP_02_ENABLED=true    # SSH 加固
SECURE_STEP_03_ENABLED=true    # fail2ban 防暴力破解
SECURE_STEP_04_ENABLED=true    # 防火墙
SECURE_STEP_05_ENABLED=true    # 自动安全更新
SECURE_STEP_06_ENABLED=true    # /tmp 加固 (nosuid,nodev)
SECURE_STEP_07_ENABLED=true    # sysctl 内核参数加固
SECURE_STEP_08_ENABLED=true    # 日志管理 (logrotate + journald)
SECURE_STEP_09_ENABLED=true    # 审查开放端口和服务
SECURE_STEP_10_ENABLED=true    # NTP 时间同步
SECURE_STEP_11_ENABLED=false   # rkhunter (可选, 默认关闭)

# ── 基础参数 ──────────────────────────────────────────────────────────────────

# SSH 端口 (默认 22，改为其他端口需同步修改防火墙端口列表)
SSH_PORT=22

# 管理员用户名 (将被创建并加入 sudo/wheel 组)
ADMIN_USER=deploy

# SSH 允许登录的用户名列表 (空格分隔，留空表示不限制)
# 示例: SSH_ALLOW_USERS="deploy ops"
SSH_ALLOW_USERS=""

# ── fail2ban 参数 ────────────────────────────────────────────────────────────

FAIL2BAN_BANTIME=3600     # 封禁时长 (秒)，默认 3600 = 1 小时
FAIL2BAN_FINDTIME=600     # 统计窗口 (秒)，默认 600 = 10 分钟
FAIL2BAN_MAXRETRY=3       # 最大尝试次数

# ── 防火墙开放端口 (空格分隔的 port/proto 列表) ──────────────────────────────
# 注意：SSH 端口由 SSH_PORT 控制，防火墙会自动开放对应端口，不需要在这里重复添加

UFW_PORTS="22/tcp 80/tcp 443/tcp"

# ── 常用场景示例 ─────────────────────────────────────────────────────────────
# 场景 1: 仅 Web 服务器 (SSH + HTTP + HTTPS)
#   UFW_PORTS="22/tcp 80/tcp 443/tcp"
#
# 场景 2: Web + 数据库 (内网访问 MySQL)
#   UFW_PORTS="22/tcp 80/tcp 443/tcp 3306/tcp"
#
# 场景 3: 仅开发机 (只 SSH)
#   SECURE_STEP_00_ENABLED=false   # 不自动更新
#   SECURE_STEP_04_ENABLED=false   # 不配置防火墙 (可能在公司内网)
#   UFW_PORTS="22/tcp"
#
# 场景 4: 已有密钥，只做系统加固 (跳过用户创建和 SSH)
#   SECURE_STEP_01_ENABLED=false
#   SECURE_STEP_02_ENABLED=false
#
# 场景 5: 纯检查模式 (什么都不改，只看审计报告)
#   SECURE_STEP_00_ENABLED=false
#   ... 全部步骤改为 false ...
#   SECURE_STEP_09_ENABLED=true    # 只审计端口和服务
#   # 然后运行: sudo bash secure-server-init.sh --dry-run
CONFEOF

    log INFO "示例配置文件已生成: ${out_file}"
    log INFO "编辑此文件后运行: sudo bash secure-server-init.sh"
}


# ══════════════════════════════════════════════════════════════════════════════
#  主流程
# ══════════════════════════════════════════════════════════════════════════════

usage() {
    cat <<EOF
用法: sudo bash $SCRIPT_NAME [选项]

选项:
  --dry-run           仅探测和检查，不执行任何修改
  --step N            仅执行步骤 N (0-11)
  --config FILE       指定配置文件 (默认按顺序查找:
                         1. --config 指定的文件
                         2. ./secure-server-init.conf
                         3. /etc/secure-server-init.conf
                         4. 均不存在则使用内置默认值)
  --generate-config [FILE]  生成示例配置文件 (默认写到 ./secure-server-init.conf)
  --help, -h          显示此帮助

步骤列表:
  0  - 系统软件包更新            6  - /tmp 分区加固
  1  - 创建管理员用户 & sudo      7  - sysctl 内核参数加固
  2  - SSH 加固                  8  - 日志管理
  3  - fail2ban 防暴力破解        9  - 审查开放端口和服务
  4  - 防火墙 (最小开放端口)      10 - NTP 时间同步
  5  - 自动安全更新              11 - rkhunter (可选, 默认关闭)

配置：
  配置文件可控制每个步骤的开关和参数值。
  环境变量优先级高于配置文件中的同名变量。

示例:
  # 完整初始化 (使用默认配置)
  sudo bash $SCRIPT_NAME

  # 仅探测，不修改
  sudo bash $SCRIPT_NAME --dry-run

  # 生成配置文件并编辑后再运行
  sudo bash $SCRIPT_NAME --generate-config
  vim secure-server-init.conf
  sudo bash $SCRIPT_NAME

  # 临时覆盖某个参数 (环境变量方式)
  SSH_PORT=2222 ADMIN_USER=myuser sudo bash $SCRIPT_NAME

  # 仅执行 SSH 加固
  sudo bash $SCRIPT_NAME --step 2

  # 跳过用户创建和 SSH，只做系统加固
  SECURE_STEP_01_ENABLED=false SECURE_STEP_02_ENABLED=false sudo bash $SCRIPT_NAME
EOF
    exit 0
}

print_summary() {
    echo ""
    log STEP "════════════════════════════════════════════════════════════════"
    log STEP "  执行摘要"
    log STEP "════════════════════════════════════════════════════════════════"

    local step_names=(
        [0]="系统软件包更新"
        [1]="创建管理员用户 & sudo"
        [2]="SSH 加固"
        [3]="fail2ban"
        [4]="防火墙"
        [5]="自动安全更新"
        [6]="/tmp 分区加固"
        [7]="内核网络参数加固"
        [8]="日志管理"
        [9]="审查开放端口和服务"
        [10]="NTP 时间同步"
        [11]="rkhunter"
    )

    for i in $(seq 0 11); do
        local status="${STEP_RESULTS[$i]:-NOT_RUN}"
        local name="${step_names[$i]:-步骤 ${i}}"
        case "$status" in
            OK)      log INFO  "  [✓] 步骤 ${i}: ${name}"  ;;
            FAILED)  log ERROR "  [✗] 步骤 ${i}: ${name} — 失败" ;;
            SKIPPED) log WARN  "  [−] 步骤 ${i}: ${name} — 已跳过" ;;
            NOT_RUN) log INFO  "  [ ] 步骤 ${i}: ${name} — 未执行" ;;
        esac
    done

    log STEP "────────────────────────────────────────────────────────────────"
    if [ "$OVERALL_SUCCESS" = true ]; then
        log INFO  "  总体状态: 成功 ✓"
    else
        log ERROR "  总体状态: 存在失败步骤 ✗"
    fi
    log INFO  "  详细日志: ${LOG_FILE}"
    log STEP "════════════════════════════════════════════════════════════════"

    echo ""
    log WARN "⚠ 重要提醒:"
    log WARN "  1. 如果修改了 SSH 配置，请保持当前会话打开，新开终端测试能否登录后再断开"
    log WARN "  2. 如果启用了防火墙，请确认已开放你需要的所有端口"
    log WARN "  3. 建议重启服务器后验证所有服务是否正常"
}


main() {
    # 解析参数
    local gen_config_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)          DRY_RUN=true; shift ;;
            --step)             SINGLE_STEP="$2"; shift 2 ;;
            --config)           CONFIG_FILE="$2"; shift 2 ;;
            --generate-config)  shift
                                if [ $# -gt 0 ] && [ "${1:0:1}" != "-" ]; then
                                    gen_config_path="$1"; shift
                                else
                                    gen_config_path="./secure-server-init.conf"
                                fi
                                ;;
            --help|-h)          usage ;;
            *) log WARN "未知参数: $1"; shift ;;
        esac
    done

    # 生成配置文件模式
    if [ -n "$gen_config_path" ]; then
        generate_config "$gen_config_path"
        exit 0
    fi

    # 权限检查
    if [ "$EUID" -ne 0 ]; then
        die "请用 sudo 运行此脚本"
    fi

    # 初始化日志
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/secure-server-init.log"
    log INFO "${COLOR_BOLD}secure-server-init.sh 启动${COLOR_RESET}"
    log INFO "系统: $(uname -a)"
    log INFO "日志文件: ${LOG_FILE}"
    [ "$DRY_RUN" = true ] && log WARN "*** DRY-RUN 模式 — 不会做任何修改 ***"

    # 探测系统
    detect_os

    # 加载配置（内置默认 → 配置文件 → 环境变量覆盖）
    resolve_config

    # 打印生效的配置 (方便调试)
    log INFO "──────────── 当前生效配置 ────────────"
    log INFO "  SECURE_STEP_00_ENABLED = $(get_conf SECURE_STEP_00_ENABLED "$_DEFAULT_SECURE_STEP_00_ENABLED")"
    log INFO "  SECURE_STEP_01_ENABLED = $(get_conf SECURE_STEP_01_ENABLED "$_DEFAULT_SECURE_STEP_01_ENABLED")"
    log INFO "  SECURE_STEP_02_ENABLED = $(get_conf SECURE_STEP_02_ENABLED "$_DEFAULT_SECURE_STEP_02_ENABLED")"
    log INFO "  SECURE_STEP_03_ENABLED = $(get_conf SECURE_STEP_03_ENABLED "$_DEFAULT_SECURE_STEP_03_ENABLED")"
    log INFO "  SECURE_STEP_04_ENABLED = $(get_conf SECURE_STEP_04_ENABLED "$_DEFAULT_SECURE_STEP_04_ENABLED")"
    log INFO "  SECURE_STEP_05_ENABLED = $(get_conf SECURE_STEP_05_ENABLED "$_DEFAULT_SECURE_STEP_05_ENABLED")"
    log INFO "  SECURE_STEP_06_ENABLED = $(get_conf SECURE_STEP_06_ENABLED "$_DEFAULT_SECURE_STEP_06_ENABLED")"
    log INFO "  SECURE_STEP_07_ENABLED = $(get_conf SECURE_STEP_07_ENABLED "$_DEFAULT_SECURE_STEP_07_ENABLED")"
    log INFO "  SECURE_STEP_08_ENABLED = $(get_conf SECURE_STEP_08_ENABLED "$_DEFAULT_SECURE_STEP_08_ENABLED")"
    log INFO "  SECURE_STEP_09_ENABLED = $(get_conf SECURE_STEP_09_ENABLED "$_DEFAULT_SECURE_STEP_09_ENABLED")"
    log INFO "  SECURE_STEP_10_ENABLED = $(get_conf SECURE_STEP_10_ENABLED "$_DEFAULT_SECURE_STEP_10_ENABLED")"
    log INFO "  SECURE_STEP_11_ENABLED = $(get_conf SECURE_STEP_11_ENABLED "$_DEFAULT_SECURE_STEP_11_ENABLED")"
    log INFO "  SSH_PORT          = $(get_conf SSH_PORT "$_DEFAULT_SSH_PORT")"
    log INFO "  ADMIN_USER        = $(get_conf ADMIN_USER "$_DEFAULT_ADMIN_USER")"
    log INFO "  UFW_PORTS         = $(get_conf UFW_PORTS "$_DEFAULT_UFW_PORTS")"
    log INFO "──────────────────────────────────────"

    # 定义步骤列表（函数名 + 开关变量名）
    local STEP_DEFS=(
        "step_00_system_update:SECURE_STEP_00_ENABLED"
        "step_01_user_sudo:SECURE_STEP_01_ENABLED"
        "step_02_ssh_harden:SECURE_STEP_02_ENABLED"
        "step_03_fail2ban:SECURE_STEP_03_ENABLED"
        "step_04_firewall:SECURE_STEP_04_ENABLED"
        "step_05_auto_updates:SECURE_STEP_05_ENABLED"
        "step_06_tmp_harden:SECURE_STEP_06_ENABLED"
        "step_07_sysctl:SECURE_STEP_07_ENABLED"
        "step_08_logging:SECURE_STEP_08_ENABLED"
        "step_09_audit_ports:SECURE_STEP_09_ENABLED"
        "step_10_ntp:SECURE_STEP_10_ENABLED"
        "step_11_rkhunter:SECURE_STEP_11_ENABLED"
    )

    if [ -n "$SINGLE_STEP" ]; then
        # 单步模式：不管开关，强制执行
        if [ "$SINGLE_STEP" -ge 0 ] 2>/dev/null && [ "$SINGLE_STEP" -le 11 ]; then
            local entry="${STEP_DEFS[$SINGLE_STEP]}"
            local func="${entry%%:*}"
            "$func"
        else
            die "无效的步骤编号: ${SINGLE_STEP} (有效范围: 0-11)"
        fi
    else
        # 全量模式：根据开关决定是否执行
        local step_idx=0
        for entry in "${STEP_DEFS[@]}"; do
            local func="${entry%%:*}"
            local switch="${entry##*:}"
            local default_val
            default_val=$(eval "echo \$_DEFAULT_${switch}")

            if step_enabled "$switch"; then
                "$func"
            else
                skip_step "$step_idx" "配置文件中 ${switch}=false"
            fi
            step_idx=$((step_idx + 1))
        done
    fi

    print_summary
}

main "$@"
