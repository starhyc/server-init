#!/usr/bin/env bash
# =============================================================================
# install-docker.sh — 一键安装 Docker Engine + Compose
#
# 从 Docker 官方源安装 docker-ce / containerd.io / buildx / compose 插件，
# 自动清理旧版本、添加用户组、启动服务。
#
# 支持: Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch
#
# 用法:
#   sudo bash install-docker.sh                # 安装最新版
#   sudo bash install-docker.sh --dry-run      # 预览模式
#   sudo bash install-docker.sh --force        # 强制覆盖安装
#   sudo bash install-docker.sh --user deploy  # 将指定用户加入 docker 组
# =============================================================================

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
FORCE=false
BATCH_MODE=false
DOCKER_USER="${SUDO_USER:-}"
CREATE_DOCKER_USER=false
DOCKER_NEW_USER="docker"
DOCKER_REGISTRY_MIRROR=""
# 保存当前 tty，管道执行时从 /dev/tty 读取用户输入
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

# ── 参数解析 ──

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --force)      FORCE=true; shift ;;
        --batch)      BATCH_MODE=true; shift ;;
        --user)       DOCKER_USER="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
用法: sudo bash $SCRIPT_NAME [选项]

无参数       交互式安装（会提示用户/用户组等配置）
--batch      非交互模式，使用默认值或 --user 指定用户
--dry-run    预览模式，仅显示操作不执行
--force      强制重新安装（剥离旧版本后重装）
--user NAME  将指定用户加入 docker 组
-h, --help   显示此帮助

安装内容:
  docker-ce  docker-ce-cli  containerd.io  buildx  compose
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

# ── 检查已有安装 ─────────────────────────────────────────────────────────────

if [ "$FORCE" != true ] && command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version 2>/dev/null || true)
    log INFO "Docker 已安装 ($DOCKER_VER)"
    if docker info &>/dev/null 2>&1; then
        log INFO "Docker 服务运行中 ✓"
    else
        log WARN "Docker 守护进程未运行，将尝试启动"
        if command -v systemctl &>/dev/null; then
            dry systemctl start docker 2>/dev/null || true
        fi
    fi
    # 仍然继续，因为可能需要安装 Compose 插件
    if docker compose version &>/dev/null 2>&1; then
        docker compose version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
        log INFO "所有组件已就绪，退出"
        exit 0
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  交互式配置
# ══════════════════════════════════════════════════════════════════════════════

if [ "$BATCH_MODE" = false ] && [ "$DRY_RUN" = false ] && [ -e /dev/tty ]; then
    echo ""
    log STEP "── 用户配置..."

    # ── 问题 1: 是否创建 docker 专属用户 ──
    if [ -z "$DOCKER_USER" ] || [ "$DOCKER_USER" = "root" ]; then
        printf "  ${C_B}是否创建专用的 docker 管理用户？ (y/N) [N] > ${C_R}"
        read -r create_yn < /dev/tty
        case "$create_yn" in
            y|Y|yes|YES)
                CREATE_DOCKER_USER=true
                printf "  ${C_B}用户名 [docker] > ${C_R}"
                read -r newuser < /dev/tty
                [ -n "$newuser" ] && DOCKER_NEW_USER="$newuser"

                # 创建用户
                if id "$DOCKER_NEW_USER" &>/dev/null 2>&1; then
                    log WARN "用户 '${DOCKER_NEW_USER}' 已存在，将仅加入 docker 组"
                    DOCKER_USER="$DOCKER_NEW_USER"
                else
                    useradd -m -s /bin/bash "$DOCKER_NEW_USER" && \
                        log INFO "用户 '${DOCKER_NEW_USER}' 已创建 ✓"
                    log WARN "请为用户 '${DOCKER_NEW_USER}' 设置密码:"
                    passwd "$DOCKER_NEW_USER" < /dev/tty || log WARN "密码设置被跳过"
                    DOCKER_USER="$DOCKER_NEW_USER"
                fi
                ;;
            *)  ;;
        esac
    fi

    # ── 问题 2: sudo 调用者是否加入 docker 组 ──
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        if [ "$DOCKER_USER" = "$SUDO_USER" ] || [ -z "$DOCKER_USER" ]; then
            printf "  ${C_B}将当前用户 '${SUDO_USER}' 加入 docker 组？ (Y/n) [Y] > ${C_R}"
            read -r add_yn < /dev/tty
            case "$add_yn" in
                n|N|no|NO) ;;
                *) DOCKER_USER="$SUDO_USER" ;;
            esac
        fi
    fi

    # ── 问题 3: Docker 镜像加速 ──
    printf "  ${C_B}配置 Docker 镜像加速地址？\n  留空跳过，常用: https://mirror.gcr.io https://docker.m.daocloud.io\n  > ${C_R}"
    read -r mirror_input < /dev/tty
    if [ -n "$mirror_input" ]; then
        DOCKER_REGISTRY_MIRROR="$mirror_input"
    fi

    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
