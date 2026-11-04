# ArbLens Monitor Ubuntu 一键安装器

这是 ArbLens Monitor 的公开安装仓库，用于在 Ubuntu 云服务器上一键安装或升级监控服务。安装器会从 GitHub Release 下载部署包，不需要 GitHub Token，也不会在仓库或发布包中保存 Gate API Key、飞书 Webhook 等私密配置。

## 一键安装 / 升级

v2026.11.04-10：补齐 FF/SS 双向历史与交换左右，新增清仓价差曲线；开清盘口互换，不直接把开仓取负。同一桶新增四个清仓聚合字段，历史和配置保留，不另采一套反向数据。旧开仓-only 历史无法还原反向开仓时显示未知，可查看反向清仓；SF 明确限制现货多/合约空。

v2026.11.04-9：FR 正反方向复用已有趋势历史，交换左右同步取回归值倒数，并提供恢复默认基准按钮；实时源暂不可用时仍可读取具体市场历史，不混用 HL xyz/io，不补造缺失数据。升级保留旧自定义回归值，可按需恢复默认基准。

在 Ubuntu 服务器中运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Slliki/ArbLensMonitor-Installer/main/install.sh | sudo bash
```

首次运行会完成环境、Nginx、ArbLens Web 服务和后台监控服务的安装。以后再次运行同一条命令即可升级到最新 Release；历史数据和现有配置会保留。新版本健康检查失败时，安装器会尝试回滚到上一个可用版本。

### 后续从网页升级

首次安装新版更新组件后，网页顶部会出现“版本更新”。检查版本和查看更新说明不需要验证；执行升级时填写**本机更新管理密钥**即可，不需要 GitHub Token，也不需要统一账号或其他人审批。密钥首次安装时生成，升级时保持不变；忘记时在本机运行：

```bash
sudo cat /etc/arblens/update.key
```

不要将输出发送到聊天或公开仓库。网页不会将密钥保存在浏览器。HTTP 会明文传输密钥，推荐先配置 HTTPS，或使用可信 VPN/SSH 隧道；HTTP 下必须明确确认风险才发送升级请求。

更新组件只接受本仓库最新稳定版，核对安装器及源包 SHA256 后执行独立后台任务。关闭网页不会停止更新；切换版本会有短暂停顿，健康检查失败时尝试回滚，历史及配置保留。任务有时间、内存限制，失败后不会无限自动重试。异常断电等情况仍可能需要终端修复。

新增服务 `arblens-updater`，只监听本机 127.0.0.1:3031，不要对外开放此端口。任务日志仅 root 可读，位于 `/var/lib/arblens-updater/<任务ID>/install.log`。网页显示进度和结果，不公开原始安装日志。

每个新版 Release 包含 `arblens-source.tar.gz`、`install.sh`、`SHA256SUMS`。缺少完整资产的版本不会启用网页升级。

## 系统要求

- Ubuntu 22.04 / 24.04（64 位）
- root 权限，或可使用 `sudo` 的账号
- 服务器可以访问 GitHub 和各交易所行情接口
- 安全组或防火墙放行 TCP 80；使用域名和 HTTPS 时还需放行 TCP 443
- 建议至少 2 GB 内存和 10 GB 可用磁盘空间

## 安装内容

- ArbLens Web 页面与 API
- 目标每 10 秒执行一次的后台行情采集；报警和历史压缩独立调度，慢请求不阻塞下一轮采集
- Nginx 反向代理
- `systemd` 开机自启与异常自动重启
- HTTP 健康看门狗与内存上限，适配 2 GB 云服务器（不再固定每 6 小时重启）
- 本地持久化的趋势历史、报警日志和用户设置

趋势数据采用分级聚合：最近 30 分钟保留 10 秒桶，24 小时内保留 1 分钟桶，7 天内保留 5 分钟桶，30 天内保留 30 分钟桶。每个桶记录平均值和区间高低值，在保留短时价差突变信息的同时控制数据库体积。

### FR 回归扫描与趋势

新版对齐 Astro Tide 的对称公式：普通开清价差为 `200×(右价−左价)/(右价+左价)`，FR 为 `200×(R−左原始价/右原始价)/(R+左原始价/右原始价)`。FR 正值表示左侧相对基准便宜，比率等于 R 时为零；固定方向，xyz、io 与原始币名分别显示。FR 趋势按 Last/Last 采样，扫描开清使用相反盘口；采用名义报价，不额外换汇。

填写回归值可立即重算当前曲线，基准保存在当前浏览器。历史不清除：新旧口径分开写入，旧桶读取时换算并标记近似；曲线显示的是桶均比率换算，不是逐笔价差均值。新增多/空各自的 Mark/Index 溢价，“跨市场指数价差”另行标注。FR 不是资金费套利，基础配置不再带猜测阈值，默认禁开禁清，导入后须人工核对。更新完成请刷新页面，并检查原有报警数值阈值是否仍适合新口径。

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
sudo systemctl is-active arblens-web arblens-monitor arblens-watchdog nginx
curl -fsS http://127.0.0.1:3000/api/health
```

四个服务应返回 `active`，健康接口应返回成功结果。看门狗会在健康接口连续失败时自动重启 Web 服务。

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
| `/etc/systemd/system/arblens-watchdog.service` | HTTP 健康检查和自动恢复服务 |

## 502 Bad Gateway 排查

先执行：

```bash
sudo systemctl status arblens-web arblens-monitor arblens-watchdog nginx --no-pager -l
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
