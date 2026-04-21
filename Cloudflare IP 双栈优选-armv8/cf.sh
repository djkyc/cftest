#!/bin/bash

# ====================================================
# VPS Cloudflare IPv4/IPv6 双栈优选 - ARMv8 版（自动运行）
# 作者: djcky（适配 ARMv8）+ 路径自适应增强（N1/U盘通用）
# 定制逻辑：只保留3个最优有效IP，多余有效IP精准清理，不足才补充
# 新增功能：Telegram / 微信通知推送与状态面板显示
# ====================================================

set -euo pipefail

ulimit -n 65535 2>/dev/null || true

# ====================================================
# 【自动获取脚本真实路径，支持任意位置/U盘】
# ====================================================
SCRIPT_PATH="$(readlink -f "$0")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# ====================================================
# 全局配置
# ====================================================

# ===== Cloudflare 认证信息（共用）=====
CF_API_TOKEN="cfut_FfJElWNyiGzlSxqdhyDLO7vWFTebNtnczuSSHmAof2c6c0a8xxxx"
CF_ZONE_ID="0fca3e58687f3b3eb2772c56712a4113xxxx"

# ===== 代理配置 (仅用于 API 请求，测速不走代理) =====
CF_API_PROXY="http://127.0.0.1:7890"

# ===== 自建微信推送配置（可选）=====
WECHAT_API_URL="域名地址帮定在cf上的/wxsend"
WECHAT_AUTH_TOKEN="在CF的变量密码"
WECHAT_BODY_TEMPLATE='{"title":"Cloudflare IP 双栈优选","content":"$MSG"}'

# ===== Telegram 推送配置（必填：替换成你的 TG 信息）=====
TG_BOT_TOKEN="7764238150:AAEfmfILigvPoJcisLdlYdrhrCRA5k_idbg"  # 你的机器人Token
TG_CHAT_ID="7646414260"                                      # 你的聊天ID/频道ID
TG_API_URL="https://api.telegram.org/bot"                   # TG API地址（无需修改）
# 如需代理访问TG，取消下面注释并填写代理地址
TG_PROXY="http://192.168.2.80:7890"

# ===== 规则参数（共用）=====
MAX_LATENCY_MS=120
CHECK_PORT=443
MAX_RETRIES=2

# ===== 优选的 Cloudflare 数据中心 =====

COLOS=("FRA" "NRT" "SIN" "SJC")  
# HKG="香港"，NRT="东京"，"SIN"=新加坡，"SJC"=圣何塞 加拿大="YYZ" 澳大利亚="SYD" 英国="LHR" 俄罗斯="LED" 迪拜="DXB" 德国="FRA" 印度="BOM" 巴西="GRU"

# ====================================================
# IPv4 配置（只保留3个）
# ====================================================
IPV4_WORK_DIR="$BASE_DIR/ipv4"
IPV4_CFST="$IPV4_WORK_DIR/cfstipv4"
IPV4_IP_FILE="$IPV4_WORK_DIR/ipv4.txt"
IPV4_RESULT_CSV="$IPV4_WORK_DIR/result_ipv4.csv"
IPV4_LOG="$IPV4_WORK_DIR/log_ipv4.txt"
IPV4_TEMP_EXISTING="$IPV4_WORK_DIR/existing_ips.txt"
IPV4_RECORD_NAME="ipv4.eee.xx.kg"
IPV4_RECORD_TYPE="A"
IPV4_MAX_IPS=3  

# ====================================================
# IPv6 配置（只保留3个）
# ====================================================
IPV6_WORK_DIR="$BASE_DIR/ipv6"
IPV6_CFST="$IPV6_WORK_DIR/cfstipv6"
IPV6_IP_FILE="$IPV6_WORK_DIR/ipv6.txt"
IPV6_RESULT_CSV="$IPV6_WORK_DIR/result_ipv6.csv"
IPV6_LOG="$IPV6_WORK_DIR/log_ipv6.txt"
IPV6_TEMP_EXISTING="$IPV6_WORK_DIR/existing_ips.txt"
IPV6_RECORD_NAME="ipv6.eee.xx.kg"
IPV6_RECORD_TYPE="AAAA"
IPV6_MAX_IPS=3  

