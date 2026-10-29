# DSH-QQ 一键部署（Windows）

全脚本部署 **AstrBot + NapCat** 并接到 QQ。不开 GUI，不点按钮：

- AstrBot 走官方脚本安装（`uv tool install astrbot`，可选中国大陆镜像）；
- 脚本建工作目录、`astrbot init`、写 OneBot 平台（端口 + token）、模型、管理员；
- 再把同一个端口和 token 写进 NapCat 的反向 WS 客户端，重启、等扫码、自检。

> 设计原则：**报错必须是人话**。每条失败都带「怎么办」。

---

## 跑起来

```powershell
# 交互式：问 QQ 号和 API Key
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
```

```powershell
# 全参数（推荐给客户用这一条）
.\deploy.ps1 -QQ 123456789 -ApiKey sk-xxxx -InstallWatchdog
```

```powershell
# 只探测：认出 AstrBot / NapCat / QQ 在哪、版本对不对，不写任何配置
.\deploy.ps1 -Probe
```

```powershell
# 只体检运行状态
.\deploy.ps1 -SelfCheck
```

```powershell
# 回滚（还原 AstrBot 配置、删守护任务；不卸载本体）
.\deploy.ps1 -Uninstall
```

```powershell
# 跳过联网预检（已经知道网是好的，省几十秒）
.\deploy.ps1 -QQ 123456789 -SkipNetworkCheck
```

---

## 网络差、机器乱的时候

这类机器（公司网、安全软件、老系统、装过一堆东西）最容易出现"看着在跑，其实早就死了"。
脚本按下面的方式来避免：

**1. 联网预检（第 1.1 步）**
开工前先逐条探路：AstrBot 文档站、清华/阿里/cernet 三个 PyPI 镜像、npmmirror 的 Python、
GitHub 直连、ghproxy。每条 5 秒超时，结果直接打在屏幕上（通了给毫秒数，不通标出来）。

- 系统代理会被自动识别（环境变量 → IE 设置），并且**先探活再使用**：代理死了就自动改直连，
  不会因为一个坏代理把整台机器误判成"没网"。
- 一个 PyPI 镜像都不通 → 直接停在第一步，告诉你该查联网、代理还是 DNS，而不是让你干等十分钟。
- GitHub 不通也没关系：AstrBot 走 PyPI 镜像直装，NapCat 走 ghproxy；只有 ghproxy 也挂了才需要手动放安装包。
- 代理会「先探活再用」，而且一旦请求失败就自动摘掉代理改直连重试一次——注册表里配着个死代理的机器很常见。
- 老系统上还会强制打开 TLS 1.2/1.3——不打开的话下载会报"基础连接已经关闭"这种鬼话。

**2. 全程有进度**
- 下载：字节级进度条（`12.3/20.3 MB 61% 1.8 MB/s`），支持断点重试、可选 sha256 校验。
- 装 AstrBot / 装 NapCat：显示已用时间 + **日志最后一行的实时尾巴**，不再是黑屏干等十几分钟。
- 标题栏同步显示当前阶段，最小化也能知道在干嘛。

**3. 装一半被关掉？**
- 安装期间**窗口的关闭按钮会被摘掉**，误点 X 关不掉；装完自动恢复（`finally` 里恢复，
  中途报错也会恢复）。
- 按 Ctrl+C：第一下不杀，先收拾现场；**要真中止得连按两次**。
- 万一被强杀、断电、任务管理器结束：会留下断点标记 `%LOCALAPPDATA%\dsh-qq-deploy\.install-in-progress.json`，
  下次运行会明确告诉你"上次卡在哪个阶段"，重跑接着装，已经装好的不重装。

> 内部约定：本脚本**不要用 `Invoke-WebRequest @参数表`（splatting）**。实测在装了安全软件的
> 机器上，这种写法会让 PowerShell 5.1 无声无息整个退出（退出码 0、没有任何报错），极难排查。
> 网络请求统一走 `HttpWebRequest`。

---

## AstrBot 的两种形态

| 形态 | 怎么来的 | 配置在哪 |
| --- | --- | --- |
| `cli` | 本脚本跑官方 `install.ps1` 装的 | `<工作目录>\data\cmd_config.json`，工作目录默认 `%LOCALAPPDATA%\dsh-qq-deploy\astrbot` |
| `launcher` | 用户自己用启动器装的 | `%USERPROFILE%\.astrbot_launcher\instances\<id>\core\data\cmd_config.json` |

`-Mode auto`（默认）：发现启动器实例就用它，没有就走 CLI 安装。
强制指定：`-Mode cli` / `-Mode launcher`。

