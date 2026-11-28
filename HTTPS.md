# ArbLens 免费 HTTPS 教程

适用于 Ubuntu 22.04 / 24.04 上已正常运行的 ArbLens。核对日期：2026-11-28。

**可以不用购买域名，直接给自己的公网 IP 配置受浏览器信任的免费 HTTPS。** 使用 Let's Encrypt 的 IP 证书，并让 Certbot 自动续期、通知 Nginx 加载新证书。

“长期免费使用”不等于“拿到一张永久证书”：IP 证书每张约 160 小时，需要持续自动续期。云服务器、公网 IP 和域名的费用不包含在免费证书内；服务器停机、端口阻断、IP 改变或续期任务失败仍可能让 HTTPS 过期。

## 先选择你的情况

- **现在已经有正常 HTTPS**：不要重复安装证书客户端或替换 Nginx。直接看第 5、6、7 节，核对续期、重载和升级保留。
- **没有域名，用公网 IP 访问**：按下面第 1–7 节操作，推荐 webroot 验证，不停 Nginx。
- **有域名**：看第 8 节。域名 A/AAAA 记录必须先指向实际服务器。

安装包通过 HTTPS 下载，和你自己的网站启用 HTTPS 是两件事。安装 ArbLens 后出现 `http://你的IP/live`，并不代表 IP 证书已经配置。

## 1. 条件和备份

需要自己的固定/可保留公网 IP、sudo 权限、正常运行的 Nginx 和 ArbLens。

在云防火墙/安全组放行 TCP 80 和 443；系统防火墙也要允许相应访问。80 用于 HTTP-01 验证，不能只允许你自己的出口 IP。证书机构的验证 IP 会变化，不应维护一份固定白名单。443 按实际访问需求开放。不要为此把 3000、3031、3032 等后端端口暴露到公网。

先记录实际配置，保存备份：

```bash
sudo nginx -t
sudo cp -a /etc/nginx "/etc/nginx.backup.$(date -u +%Y%m%dT%H%M%SZ)"
sudo systemctl is-active nginx arblens-web arblens-monitor
sudo ss -ltnp | grep -E ':80 |:443 |:3000 |:3031 |:3032 '
```

已有其他网站、Astro、CDN、反向代理面板或发布授权服务时，先定位实际负责 ArbLens 的 server 块。**不要覆盖整份 nginx.conf、不要清空 sites-enabled、不要删除其他站点。**

下面变量必须替换为你自己的真实值，示例 IP 不能用于签发：

```bash
ARBLENS_IP='203.0.113.10'
ADMIN_EMAIL='you@example.com'
```

在同一个终端继续执行；换终端后重新设置变量。不要把示例 IP 或本文其他人的 IP 当成你的 IP。

## 2. 使用支持 IP 证书的 Certbot

官方说明要求 webroot IP 支持使用 **Certbot 5.4 或更新版**。Ubuntu 自带的旧 apt 版本可能不满足，不能仅看到“certbot 已安装”就继续。

新配置可采用官方 Snap 安装方式：

```bash
sudo apt-get update
sudo apt-get install -y snapd
sudo snap install --classic certbot
/snap/bin/certbot --version
```

若已使用 Snap Certbot，就检查版本，必要时 `sudo snap refresh certbot`，不重复安装。若已有 apt、acme.sh 或其他客户端管理证书，不要让多个客户端争用同一证书；先核对现有续期流程，再决定是否迁移。本文后续统一使用 `/snap/bin/certbot`，避免误调用旧版本。

## 3. 配置 HTTP 验证路径，再申请证书

创建只存公开验证文件的目录：

```bash
sudo mkdir -p /var/www/arblens-acme/.well-known/acme-challenge
```

