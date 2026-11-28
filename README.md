# ArbLens Monitor 安装入口

在 Ubuntu 22.04 或 24.04 上下载并运行最新安装器。首次安装需要发布者提供的安装密钥。

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl python3 openssl
curl -fsSLo install.sh https://github.com/Slliki/ArbLensMonitor-Installer/releases/latest/download/install.sh
sudo bash install.sh
```

安装器通过 HTTPS 验证授权，再下载和验证签名运行包。安装密钥在终端输入时不显示。

## 给自己的网站启用免费 HTTPS

没有域名也可以使用 Let's Encrypt 的公网 IP 证书。证书本身短期有效，长期使用依靠自动续期和 Nginx 重载，并不是永久证书。

完整教程：[免费 HTTPS：公网 IP / 域名、自动续期与升级保留](https://github.com/Slliki/ArbLensMonitor-Installer/blob/main/HTTPS.md)。

教程包含端口与验证路径、Certbot 版本要求、正式证书申请、新闻/Agent/更新代理、续期检查及自管 Nginx 升级保护。仅安装 ArbLens 不代表纯 IP HTTPS 已配置。

## 网页升级与 Agent

已授权实例可以在 ArbLens 的「版本更新」页面检查并升级。开始升级仍需该实例原有的本机管理密钥。安装密钥轮换后，已授权的实例凭证可以继续使用。

Agent 页需从 HTTPS 访问。实例管理员可在 Ubuntu 上运行 `sudo cat /etc/arblens/agent.env`，把 `ARBLENS_AGENT_TOKEN` 的值填入 Agent 页，再配置所选模型服务的 API Key。同一浏览器的会话有效期为 7 天，可在 Agent 页断开。自管反向代理应在转发 `/api/news/` 时覆盖 `X-Forwarded-Proto`，使用实际访问协议。

[最新安装入口](https://github.com/Slliki/ArbLensMonitor-Installer/releases/latest)