**CLI 形态下脚本做的顺序**：装 → 建工作目录 → `astrbot init`（已初始化则跳过）→ 写配置 → `astrbot run` → 等 6199 端口。

---

## 它到底做了什么

1. **环境检查**：PowerShell 5.1+、64 位、磁盘 ≥3 GB、**联网预检**（各下载源是否可达、代理是否活着）、是否管理员。
2. **AstrBot**：没装就装，两条路线，先试 A：
   - **路线 A（默认）**：`uv` 从 PyPI 镜像取 wheel → Python 3.12 从 npmmirror 取官方安装包静默装 →
     `uv tool install astrbot --python <3.12> --default-index <镜像>`。**全程不碰 GitHub**。
   - **路线 B（兜底）**：A 全失败才下载官方 `install.ps1` 照原样跑。
   - 装完找 `astrbot` 命令（PATH / `%USERPROFILE%\.local\bin` / `%APPDATA%\uv\tools\astrbot`）。
3. **初始化**：CLI 形态建工作目录并 `astrbot init`；没生成配置就先 `astrbot run` 一次把它逼出来。
4. **写 AstrBot**：`aiocqhttp` 平台（端口 + token，没有就建、有就沿用）、DeepSeek 模型（给了 Key 才写）、把你的 QQ 加进管理员。
5. **NapCat**：找真正的根目录（`bootmain` 是壳，判断标准是**有没有 config**）；找不到就下 `NapCat.Shell.zip`。
6. **版本对齐**：QQ 客户端 build vs NapCat 的 `qqnt.json`，对不上直接报警（这是“登录掉线、面板失效”的头号原因）。
7. **写 NapCat**：在 `onebot11_<QQ>.json` 里建/复用反向 WS 客户端，填 AstrBot 的端口和 token，`enable: true`。
8. **重启 + 扫码**：NapCat 只在启动时读配置，所以重启一次；然后**每 2 秒盯一次二维码**，
   一出就自动帮你打开（还打不开就用画图兜底），屏幕上有大字提示「扫哪个号、扫完会怎样」；
   90 秒没动静会再开一次，每 30 秒报一次「还在等你扫码」。最多等 6 分钟，失败时连
   NapCat 面板地址和 token 一起给出来。
9. **自检**：端口 / AstrBot 进程 / NapCat 进程 / 两端连接；`-InstallWatchdog` 再加一个每 5 分钟自检的计划任务。

改动前一律 `.bak`。


---

## NapCat：默认用「一体包」（自带 QQ）

-NapCatMode auto（默认）：有能用的现成 NapCat 就用，没有就装一体包。

**一体包实测数据**（本机跑通一次）：

| 步骤 | 体积 / 耗时 |
| --- | --- |
| 下载 NapCat.Shell.Windows.OneKey.zip | 0.95 MB |
| 安装器自动下载 QQ 客户端 | 约 300 MB |
| 安装器自动下载 NapCat | 约 34 MB |
| 解压 + 复制 bootmain + 改 package.json | 约 1 分钟 |
| 全程 | 约 6 分钟，**零交互** |

装出来是 NapCat.<版本>.Shell\，里面自带一整套 QQ（ersions\<qq版本>-<build>\）和 NapCat，**客户机器上不需要预装 QQ**，也不存在“QQ 版本和 NapCat 对不上”的问题——脚本检测到自带 QQ 会自动跳过版本对比。

-NapCatMode shell：走老路，只下不带 QQ 的 NapCat.Shell.zip，用客户自己的 QQ，这时才会做版本对齐检查。

首次启动前 NapCat 还没有 config 目录，脚本会**自己建好并写入 onebot11_<QQ>.json**，所以第一次启动就带着 WS 客户端，不用先跑一遍再配。
---

## 参数

| 参数 | 说明 |
| --- | --- |
| `-QQ` / `-ApiKey` | 机器人号 / 模型 Key（不给就交互式问） |
| `-Model` | 默认 `deepseek-flash` |
| `-Mode` | `auto`（默认）/ `cli` / `launcher` |
| `-WorkDir` | CLI 形态的 AstrBot 工作目录 |
| `-AstrBotDir` | 指定 AstrBot 根目录（两种形态都认） |
| `-NapCatDir` | NapCat 根目录（含 config 那层，不是 bootmain） |
| `-OneBotPort` | 仅当 AstrBot 还没有平台时使用，默认 6199 |
| `-NapCatMode` | `auto`（默认）/ `onekey`（自带 QQ，推荐）/ `shell`（用客户已有 QQ） |
| `-DownloadSource` | `china`（默认）/ `official` |
| `-Probe` / `-SelfCheck` | 只探测 / 只体检 |
| `-KeepNapCatRunning` | 不重启 NapCat |
| `-InstallWatchdog` | 装守护任务 |
| `-Uninstall` | 回滚配置 |

