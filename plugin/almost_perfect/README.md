# Almost perfect

NapCat 掉线自愈插件（AstrBot）。

## 为什么不做"掉线提醒"

NapCat 掉线时，机器人本身发不出消息——消息就是走 NapCat 出去的。
所以"掉线了给你发个 QQ 提醒"这件事在通道上不成立。这个插件改成：

- 掉线了：**自己修**（停干净 → 拉起 → 等自动登录 → 等连回 AstrBot）
- 修好了：借恢复的连接发一条「修复完成」
- 修不好：**不硬发**，把过程写进 `logs\`，再放一个 `修复失败-请看这里.txt`

## 它怎么判断"掉线"

每 60 秒（可配）跑一次检查：

| 检查项 | 手段 | 说明 |
| --- | --- | --- |
| NapCat 进程 | `Get-CimInstance Win32_Process` | 进程没了 = 死了 |
| 与 AstrBot 连接 | `Get-NetTCPConnection -RemotePort 6199 -State Established` | 连着 = 活着 |

两个都满足才算健康。

## 防反复重启

- 失败退避：30s → 2min → 5min → 15min
- 每小时最多修 3 次，超了就不折腾，只写日志
- 计数落盘（`state.json`），自己重启 AstrBot 也不会清零
- 修复脚本内部还会先确认"所有 NapCat 都杀干净了"再拉起，避免两个实例抢 QQ

## 指令

| 指令 | 作用 |
| --- | --- |
| `/ap` 或 `/ap status` | 看当前状态、最近一小时修了几次 |
| `/ap check` | 立刻检查一次 |
| `/ap repair` | 立刻手动修一次 |
| `/ap off` / `/ap on` | 关掉 / 打开自动修复 |

## 需要扫码的情况

修复脚本会等 120 秒。如果这期间出现新的二维码，说明需要重新扫码——
脚本会把二维码 **打开在屏幕上** 并复制一份到 `logs\qrcode-<时间>.png`，
然后以退出码 2 告诉插件"起来了但要扫码"。

此时主人收不到消息（通道断着），只能看到屏幕上弹出来的二维码；
扫完就会自动连回来。

## 配置

`settings.json`（部署脚本会自动填前两项）：

```json
{
  "enabled": true,
  "napcat_dir": "",          // NapCat 根目录（含 NapCatWinBootMain.exe）
  "onebot_port": 6199,       // AstrBot 的 OneBot 端口
  "owner_qq": "",            // 预留
  "check_interval_sec": 60,
  "max_repair_per_hour": 3,
  "backoff_seconds": [30, 120, 300, 900]
}
```

## 文件

```
main.py                     插件本体
metadata.yaml               AstrBot 插件清单
repair.ps1                  修复脚本（被插件调用）
settings.json               配置
state.json                  运行时状态（自动生成）
logs\                       每次修复的详细输出
修复失败-请看这里.txt        失败时写给用户看的说明（自动生成）
```