在**现有负责该 IP 的 80 端口 server 块**中添加以下 location。常见配置文件为 `/etc/nginx/sites-available/arblens`，但须以实际启用的配置为准。

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/arblens-acme;
    default_type text/plain;
    try_files $uri =404;
}
```

此阶段保留原来的网站代理。若该 server 块有服务器级 `return 301 ...`，须调整为普通 `location /` 内重定向，确保 challenge 路径直接通过 HTTP 返回文件。

```bash
sudo nginx -t && sudo systemctl reload nginx
printf 'arblens-acme-ok\n' | sudo tee /var/www/arblens-acme/.well-known/acme-challenge/arblens-https-check >/dev/null
curl -f "http://$ARBLENS_IP/.well-known/acme-challenge/arblens-https-check"
```

还应从服务器之外访问这个测试地址，确认不是只有本机能访问。应返回 `arblens-acme-ok`，不是首页、403、404 或重定向循环。

建议先使用测试环境，避免反复错误请求消耗生产签发额度：

```bash
sudo /snap/bin/certbot certonly --staging --preferred-profile shortlived --webroot --webroot-path /var/www/arblens-acme --ip-address "$ARBLENS_IP" --cert-name arblens-ip-test --agree-tos --email "$ADMIN_EMAIL" --non-interactive
```

测试证书不受浏览器信任，**不能把 arblens-ip-test 部署到正式站点**。测试通过后申请正式证书，去掉 `--staging`，使用独立证书名：

```bash
sudo /snap/bin/certbot certonly --preferred-profile shortlived --webroot --webroot-path /var/www/arblens-acme --ip-address "$ARBLENS_IP" --cert-name arblens-ip --agree-tos --email "$ADMIN_EMAIL" --non-interactive
sudo /snap/bin/certbot certificates --cert-name arblens-ip
```

正式证书通常位于：

- `/etc/letsencrypt/live/arblens-ip/fullchain.pem`
- `/etc/letsencrypt/live/arblens-ip/privkey.pem`

以 Certbot 实际输出为准。Nginx 应引用 live 路径，不要复制成一份不会随续期变化的旧证书。不要公开 TLS 私钥；它也不是 ArbLens 发布签名私钥。

## 4. 配置 Nginx 的 HTTPS

Certbot 负责取证书，本节负责网站代理。保留完整的原 ArbLens 代理规则，把服务迁移到 443。不能只代理网页而漏掉新闻、Agent 或版本更新接口。

以下是默认单实例的配置参考，**不是让你直接覆盖现有文件的命令**。把两处 `YOUR_PUBLIC_IP` 改成你的 IP。后端 Web 如不是 3000，要改成实际监听端口。

**如果本机还托管授权分发端 `/arblens-conf/`、Astro、其他站点或自定义 OAuth 路由，必须额外保留其原配置。发布者自己的服务器不能直接用此最小模板替换现有站点。**

```nginx
server {
    listen 80;
    server_name YOUR_PUBLIC_IP;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/arblens-acme;
        default_type text/plain;
        try_files $uri =404;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name YOUR_PUBLIC_IP;
    ssl_certificate /etc/letsencrypt/live/arblens-ip/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/arblens-ip/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 2m;

    # 专用只读接口继续仅供本地 SSH 转发访问。
    location ~* ^/api/read(?:/|$) { return 404; }
    location = /api/monitor/news { return 404; }
    location = /.well-known/oauth-protected-resource/api/news/mcp {
        proxy_pass http://127.0.0.1:3032;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location ^~ /api/news/ {
        proxy_pass http://127.0.0.1:3032;
        proxy_http_version 1.1;
        proxy_read_timeout 55s;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 16k;
    }
    location ^~ /api/system/update/ {
        proxy_pass http://127.0.0.1:3031;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 70s;
        client_max_body_size 4k;
    }
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

检查语法通过后再重载；失败时不要重启 Nginx，先修正或恢复备份：

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -fI "https://$ARBLENS_IP/live"
curl -fsS "https://$ARBLENS_IP/api/health"
curl -fsS "https://$ARBLENS_IP/api/system/update/check"
```

使用普通浏览器验证，无证书警告，新闻/Agent/更新页可访问。不要用 `curl -k` 或浏览器忽略警告来冒充 HTTPS 验收成功。HTTPS 只加密连接，不等于网站自动有登录保护。

## 5. 自动续期并加载证书

IP 证书短期有效，必须配置自动续期。先检查是否已有 Certbot 或其他 ACME 客户端的任务：

```bash
sudo systemctl list-timers --all | grep -Ei 'certbot|acme|cert.*renew'
```

已有正常运行、覆盖当前证书的官方续期任务就复用它。不要重复部署多个续期客户端，也不要通过强制续期反复申请证书。

为 Certbot 增加续期成功后的 Nginx 重载 hook。使用独立文件，不覆盖其他 hook。**如果下面这个文件已存在，先查看并合并，不要直接执行覆盖命令。**

```bash
sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/20-arblens-reload-nginx >/dev/null <<'HOOK'
#!/bin/sh
set -eu
/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx
HOOK
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/20-arblens-reload-nginx
sudo /snap/bin/certbot renew --cert-name arblens-ip --dry-run --run-deploy-hooks
```

dry-run 会执行验证请求；首次配置后测试一次即可。证书验证成功但没有 reload，Nginx 仍可能继续使用内存中的旧证书。

**仅在确实没有启用可用续期任务时**，可创建以下专用 systemd 任务。证书名或客户端路径不同则一并调整：

```bash
sudo tee /etc/systemd/system/arblens-cert-renew.service >/dev/null <<'SERVICE'
[Unit]
Description=Renew ArbLens IP TLS certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/snap/bin/certbot renew --quiet --cert-name arblens-ip
SERVICE

sudo tee /etc/systemd/system/arblens-cert-renew.timer >/dev/null <<'TIMER'
[Unit]
Description=Check ArbLens TLS certificate renewal hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now arblens-cert-renew.timer
sudo systemctl list-timers arblens-cert-renew.timer
```

每小时执行的是“检查是否应续期”，不是每小时签一张新证书。配置完成后，还要检查日志和到期日；失败任务不会因为有 timer 就自动变成功。

## 6. 让后续 ArbLens 升级保留 HTTPS

HTTPS、所有代理路由和续期都验证成功后，再设置安装器支持的“自管 Nginx”标记：

```bash
printf 'https://%s/live\n' "$ARBLENS_IP" | sudo tee /etc/arblens/nginx-managed-externally >/dev/null
sudo chmod 644 /etc/arblens/nginx-managed-externally
```

后续 ArbLens 安装器会保留自管代理配置，不再按默认 HTTP 模板重写它。标记本身不会申请证书，也不会修复缺失的代理路由。以后版本若新增路由，仍需按更新说明维护自管配置。

若新闻推送链接还指向 HTTP，使用 `sudoedit /etc/arblens/news.env`，只把 `ARBLENS_NEWS_SITE_URL` 改为 `https://你的IP`（不带 `/live`），保留所有密钥，再重启 `arblens-news`。不要把整个 env 文件贴出来。

不需要重装 ArbLens，不要删除 `/var/lib/arblens`、`/etc/arblens` 或已有证书目录。证书续期与 ArbLens 程序升级是两套独立任务。

## 7. 日常检查和排错

```bash
sudo /snap/bin/certbot certificates --cert-name arblens-ip
sudo systemctl list-timers --all | grep -Ei 'certbot|acme|cert.*renew'
sudo journalctl -u arblens-cert-renew.service --since '-7 days' --no-pager -n 60
sudo nginx -t
curl -fI "https://$ARBLENS_IP/live"
```

上面的 journalctl 只适用于自己创建的专用任务；使用 Snap 官方任务时，查看实际的 `snap.certbot.renew.service` 等对应日志；acme.sh 则查看其自己的任务与日志。不要因为某个示例 unit 不存在就认定所有续期都失败。

| 现象 | 优先检查 |
| --- | --- |
| 签发/续期验证失败 | IP 是否仍属本机，80 是否公网可达，challenge 是否返回正确文件，是否被 WAF/跳转/访问白名单挡住。 |
| HTTP 正常、HTTPS 超时 | 云防火墙和系统防火墙的 443、Nginx 是否监听 443。 |
| 浏览器证书警告 | 是否误装测试证书、IP/SAN 是否匹配、证书是否过期、服务器和客户端时间。 |
| 证书文件已更新、浏览器仍看到旧证书 | Nginx 指向的路径和续期 deploy hook 是否正确，reload 是否成功。 |
| 新闻/Agent/升级报错 | 对应后端 3032/3031 是否运行，代理路由是否保留，是否传递实际 `X-Forwarded-Proto` 和必要鉴权头。 |
| Nginx 502 | 检查 `arblens-web` 与实际 Web 端口；不是重新签证书能解决的问题。 |
| 服务器换 IP | 原 IP 证书不会自动覆盖新 IP，需要重新验证新 IP 并更新证书、链接和访问配置。 |

## 8. 有域名的方式

先将域名解析到本机，检查 A/AAAA 是否都正确、80/443 是否可达。安装 ArbLens 时填写域名，现行安装器会尝试使用 Certbot 配置域名 HTTPS，但仍须检查签发结果和续期任务。

已经安装的实例可在备份并核对 Nginx 后，采用支持 Nginx 的当前 Certbot：

```bash
sudo /snap/bin/certbot --nginx -d monitor.example.com
```

替换成自己的真实域名。不要把纯 IP 填到旧客户端的 `-d` 当作 IP 证书申请方式。域名证书同样需要自动续期；已有自管站点须保留全部 ArbLens 路由及第 6 节的升级保护。

## 关于已有部署和安全

2026-11-28 对维护者现有部署的公网握手检查，证书由 Let's Encrypt 签发，SAN 为该服务器 IP，有效期约 160 小时。该检查只能证明当时证书有效，不能单靠公网证书确认后台续期任务正常。不要把维护者的 IP、公钥、TLS 私钥、业务 token 或服务器专属配置复制到自己的实例。

**免费证书不等于永久免费服务器，也不等于“以后不用检查”。** 保持固定公网 IP、验证路径可达、续期任务启用、重载成功，并监控证书到期和任务失败，才能长期使用。

## 官方参考

- [Let's Encrypt：IP 与六日证书正式开放](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)
- [Let's Encrypt：Certbot 的 IP/webroot 申请方式](https://letsencrypt.org/2026/03/11/shorter-certs-certbot)
- [Certbot 官方使用与续期文档](https://eff-certbot.readthedocs.io/en/stable/using.html)
- [Certbot 官方安装入口](https://certbot.eff.org/instructions)