---

## 常见报错与处理

| 你看到的 | 原因 | 怎么办 |
| --- | --- | --- |
| `下载 AstrBot 安装脚本失败` | 访问不了 docs.astrbot.app | 检查网络/代理；或让客户手动跑一遍安装脚本，再重跑本脚本 |
| `AstrBot 安装超过 15 分钟没结束` | 卡在下载 | 看 `logs\astrbot-install-*.log`；换 `-DownloadSource official`；或手动装 |
| `装完了还是找不到 astrbot 命令` | PATH 没刷新 | 关掉窗口重开 PowerShell 再跑；或 `where.exe astrbot` 确认 |
| `AstrBot 起了但没生成配置文件` | 工作目录没写权限 / CLI 版本不对 | 看 `logs\astrbot.out.log`；换个 `-WorkDir` |
| `AstrBot 的 OneBot 端口 xxx 没有起来` | 平台没启用 / 端口被占 | 看日志；或 `-OneBotPort 8123`（脚本会同步改 NapCat） |
| `指定的目录不像 NapCat 根目录` | 指到了 bootmain 壳 | 指向含 `config` 的那层 |
| `QQ build A 和 NapCat 认的 build B 对不上` | QQ 自动升级了 | 换同代 NapCat，或把 QQ 降回对应版本 |
| `等了五分钟，NapCat 一直没连上 AstrBot` | 二维码过期 / 扫错号 / 版本不符 / 端口占用 / 杀软拦注入 | 重跑拿新码；确认扫的是脚本里那个 QQ；看第 3.5 步；换端口；加白名单 |
| `配置文件不是合法 JSON` | 手改坏了 | 用同目录 `.bak-时间戳` 还原再重跑 |

---

## 安全说明

- **不保存 QQ 密码**：登录走扫码。
- **token 由 AstrBot 生成**，脚本只读取并同步给 NapCat。
- **API Key 明文落盘**（AstrBot 自己的存法），介意就用低额度 Key。
- **管理员**：只把你的 QQ 加进 `admins_id`，不开放成员级执行权限。
- 所有改动前 `.bak`，`-Uninstall` 可回滚。

---

## 已知限制

- 只做 Windows；Ubuntu 版待补（官方 `install.sh` + `systemd`）。
- CLI 形态的实际安装过程没在本机跑过全流程（只在已装环境上验过探测/写配置/自检），首次量产前建议先找一台干净机器试。
- 二维码有效期短，脚本只等 5 分钟；过期重跑。
- 不做账号池、不代管 token：客户用自己的号、自己的 Key。

---

## 日志

`%LOCALAPPDATA%\dsh-qq-deploy\logs\`

- `deploy-<时间>.log`：脚本每一步
- `astrbot-install-<时间>.log`：官方安装脚本的输出
- `astrbot.out.log` / `astrbot.err.log`：AstrBot 运行输出
- `astrbot-init.log`：astrbot init 的输出
---

## 群聊预设（`-Group`）

群机器人时用这个，一次把该配的都配好：

```powershell
.\deploy.ps1 -QQ 123456789 -ApiKey sk-xxx -Group -WakeWord 鱼 -GroupId 987654123 -InstallWatchdog
```

它会写：

- `wake_prefix` = 唤醒词（群里必须叫它才理）
- `platform_settings.enable_id_white_list` = true，并把群号加进白名单
- `rate_limit` = 60 秒 12 条，策略 `stall`（超了排队不回，不刷屏）
- `ignore_bot_self_message` = true（防自问自答）
- **Agent 执行权限保持关闭**：群里谁都不该让机器人跑命令

`-GroupId` 可以先不给，装完在群里发 `/sid` 拿到群号再补。
---

## 双击就能用（不用碰 PowerShell）

| 双击这个 | 作用 |
| --- | --- |
| `一键部署.cmd` | 第一次部署：装 AstrBot / NapCat、写配置、起服务、出二维码 |
| `环境检查.cmd` | 只看这台机器能不能跑（不写任何东西） |
| `启动.cmd` | 已经部署过，把服务拉起来 |
| `停止.cmd` | 关掉服务，数据保留 |
| `状态.cmd` | 四项自检：端口 / AstrBot / NapCat / 两端连接 |
| `备份数据.cmd` | 打包配置与聊天数据，保留最近 10 份 |
| `查看日志.cmd` | 实时跟日志（Ctrl+C 退出） |

每个 `.cmd` 只是三行壳，实际都调用 `deploy.ps1 -Action <名字>`；
喜欢命令行的也可以直接：`.\deploy.ps1 -Action Status`