# ====================================================
# 运行时变量
# ====================================================
CURRENT_LOG=""
DELETED_IPS=()
ADDED_IPS=()
IPV4_SUMMARY=""
IPV6_SUMMARY=""
WECHAT_PUSH_STATUS="未配置"
TG_PUSH_STATUS="未配置"

# ====================================================
# 工具函数
# ====================================================
get_proxy_args() {
  if [ -n "${CF_API_PROXY:-}" ]; then
    echo "-x $CF_API_PROXY"
  fi
}

get_tg_proxy_args() {
  if [ -n "${TG_PROXY:-}" ]; then
    echo "-x $TG_PROXY"
  fi
}

sleep_compat() {
  local t="$1"
  sleep "$t" 2>/dev/null || sleep 1
}

get_file_size() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo 0
    return
  fi
  if stat -c %s "$file" 2>/dev/null; then
    return
  fi
  if stat -f %z "$file" 2>/dev/null; then
    return
  fi
  wc -c < "$file" | tr -d ' '
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$CURRENT_LOG"
}

rotate_log() {
  local log_file="$1"
  if [ -f "$log_file" ]; then
    local log_size
    log_size=$(get_file_size "$log_file")
    if [ "${log_size:-0}" -gt 409600 ]; then
      tail -c 204800 "$log_file" > "$log_file.tmp" && mv "$log_file.tmp" "$log_file"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ 日志文件超过 400KB，已执行截断回滚。" >> "$log_file"
    fi
  fi
}

# ====================================================
# 架构检测
# ====================================================
CFST_VERSION="v2.2.5"
CFST_BASE_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/${CFST_VERSION}"

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7*|armhf) echo "armv7" ;;
    armv6*) echo "armv6" ;;
    i386|i686) echo "386" ;;
    mips) echo "mips" ;;
    mipsle) echo "mipsle" ;;
    *) echo "" ;;
  esac
}

detect_os() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux) echo "linux" ;;
    darwin) echo "darwin" ;;
    *) echo "" ;;
  esac
}

