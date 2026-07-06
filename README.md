# server-init

Linux 服务器安全初始化脚本，一键完成安全加固。

## 快速开始

```bash
# 一条命令
sudo bash secure-server-init.sh
```

脚本自动检测操作系统，执行以下安全配置：

| 步骤 | 功能 |
|------|------|
| SSH 加固 | 禁用 root 登录、禁用密码登录、仅密钥认证 |
| fail2ban | 防暴力破解，3 次失败封禁 1 小时 |
| 防火墙 | 最小化开放端口，默认仅 22/80/443 |
| 自动安全更新 | 按发行版自动适配（unattended-upgrades/dnf-automatic） |
| /tmp 加固 | nosuid,nodev（不含 noexec，不影响 AI agent） |
| sysctl | SYN cookie、RP filter、禁用源路由/ICMP 重定向 |
| 日志管理 | journald 限制 + logrotate 轮转 |
| NTP 时间同步 | systemd-timesyncd 或 chrony |
| rkhunter | rootkit 扫描（可选，默认关闭） |

## 自定义配置

```bash
# 生成配置文件
bash secure-server-init.sh --generate-config

# 编辑后运行
vim secure-server-init.conf
sudo bash secure-server-init.sh
```

## 支持的发行版

- Ubuntu / Debian
- CentOS / Rocky / Alma / RHEL / Fedora
- openSUSE
- Arch Linux

## 选项

| 参数 | 说明 |
|------|------|
| `--dry-run` | 仅探测，不修改 |
| `--step N` | 仅执行步骤 N（0-11） |
| `--config FILE` | 指定配置文件 |
| `--generate-config` | 生成示例配置文件 |

## 配置优先级

```
环境变量 > --config 指定 > ./secure-server-init.conf > /etc/secure-server-init.conf > 内置默认值
```