#  安装（按发行版）
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 安装 Docker Engine..."

# ── 通用：清理冲突包 ──

_remove_conflicts() {
    case "$OS_ID" in
        ubuntu|debian)
            for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
                dpkg -s "$pkg" &>/dev/null 2>&1 && dry apt-get remove -y "$pkg" && log INFO "  已移除: $pkg"
            done
            ;;
        fedora|rhel)
            for pkg in docker docker-client docker-client-latest docker-common docker-latest \
                       docker-latest-logrotate docker-logrotate docker-engine podman runc; do
                rpm -q "$pkg" &>/dev/null 2>&1 && dry dnf remove -y "$pkg" && log INFO "  已移除: $pkg"
            done
            ;;
        suse)
            rpm -q docker &>/dev/null 2>&1 && dry zypper remove -y docker && log INFO "  已移除旧 docker"
            ;;
        arch)
            pacman -Q podman-docker &>/dev/null 2>&1 && dry pacman -R --noconfirm podman-docker && log INFO "  已移除 podman-docker"
            ;;
    esac
}

_remove_conflicts

# ── 安装 ──

case "$OS_ID" in
    ubuntu|debian)
        # 添加 Docker 官方 GPG 密钥（现代方式：放 keyrings 目录）
        dry install -m 0755 -d /etc/apt/keyrings
        gpg_url="https://download.docker.com/linux/${OS_ID}/gpg"
        if [ "$DRY_RUN" = false ]; then
            curl -fsSL "$gpg_url" -o /etc/apt/keyrings/docker.asc || die "Docker GPG 密钥下载失败"
            chmod a+r /etc/apt/keyrings/docker.asc
        else
            log WARN "[DRY] curl -fsSL $gpg_url"
        fi
        log INFO "Docker GPG 密钥已添加 ✓"

        # 添加 apt 源
        codename=$( (. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") 2>/dev/null || echo "stable" )
        arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${codename} stable"
        echo "$repo_line" | dry tee /etc/apt/sources.list.d/docker.list > /dev/null
        log INFO "Docker apt 源已添加 ✓"

        dry apt-get update -y
        dry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;

    fedora|rhel)
        dry dnf install -y dnf-plugins-core 2>/dev/null || dry yum install -y yum-utils 2>/dev/null

        if [ "$OS_ID" = "fedora" ]; then
            repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
        else
            repo_url="https://download.docker.com/linux/rhel/docker-ce.repo"
        fi

        if command -v dnf &>/dev/null; then
            dry dnf config-manager --add-repo "$repo_url"
            dry dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        else
            dry yum-config-manager --add-repo "$repo_url"
            dry yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
        ;;

    suse)
        dry zypper refresh
        # openSUSE 官方源自带 docker + docker-compose
        dry zypper install -y docker docker-compose
        ;;

    arch)
        dry pacman -Sy --noconfirm docker docker-compose
        ;;
esac

if [ "$DRY_RUN" = false ]; then
    command -v docker &>/dev/null || die "Docker 安装失败"
    docker --version 2>/dev/null | while IFS= read -r l; do log INFO "  ${l}"; done
