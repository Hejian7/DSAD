# DSH / 大肥鱼 QQ 机器人一键部署

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
sudo bash linuxdsq/deploy.sh --qq 123456789 --api-key sk-xxxx
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

## 两个版本：基础版 / 升级版

客户拿到的入口只有两个：

| 版本 | 入口 | 拉什么 | 装什么 |
| --- | --- | --- | --- |
| 基础版 | `安装-基础版.cmd` | 只拉 `deploy.ps1` | 只装软件（AstrBot + NapCat） |
| 升级版 | `安装-升级版.cmd` | `deploy.ps1` + `plugin/` 整个插件包 | 软件 + 看门狗插件 |

**区别不在于部署脚本写了分支，而在于包里有没有 `plugin/install-plugin.ps1`。**
部署脚本装完软件后会去 `plugin\` 底下看一眼：
- 有 `install-plugin.ps1` → 直接执行它 → 插件被装进 AstrBot
- 没有 → 打印「基础版：包里没有插件安装器，跳过选装插件」，继续自检收尾

所以以后加新插件，只要在 `plugin/` 里放个同名安装器，部署脚本不用改。

```
install-basic.ps1      基础版入口（下载 deploy.ps1 后执行）
install-plus.ps1       升级版入口（多拉 plugin/ 整个包）
安装-基础版.cmd         给客户双击的壳
安装-升级版.cmd         给客户双击的壳
deploy.ps1             Windows 部署脚本（只管装软件 + 有插件就调安装器）
```

## 装在哪：`ds-as-nap\`

**所有东西都装在脚本旁边的 `ds-as-nap\` 里**，不往用户目录、系统目录散：

```
ds-as-nap\
  astrbot\        AstrBot 本体（独立 venv）+ data\（配置、插件、聊天记录）
  napcat\         NapCat 一体包（含它自带的 QQ）
  python\         Python 3.12（只给 AstrBot 用）
  uv\             uv（单个 exe）
  logs\           部署与安装日志
  _install\       入口脚本下载下来的 deploy.ps1 / 插件包
```

想搬走整个机器人？把 `ds-as-nap\` 拷到别的机器同一位置就行。

几个和"装得干净"有关的取舍：

- **Python 用可嵌入版 zip**，不用官方安装器。官方安装器会在注册表里留"已安装"记录，
  某些机器上再跑会认为装过了、什么都不做（`WixBundleInstalled=1`，退出码还是 0），
  排查起来极其费劲。可嵌入版是纯解包，装在哪就在哪，删目录即卸载。
  代价是它默认不加载 site-packages，脚本会顺手把 `python312._pth` 里的 `import site` 放开。
- **uv 也是一个 exe**，放进 `ds-as-nap\uv\`，不碰 `%USERPROFILE%\.local\bin`。
- AstrBot 装在 `ds-as-nap\astrbot\.venv` 里（`uv venv` + `uv pip install`），
  不是全局的 `uv tool install`，所以卸载就是删目录。

> 路径里有空格（比如 `A:\true porject\`）会让外部命令的参数被劈开。
> 脚本里所有传给 `Start-Process` 的路径参数都已经显式加了引号，改的时候别漏。

## 卸载

双击 `卸载.cmd`，会出一个菜单：

```
   1) 只删 AstrBot（本体 + 配置 + 插件都在里面）
   2) 只删 NapCat（含它自带的那份 QQ）
   3) 只删看门狗插件 Almost perfect
   4) 全删（AstrBot + NapCat + 插件 + 日志缓存，以及历史遗留）
   0) 退出
```

删除前会先停掉相关进程、列出每一项的路径和体积，再问一次确认。

也可以带参数跑：

```powershell
.\uninstall.ps1 -Target all -DryRun   # 只看会删什么，不动手
.\uninstall.ps1 -Target plugin        # 只删插件
.\uninstall.ps1 -Target all -Yes      # 全删，不确认
```

它只删本部署装出来的东西，**不动你自己的 QQ 客户端**。
全删时还会顺手把 `DSH-QQ-Watchdog` 计划任务清掉，并把老版本散落在用户目录的残留
（`%LOCALAPPDATA%\dsh-qq-deploy`、`%APPDATA%\uv\tools\astrbot`、桌面上的 NapCat 一体包等）一并清掉。

## 仓库结构

```
install-basic.ps1 / install-plus.ps1   两个版本的入口
deploy.ps1            Windows 部署脚本
linuxdsq/deploy.sh    Ubuntu / Debian 部署脚本
README-windows.md     Windows 使用说明
README-ubuntu.md      Ubuntu 使用说明（2C2G 开 swap、headless 登录方式）
docs/                 设计与规划文档（架构、待办）
plugin/install-plugin.ps1   插件安装器（存在 = 升级版）
plugin/almost_perfect/      看门狗插件本体
```

## 看门狗插件 Almost perfect（选装）

只有升级版会带上它。它做的是**掉线自愈**：

- 每 60 秒检查 NapCat 进程 + 与 AstrBot 的连接
- 掉线就修：停干净 → 拉起 → 等自动登录 → 等连回来
- 修好了发一条「修复完成」；修不好只写日志（此时机器人在断线状态，发不出去）
- 防反复重启：失败退避 30s→2min→5min→15min，每小时最多 3 次

QQ 里发 `/ap` 看状态，`/ap repair` 手动修一次，`/ap off` 关掉自动修复。
详见 [plugin/almost_perfect/README.md](plugin/almost_perfect/README.md)。

> **改 `deploy.ps1` 的人注意：这个文件必须带 UTF-8 BOM。**
> 目标运行时是 Windows PowerShell 5.1，没有 BOM 它会按系统 ANSI（中文机器上是 GBK）读，
> 中文全部乱码，甚至直接报一串 `Unexpected token` 语法错误。
> 用编辑器另存为「UTF-8 带 BOM」；批量替换/脚本改写过之后，务必检查文件开头是不是 `EF BB BF`。
> 插件里的 `repair.ps1` 同理（部署脚本会对它做 BOM 兜底）。

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
---

## 不想敲命令？

Windows 下直接双击 `一键部署.cmd`；之后日常用 `启动.cmd` / `停止.cmd` / `状态.cmd` / `备份数据.cmd` / `查看日志.cmd`。
Ubuntu 下用 `--action start|stop|status|backup|logs`。
