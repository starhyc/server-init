# server-init

新购个人服务器一键安全初始化脚本，交互式菜单向导，5 分钟完成基础加固。

## 一行命令

```bash
curl -fsSL https://raw.githubusercontent.com/starhyc/server-init/main/secure-server-init.sh | sudo bash
```

## 核心功能

| 步骤 | 内容 |
|------|------|
| 系统更新 | 更新全部软件包到最新版本 |
| 管理员用户 | 创建非 root 管理员，加入 sudo/wheel 组 |
| SSH 加固 | 两级加固：基础加固（无密钥时保留密码）→ 完全加固（禁用密码，仅密钥） |
| fail2ban | SSH 试错 3 次自动封禁 1 小时，防暴力破解 |
| 防火墙 | 仅开放必要端口（SSH/HTTP/HTTPS），默认拒绝入站 |
| 自动更新 | 无人值守安全更新，漏洞修复自动完成 |

## SSH 加固策略

| 场景 | 行为 |
|------|------|
| 无 SSH 密钥 | **基础加固**：禁用 root 登录、降低 MaxAuthTries，**保留密码登录** |
| 已有 SSH 密钥 | **完全加固**：禁用 root + 禁用密码，仅允许密钥认证 |
| 重复运行 + 密钥已配置 | 自动检测，提示升级为基础→完全 |

## 支持系统

Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / RHEL / openSUSE / Arch

## 使用方式

### 交互式菜单（推荐）

```bash
sudo bash secure-server-init.sh
```

进入三阶段向导：勾选步骤 → 配置参数 → 确认执行。方向键移动，空格勾选，回车确认。

### 批量部署

```bash
# 生成配置文件
bash secure-server-init.sh --generate-config > my.conf

# 编辑配置后执行
sudo bash secure-server-init.sh --config my.conf
```

### 预览模式

```bash
sudo bash secure-server-init.sh --dry-run
```

## 配置文件

```bash
# ── 步骤开关 ──
SECURE_STEP_00_ENABLED=true    # 系统更新
SECURE_STEP_01_ENABLED=true    # 管理员用户 + sudo
SECURE_STEP_02_ENABLED=true    # SSH 加固
SECURE_STEP_03_ENABLED=true    # fail2ban
SECURE_STEP_04_ENABLED=true    # 防火墙
SECURE_STEP_05_ENABLED=true    # 自动安全更新

# ── 参数 ──
ADMIN_USER=deploy               # 管理员用户名
SSH_PORT=22                     # SSH 端口
SSH_ALLOW_USERS=""              # 限制登录用户（空格分隔）
FAIL2BAN_BANTIME=3600           # 封禁时长（秒）
FAIL2BAN_MAXRETRY=3             # 最大试错次数
UFW_PORTS="22/tcp 80/tcp 443/tcp"  # 防火墙开放端口
```

环境变量可覆盖任意配置项：

```bash
SSH_PORT=2222 ADMIN_USER=ops sudo -E bash secure-server-init.sh
```

## 幂等性

脚本可安全重复执行：

- SSH：已加固则跳过；密钥就绪后自动升级到完全加固
- 防火墙：已激活则仅补充缺失端口，不覆盖已有规则
- fail2ban：已配置标记则跳过
- 用户：已存在则跳过创建

## 日志

执行日志保存在 `/var/log/secure-server-init-*.log`，每次运行独立文件。

---

# dev-env-init

安全加固完成后，一键安装开发环境：JDK、Python、Node.js、Nginx、MySQL、Redis、Docker 等。

## 一行命令

```bash
curl -fsSL https://raw.githubusercontent.com/starhyc/server-init/main/dev-env-init.sh | sudo bash
```

## 支持工具

| 工具 | 说明 |
|------|------|
| 基础构建工具 | gcc / g++ / make / curl / wget 等 |
| Git | 版本控制 |
| Python 3 | Python + pip + venv |
| Node.js | LTS 版本，通过 NodeSource 源安装 |
| JDK | OpenJDK，可选 8 / 11 / 17 / 21 |
| Nginx | 高性能 Web 服务器，安装后自动启动 |
| MySQL | MySQL Server，自动执行安全初始化 |
| Redis | 内存缓存，安装后验证 PING |
| Docker | 容器运行时 + docker-compose |

## 使用方式

```bash
# 交互菜单（方向键选择）
sudo bash dev-env-init.sh

# 批量安装
bash dev-env-init.sh --generate-config > my.conf
sudo bash dev-env-init.sh --config my.conf
```

## 推荐顺序

```bash
# 1. 安全加固
curl -fsSL https://raw.githubusercontent.com/starhyc/server-init/main/secure-server-init.sh | sudo bash

# 2. 开发环境
curl -fsSL https://raw.githubusercontent.com/starhyc/server-init/main/dev-env-init.sh | sudo bash
```
