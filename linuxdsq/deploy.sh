#!/usr/bin/env bash
# =============================================================================
#  DSH-QQ 一键部署 · Ubuntu / Debian 版
#
#  和 Windows 版同一套思路：
#    1) 环境检查
#    2) 官方脚本装 AstrBot（uv + Python 3.12，可选大陆镜像）
#    3) astrbot init + 写 OneBot 平台（端口 + token）+ 模型 + 管理员
#    4) 官方脚本装 NapCat（自带 QQ + Xvfb，无需桌面环境）
#    5) 把 AstrBot 的端口和 token 写进 NapCat 的反向 WS 客户端
#    6) 起服务、等两端握手
#    7) 提示登录方式（终端二维码 / SSH 隧道开 WebUI）
#
#  用法：
#    sudo bash deploy.sh --qq 123456789 --api-key sk-xxx
#    sudo bash deploy.sh --qq 123456789 --self-check
#    sudo bash deploy.sh --probe
# =============================================================================
set -Eeuo pipefail

APP_NAME="DSH-QQ 一键部署 (Ubuntu)"
ROOT_DIR="/opt/dsh-qq-deploy"
LOG_DIR="${ROOT_DIR}/logs"
WORK_DIR="${ROOT_DIR}/astrbot"
NAPCAT_HOME="${HOME}/Napcat"
ONEBOT_PORT=6199
QQ=""
API_KEY=""
MODEL="deepseek-flash"
MODE="native"          # native | docker
DOWNLOAD_SOURCE="china"
INSTALL_DEPS=1
DO_PROBE=0
DO_SELF_CHECK=0
DO_UNINSTALL=0
ACTION="deploy"
GROUP_MODE=0
WAKE_WORD="小五"
GROUP_ID=""

# ── 输出 ────────────────────────────────────────────────────────────────────
c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_gray=$'\033[90m'

logfile=""
log()  { echo "[$(date '+%F %T')] $*" | tee -a "${logfile:-/dev/null}" >/dev/null; }
say()  { printf '%s\n' "$*"; }
step() { echo; printf '%s[%s] %s%s\n' "$c_cyan" "$1" "$2" "$c_reset"; }
ok()   { printf '%s    √ %s%s\n' "$c_green" "$*" "$c_reset"; log "OK  $*"; }
info() { printf '%s    · %s%s\n' "$c_gray" "$*" "$c_reset"; log ".. $*"; }
warn() { printf '%s    ! %s%s\n' "$c_yellow" "$*" "$c_reset"; log "WARN $*"; }

die() {
  local reason="$1"; shift || true
  echo
  printf '%s──────────────────────────────────────────────%s\n' "$c_red" "$c_reset"
  printf '%s✗ 失败：%s%s\n' "$c_red" "$reason" "$c_reset"
  if [ $# -gt 0 ]; then
    echo
    printf '%s怎么办：%s\n' "$c_yellow" "$c_reset"
    while [ $# -gt 0 ]; do printf '%s  %s%s\n' "$c_yellow" "$1" "$c_reset"; shift; done
  fi
  echo
  printf '%s完整日志：%s%s\n' "$c_gray" "${logfile:-（还没开始写）}" "$c_reset"
  printf '%s──────────────────────────────────────────────%s\n' "$c_red" "$c_reset"
  log "FAIL $reason"
  exit 1
}

trap 'die "脚本在第 ${LINENO} 行出错了" "把上面这段报错原文发出来；完整日志在 ${logfile:-/dev/null}"' ERR

# ── 参数 ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
用法: sudo bash deploy.sh [选项]

  --qq <号码>            机器人 QQ（必填，除 --probe / --self-check）
  --api-key <key>        模型 API Key（可选，之后也能在 WebUI 填）
  --model <名字>         默认 deepseek-flash
  --mode <native|docker> 默认 native（官方安装器，自带 QQ + Xvfb）
                         docker 走 mlikiowa/napcat-docker
  --port <端口>          AstrBot 的 OneBot 端口，默认 6199
  --workdir <目录>       AstrBot 工作目录，默认 /opt/dsh-qq-deploy/astrbot
  --source <china|official>  下载源，默认 china
  --no-deps              跳过 apt 依赖安装
  --action <名字>        deploy|check|start|stop|status|backup|logs（默认 deploy）
  --group                群聊预设：唤醒词 + 群白名单 + 限流，Agent 权限保持关闭
  --wake <词>            唤醒词，默认 小五
  --group-id <群号>      群白名单（可选，之后也能在面板里加）
  --probe                只探测，不写任何配置
  --self-check           只体检
  --uninstall            回滚 AstrBot 配置 + 停服务
  -h, --help             这个帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --qq) QQ="${2:-}"; shift 2 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --port) ONEBOT_PORT="${2:-}"; shift 2 ;;
    --workdir) WORK_DIR="${2:-}"; shift 2 ;;
    --source) DOWNLOAD_SOURCE="${2:-}"; shift 2 ;;
    --no-deps) INSTALL_DEPS=0; shift ;;
    --action) ACTION="${2:-deploy}"; shift 2 ;;
    --group) GROUP_MODE=1; shift ;;
    --wake) WAKE_WORD="${2:-小五}"; shift 2 ;;
    --group-id) GROUP_ID="${2:-}"; shift 2 ;;
    --probe) DO_PROBE=1; shift ;;
    --self-check) DO_SELF_CHECK=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "不认识的参数：$1" "运行 bash deploy.sh --help 看用法" ;;
  esac
