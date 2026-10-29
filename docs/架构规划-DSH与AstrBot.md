# DSH × AstrBot 双系统架构规划

> 状态：**草案，未实施**
> 日期：2026-10-29
> 关联：`deploy.ps1` / `deploy.sh`（DSAD 一键部署）

---

## 1. 目标

一个 QQ 号上，同时拿到两套系统的能力，而不是二选一：

1. **DSH 的插件**——记忆、人格、上下文、工具链。这是"脑子"。
2. **AstrBot 的插件**——表情包、群管、签到这类成熟生态。这是"素材库和手"。
3. **能远程连进 DSH 修东西**——出问题时不用跑到客户机器前。

约束：只用**一个** QQ 小号，不搞两个号各连一个 bot。

---

## 2. 现状

现在其实是"星形"：NapCat 是总机，同时喂两个消费者。

```
NapCat（OneBot 实现）
 ├─ 正向 WS 服务端 :3001 ──→ dsh-qq-bridge（跑在 DSH 进程内的 Cordis 插件）
 └─ 反向 WS 客户端 ──────→ AstrBot :6199
```

证据：`dsh-packs\pack-test-2\napcat\config\onebot11.json` 里，`websocketServers[0]` 是
`dsh-qq-bridge`（3001），`websocketClients[0]` 是 `astrbot`（6199）。一个号、两个消费者，
这件事本来就成立。

**真正的问题不是连通，是"谁开口"。** 两个框架都看见全部消息，如果都配了对话模型，
就会一句话回两遍。

---

## 3. 候选拓扑与取舍

### A. 星形分工：DSH 独嘴，AstrBot 当工具箱 ← **选这个**

- DSH 保留全部 QQ 能力：唤醒规则、记忆、人设、斗图工具
- AstrBot 关掉主对话回复，只留插件；由 DSH 通过它的 HTTP API 被动调用
- 不发生双回复（只有一张嘴）

### B. 把 DSH 伪装成 OpenAI 兼容模型，给 AstrBot 当"自定义模型"

- 技术可行：写个 shim，收 `POST /v1/chat/completions` → 跑
  `dsh --profile headless --session-id <id>` → 把 stdout 包成 OpenAI 响应
- **不选**，三个硬伤：
  1. 每条 QQ 消息 = 一个完整 DSH agent turn（系统提示 + 工具清单全算），贵且慢；
     qq-bridge 的"概率唤醒 / 其余只记录"闸门完全失效
  2. DSH 的 QQ 专属工具全废：`send_meme`、发图依赖 qq-bridge 判断"本轮是否 QQ 发起"，
     走模型接口后 DSH 不知道对面是 QQ，只能吐 `[表情: xxx]` 文本
  3. 两套记忆打架：OpenAI 协议无状态（每次都重发全量历史），DSH 会话有状态；
     headless 并发跑同一 session id 还得自己排队
- 结论：省下的不是时间，是坑

### C. AstrBot 的「Agent 执行器」插件位（Dify / Coze / DeerFlow 同位置）

- 比 B 贴合，AstrBot 设计上就支持外部 agent 后端
- 代价：要写 AstrBot 侧插件（Python），工作量比 shim 大
- **备选**：如果将来想要"AstrBot 出 QQ 层、DSH 出脑子"，走这条，不要走 B

| | 写多少代码 | 双回复风险 | DSH 记忆插件 | AstrBot 表情包 | 成本 |
| --- | --- | --- | --- | --- | --- |
| A 星形分工 | 1 个 DSH 插件 | 无 | ✅ | ✅（被调用） | 低 |
| B 模型 shim | 1 个 shim | 无（AstrBot 只剩壳） | ✅ | 需 LLM，见 §8 | 高 |
| C runner 插件 | DSH + AstrBot 两侧 | 低 | ✅ | ✅ | 中 |

---

## 4. 选定架构（A）

```
                    ┌──────────────┐
   QQ ──────────────│   NapCat     │
                    │  :3001 / :6199│
                    └──┬────────┬──┘
            正向 WS     │        │ 反向 WS
                        ▼        ▼
              ┌─────────────┐  ┌──────────────┐
              │    DSH      │  │   AstrBot    │
              │ qq-bridge   │  │ 插件（表情包）│
              │ 记忆/人格/工具│  │ 主对话：关闭  │
              └──────┬──────┘  └──────▲───────┘
                     │  HTTP API 调用  │
                     └────────────────┘
                    POST /api/v1/im/message
                    POST /api/v1/chat
                    POST /api/v1/file
```

职责：

- **DSH**：决定回不回、回什么、什么时候发表情包。唯一开口者。
- **AstrBot**：不主动说话；被 DSH 点单时，用它自己的插件链产出内容并发送。
- **NapCat**：只做协议端，两边都连它。