fi

# ══════════════════════════════════════════════════════════════════════════════
#  启动服务
# ══════════════════════════════════════════════════════════════════════════════

log STEP "── 启动 Docker 守护进程..."

if command -v systemctl &>/dev/null; then
    dry systemctl enable docker 2>/dev/null || true
    dry systemctl start docker 2>/dev/null || true

    if [ "$DRY_RUN" = false ]; then
        if systemctl is-active docker &>/dev/null 2>&1; then
            log INFO "Docker 守护进程已启动 ✓"
        else
            log WARN "Docker 未启动，可能是 cgroup/snap 冲突，请手动排查"
        fi
    fi
else
    dry service docker start 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════════════════
#  镜像加速
# ══════════════════════════════════════════════════════════════════════════════

if [ -n "$DOCKER_REGISTRY_MIRROR" ]; then
    log STEP "── 配置 Docker 镜像加速..."

    if [ "$DRY_RUN" = true ]; then
        log WARN "[DRY] 写入 /etc/docker/daemon.json"
    else
        dry mkdir -p /etc/docker

        # 构建 JSON 数组
        first=true
        mirrors_json=""
        for m in $DOCKER_REGISTRY_MIRROR; do
            if $first; then
                mirrors_json="    \"$m\""
                first=false
            else
                mirrors_json="${mirrors_json},\n    \"$m\""
            fi
        done

        if [ -f /etc/docker/daemon.json ]; then
            cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$(date +%Y%m%d-%H%M%S)"
            log WARN "已有 daemon.json 将被覆盖，旧文件已备份"
        fi

        printf '{\n  "registry-mirrors": [\n%s\n  ]\n}\n' "$mirrors_json" \
            | dry tee /etc/docker/daemon.json > /dev/null
        log INFO "镜像加速写入 /etc/docker/daemon.json ✓"

        dry systemctl restart docker 2>/dev/null || dry service docker restart 2>/dev/null || true
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  用户组
# ══════════════════════════════════════════════════════════════════════════════

if [ -n "$DOCKER_USER" ]; then
    log STEP "── 将用户 '${DOCKER_USER}' 加入 docker 组..."

    if id "$DOCKER_USER" &>/dev/null 2>&1; then
        dry usermod -aG docker "$DOCKER_USER"
        if [ "$DRY_RUN" = false ]; then
            if groups "$DOCKER_USER" 2>/dev/null | grep -qw docker; then
                log INFO "用户 '${DOCKER_USER}' 已加入 docker 组 ✓"
                log WARN "注意: 需重新登录或执行 'newgrp docker' 才能使组权限生效"
            else
                log WARN "加入 docker 组失败，请手动执行: usermod -aG docker ${DOCKER_USER}"
            fi
        fi
    else
        log WARN "用户 '${DOCKER_USER}' 不存在，跳过"
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
    docker --version 2>/dev/null | while IFS= read -r l; do log INFO "  docker:   ${l}"; done
    containerd --version 2>/dev/null | while IFS= read -r l; do log INFO "  containerd: ${l}"; done
    docker compose version 2>/dev/null | while IFS= read -r l; do log INFO "  compose:  ${l}"; done
    docker buildx version 2>/dev/null | while IFS= read -r l; do log INFO "  buildx:   ${l}"; done

    echo ""
    if docker info &>/dev/null 2>&1; then
        log INFO "Docker 运行正常 ✓"
    else
        log WARN "Docker 可能未正常启动，请检查: journalctl -u docker"
    fi
fi

# ── 结果 ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$DRY_RUN" = true ]; then
    log WARN "预览模式完成。正式安装请运行: sudo bash ${SCRIPT_NAME}"
else
    log STEP "Docker 安装完成！"
    echo ""
    if [ -n "$DOCKER_USER" ]; then
        log INFO "用户 '${DOCKER_USER}' 需重新登录后生效: su - ${DOCKER_USER}"
    fi
fi