done

mkdir -p "$LOG_DIR"
logfile="${LOG_DIR}/deploy-$(date '+%Y%m%d-%H%M%S').log"
touch "$logfile"

# ── 工具 ────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "这一步需要 root（要装系统包、写 systemd 服务）" "用 sudo 重跑：sudo bash deploy.sh ..."
  fi
}

as_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then echo "$SUDO_USER"; else echo "$(id -un)"; fi
}

user_home() {
  local u; u="$(as_user)"
  getent passwd "$u" 2>/dev/null | cut -d: -f6 || echo "$HOME"
}

run_as_user() {
  local u; u="$(as_user)"
  if [ "$u" = "$(id -un)" ]; then bash -lc "$*"; else sudo -u "$u" -H bash -lc "$*"; fi
}

port_listening() {
  if have ss; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; else
    (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1
  fi
}

wait_until() { # wait_until <秒> <描述> <命令...>
  local timeout="$1" desc="$2"; shift 2
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then printf '\n'; return 0; fi
    printf '\r%s    等待 %s ... 还剩 %s 秒%s' "$c_gray" "$desc" "$((timeout - waited))" "$c_reset"
    sleep 2; waited=$((waited + 2))
  done
  printf '\n'; return 1
}

install_deps() {
  step 1 "检查环境并安装依赖"
  if [ "$INSTALL_DEPS" -eq 1 ]; then
    if have apt-get; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1 || warn "apt update 有点问题，继续尝试"
      local pkgs="curl ca-certificates unzip xz-utils jq xvfb fonts-noto-cjk"
      info "apt 安装：$pkgs（2C2G 机器第一次跑要一两分钟）"
      if ! apt-get install -y -qq $pkgs >>"$logfile" 2>&1; then
        warn "有一批包装不上，退一步只装关键的"
        apt-get install -y -qq curl ca-certificates unzip jq >>"$logfile" 2>&1 || \
          die "系统依赖装不上" "先手动执行：sudo apt update && sudo apt install -y curl ca-certificates unzip jq xvfb" 
      fi
      ok "系统依赖就绪"
    else
      warn "不是 apt 系系统（Debian/Ubuntu 才有），依赖自己确认：curl unzip jq xvfb"
    fi
  else
    info "按 --no-deps 跳过依赖安装"
  fi

  [ "$(uname -m)" = "x86_64" ] || warn "当前架构 $(uname -m)：NapCat 官方安装器支持 amd64/arm64，其他架构要自查"
  local mem_kb; mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  local mem_mb=$((mem_kb / 1024))
  if [ "$mem_mb" -lt 1800 ]; then
    warn "内存只有 ${mem_mb} MB：建议先加 1~2 GB swap，不然装 Python 依赖时容易被 OOM 杀掉"
    info "临时开 swap：sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
  else
    ok "内存 ${mem_mb} MB"
  fi
  local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  [ "$free_mb" -gt 4000 ] || warn "磁盘只剩 ${free_mb} MB：AstrBot + NapCat + QQ 大约要 3 GB"
  ok "磁盘可用 ${free_mb} MB"
}

# ── AstrBot ────────────────────────────────────────────────────────────────
astrbot_cli() {
  local p
  p="$(command -v astrbot || true)"
  [ -n "$p" ] && { echo "$p"; return; }
  for p in "$(user_home)/.local/bin/astrbot" "${HOME}/.local/bin/astrbot" "/root/.local/bin/astrbot"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  echo ""
}

install_astrbot() {
  step 2 "安装 AstrBot（官方脚本，下载源：${DOWNLOAD_SOURCE}）"
  local cli; cli="$(astrbot_cli)"
  if [ -n "$cli" ]; then ok "已经装了：$cli"; return; fi

  local tmp="/tmp/astrbot-install.sh"
  info "下载安装脚本：https://docs.astrbot.app/install.sh"
  if ! curl -fsSL --connect-timeout 20 --max-time 120 https://docs.astrbot.app/install.sh -o "$tmp"; then
    die "下载 AstrBot 安装脚本失败" \
        "检查网络/代理；或手动执行：curl -fsSL https://docs.astrbot.app/install.sh | bash" \
        "装完再重跑本脚本（会自动认出 astrbot）"
  fi

  info "开始安装（uv + Python 3.12 + astrbot），可能要几分钟"
  if ! run_as_user "bash '$tmp' --language zh-CN --download-source '$DOWNLOAD_SOURCE' --non-interactive" >>"$logfile" 2>&1; then
    die "AstrBot 安装脚本失败" "看日志：$logfile" "也可以手动跑：bash $tmp --language zh-CN --download-source china --non-interactive"
  fi
  cli="$(astrbot_cli)"
  [ -n "$cli" ] || die "装完了但找不到 astrbot 命令" \
    "PATH 没刷新：source ~/.bashrc 后再跑本脚本" \
    "或手动确认：ls ~/.local/bin/astrbot"
  ok "AstrBot 已安装：$cli"
}

init_workdir() {
  step 3 "初始化 AstrBot 工作目录"
  mkdir -p "$WORK_DIR"
  local u; u="$(as_user)"
  chown -R "$u":"$u" "$WORK_DIR" 2>/dev/null || true

  if [ -f "${WORK_DIR}/data/cmd_config.json" ]; then ok "已有配置，跳过 init"; return; fi
  info "astrbot init（工作目录：$WORK_DIR）"
  run_as_user "cd '$WORK_DIR' && astrbot init" >>"$logfile" 2>&1 || warn "astrbot init 返回非零，继续（run 时会自己生成）"
  [ -f "${WORK_DIR}/data/cmd_config.json" ] && ok "配置已生成" || info "还没生成，起一次服务再补"
}

write_astrbot_config() {
  step 4 "写 AstrBot 的 OneBot 平台 / 模型 / 管理员"
  local cfg="${WORK_DIR}/data/cmd_config.json"
  if [ ! -f "$cfg" ]; then
    warn "还没有 cmd_config.json：先起一次 AstrBot"
    start_astrbot
    wait_until 120 "AstrBot 生成配置" test -f "$cfg" || die "AstrBot 起了却没生成配置" "看日志：${LOG_DIR}/astrbot.out.log"
  fi

  cp -f "$cfg" "${cfg}.bak-$(date '+%Y%m%d-%H%M%S')"

  local token
  token="$(jq -r '(.platform // [])[] | select(.type=="aiocqhttp") | .ws_reverse_token // empty' "$cfg" 2>/dev/null | head -n1 || true)"
  if [ -z "$token" ]; then
    token="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  fi

  local tmpc; tmpc="$(mktemp)"
  jq --argjson port "$ONEBOT_PORT" --arg token "$token" '
    .platform = ((.platform // []) | if any(.type=="aiocqhttp") then
        map(if .type=="aiocqhttp" then (.enable=true | .ws_reverse_host="0.0.0.0" | .ws_reverse_port=$port | .ws_reverse_token=$token) else . end)
      else
        . + [{id:"deploy", type:"aiocqhttp", enable:true, ws_reverse_host:"0.0.0.0", ws_reverse_port:$port, ws_reverse_token:$token}]
      end)
  ' "$cfg" > "$tmpc" && mv "$tmpc" "$cfg"

  if [ -n "$API_KEY" ]; then
    tmpc="$(mktemp)"
    jq --arg key "$API_KEY" --arg model "$MODEL" '
      .provider_sources = ((.provider_sources // []) | if any(.provider=="deepseek") then
          map(if .provider=="deepseek" then (.key=[$key] | .enable=true) else . end)
        else
          . + [{provider:"deepseek", type:"openai_chat_completion", provider_type:"chat_completion",
                key:[$key], api_base:"https://api.deepseek.com/v1", timeout:120, proxy:"",
                custom_headers:{}, id:"deepseek", enable:true}]
        end) |
      .provider = ((.provider // []) | if any(.id==("deepseek/"+$model)) then .
        else . + [{id:("deepseek/"+$model), enable:true, provider_source_id:"deepseek", model:$model,
                   modalities:["text","image","tool_use"], custom_extra_body:{}, max_context_tokens:1000000}] end)
    ' "$cfg" > "$tmpc" && mv "$tmpc" "$cfg"
    ok "模型 deepseek/${MODEL} 已写入"
  else
    info "没给 API Key：模型不动，之后在 WebUI 填"
  fi

  if [ -n "$QQ" ]; then
    tmpc="$(mktemp)"
    jq --arg qq "$QQ" '
      .admins_id = (((.admins_id // []) | map(select(type=="string" and (test("^[0-9]{5,12}$") or .=="astrbot")))) + [$qq] | unique)
    ' "$cfg" > "$tmpc" && mv "$tmpc" "$cfg"
    ok "管理员已加入 $QQ"
  fi

  if [ "$GROUP_MODE" -eq 1 ]; then
    tmpc="$(mktemp)"
    jq --arg wake "$WAKE_WORD" --arg gid "$GROUP_ID" '
      .platform_settings = (.platform_settings // {}) |
      .platform_settings.enable_id_white_list = true |
      .platform_settings.id_whitelist = (((.platform_settings.id_whitelist // []) | map(tostring)) + (if $gid != "" then [$gid] else [] end) | unique) |
      .platform_settings.rate_limit = ((.platform_settings.rate_limit // {}) + {time:60, count:12, strategy:"stall"}) |
      .platform_settings.friend_message_needs_wake_prefix = false |
      .platform_settings.ignore_bot_self_message = true |
      .wake_prefix = [$wake] |
      .provider_settings = (.provider_settings // {}) |
      .provider_settings.computer_use_require_admin = true |
      .provider_settings.computer_use_local_permissions = (.provider_settings.computer_use_local_permissions // {}) |
      .provider_settings.computer_use_local_permissions.member = ((.provider_settings.computer_use_local_permissions.member // {}) + {allow_execution:false, allow_network:false, filesystem_scope:"workspace"})
    ' "$cfg" > "$tmpc" && mv "$tmpc" "$cfg"
    ok "群聊预设：唤醒词「${WAKE_WORD}」"
    if [ -n "$GROUP_ID" ]; then ok "群白名单：${GROUP_ID}"; else info "没给群号：白名单留空，之后在群里用 /sid 拿到群号再加"; fi
    ok "限流：每人每分钟 12 条"
    ok "Agent 执行权限保持关闭"
  fi

  local u; u="$(as_user)"; chown "$u":"$u" "$cfg" 2>/dev/null || true
  printf '%s' "$token" > "${LOG_DIR}/onebot-token.txt"; chmod 600 "${LOG_DIR}/onebot-token.txt"
  ok "OneBot 服务端：端口 ${ONEBOT_PORT}，token 已就绪"
}

service_unit() {
  cat <<EOF
[Unit]
Description=DSH QQ deploy - $1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$2
WorkingDirectory=$3
ExecStart=$4
Restart=always
RestartSec=5
StandardOutput=append:${LOG_DIR}/$1.out.log
StandardError=append:${LOG_DIR}/$1.err.log
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

start_astrbot() {
  local u; u="$(as_user)"
  local cli; cli="$(astrbot_cli)"
  [ -n "$cli" ] || die "找不到 astrbot 命令" "source ~/.bashrc 后重跑，或 grep -r astrbot ~/.local/bin"

  if have systemctl; then
    service_unit "astrbot" "$u" "$WORK_DIR" "$cli run" > /etc/systemd/system/astrbot.service
    systemctl daemon-reload
    systemctl enable astrbot >/dev/null 2>&1 || true
    systemctl restart astrbot || die "astrbot.service 起不来" "看：journalctl -u astrbot -n 80 --no-pager"
    ok "astrbot.service 已启动（开机自启）"
  else
    info "没有 systemd，用 nohup 后台跑"
    run_as_user "cd '$WORK_DIR' && nohup '$cli' run >>'${LOG_DIR}/astrbot.out.log' 2>&1 &" || die "AstrBot 启动失败" "看日志：${LOG_DIR}/astrbot.out.log"
    ok "AstrBot 已在后台运行"
  fi

  wait_until 180 "AstrBot 打开 ${ONEBOT_PORT} 端口" port_listening "$ONEBOT_PORT" || {
    tail -n 15 "${LOG_DIR}/astrbot.out.log" 2>/dev/null || true
    die "AstrBot 的 OneBot 端口 ${ONEBOT_PORT} 没起来" \
        "看日志：journalctl -u astrbot -n 80 --no-pager" \
        "端口被占用就换：--port 8123（脚本会同步改 NapCat）"
  }
  ok "AstrBot 服务端就绪：${ONEBOT_PORT}"
}

# ── NapCat ─────────────────────────────────────────────────────────────────
install_napcat_native() {
  step 5 "安装 NapCat（官方安装器：自带 QQ + Xvfb）"
  if have napcat || { [ -d "$NAPCAT_HOME" ] && find "$NAPCAT_HOME" -maxdepth 4 -name 'napcat' 2>/dev/null | head -n1 | grep -q .; }; then
    ok "已经装过：$NAPCAT_HOME"
    return
  fi

  local tmp="/tmp/napcat-install.sh"
  info "下载安装脚本（GitHub 直连，失败会自动换加速地址）"
  local urls=(
    "https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh"
    "https://ghproxy.net/https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh"
    "https://ghfast.top/https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh"
  )
  local okdl=0 u
  for u in "${urls[@]}"; do
    if run_as_user "curl -fL --connect-timeout 20 --max-time 300 -o '$tmp' '$u'"; then okdl=1; break; fi
  done
  [ "$okdl" -eq 1 ] || die "下载 NapCat 安装脚本失败" \
    "本机连不上 GitHub：先配代理，或手动执行官网那行 curl 到本机再 bash napcat.sh"

  info "开始安装（会下 QQ Linux 版 + NapCat，几百 MB，第一次要几分钟）"
  if ! run_as_user "bash '$tmp' --docker n --cli y --github-proxy 0" >>"$logfile" 2>&1; then
    warn "原生安装失败，看看是不是缺 Xvfb 或者下载不通；日志：$logfile"
    die "NapCat 原生安装失败" \
      "可以改用 Docker：sudo bash deploy.sh --mode docker --qq ${QQ}" \
      "或者手动：bash $tmp --docker n --cli y --github-proxy 0 看它报什么"
  fi
  ok "NapCat 安装完成（$NAPCAT_HOME）"
}

napcat_config_dir() {
  local d
  d="$(find "$NAPCAT_HOME" -maxdepth 6 -type d -path '*napcat/config' 2>/dev/null | head -n1 || true)"
  [ -n "$d" ] && { echo "$d"; return; }
  echo "${NAPCAT_HOME}/config"
}

write_napcat_config_native() {
  step 6 "把服务端信息写进 NapCat（反向 WS 客户端）"
  local token; token="$(cat "${LOG_DIR}/onebot-token.txt")"
  local cfgdir; cfgdir="$(napcat_config_dir)"
  mkdir -p "$cfgdir"
  local f="${cfgdir}/onebot11_${QQ}.json"

  if [ -f "$f" ]; then cp -f "$f" "${f}.bak-$(date '+%Y%m%d-%H%M%S')"; fi
  if [ ! -f "$f" ]; then
    echo '{"network":{"httpServers":[],"httpSseServers":[],"httpClients":[],"websocketServers":[],"websocketClients":[],"plugins":[]},"musicSignUrl":"","enableLocalFile2Url":false,"parseMultMsg":false,"imageDownloadProxy":"","timeout":{"baseTimeout":10000,"uploadSpeedKBps":256,"downloadSpeedKBps":256,"maxTimeout":1800000}}' > "$f"
  fi

  local tmpc; tmpc="$(mktemp)"
  jq --argjson port "$ONEBOT_PORT" --arg token "$token" '
    .network = (.network // {}) |
    .network.websocketClients = ((.network.websocketClients // []) |
      if any(.name=="dsh-deploy") then
        map(if .name=="dsh-deploy" then
          (.enable=true | .url=("ws://127.0.0.1:"+($port|tostring)+"/ws") | .token=$token |
           .reportSelfMessage=false | .messagePostFormat="array" | .heartInterval=30000 | .reconnectInterval=30000 | .verifyCertificate=true)
        else . end)
      else
        . + [{name:"dsh-deploy", enable:true, url:("ws://127.0.0.1:"+($port|tostring)+"/ws"),
              token:$token, reportSelfMessage:false, messagePostFormat:"array",
              heartInterval:30000, reconnectInterval:30000, verifyCertificate:true}]
      end)
  ' "$f" > "$tmpc" && mv "$tmpc" "$f"

  local u; u="$(as_user)"; chown -R "$u":"$u" "$cfgdir" 2>/dev/null || true
  ok "已启用客户端：ws://127.0.0.1:${ONEBOT_PORT}/ws"
}

install_napcat_docker() {
  step 5 "安装 NapCat（Docker 模式）"
  have docker || die "没装 Docker" "先装：curl -fsSL https://get.docker.com | sh" "装完重跑：sudo bash deploy.sh --mode docker --qq ${QQ}"
  info "写 compose 文件到 ${ROOT_DIR}/docker"
  mkdir -p "${ROOT_DIR}/docker/data/qq" "${ROOT_DIR}/docker/data/config" "${ROOT_DIR}/docker/data/plugins"
  local token; token="$(hd=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24); echo "$hd")"
  cat > "${ROOT_DIR}/docker/compose.yaml" <<EOF
services:
  napcat:
    image: mlikiowa/napcat-docker:latest
    restart: unless-stopped
    environment:
      MODE: ws
      WEBUI_TOKEN: ${token}
    ports:
      - "127.0.0.1:6099:6099"
      - "127.0.0.1:3001:3001"
    volumes:
      - ./data/qq:/app/.config/QQ
      - ./data/config:/app/napcat/config
      - ./data/plugins:/app/napcat/plugins
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
  ( cd "${ROOT_DIR}/docker" && docker compose up -d ) >>"$logfile" 2>&1 || die "docker compose 起不来" "看：cd ${ROOT_DIR}/docker && docker compose logs -n 50"
  ok "NapCat 容器已启动（WebUI token 存在 ${ROOT_DIR}/docker/compose.yaml）"
}

write_napcat_config_docker() {
  step 6 "把服务端信息写进 NapCat（Docker 数据卷）"
  local token; token="$(cat "${LOG_DIR}/onebot-token.txt")"
  local cfgdir="${ROOT_DIR}/docker/data/config"
  local f="${cfgdir}/onebot11_${QQ}.json"
  [ -f "$f" ] && cp -f "$f" "${f}.bak-$(date '+%Y%m%d-%H%M%S')"
  [ -f "$f" ] || echo '{"network":{"httpServers":[],"httpSseServers":[],"httpClients":[],"websocketServers":[],"websocketClients":[],"plugins":[]}}' > "$f"
  local tmpc; tmpc="$(mktemp)"
  jq --argjson port "$ONEBOT_PORT" --arg token "$token" '
    .network.websocketClients = ((.network.websocketClients // []) + [{name:"dsh-deploy", enable:true,
      url:("ws://host.docker.internal:"+($port|tostring)+"/ws"), token:$token,
      reportSelfMessage:false, messagePostFormat:"array", heartInterval:30000, reconnectInterval:30000, verifyCertificate:true}])
  ' "$f" > "$tmpc" && mv "$tmpc" "$f"
  ( cd "${ROOT_DIR}/docker" && docker compose restart ) >>"$logfile" 2>&1 || warn "容器重启失败，手动 restart 一次"
  ok "已写入（Docker 里连宿主机用 host.docker.internal，Compose 24+ 自带映射）"
}

start_napcat_native() {
  step 7 "启动 NapCat"
  if have systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^napcat'; then
    systemctl restart napcat || die "napcat.service 起不来" "看：journalctl -u napcat -n 80 --no-pager"
    ok "napcat.service 已启动"
  elif have napcat; then
    run_as_user "napcat start" >>"$logfile" 2>&1 || warn "napcat start 返回非零，检查它是否已经在跑"
    ok "已尝试用 napcat 命令启动"
  else
    warn "没找到 systemd 单元也没找到 napcat 命令：装完要手动启动一次"
    info "一般装完在 ${NAPCAT_HOME}，里面找 launcher / napcat 命令"
  fi

  wait_until 300 "NapCat 连上 AstrBot" bash -c "ss -tn 2>/dev/null | grep -q ':${ONEBOT_PORT}.*ESTAB'" || true
}

# ── 登录提示 / 自检 / 回滚 ────────────────────────────────────────────────
print_login_help() {
  local ip; ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  step 8 "接下来登录 QQ（两选一）"
  say "    ① 终端二维码（最简单，不用开端口）"
  say "       看 NapCat 的输出：sudo journalctl -u napcat -f --no-pager"
  say "       或者找它落盘的二维码文件：find ${NAPCAT_HOME} -name 'qrcode.png' -mmin -10"
  say "       小技巧：把 png 拖到本地看，或者在本机执行 ssh 端口转发后用 WebUI（见 ②）"
  echo
  say "    ② WebUI（在自己电脑上开，安全，别直接暴露公网）"
  say "       本机转发：ssh -N -L 6099:127.0.0.1:6099 root@${ip}"
  say "       然后浏览器打开：http://127.0.0.1:6099/webui"
  say "       登录 token 在：${NAPCAT_HOME}（找 webui.json 里的 token）"
  echo
  say "    首次登录后 NapCat 会留快速登录凭证，之后重启不用再扫。"
}

self_check() {
  step 7 "自检"
  local bad=0
  local cfg="${WORK_DIR}/data/cmd_config.json"
  local port="$ONEBOT_PORT"
  if [ -f "$cfg" ]; then
    local p; p="$(jq -r '(.platform // [])[] | select(.type=="aiocqhttp") | .ws_reverse_port // empty' "$cfg" | head -n1)"
    [ -n "$p" ] && port="$p"
  fi

  if port_listening "$port"; then ok "AstrBot OneBot 端口 ${port} 在听"; else warn "${port} 端口没在听"; bad=$((bad+1)); fi

  if (systemctl is-active --quiet astrbot 2>/dev/null) || pgrep -f 'astrbot.*run' >/dev/null 2>&1; then
    ok "AstrBot 进程在"
  else warn "AstrBot 进程不在"; bad=$((bad+1)); fi

  if pgrep -f 'napcat|NapCat|qq' >/dev/null 2>&1; then ok "NapCat / QQ 进程在"; else warn "NapCat 进程不在"; bad=$((bad+1)); fi

  if ss -tn 2>/dev/null | grep -q ":${port}.*ESTAB"; then ok "NapCat ↔ AstrBot 连接已建立"; else warn "两边还没连上（没登录 / 端口不对 / token 不一致）"; bad=$((bad+1)); fi

  echo
  if [ "$bad" -eq 0 ]; then printf '%s自检通过：去 QQ 里给机器人发一句话试试。%s\n' "$c_green" "$c_reset"
  else printf '%s自检有 %s 项没过，按上面提示处理。%s\n' "$c_yellow" "$bad" "$c_reset"; fi
  return "$bad"
}

do_uninstall() {
  step 0 "回滚"
  local cfg="${WORK_DIR}/data/cmd_config.json"
  if [ -f "$cfg" ]; then
    local bak; bak="$(ls -1t "${cfg}".bak-* 2>/dev/null | head -n1 || true)"
    if [ -n "$bak" ]; then cp -f "$bak" "$cfg"; ok "已还原 AstrBot 配置"; else warn "没找到备份"; fi
  fi
  if have systemctl; then
    systemctl stop astrbot >/dev/null 2>&1 || true
    systemctl disable astrbot >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/astrbot.service
    systemctl daemon-reload
    ok "已停并删除 astrbot.service"
  fi
  [ -f "${ROOT_DIR}/docker/compose.yaml" ] && ( cd "${ROOT_DIR}/docker" && docker compose down ) >/dev/null 2>&1 && ok "已停 Docker 里的 NapCat"
  ok "回滚完成（AstrBot / NapCat 本体没卸载）"
}

probe() {
  step 1 "环境"
  info "架构：$(uname -m)  内存：$(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)  磁盘：$(df -Pm / | awk 'NR==2{print $4" MB 可用"}')"
  info "apt：$(have apt-get && echo 有 || echo 无)  docker：$(have docker && echo 有 || echo 无)  systemd：$(have systemctl && echo 有 || echo 无)"
  local cli; cli="$(astrbot_cli)"; info "astrbot：${cli:-没装}"
  info "NapCat 目录：$([ -d "$NAPCAT_HOME" ] && echo "$NAPCAT_HOME" || echo 没装)"
  local cfg="${WORK_DIR}/data/cmd_config.json"
  info "AstrBot 配置：$cfg（存在=$([ -f "$cfg" ] && echo yes || echo no)）"
  [ -d "$NAPCAT_HOME" ] && info "NapCat 配置目录：$(napcat_config_dir)"
  say
  say "探测结束，没有改动任何文件。"
}

# ── 面向客户的动作（--action）──────────────────────────────────────────────
action_start() {
  need_root
  start_astrbot
  if have systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^napcat'; then
    systemctl start napcat || true
    ok "napcat.service 已启动"
  elif have napcat; then
    run_as_user "napcat start" >>"$logfile" 2>&1 || warn "napcat start 返回非零"
  else
    warn "没找到 napcat 服务或命令：手动启动一次"
  fi
  self_check || true
}

action_stop() {
  need_root
  if have systemctl; then
    systemctl stop astrbot >/dev/null 2>&1 || true
    systemctl stop napcat  >/dev/null 2>&1 || true
  fi
  pkill -f 'astrbot run' >/dev/null 2>&1 || true
  ok "已停止（数据保留）"
}

action_backup() {
  local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
  local bdir="${ROOT_DIR}/backups"; mkdir -p "$bdir"
  local items=()
  [ -d "${WORK_DIR}/data" ] && items+=("${WORK_DIR}/data")
  local ncdir; ncdir="$(napcat_config_dir)"; [ -d "$ncdir" ] && items+=("$ncdir")
  if [ ${#items[@]} -eq 0 ]; then die "没有可备份的内容" "先部署一次再备份"; fi
  tar -czf "${bdir}/backup-${stamp}.tar.gz" "${items[@]}" >>"$logfile" 2>&1 || die "打包失败" "文件被占用就先 --action stop 再备份"
  ok "备份完成：${bdir}/backup-${stamp}.tar.gz"
  ls -1t "${bdir}"/backup-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
  info "保留最近 10 份"
}

action_logs() {
  if have journalctl && systemctl list-unit-files 2>/dev/null | grep -q '^astrbot'; then
    journalctl -u astrbot -f --no-pager
  else
    tail -n 40 -f "${LOG_DIR}/astrbot.out.log"
  fi
}

# ── 主流程 ─────────────────────────────────────────────────────────────────

main() {
  say "=== ${APP_NAME} ==="
  say "时间：$(date '+%F %T')"

  [ "$DO_UNINSTALL" -eq 1 ] && { need_root; do_uninstall; exit 0; }
  [ "$DO_PROBE" -eq 1 ] && { probe; exit 0; }
  [ "$DO_SELF_CHECK" -eq 1 ] && { self_check || true; exit 0; }

  case "$ACTION" in
    deploy) : ;;
    check)  probe; exit 0 ;;
    start)  action_start; exit 0 ;;
    stop)   action_stop; exit 0 ;;
    status) self_check || true; exit 0 ;;
    backup) need_root; action_backup; exit 0 ;;
    logs)   action_logs; exit 0 ;;
    *)      die "未知 --action：${ACTION}" "可用：deploy|check|start|stop|status|backup|logs" ;;
  esac

  [ -n "$QQ" ] || read -r -p "请输入机器人 QQ 号（纯数字）: " QQ
  [[ "$QQ" =~ ^[0-9]{5,12}$ ]] || die "QQ 号格式不对：${QQ}" "只填数字，5~12 位"
  if [ -z "$API_KEY" ]; then
    read -r -s -p "请输入模型 API Key（直接回车跳过，之后在 WebUI 填）: " API_KEY; echo
  fi

  need_root
  install_deps
  install_astrbot
  init_workdir
  write_astrbot_config
  start_astrbot

  if [ "$MODE" = "docker" ]; then
    install_napcat_docker
    write_napcat_config_docker
  else
    install_napcat_native
    write_napcat_config_native
    start_napcat_native
  fi

  print_login_help
  self_check || true

  say
  say "部署完成。"
  say "  AstrBot WebUI：http://127.0.0.1:6185（用 ssh -L 6185:127.0.0.1:6185 转发后看）"
  say "  日志目录：${LOG_DIR}"
  say
}

main "$@"
