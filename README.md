# ArbLens Monitor Ubuntu 一键安装器

这是 ArbLens Monitor 的公开安装仓库，用于在 Ubuntu 云服务器上一键安装或升级监控服务。安装器会从 GitHub Release 下载部署包，不需要 GitHub Token，也不会在仓库或发布包中保存 Gate API Key、飞书 Webhook 等私密配置。

## 一键安装 / 升级

在 Ubuntu 服务器中运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Slliki/ArbLensMonitor-Installer/main/install.sh | sudo bash
```

首次运行会完成环境、Nginx、ArbLens Web 服务和后台监控服务的安装。以后再次运行同一条命令即可升级到最新 Release；历史数据和现有配置会保留。新版本健康检查失败时，安装器会尝试回滚到上一个可用版本。

## 系统要求

- Ubuntu 22.04 / 24.04（64 位）
- root 权限，或可使用 `sudo` 的账号
- 服务器可以访问 GitHub 和各交易所行情接口
- 安全组或防火墙放行 TCP 80；使用域名和 HTTPS 时还需放行 TCP 443
- 建议至少 2 GB 内存和 10 GB 可用磁盘空间

## 安装内容

- ArbLens Web 页面与 API
- 每 3 秒执行一次的后台行情监控和报警检查
- Nginx 反向代理
- `systemd` 开机自启与异常自动重启
- 本地持久化的趋势历史、报警日志和用户设置

安装完成后，终端会显示访问地址，通常为：

```text
http://服务器公网IP/live
```

如果安装时填写了域名并成功签发证书，则使用安装器输出的 HTTPS 地址。

## 安装过程中的配置

### Gate API

Gate API Key 和 Secret 为可选项，但 Gate CrossEx 行情可能需要配置后才能完整采集。建议创建单独的只读 API：

- 只开启读取行情或账户所需的最低权限
- 不开启交易、提现或转账权限
- 条件允许时绑定服务器公网 IP
- 不要把 Key、Secret 粘贴到 Issue、聊天记录或公开仓库

凭据只保存在服务器的 `/etc/arblens/settings` 中，不包含在公开安装仓库和 Release 包内。

### 域名

域名为可选项。留空时可直接通过公网 IP 访问；填写已经解析到本服务器的域名时，安装器会尝试配置 HTTPS。

## 检查服务状态

```bash
sudo systemctl is-active arblens-web arblens-monitor nginx
curl -fsS http://127.0.0.1:3000/api/health
```

三个服务应返回 `active`，健康接口应返回成功结果。

实时查看日志：

```bash
sudo journalctl -u arblens-web -f
sudo journalctl -u arblens-monitor -f
```

## 重要路径

| 路径 | 用途 |
| --- | --- |
| `/opt/arblens/current` | 当前运行版本 |
| `/opt/arblens/releases` | 已下载的版本，用于升级和回滚 |
| `/var/lib/arblens` | 历史趋势、报警记录等持久化数据 |
| `/etc/arblens/settings` | Gate、飞书和域名等持久化配置 |
| `/etc/arblens/runtime.env` | 运行时环境变量 |
| `/etc/systemd/system/arblens-web.service` | Web 服务定义 |
| `/etc/systemd/system/arblens-monitor.service` | 后台监控服务定义 |

## 502 Bad Gateway 排查

先执行：

```bash
sudo systemctl status arblens-web arblens-monitor nginx --no-pager -l
sudo journalctl -u arblens-web -n 100 --no-pager
sudo nginx -t
curl -v http://127.0.0.1:3000/api/health
```

如配置检查正常，可重启服务：

```bash
sudo systemctl restart arblens-web arblens-monitor nginx
```

若问题发生在刚升级之后，可再次运行一键安装命令；安装器会重新进行部署和健康检查。

## 安全说明

- 通过公网 IP 或域名部署后，页面默认可被能够访问该地址的人打开。需要限制访问时，请额外配置云防火墙、Nginx Basic Auth、VPN 或零信任网关。
- ArbLens 是监控与策略辅助工具，不会因为扫描到机会就自动下单。
- 交易所行情可能受接口维护、限频、网络延迟和合约规则变化影响，页面数据不构成投资建议，下单前请在交易所核验。

## Release

安装器默认使用最新稳定 Release：

[查看 ArbLensMonitor-Installer Releases](https://github.com/Slliki/ArbLensMonitor-Installer/releases)