download_cfst() {
  local target_dir="$1"
  local target_name="$2"
  local target_path="${target_dir}/${target_name}"
  if [ -x "$target_path" ]; then return 0; fi

  local os arch
  os="$(detect_os)"
  arch="$(detect_arch)"
  if [ -z "$os" ] || [ -z "$arch" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 无法检测系统架构" | tee -a "$CURRENT_LOG"
    return 1
  fi

  local filename="CloudflareST_${os}_${arch}.tar.gz"
  local download_url="${CFST_BASE_URL}/${filename}"
  local tmp_dir="${target_dir}/tmp_cfst_$$"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📥 检测到架构: ${os}/${arch}，正在下载测速工具..." | tee -a "$CURRENT_LOG"
  mkdir -p "$tmp_dir"

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "${tmp_dir}/${filename}" "$download_url" 2>/dev/null
  elif command -v curl >/dev/null 2>&1; then
    curl -sL -o "${tmp_dir}/${filename}" "$download_url" 2>/dev/null
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 未找到 wget 或 curl" | tee -a "$CURRENT_LOG"
    rm -rf "$tmp_dir"
    return 1
  fi

  tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir" 2>/dev/null
  if [ -f "${tmp_dir}/CloudflareST" ]; then
    mv "${tmp_dir}/CloudflareST" "$target_path"
    chmod +x "$target_path"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 测速工具已安装" | tee -a "$CURRENT_LOG"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 解压失败" | tee -a "$CURRENT_LOG"
    rm -rf "$tmp_dir"
    return 1
  fi
  rm -rf "$tmp_dir"
  return 0
}

download_ip_list() {
  local target_file="$1"
  local ip_version="$2"
  if [ -s "$target_file" ]; then return 0; fi
  local url
  if [ "$ip_version" = "4" ]; then
    url="https://www.cloudflare.com/ips-v4"
  else
    url="https://www.cloudflare.com/ips-v6"
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📥 正在下载 IPv${ip_version} IP库..." | tee -a "$CURRENT_LOG"
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$target_file" "$url" 2>/dev/null
  elif command -v curl >/dev/null 2>&1; then
    curl -sL -o "$target_file" "$url" 2>/dev/null
  fi
}

ensure_cfst_ready() {
  local ip_version="$1"
  local work_dir cfst_path ip_file
  if [ "$ip_version" = "4" ]; then
    work_dir="$IPV4_WORK_DIR"
    cfst_path="$IPV4_CFST"
    ip_file="$IPV4_IP_FILE"
  else
    work_dir="$IPV6_WORK_DIR"
    cfst_path="$IPV6_CFST"
    ip_file="$IPV6_IP_FILE"
  fi
  mkdir -p "$work_dir"
  local cfst_name
  cfst_name="$(basename "$cfst_path")"
  download_cfst "$work_dir" "$cfst_name"
  download_ip_list "$ip_file" "$ip_version"
}

# ====================================================
# Cloudflare API
# ====================================================
get_current_records() {
  local record_type="$1"
  local record_name="$2"
  local proxy_args
  proxy_args="$(get_proxy_args)"
  curl -s $proxy_args -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=${record_type}&name=${record_name}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json"
}

delete_record() {
  local record_id="$1"
  local ip_val="$2"
  local reason="$3"
  local proxy_args
  proxy_args="$(get_proxy_args)"
  curl -s $proxy_args -X DELETE \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" >/dev/null 2>&1 || true
  log "🗑️ 已删除失效记录: ${ip_val} (${reason})"
  DELETED_IPS+=("${ip_val}|${reason}")
}

add_record() {
  local record_type="$1"
  local record_name="$2"
  local ip="$3"
  local latency="$4"
  local resp
  local proxy_args
  proxy_args="$(get_proxy_args)"
  resp="$(curl -s $proxy_args -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"${record_type}\",\"name\":\"${record_name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}")"
  if echo "$resp" | grep -q '"success":true'; then
    log "✅ 上报成功：${record_name} -> ${ip}"
    ADDED_IPS+=("${ip}|${latency}")
  else
    log "❌ 上报失败: ${ip}"
  fi
}

# ====================================================
# IP 校验
# ====================================================
check_connectivity() {
  local ip="$1"
  local retry=0
  local target_url
  if echo "$ip" | grep -q ":"; then
     target_url="http://[${ip}]:${CHECK_PORT}"
  else
     target_url="http://${ip}:${CHECK_PORT}"
  fi
  while [ "$retry" -lt "$MAX_RETRIES" ]; do
    if [ "$retry" -gt 0 ]; then sleep 2; fi
    if curl -s -I -m 5 --noproxy "*" "$target_url" >/dev/null 2>&1; then
      return 0
    fi
    retry=$((retry+1))
  done
  return 1
}

get_ping_avg_latency_ms() {
  local ip="$1"
  local ip_version="${2:-4}"
  local ping_output avg ping_cmd
  if [ "$ip_version" = "6" ]; then
    if command -v ping6 >/dev/null 2>&1; then
      ping_cmd="ping6"
    elif ping -6 -c 1 ::1 >/dev/null 2>&1; then
      ping_cmd="ping -6"
    else
      echo ""
      return 0
    fi
  else
    ping_cmd="ping"
  fi
  ping_output="$($ping_cmd -c 3 -W 2 -q "$ip" 2>/dev/null || true)"
  avg="$(echo "$ping_output" | grep -oP 'rtt min/avg/max/mdev = [\d.]+/\K[\d.]+' 2>/dev/null || true)"
  if [ -z "$avg" ]; then
    avg="$(echo "$ping_output" | awk -F'/' '/^rtt/ {print $5}' 2>/dev/null || true)"
  fi
  echo "$avg"
}

