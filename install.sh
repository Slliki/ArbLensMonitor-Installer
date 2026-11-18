#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null && command -v openssl >/dev/null || { echo '请先安装 python3 和 openssl。' >&2; exit 1; }
exec python3 - <<'ARBLENS_BOOTSTRAP_PY'
#!/usr/bin/env python3
"""HTTPS client for licensed installations and updates."""
import base64
import getpass
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

TAG = re.compile(r"v\d{4}\.\d{2}\.\d{2}-\d{1,6}\Z")
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}\Z")
CONFIG = Path("/etc/arblens/release-access.json")
ARCHIVE = "arblens-source.tar.gz"
FILES = {"install.sh": 256_000, ARCHIVE: 128_000_000}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def endpoint(value):
    url = urllib.parse.urlsplit(value)
    path = url.path.rstrip("/")
    if (url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None
            or url.query or url.fragment or not re.fullmatch(r"(?:/[A-Za-z0-9_-]+)*", path)):
        raise ValueError("安装授权地址须使用 HTTPS，可包含固定路径")
    return urllib.parse.urlunsplit((url.scheme, url.netloc, path, "", ""))


def request(origin, path, *, token=None, body=None):
    headers = {"User-Agent": "ArbLens-Release/1"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(body).encode()
    req = urllib.request.Request(endpoint(origin) + path, data=body, headers=headers)
    try:
        return urllib.request.build_opener(NoRedirect()).open(req, timeout=45)
    except (OSError, urllib.error.URLError) as exc:
        if getattr(exc, "code", None) in (401, 403, 429):
            raise ValueError("安装密钥或实例授权不可用，请联系发布者") from None
        raise ValueError("无法连接授权发布服务，请稍后重试") from None


def json_request(origin, path, **kwargs):
    with request(origin, path, **kwargs) as response:
        return json.loads(response.read(65_537))


def signed_manifest(envelope, key):
    data = base64.b64decode(envelope["manifest"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    if len(data) > 32_768 or len(signature) != 64:
        raise ValueError("发布签名格式无效")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, content in [("manifest", data), ("signature", signature), ("public.pem", key.encode())]:
            (root / name).write_bytes(content)
        result = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(root / "public.pem"),
                                 "-rawin", "-in", str(root / "manifest"), "-sigfile", str(root / "signature")],
                                capture_output=True)
    if result.returncode != 0:
        raise ValueError("发布签名验证失败")
    manifest = json.loads(data)
    if not TAG.fullmatch(manifest.get("tag", "")) or set(manifest.get("sha256", {})) != set(FILES):
        raise ValueError("发布清单无效")
    if any(not re.fullmatch(r"[0-9a-f]{64}", digest) for digest in manifest["sha256"].values()):
        raise ValueError("发布校验值无效")
    return manifest


def latest(config):
    value = json_request(config["origin"], "/v1/latest", token=config["token"])
    return signed_manifest(value, config["public_key"])


def download(config, tag, directory):
    value = json_request(config["origin"], "/v1/ticket", token=config["token"], body={"tag": tag})
    manifest = signed_manifest(value, config["public_key"])
    if manifest["tag"] != tag or not TOKEN.fullmatch(value.get("ticket", "")):
        raise ValueError("下载授权与所请求版本不一致")
    for name, limit in FILES.items():
        digest = hashlib.sha256()
        remaining = limit
        with request(config["origin"], f"/v1/files/{tag}/{name}", token=value["ticket"]) as response:
            with (directory / name).open("xb") as output:
                while chunk := response.read(65_536):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise ValueError("发布文件超过大小限制")
                    digest.update(chunk)
                    output.write(chunk)
        if digest.hexdigest() != manifest["sha256"][name]:
            raise ValueError("发布文件 SHA-256 校验失败")
    return manifest


def run_installer(config, tag, directory, *, noninteractive):
    manifest = download(config, tag, directory)
    env = os.environ.copy()
    env.update(ARBLENS_RELEASE_TAG=tag, ARBLENS_EXPECTED_SHA256=manifest["sha256"][ARCHIVE],
               ARBLENS_VERIFIED_ARCHIVE=str(directory / ARCHIVE))
    if noninteractive:
        env.update(ARBLENS_NONINTERACTIVE="1", NODE_OPTIONS="--max-old-space-size=384")
    return subprocess.run(["/bin/bash", str(directory / "install.sh")], env=env, timeout=3300).returncode


def save_config(config):
    CONFIG.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=CONFIG.parent, delete=False) as fp:
        temp = Path(fp.name)
        json.dump(config, fp)
    try:
        temp.chmod(0o600)
        os.replace(temp, CONFIG)
    finally:
        temp.unlink(missing_ok=True)


def bootstrap(origin, key):
    if os.geteuid() != 0:
        raise ValueError("请用 sudo 从终端运行安装器")
    origin = endpoint(origin)
    key = key.replace("\r\n", "\n")
    config = {"origin": origin, "public_key": key}
    existing = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    if existing.get("origin") == origin and existing.get("public_key", "").replace("\r\n", "\n") == key:
        config["token"] = existing["token"]
    else:
        with open("/dev/tty", "w"):
            pass
        password = getpass.getpass("ArbLens 安装密钥：")
        issued = json_request(origin, "/v1/enroll", body={"key": password, "label": os.uname().nodename[:100]})
        config["token"] = issued["token"]
        if not TOKEN.fullmatch(config["token"]):
            raise ValueError("实例凭证格式无效")
    manifest = latest(config)
    with tempfile.TemporaryDirectory(prefix="arblens-licensed-") as directory:
        if run_installer(config, manifest["tag"], Path(directory), noninteractive=False):
            raise ValueError("安装未完成，请检查服务器日志")
    save_config(config)


try:
    bootstrap(*json.loads(base64.b64decode("WyJodHRwczovLzE1MC4xMDkuMTk3LjI0OC9hcmJsZW5zLWNvbmYiLCAiLS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS1cbk1Db3dCUVlESzJWd0F5RUFXZ0FISjRBTHdZSGRGdjlFRitNZXI3Q0xlQ1J3SWxzTVM0THFYdHJWWTdJPVxuLS0tLS1FTkQgUFVCTElDIEtFWS0tLS0tXG4iXQ==")))
except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as exc:
    import sys
    print(str(exc), file=sys.stderr)
    sys.exit(1)
ARBLENS_BOOTSTRAP_PY
