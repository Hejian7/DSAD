"""Almost perfect —— NapCat 掉线自愈插件

设计前提：
    NapCat 掉线时，机器人自己也发不出消息（消息本来就走 NapCat）。
    所以这个插件只做三件事：
      1. 检测（NapCat 进程没了 / 与 AstrBot 的连接断了）
      2. 修复（停干净 → 拉起 → 等它自动登录并连回来；需要扫码就把二维码打开并落盘）
      3. 修复成功后再发一条「修复完成」；失败则只写日志，等人或 AI 来看

不做什么：
    不做"掉线提醒"。发不出去的提醒是自欺欺人，见上文。

防反复重启：
    - 失败后指数退避：30s → 2min → 5min → 15min
    - 每小时最多修复 N 次（默认 3），超了就不再折腾，只写日志
    - 自己重启 AstrBot 也不会清空计数（状态落盘）
"""

import asyncio
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from astrbot.api import logger
from astrbot.api.event import AstrMessageEvent, MessageChain, filter
from astrbot.api.star import Context, Star

PLUGIN_DIR = Path(__file__).resolve().parent
SETTINGS_FILE = PLUGIN_DIR / "settings.json"
STATE_FILE = PLUGIN_DIR / "state.json"
LOG_DIR = PLUGIN_DIR / "logs"

DEFAULT_SETTINGS = {
    "enabled": True,
    "napcat_dir": "",
    "onebot_port": 6199,
    "owner_qq": "",
    "check_interval_sec": 60,
    "max_repair_per_hour": 3,
    "backoff_seconds": [30, 120, 300, 900],
    "repair_script": "repair.ps1",
    "quiet_hours": [],
}


def _now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _load_json(path: Path, default):
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        logger.warning(f"[almost_perfect] 读 {path.name} 失败：{exc}")
    return dict(default) if isinstance(default, dict) else default


def _save_json(path: Path, data) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        logger.warning(f"[almost_perfect] 写 {path.name} 失败：{exc}")