is_valid_ip_format() {
  local ip="$1"
  local ip_version="$2"
  if [ "$ip_version" = "4" ]; then
    echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  else
    echo "$ip" | grep -Eq '^[0-9a-fA-F:]+$'
  fi
}

# ====================================================
# 核心优选（含智能保留3个IP逻辑）
# ====================================================
run_ip_selection() {
  local ip_version="$1"
  local work_dir cfst ip_file result_csv log_file temp_existing
  local record_name record_type max_ips

  if [ "$ip_version" = "4" ]; then
    work_dir="$IPV4_WORK_DIR"
    cfst="$IPV4_CFST"
    ip_file="$IPV4_IP_FILE"
    result_csv="$IPV4_RESULT_CSV"
    log_file="$IPV4_LOG"
    temp_existing="$IPV4_TEMP_EXISTING"
    record_name="$IPV4_RECORD_NAME"
    record_type="$IPV4_RECORD_TYPE"
    max_ips="$IPV4_MAX_IPS"
  else
    work_dir="$IPV6_WORK_DIR"
    cfst="$IPV6_CFST"
    ip_file="$IPV6_IP_FILE"
    result_csv="$IPV6_RESULT_CSV"
    log_file="$IPV6_LOG"
    temp_existing="$IPV6_TEMP_EXISTING"
    record_name="$IPV6_RECORD_NAME"
    record_type="$IPV6_RECORD_TYPE"
    max_ips="$IPV6_MAX_IPS"
  fi

  CURRENT_LOG="$log_file"
  DELETED_IPS=()
  ADDED_IPS=()
  mkdir -p "$work_dir"
  rotate_log "$log_file"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "开始 IPv${ip_version} 优选..."
  log "目标域名: ${record_name}"

  if [ ! -x "$cfst" ]; then
    log "❌ 未检测到 cfst"
    return 1
  fi

  log "🔍 检查当前 Cloudflare 记录..."
  local records_json
  records_json="$(get_current_records "$record_type" "$record_name")"
  echo "$records_json" | jq -r '.result[] | "\(.id) \(.content)"' > "$temp_existing" 2>/dev/null || true
  local existing_count
  existing_count=$(wc -l < "$temp_existing" 2>/dev/null || echo 0)
  log "📊 当前存在记录数: ${existing_count}"

  local valid_ips=()
  local invalid_rows=()

  if [ "$existing_count" -gt 0 ]; then
    log "⚡ 正在验证现有 IP 有效性..."
    while read -r id ip; do
      [ -z "$id" ] && continue
      [ -z "$ip" ] && continue
      if check_connectivity "$ip"; then
        local avg_latency
        avg_latency="$(get_ping_avg_latency_ms "$ip" "$ip_version")"
        if [ -n "$avg_latency" ]; then
          local is_fast
          is_fast=$(awk -v lat="$avg_latency" -v th="$MAX_LATENCY_MS" 'BEGIN{print (lat<th)?1:0}')
          if [ "$is_fast" -eq 1 ]; then
            log "✅ 有效 IP: ${ip}（延迟: ${avg_latency}ms）"
            valid_ips+=("$ip")
          else
            invalid_rows+=("${id}|${ip}|>${MAX_LATENCY_MS}ms")
          fi
        else
          valid_ips+=("$ip")
        fi
      else
        invalid_rows+=("${id}|${ip}|Timeout")
      fi
      sleep_compat 0.3
    done < "$temp_existing"
  fi

  if [ "${#invalid_rows[@]}" -gt 0 ]; then
    for row in "${invalid_rows[@]}"; do
      local rec_id rec_ip rec_reason
      rec_id=$(echo "$row" | cut -d'|' -f1)
      rec_ip=$(echo "$row" | cut -d'|' -f2)
      rec_reason=$(echo "$row" | cut -d'|' -f3)
      delete_record "$rec_id" "$rec_ip" "$rec_reason"
    done
  fi

  local current_valid_count="${#valid_ips[@]}"
  log "✅ 当前有效 IP 数: ${current_valid_count}"
  
  if [ "$current_valid_count" -gt "$max_ips" ]; then
    log "📊 有效IP数(${current_valid_count})超过上限(${max_ips})，开始清理多余的有效IP..."
    local sorted_records="${temp_existing}.sorted"
    echo "$records_json" | jq -r '.result[] | "\(.id) \(.content)"' > "$temp_existing" 2>/dev/null || true
    
    local ip_latency=()
    for ip in "${valid_ips[@]}"; do
      local lat
      lat="$(get_ping_avg_latency_ms "$ip" "$ip_version")"
      lat=${lat:-999} 
      ip_latency+=("${lat}|${ip}")
    done
    
    local keep_ips=()
    for pair in $(echo "${ip_latency[@]}" | tr ' ' '\n' | sort -n | head -n "$max_ips"); do
      keep_ips+=("${pair#*|}")
    done
    
    while read -r id ip; do
      [ -z "$id" ] && continue
      [ -z "$ip" ] && continue
      local is_keep=0
      for keep_ip in "${keep_ips[@]}"; do
        [ "$ip" = "$keep_ip" ] && is_keep=1 && break
      done
      if [ "$is_keep" -eq 0 ]; then
        delete_record "$id" "$ip" "有效但超出保留数量(${max_ips})"
        valid_ips=(${valid_ips[@]/$ip})
      fi
    done < "$temp_existing"
    
    current_valid_count="${#valid_ips[@]}"
    log "✅ 清理完成，保留 ${current_valid_count} 个最优有效IP"
  fi
  
  local needed_count=$((max_ips - current_valid_count))
  if [ "$needed_count" -le 0 ]; then
    local summary="✅ 有效 ${current_valid_count}/${max_ips}"
    [ "$ip_version" = "4" ] && IPV4_SUMMARY="$summary" || IPV6_SUMMARY="$summary"
    return 0
  fi
  log "📉 需要补充 ${needed_count} 个新 IP"

  local NEW_IPS_DATA=()
  local CF_COLO
  local clean_ip_file="${work_dir}/clean_ips.txt"
  [ -f "$ip_file" ] && sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' "$ip_file" > "$clean_ip_file"

  for CF_COLO in "${COLOS[@]}"; do
    log "开始 IPv${ip_version} 测速（${CF_COLO}）..."
    > "$result_csv"
    "$cfst" -f "$clean_ip_file" -dn 5 -t 3 -httping -cfcolo "$CF_COLO" -o "$result_csv" || true
    if [ ! -s "$result_csv" ]; then
      log "⚠️ ${CF_COLO} 无结果"
      continue
    fi

    local ip lat speed duplicate
    while IFS=, read -r c1 c2 c3 c4 c5 c6 _rest; do
      ip=$(echo "${c1:-}" | tr -d ' "')
      lat=$(echo "${c5:-}" | tr -d ' "')
      [ -z "$ip" ] && continue
      [ "$ip" = "IP" ] && continue
      is_valid_ip_format "$ip" "$ip_version" || continue

      duplicate=0
      for v in "${valid_ips[@]}"; do [ "$ip" = "$v" ] && duplicate=1; done
      for n in "${NEW_IPS_DATA[@]}"; do [ "$ip" = "${n%%|*}" ] && duplicate=1; done
      [ "$duplicate" -eq 1 ] && continue

      NEW_IPS_DATA+=("${ip}|${lat}ms")
      needed_count=$((needed_count-1))
      log "➕ 选中新 IP: ${ip}"
      [ "$needed_count" -le 0 ] && break
    done < "$result_csv"
    [ "$needed_count" -le 0 ] && break
  done

  if [ "${#NEW_IPS_DATA[@]}" -gt 0 ]; then
    for data in "${NEW_IPS_DATA[@]}"; do
      local ip_addr latency
      ip_addr="${data%%|*}"
      latency="${data#*|}"
      add_record "$record_type" "$record_name" "$ip_addr" "$latency"
    done
  fi

  local final_valid_count=$((current_valid_count + ${#ADDED_IPS[@]}))
  local summary="🔄 删除${#DELETED_IPS[@]}/添加${#ADDED_IPS[@]} | 有效 ${final_valid_count}/${max_ips}"
  [ "$ip_version" = "4" ] && IPV4_SUMMARY="$summary" || IPV6_SUMMARY="$summary"
  return 0
}

# ====================================================
# 通知模块（微信 + Telegram）
# ====================================================
send_wechat_notification() {
  if [ -z "${WECHAT_API_URL}" ] || [ -z "${WECHAT_BODY_TEMPLATE}" ]; then 
    WECHAT_PUSH_STATUS="未配置"
    return 0
  fi
  
  local timestamp msg body res http_code err_msg
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  msg="🌐 Cloudflare IP 双栈优选报告
━━━━━━━━━━━━━━━━━━
⏰ 时间: ${timestamp}
━━━━━━━━━━━━━━━━━━

📡 IPv4 (${IPV4_RECORD_NAME})
   ${IPV4_SUMMARY:-未执行}

📡 IPv6 (${IPV6_RECORD_NAME})
   ${IPV6_SUMMARY:-未执行}"

  # 构建合法 JSON payload
  body=$(echo "$WECHAT_BODY_TEMPLATE" | jq -c --arg msg "$msg" '.content = $msg')
  
  # 发送微信请求：保留错误输出并提取状态码
  res=$(curl -k -sS -w "\n%{http_code}" -X POST "$WECHAT_API_URL" \
    -H "Authorization: ${WECHAT_AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" -o /dev/null 2>&1 || true)
    
  http_code=$(echo "$res" | tail -n1)
  err_msg=$(echo "$res" | sed '$d')

  if [ "$http_code" = "200" ]; then
    log "✅ 微信通知发送成功"
    WECHAT_PUSH_STATUS="✅ 成功"
  else
    err_msg=$(echo "$err_msg" | tr -d '\n' | tr -d '\r')
    log "⚠️ 微信通知发送失败 (HTTP状态码: $http_code), 错误细则: ${err_msg:-未知问题}"
    WECHAT_PUSH_STATUS="⚠️ 失败 (HTTP: $http_code)"
  fi
}

send_telegram_notification() {
  if [ -z "${TG_BOT_TOKEN}" ] || [ -z "${TG_CHAT_ID}" ]; then 
    log "⚠️ TG通知未配置：请填写 TG_BOT_TOKEN 和 TG_CHAT_ID"
    TG_PUSH_STATUS="未配置"
    return 0
  fi
  
  local timestamp msg tg_proxy_args body res http_code err_msg
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  msg="🌐 *Cloudflare IP 双栈优选报告*
━━━━━━━━━━━━━━━━━━
⏰ *时间*: ${timestamp}
━━━━━━━━━━━━━━━━━━

📡 *IPv4* (${IPV4_RECORD_NAME})
   ${IPV4_SUMMARY:-未执行}

📡 *IPv6* (${IPV6_RECORD_NAME})
   ${IPV6_SUMMARY:-未执行}"
  
  # 转义 TG MarkdownV2 全部保留字符
  msg=$(echo "$msg" | sed \
    -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' \
    -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' -e 's/`/\\`/g' \
    -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' -e 's/-/\\-/g' \
    -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' -e 's/}/\\}/g' \
    -e 's/\./\\./g' -e 's/!/\\!/g')
    
  tg_proxy_args=$(get_tg_proxy_args)
  
  # 封装安全 JSON 数据
  body=$(jq -n -c \
    --arg chat_id "${TG_CHAT_ID}" \
    --arg text "${msg}" \
    '{
      "chat_id": $chat_id,
      "text": $text,
      "parse_mode": "MarkdownV2",
      "disable_web_page_preview": true
    }')
  
  # 发起 TG 请求并捕获底层执行结果
  res=$(curl -k -sS ${tg_proxy_args} -w "\n%{http_code}" -X POST "${TG_API_URL}${TG_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$body" -o /dev/null 2>&1 || true)
    
  http_code=$(echo "$res" | tail -n1)
  err_msg=$(echo "$res" | sed '$d')

  if [ "$http_code" = "200" ]; then
    log "✅ TG通知发送成功"
    TG_PUSH_STATUS="✅ 成功"
  else
    err_msg=$(echo "$err_msg" | tr -d '\n' | tr -d '\r')
    log "⚠️ TG通知发送失败 (HTTP状态码: $http_code), 错误细则: ${err_msg:-未知问题}"
    TG_PUSH_STATUS="⚠️ 失败 (HTTP: $http_code)"
  fi
}

send_unified_notification() {
  send_wechat_notification  
  send_telegram_notification
}

# ====================================================
# 快捷命令 + 定时任务
# ====================================================
ensure_shortcut_and_cron() {
  rm -f /usr/bin/cf
  echo '#!/bin/bash' > /usr/bin/cf
  echo "bash '$SCRIPT_PATH'" >> /usr/bin/cf
  chmod +x /usr/bin/cf
  echo "✅ 全局快捷命令 cf 已创建：$SCRIPT_PATH"

  local CRON_ENTRY="0 */4 * * * bash '$SCRIPT_PATH' >/dev/null 2>&1"
  if [ -f /etc/crontabs/root ]; then
    sed -i "/cf\.sh/d" /etc/crontabs/root
    echo "$CRON_ENTRY" >> /etc/crontabs/root
    /etc/init.d/cron restart 2>/dev/null || true
  else
    local current_cron
    current_cron=$(crontab -l 2>/dev/null | grep -v cf.sh || true)
    (echo "$current_cron"; echo "$CRON_ENTRY") | crontab -
  fi
}

# ====================================================
# 主函数
# ====================================================
main() {
  mkdir -p "$IPV4_WORK_DIR" "$IPV6_WORK_DIR"
  if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 请先安装 jq：opkg install jq"
    return 1
  fi

  CURRENT_LOG="$IPV4_LOG"
  log "🔍 验证 Cloudflare API Token..."
  local VERIFY proxy_args
  proxy_args=$(get_proxy_args)
  VERIFY=$(curl -s $proxy_args -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result.status')

  if [ "${VERIFY}" != "active" ]; then
    log "❌ Token 验证失败，请检查 CF_API_TOKEN 和 CF_ZONE_ID"
    return 1
  fi
  log "✅ Token 有效"

  run_ip_selection "4"
  run_ip_selection "6"
  send_unified_notification

  echo ""
  echo "════════════════════════════════════════════════"
  echo "  Cloudflare IP 双栈优选完成"
  echo "════════════════════════════════════════════════"
  echo "  [优选结果]"
  echo "  IPv4: $IPV4_SUMMARY"
  echo "  IPv6: $IPV6_SUMMARY"
  echo "  [推送概况]"
  echo "  微信: $WECHAT_PUSH_STATUS"
  echo "  Telegram: $TG_PUSH_STATUS"
  echo "════════════════════════════════════════════════"
  return 0
}

# ====================================================
# 入口
# ====================================================
EXIT_CODE=0
main || EXIT_CODE=$?
ensure_shortcut_and_cron
exit "$EXIT_CODE"
