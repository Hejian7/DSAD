# DSH-QQ 一键部署 · Ubuntu / Debian 版

跟 Windows 版同一套思路，但目标机器通常是**没有桌面的云服务器**（2C2G 那种）。

```bash
sudo bash deploy.sh --qq 123456789 --api-key sk-xxxx
```

它做的事：

1. 检查环境（架构、内存、磁盘），`apt` 装 `curl / unzip / jq / xvfb / fonts-noto-cjk`
2. 官方脚本装 AstrBot：`install.sh --language zh-CN --download-source china --non-interactive`
3. `astrbot init` → 写 `aiocqhttp` 平台（端口 + token）、模型、管理员
4. 官方安装器装 NapCat（自带 QQ Linux 版 + Xvfb，**不需要桌面**）
5. 把 AstrBot 的端口和 token 写进 NapCat 的反向 WS 客户端
6. 写 systemd 服务、启动、等两端握手
7. 打印登录指引 + 自检

---

## 先看这条（2C2G 的机器必读）

装 Python 3.12 + AstrBot 依赖时内存容易打满，**先开 2G swap**：

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

磁盘至少留 4 GB（QQ + NapCat + AstrBot 依赖）。

---

## 登录方式：headless 该怎么选

服务器上没有浏览器、没有看图工具，所以：

**① 终端二维码（默认，最省事）**
NapCat 起来后会在终端/日志里输出二维码，同时落一张 `qrcode.png`：

```bash
sudo journalctl -u napcat -f --no-pager
# 或者找文件：
find ~/Napcat -name 'qrcode.png' -mmin -10
```

把那张 png 拉到本地（`scp`）扫码即可。

**② SSH 隧道 + WebUI（最稳，推荐）**
不用把 6099 暴露公网，在自己电脑上：

```bash
ssh -N -L 6099:127.0.0.1:6099 root@<服务器IP>
# 然后浏览器打开 http://127.0.0.1:6099/webui
```

WebUI 登录 token 在 `~/Napcat/**/webui.json` 里（字段 `token`）。

**关于账密登录**：NapCat 的账密登录只在 WebUI 里，不在 CLI。所以 headless 下想用账密，也得走 ②；而且和 Windows 一样，密码进去之后仍然要手机确认。**不建议**把 6099 直接绑 0.0.0.0 暴露到公网——那等于把机器人后台挂在互联网上。

首次登录成功后会留下快速登录凭证，之后重启不用再动。

---

## 参数

| 参数 | 说明 |
| --- | --- |
| `--qq` | 机器人 QQ（必填） |
| `--api-key` | 模型 Key（不给就之后在 WebUI 填） |
| `--model` | 默认 `deepseek-flash` |
| `--mode native\|docker` | 默认 native；docker 走 `mlikiowa/napcat-docker` |
| `--port` | AstrBot 的 OneBot 端口，默认 6199 |
| `--workdir` | AstrBot 工作目录，默认 `/opt/dsh-qq-deploy/astrbot` |
| `--source china\|official` | 下载源，默认 china |
| `--no-deps` | 跳过 apt 安装 |
| `--probe` | 只探测，不写任何配置 |
| `--self-check` | 只体检 |
| `--uninstall` | 回滚配置 + 停服务 |

---

## 两种 NapCat 模式

**native（默认）**：官方安装器，装到 `~/Napcat`，自带 QQ 和 Xvfb，systemd 起服务。
**docker**：`mlikiowa/napcat-docker`，端口只绑 `127.0.0.1`（6099 / 3001），数据卷在 `/opt/dsh-qq-deploy/docker/data`。反向 WS 用 `host.docker.internal`（compose 里已加 `host-gateway`）。

Docker 模式适合：系统仓库里没有 Xvfb、或不想让 QQ 跑在宿主机上。

---

## 常见报错

| 你看到的 | 原因 | 怎么办 |
| --- | --- | --- |
| `内存只有 xxx MB：建议先加 swap` | 2G 机器装依赖会 OOM | 按上面开 2G swap 再跑 |
| `下载 AstrBot 安装脚本失败` | 连不上 docs.astrbot.app | 配代理；或手动 `curl -fsSL https://docs.astrbot.app/install.sh \| bash` |
| `装完了但找不到 astrbot 命令` | PATH 没刷新 | `source ~/.bashrc`；或 `ls ~/.local/bin/astrbot` |
| `AstrBot 的 OneBot 端口没有起来` | 平台没启用 / 端口被占 | `journalctl -u astrbot -n 80 --no-pager`；换 `--port 8123` |
| `NapCat 原生安装失败` | 缺 Xvfb / 下载不通 | 改用 `--mode docker`；或手动跑官方安装器看报错 |
| `两边还没连上` | 没登录 / token 不一致 / 端口不对 | 先扫码登录；再 `bash deploy.sh --self-check` |

---

## 日志

- `/opt/dsh-qq-deploy/logs/deploy-<时间>.log`：脚本每一步
- `/opt/dsh-qq-deploy/logs/astrbot.out.log` / `systemd`：`journalctl -u astrbot`
- `journalctl -u napcat`

---

## 尚未验证（重要）

- 这份脚本**没有在真机上跑过**（本机是 Windows，没有可用的 Linux 环境），只做了逻辑推演和静态检查。
- 已知不确定点：
  1. NapCat 官方安装器在 2C2G 上是否稳定、装完的服务名是不是 `napcat.service`；
  2. NapCat 在 Linux 里配置目录的确切位置（脚本用 `find` 猜，猜不到会落到 `~/Napcat/config`）；
  3. Docker 模式下 `host.docker.internal` 的连通性（已加 `host-gateway`，但仍需实测）。
- 建议第一次先在一台测试机（或 WSL）上跑 `--probe` 和 `--self-check`，再上正式服务器。
---

## 群聊预设（`--group`）

```bash
sudo bash deploy.sh --qq 123456789 --api-key sk-xxx --group --wake 鱼 --group-id 987654123
```

写的东西和 Windows 版一致：唤醒词、群白名单、每人每分钟 12 条限流、忽略自己的消息、**Agent 权限保持关闭**。
群号可以之后用 `/sid` 拿到再补。