class AlmostPerfect(Star):
    def __init__(self, context: Context):
        super().__init__(context)
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.settings = {**DEFAULT_SETTINGS, **_load_json(SETTINGS_FILE, DEFAULT_SETTINGS)}
        self.state = _load_json(STATE_FILE, {})
        self.state.setdefault("repair_times", [])
        self.state.setdefault("consecutive_failures", 0)
        self.state.setdefault("last_umo", "")
        self.state.setdefault("was_down", False)
        self._task: asyncio.Task | None = None

    # ── 生命周期 ─────────────────────────────────────────────────────────
    async def initialize(self):
        if self._task and not self._task.done():
            return
        self._task = asyncio.create_task(self._watch_loop())
        logger.info("[almost_perfect] 看门狗已启动")

    async def terminate(self):
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        logger.info("[almost_perfect] 看门狗已停止")

    # ── 记住"往哪儿发消息" ───────────────────────────────────────────────
    @filter.event_message_type(filter.EventMessageType.ALL)
    async def _remember_session(self, event: AstrMessageEvent):
        umo = getattr(event, "unified_msg_origin", "")
        if umo and umo != self.state.get("last_umo"):
            self.state["last_umo"] = umo
            _save_json(STATE_FILE, self.state)

    # ── 指令 ────────────────────────────────────────────────────────────
    @filter.command("ap")
    async def ap(self, event: AstrMessageEvent):
        """Almost perfect 控制台：/ap status|check|repair|on|off"""
        arg = event.message_str.strip().split()
        sub = arg[1].lower() if len(arg) > 1 else "status"

        if sub == "on":
            self.settings["enabled"] = True
            _save_json(SETTINGS_FILE, self.settings)
            yield event.plain_result("看门狗已开启")
            return
        if sub == "off":
            self.settings["enabled"] = False
            _save_json(SETTINGS_FILE, self.settings)
            yield event.plain_result("看门狗已关闭（不会再自动修复）")
            return
        if sub == "check":
            health = await self._check_health()
            yield event.plain_result(self._format_health(health))
            return
        if sub == "repair":
            yield event.plain_result("开始手动修复，稍后回报结果…")
            ok, detail = await self._repair_once(force=True)
            yield event.plain_result(("修复结果：" + detail))
            return

        health = await self._check_health()
        yield event.plain_result(self._format_health(health))

    # ── 检测 ────────────────────────────────────────────────────────────
    async def _check_health(self) -> dict:
        port = int(self.settings.get("onebot_port") or 6199)
        script = (
            "$nap = @(Get-CimInstance Win32_Process -Filter \"Name='NapCatWinBootMain.exe'\" "
            "-ErrorAction SilentlyContinue); "
            f"$conn = @(Get-NetTCPConnection -RemotePort {port} -State Established "
            "-ErrorAction SilentlyContinue); "
            "[pscustomobject]@{ napcat = ($nap.Count -gt 0); "
            "connected = ($conn.Count -gt 0); "
            "pids = @($nap | ForEach-Object { $_.ProcessId }) } | ConvertTo-Json -Compress"
        )
        try:
            out = await self._run_ps(script, timeout=25)
            data = json.loads(out.strip() or "{}")
        except Exception as exc:  # noqa: BLE001
            return {"napcat": None, "connected": None, "error": str(exc)}
        return data

    def _format_health(self, health: dict) -> str:
        if health.get("error"):
            return f"检查失败：{health['error']}"
        nap = "在" if health.get("napcat") else "不在"
        con = "已连接" if health.get("connected") else "未连接"
        times = len(self.state.get("repair_times", []))
        return (
            f"NapCat 进程：{nap}（PID {health.get('pids')}）\n"
            f"与 AstrBot 连接：{con}\n"
            f"最近一小时修复次数：{times}\n"
            f"看门狗：{'开启' if self.settings.get('enabled') else '关闭'}"
        )

    # ── 主循环 ──────────────────────────────────────────────────────────
    async def _watch_loop(self):
        # 启动后先等 AstrBot 自己就绪
        await asyncio.sleep(20)
        while True:
            try:
                await self._tick()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                logger.warning(f"[almost_perfect] 巡检异常：{exc}")
            await asyncio.sleep(max(15, int(self.settings.get("check_interval_sec") or 60)))

    async def _tick(self):
        if not self.settings.get("enabled", True):
            return

        health = await self._check_health()
        if health.get("error"):
            return

        healthy = bool(health.get("napcat")) and bool(health.get("connected"))

        if healthy:
            if self.state.get("was_down"):
                self.state["was_down"] = False
                self.state["consecutive_failures"] = 0
                _save_json(STATE_FILE, self.state)
                await self._notify("修复完成：NapCat 已重新登录并连上 AstrBot。")
            return

        # 不健康
        if not health.get("napcat"):
            reason = "NapCat 进程不在了"
        else:
            reason = "NapCat 在跑，但和 AstrBot 的连接断了"

        self.state["was_down"] = True
        _save_json(STATE_FILE, self.state)
        logger.warning(f"[almost_perfect] 检测到掉线：{reason}")

        if not self._may_repair():
            logger.warning("[almost_perfect] 达到本次上限，暂不重启（防止反复重启）")
            return

        ok, detail = await self._repair_once()
        if ok:
            await self._notify(f"修复完成：{detail}")
        else:
            logger.warning(f"[almost_perfect] 修复未成功：{detail}")

    # ── 防反复重启 ──────────────────────────────────────────────────────
    def _may_repair(self) -> bool:
        now = time.time()
        times = [t for t in self.state.get("repair_times", []) if now - t < 3600]
        self.state["repair_times"] = times
        limit = int(self.settings.get("max_repair_per_hour") or 3)
        if len(times) >= limit:
            return False

        # 退避：连续失败越多，等得越久
        fails = int(self.state.get("consecutive_failures") or 0)
        backoff = self.settings.get("backoff_seconds") or [30, 120, 300, 900]
        wait = backoff[min(fails, len(backoff) - 1)]
        last = self.state.get("last_attempt_at") or 0
        return (now - last) >= wait

    # ── 修复 ────────────────────────────────────────────────────────────
    async def _repair_once(self, force: bool = False):
        napcat_dir = str(self.settings.get("napcat_dir") or "").strip()
        if not napcat_dir:
            return False, "没配置 NapCat 目录（settings.json 的 napcat_dir）"

        script = PLUGIN_DIR / str(self.settings.get("repair_script") or "repair.ps1")
        if not script.exists():
            return False, f"修复脚本不存在：{script}"

        self.state["last_attempt_at"] = time.time()
        self.state.setdefault("repair_times", []).append(time.time())
        _save_json(STATE_FILE, self.state)

        port = int(self.settings.get("onebot_port") or 6199)
        args = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(script),
            "-NapCatDir", napcat_dir,
            "-Port", str(port),
            "-LogDir", str(LOG_DIR),
        ]
        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=300)
            text = (out or b"").decode("utf-8", errors="replace")
        except asyncio.TimeoutError:
            self._bump_failure("修复脚本超过 5 分钟没结束", "")
            return False, "修复脚本超时"
        except Exception as exc:  # noqa: BLE001
            self._bump_failure(str(exc), "")
            return False, f"修复脚本起不来：{exc}"

        rc = proc.returncode
        if rc == 0:
            self.state["consecutive_failures"] = 0
            _save_json(STATE_FILE, self.state)
            return True, "已重新拉起并连上 AstrBot"

        if rc == 2:
            # 需要扫码：二维码已经打开并落盘，但主人此时收不到消息（通道断了）
            self._bump_failure("需要扫码登录", text)
            return False, "需要扫码登录（二维码已打开，见 logs 目录）"

        self._bump_failure(f"修复脚本退出码 {rc}", text)
        return False, f"修复失败（退出码 {rc}），详情见 logs 目录"

    def _bump_failure(self, reason: str, output: str) -> None:
        self.state["consecutive_failures"] = int(self.state.get("consecutive_failures") or 0) + 1
        _save_json(STATE_FILE, self.state)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        path = LOG_DIR / f"repair-{stamp}.log"
        try:
            path.write_text(
                f"[{_now_str()}] {reason}\n\n{output}\n",
                encoding="utf-8",
            )
        except Exception:  # noqa: BLE001
            pass
        self._write_help_note(reason)

    def _write_help_note(self, reason: str) -> None:
        """把"该找谁看"写成一个显眼的文件，放在插件目录下。"""
        note = PLUGIN_DIR / "修复失败-请看这里.txt"
        try:
            note.write_text(
                "Almost perfect 自动修复没有成功。\n\n"
                f"时间：{_now_str()}\n"
                f"原因：{reason}\n\n"
                "怎么办：\n"
                "  1) 打开 AstrBot 面板看日志：http://127.0.0.1:6185\n"
                f"  2) 本目录 logs\\ 里有每次修复的详细输出：{LOG_DIR}\n"
                "  3) 手动试一次：双击启动.cmd，或在 QQ 里发 /ap repair\n"
                "  4) 还不行，把 logs 目录整个发给懂的人（或者直接问 AI）\n",
                encoding="utf-8",
            )
        except Exception:  # noqa: BLE001
            pass

    # ── 发消息 ──────────────────────────────────────────────────────────
    async def _notify(self, text: str) -> None:
        umo = self.state.get("last_umo") or ""
        if not umo:
            logger.info(f"[almost_perfect] 还没有会话记录，消息没发：{text}")
            return
        try:
            await self.context.send_message(umo, MessageChain().message(text))
            logger.info(f"[almost_perfect] 已通知：{text}")
        except Exception as exc:  # noqa: BLE001
            logger.warning(f"[almost_perfect] 通知失败：{exc}")

    # ── 工具 ────────────────────────────────────────────────────────────
    async def _run_ps(self, script: str, timeout: int = 30) -> str:
        proc = await asyncio.create_subprocess_exec(
            "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0:
            raise RuntimeError((err or b"").decode("utf-8", errors="replace")[:400])
        return (out or b"").decode("utf-8", errors="replace")
