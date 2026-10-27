# AstrBot大肥鱼 QQ 机器人一键部署

把 **AstrBot + NapCat** 接到 QQ 的部署脚本。Windows 和 Ubuntu 各一份，都是「一条命令 → 装好 → 扫一次码」。

| 平台 | 脚本 | 说明 |
| --- | --- | --- |
| Windows 10/11 | [`deploy.ps1`](deploy.ps1) | [使用说明](README-windows.md) |
| Ubuntu / Debian | [`deploy.sh`](deploy.sh) | [使用说明](README-ubuntu.md) |

---

## 30 秒开始

**Windows**（PowerShell）

```powershell
git clone https://github.com/Hejian7/DSAD.git
cd DSAD
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -QQ 123456789 -ApiKey sk-xxxx
```

**Ubuntu 服务器**

```bash
git clone https://github.com/Hejian7/DSAD.git
cd DSAD
sudo bash deploy.sh --qq 123456789 --api-key sk-xxxx
```

装完扫一次二维码就完事；之后 NapCat 会留快速登录凭证，重启不用再扫。

---

## 它做什么

1. **AstrBot**：没有就跑官方安装脚本（`uv` + Python 3.12，可选中国大陆镜像）
2. **NapCat**：Windows 装自带 QQ 的一体包（客户机器不用预装 QQ）；Ubuntu 走官方安装器或 Docker
3. **对齐配置**：读 AstrBot 的 OneBot 端口与 token，写进 NapCat 的反向 WS 客户端，两端一致
4. **起服务 + 等握手**：Windows 用后台进程，Ubuntu 用 systemd；握手成功才结束
5. **自检**：端口 / 进程 / 两端连接，四项全绿才算部署完成

所有改动前都会备份（`.bak-时间戳`）。

---

## 仓库结构

```
deploy.ps1            Windows 部署脚本
deploy.sh             Ubuntu / Debian 部署脚本
README-windows.md     Windows 使用说明
README-ubuntu.md      Ubuntu 使用说明（2C2G 开 swap、headless 登录方式）
```

---

## 几个前提

- **不保存 QQ 密码**：登录走扫码，脚本全程不碰密码。
- **token 由 AstrBot 生成**，脚本只读取并同步给 NapCat。
- **API Key 会明文落盘**（AstrBot 自身的存法），建议用低额度 Key。
- 只做「客户用自己的号、自己的 Key」，**不做账号池、不代管 token**。

---

## 状态

- Windows：本机实测过探测、配置写入、自检；安装链路按官方脚本实现。
- Ubuntu：逻辑完整，但**尚未在真机跑过**，已知不确定点写在 [README-ubuntu.md](README-ubuntu.md) 末尾。