---

## 5. 接口与约定

### AstrBot HTTP API（要求 **v4.18.0+**）

WebUI → 设置 → OpenAPI → 创建 API Key，请求头 `Authorization: Bearer abk_xxx`。

| 用途 | 接口 | 备注 |
| --- | --- | --- |
| 按 UMO 主动发消息 | `POST /api/v1/im/message` | `message` 支持消息段数组；`image` 段要 `attachment_id` |
| 跑它的插件/工具链 | `POST /api/v1/chat` | 需 `username`，SSE 流式；可选 `session_id` |
| 上传图片拿附件 id | `POST /api/v1/file` | 返回 `attachment_id` |
| 查 bot / 平台 id | `GET /api/v1/im/bots` | 拼 UMO 用 |

UMO 形如 `aiocqhttp:FriendMessage:<QQ号>` / `aiocqhttp:GroupMessage:<群号>`。
交互文档在本机 `http://localhost:6185/api/v1/docs`。

### DSH 侧

- 现有：`dsh-qq-bridge`（Cordis 插件，进程内，连 NapCat 正向 WS，用 `agent.followup` 注入）
- 新增：**`astrbot-bridge`** 插件，向模型暴露工具：
  - `astrbot_send_image(path|url, destination)` —— 上传 + `im/message` 发图
  - `astrbot_send_text(text, destination)` —— 纯文本旁路发送
  - `astrbot_ask(prompt, session_id?)` —— 调 `/api/v1/chat`，拿 AstrBot 插件链的产出
- 沿用 qq-bridge 的出站闸门：只有"QQ 发起的轮次"才允许真正发送，避免聊天界面里
  随手一句话被发到 QQ。

---

## 6. 要写 / 要改的东西

1. **DSH 插件 `astrbot-bridge`**（新）：三个工具 + 设置页（API Key、base url、默认 UMO）
2. **AstrBot 配置**：开 OpenAPI Key、关掉主对话自动回复（只留插件）
3. **DSAD 部署脚本**：从"AstrBot 单独装、当主服务"改成"DSH + AstrBot 双装、配 Key、
   掐掉 AstrBot 主回复、装 qq-bridge"
4. **README**：写清"谁说话"的分工

---

## 7. 远程运维（独立于 QQ 链路）

DSH Web 默认只听 `127.0.0.1:3080`。四个方案：

| 方案 | 适合 | 代价 |
| --- | --- | --- |
| SSH 隧道 `ssh -L 3080:127.0.0.1:3080` | 自己的机器、临时 | 要 SSH 可达 |
| Tailscale | 自己的多台机器 | 每台装一个 agent |
| Cloudflare Tunnel | 客户机器，长期 | 要 CF 账号 + 域名；无常驻端口 |
| frp | 自建 VPS | 要自己维护服务端 |

**建议**：客户机器上由部署脚本带一个常驻隧道（Cloudflare Tunnel 优先），DSH 永远
只监听本地、由隧道往外连，不开放任何公网端口。远程除了 Web，还能直接
`dsh --profile headless "..."` 做无头抢救。

---

## 8. 未决问题

1. **表情包插件是否依赖 LLM**——关键词/概率触发的，关掉 AstrBot 模型照样能跑；
   靠 LLM 判断情绪的那种，关掉就哑。**待确认插件名 + 读源码**。
2. **远程连接的目标**——自己的机器，还是客户的机器？决定选 SSH/Tailscale 还是隧道。
3. **AstrBot 能否关闭"私聊自动回复"而保留插件事件钩子**——若不能，私聊会双回复，
   需要退一步：私聊归 DSH，AstrBot 只在群里干活。
4. DSH 插件如何拿到 AstrBot 的 API Key——存 DSH 的 credential 服务，不写明文。

---

## 9. 里程碑

| # | 内容 | 前置 |
| --- | --- | --- |
| M0 | **修 astrbot 安装链路（当前阻塞）** | — |
| M1 | 部署脚本双装 + AstrBot 静默化 | M0 |
| M2 | `astrbot-bridge` 插件：发图/发文本 | M1 |
| M3 | `astrbot_ask` + 插件链联动 | M2 |
| M4 | 远程隧道集成进部署脚本 | M1 |

---

## 10. 风险

- **token 成本**：DSH 开口意味着每条唤醒消息都是一轮 agent，靠唤醒规则控量，别放开概率。
- **双回复**：唯一硬约束——AstrBot 的主对话必须真关掉，不能只是"看起来没回"。
- **版本漂移**：AstrBot HTTP API 是 v4.18.0 才有的，脚本里要检查版本并给明确报错。
- **插件生态差异**：AstrBot 插件被"点单"和"自己被动收到消息"是两种触发路径，
  不是所有插件都吃前者，需要逐个验证。
