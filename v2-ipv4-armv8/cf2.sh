#!/bin/bash

# ====================================================
# VPS Cloudflare IPv4 优选 - ARMv8 版（自动运行）
# 作者: djcky（适配 ARMv8 by ChatGPT）
# 支持 ARMv8（aarch64）架构设备
#
# 在原 cf2.sh 基础上合入 cfst2.0.sh 新增功能：
# 1) 先校验现有 A 记录连通性与延迟（>120ms 或超时即清理）
# 2) 仅在不足目标数量时，轮换数据中心测速补齐
# 3) 日志自动截断回滚（>400KB 保留最后 200KB）
# 4) 可选：自建微信推送接口通知（不配置则不推送）
#
# 其余功能保持不变：Token 验证、ARMv8 cfst 调用、创建 cf 快捷命令、每 4 小时定时任务
# ====================================================

set -euo pipefail

ulimit -n 65535

WORK_DIR="/root/cf2/ipv4"
CFST="$WORK_DIR/cfst"   # ✅ 修复：必须指向可执行文件，不是目录
IPV4_FILE="$WORK_DIR/ip.txt"
RESULT_CSV="$WORK_DIR/result_ipv4.csv"
LOG="$WORK_DIR/log.txt"

TEMP_EXISTING_IPS="$WORK_DIR/existing_ips.txt"   # 格式：ID IP
TEMP_CHECK_IPS="$WORK_DIR/check_ips.txt"

# ===== Cloudflare 认证信息 =====
CF_API_TOKEN="f9uX54FayzaQYNd8KlLef1vO66s1QX0MH2jICpU5"     # Cloudflare API Token
CF_ZONE_ID="0fca3e58687f3b3eb2772c56712a4113"         # Zone ID
CF_RECORD_NAME="ip.eee.xx.kg"                # 目标 DNS 记录

# ===== 自建微信推送配置（可选，不用就留空）=====
WECHAT_API_URL=""               # 例如：https://域名/wxsend
WECHAT_AUTH_TOKEN=""            # 例如：Bearer xxxx 或你接口需要的 token
WECHAT_BODY_TEMPLATE='{"title":"Cloudflare IP 优选更新","content":"$MSG"}'

# ===== 目标保留 IP 数量（保持与原脚本一致：上报前 2 个最佳 IP）=====
MAX_IPS=2

# ===== 规则参数 =====
MAX_LATENCY_MS=120
CHECK_PORT=443
MAX_RETRIES=2

# ===== 优选的 Cloudflare 数据中心：东京/新加坡/硅谷（保持原脚本一致）=====
COLOS=("NRT" "SIN" "SJC")

# ===== 通知记录 =====
DELETED_IPS=()  # "IP|原因"
ADDED_IPS=()    # "IP|延迟"

# ✅ 修复：兼容不支持小数 sleep 的环境（BusyBox 等）
sleep_compat() {
  local t="$1"
  sleep "$t" 2>/dev/null || sleep 1
}

log() {
  echo "$*" | tee -a "$LOG"
}

# ====================================================
# 日志回滚（限制 400KB，保留最后 200KB）
# ====================================================
mkdir -p "$WORK_DIR"
if [ -f "$LOG" ]; then
  log_size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "${log_size:-0}" -gt 409600 ]; then
    tail -c 204800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    log "⚠️ 日志文件超过 400KB，已执行截断回滚。"
  fi
fi

# ====================================================
# 微信推送（可选）
# ====================================================
build_notification_message() {
  local current_count="$1"
  local deleted_count="${#DELETED_IPS[@]}"
  local added_count="${#ADDED_IPS[@]}"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  local msg=""
  if [ "$deleted_count" -eq 0 ] && [ "$added_count" -eq 0 ]; then
    msg+="🌐 Cloudflare IP 优选日报\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="🏠 域名: ${CF_RECORD_NAME}\n"
    msg+="⏰ 时间: ${timestamp}\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="✅ 状态: 所有 IP 均有效，无需更新。\n"
    msg+="📊 当前有效 IP: ${current_count}/${MAX_IPS}"
  elif [ "$current_count" -lt "$MAX_IPS" ]; then
    msg+="⚠️ Cloudflare IP 优选异常\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="🏠 域名: ${CF_RECORD_NAME}\n"
    msg+="⏰ 时间: ${timestamp}\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="🚫 状态: 优选 IP 不足（缺 $((MAX_IPS-current_count)) 个）\n"
    msg+="🗑️ 已清理: ${deleted_count} 个\n"
    msg+="➕ 已添加: ${added_count} 个（测速资源不足）\n"
    msg+="📊 当前有效 IP: ${current_count}/${MAX_IPS}"
  else
    msg+="🌐 Cloudflare IP 优选更新\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="🏠 域名: ${CF_RECORD_NAME}\n"
    msg+="⏰ 时间: ${timestamp}\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"

    if [ "$deleted_count" -gt 0 ]; then
      msg+="🗑️ 已清理失效 IP [${deleted_count}]：\n"
      for item in "${DELETED_IPS[@]}"; do
        local ip reason
        ip="$(echo "$item" | cut -d'|' -f1)"
        reason="$(echo "$item" | cut -d'|' -f2)"
        msg+="   - ${ip} (${reason})\n"
      done
      msg+="\n"
    fi

    if [ "$added_count" -gt 0 ]; then
      msg+="➕ 已添加新 IP [${added_count}]：\n"
      for item in "${ADDED_IPS[@]}"; do
        local ip latency
        ip="$(echo "$item" | cut -d'|' -f1)"
        latency="$(echo "$item" | cut -d'|' -f2)"
        msg+="   - ${ip} (${latency})\n"
      done
      msg+="\n"
    fi

    msg+="📊 当前有效 IP: ${current_count}/${MAX_IPS}"
  fi

  echo -e "$msg"
}

send_notification() {
  local current_valid_count="$1"

  if [ -z "${WECHAT_API_URL}" ] || [ -z "${WECHAT_BODY_TEMPLATE}" ]; then
    return 0
  fi

  local msg_content safe_msg body
  msg_content="$(build_notification_message "$current_valid_count")"
  safe_msg="$(echo "$msg_content" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')"
  body="${WECHAT_BODY_TEMPLATE//\$MSG/$safe_msg}"

  log "📨 正在发送微信推送..."
  curl -s -X POST "$WECHAT_API_URL" \
    -H "Authorization: ${WECHAT_AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1 || true
}

# ====================================================
# Cloudflare API
# ====================================================
get_current_records() {
  curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json"
}

delete_record() {
  local record_id="$1"
  local ip_val="$2"
  local reason="$3"

  curl -s -X DELETE \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" >/dev/null 2>&1 || true

  log "🗑️ 已删除失效记录: ${ip_val} (${reason})"
  DELETED_IPS+=("${ip_val}|${reason}")
}

add_record() {
  local ip="$1"
  local latency="$2"
  local resp

  resp="$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\": \"A\",
      \"name\": \"${CF_RECORD_NAME}\",
      \"content\": \"${ip}\",
      \"ttl\": 1,
      \"proxied\": false
    }")"

  if echo "$resp" | grep -q '"success":true'; then
    log "✅ 上报成功：${CF_RECORD_NAME} -> ${ip}"
    ADDED_IPS+=("${ip}|${latency}")
  else
    log "❌ 上报失败: ${ip} ($(echo "$resp" | jq -r '.errors[]?.message' 2>/dev/null | head -n1))"
  fi
}

# ====================================================
# IP 校验（连通性 + 延迟）
# ====================================================
check_connectivity() {
  local ip="$1"
  local retry=0

  while [ "$retry" -lt "$MAX_RETRIES" ]; do
    if [ "$retry" -gt 0 ]; then
      log "   🔄 重试 IP: ${ip}（第 ${retry} 次）"
      sleep 2
    fi

    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 5 "$ip" "$CHECK_PORT" >/dev/null 2>&1; then
        return 0
      fi
    else
      if command -v timeout >/dev/null 2>&1; then
        if timeout 5 bash -c "cat < /dev/tcp/${ip}/${CHECK_PORT}" >/dev/null 2>&1; then
          return 0
        fi
      else
        (bash -c "cat < /dev/tcp/${ip}/${CHECK_PORT}" >/dev/null 2>&1) & sleep 5; kill $! >/dev/null 2>&1 || true
      fi
    fi
    retry=$((retry+1))
  done

  return 1
}

get_ping_avg_latency_ms() {
  local ip="$1"
  local ping_output avg

  if ! command -v ping >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  ping_output="$(ping -c 3 -W 2 -q "$ip" 2>/dev/null || true)"
  if [ -z "$ping_output" ]; then
    echo ""
    return 0
  fi

  avg="$(echo "$ping_output" | grep -oP 'rtt min/avg/max/mdev = [\d.]+/\K[\d.]+' 2>/dev/null || true)"
  if [ -z "$avg" ]; then
    avg="$(echo "$ping_output" | awk -F'/' '/^rtt/ {print $5}' 2>/dev/null || true)"
  fi
  echo "$avg"
}

# ====================================================
# 保持原脚本功能：创建快捷命令 + 定时任务
# ====================================================
ensure_shortcut_and_cron() {
  if [ ! -f /usr/bin/cf ]; then
    echo '#!/bin/bash' > /usr/bin/cf
    echo "bash $WORK_DIR/cf.sh" >> /usr/bin/cf
    chmod +x /usr/bin/cf
    log "✅ 创建命令快捷方式：cf"
  fi

  local CRON_FILE="/etc/crontabs/root"
  if ! grep -q "bash $WORK_DIR/cf.sh" "$CRON_FILE" 2>/dev/null; then
    echo "0 */4 * * * bash $WORK_DIR/cf.sh >/dev/null 2>&1" >> "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    log "✅ 已添加定时任务（每 4 小时）"
  fi
}

# ====================================================
# 主逻辑
# ====================================================
main() {
  if ! command -v jq >/dev/null 2>&1; then
    log "❌ 未安装 jq，请先执行：opkg install jq -y"
    return 1
  fi

  if [ ! -x "$CFST" ]; then
    log "❌ 未检测到 ARMv8 版 cfst，请放入：$CFST"
    return 1
  fi

  log "🔍 验证 Cloudflare API Token..."
  local VERIFY
  VERIFY="$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result.status')"

  if [ "${VERIFY}" != "active" ]; then
    log "❌ Token 验证失败，请检查。"
    return 1
  fi
  log "✅ Token 有效，继续执行..."

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "$(date '+%F %T') 开始执行智能优选..."

  log "🔍 检查当前 Cloudflare 记录..."
  local records_json
  records_json="$(get_current_records)"
  echo "$records_json" | jq -r '.result[] | "\(.id) \(.content)"' > "$TEMP_EXISTING_IPS" || true

  local existing_count
  if [ ! -s "$TEMP_EXISTING_IPS" ]; then
    existing_count=0
  else
    existing_count="$(wc -l < "$TEMP_EXISTING_IPS" | tr -d ' ')"
  fi
  log "📊 当前存在记录数: ${existing_count}"

  local valid_ips=()
  local invalid_rows=()

  if [ "$existing_count" -gt 0 ]; then
    log "⚡ 正在验证现有 IP 有效性（TCP:${CHECK_PORT} + ping 延迟 < ${MAX_LATENCY_MS}ms）..."
    while read -r id ip; do
      [ -z "${id}" ] && continue
      [ -z "${ip}" ] && continue

      if check_connectivity "$ip"; then
        local avg_latency
        avg_latency="$(get_ping_avg_latency_ms "$ip")"

        if [ -n "$avg_latency" ]; then
          local is_fast
          is_fast="$(awk -v lat="$avg_latency" -v th="$MAX_LATENCY_MS" 'BEGIN{if(lat < th) print 1; else print 0}')"
          if [ "$is_fast" -eq 1 ]; then
            log "✅ 有效 IP: ${ip}（延迟: ${avg_latency}ms）"
            valid_ips+=("$ip")
          else
            log "⚠️ 高延迟 IP: ${ip}（延迟: ${avg_latency}ms > ${MAX_LATENCY_MS}ms）"
            invalid_rows+=("${id}|${ip}|>${MAX_LATENCY_MS}ms")
          fi
        else
          log "✅ 有效 IP: ${ip}（TCP 连接正常，ping 不可用）"
          valid_ips+=("$ip")
        fi
      else
        log "⚠️ 失效 IP: ${ip}（TCP ${CHECK_PORT} 端口无法连接，已重试 ${MAX_RETRIES} 次）"
        invalid_rows+=("${id}|${ip}|Timeout")
      fi

      # ✅ 修复：不要用 sleep 0.3（部分系统不支持小数）
      sleep_compat 0.3
    done < "$TEMP_EXISTING_IPS"
  else
    log "ℹ️ Cloudflare 上没有记录，将进行补齐更新"
  fi

  if [ "${#invalid_rows[@]}" -gt 0 ]; then
    log "🗑️ 正在删除 ${#invalid_rows[@]} 个失效记录..."
    for row in "${invalid_rows[@]}"; do
      local rec_id rec_ip rec_reason
      rec_id="$(echo "$row" | cut -d'|' -f1)"
      rec_ip="$(echo "$row" | cut -d'|' -f2)"
      rec_reason="$(echo "$row" | cut -d'|' -f3)"
      delete_record "$rec_id" "$rec_ip" "$rec_reason"
    done
  fi

  local current_valid_count="${#valid_ips[@]}"
  log "✅ 当前有效 IP 数: ${current_valid_count}"

  local needed_count=$((MAX_IPS - current_valid_count))
  if [ "$needed_count" -le 0 ]; then
    log "🎉 有效 IP 已达到或超过目标 (${MAX_IPS})，无需更新。"
    send_notification "$current_valid_count"
    log "$(date '+%F %T') 🎯 IPv4 优选完成"
    return 0
  fi
  log "📉 需要补充 ${needed_count} 个新 IP"

  local NEW_IPS_DATA=() # "IP|Latency"
  local CF_COLO

  for CF_COLO in "${COLOS[@]}"; do
    log "$(date '+%F %T') 开始 IPv4 测速（${CF_COLO}）..."

    > "$RESULT_CSV"
    $CFST -f "$IPV4_FILE" -dn 5 -t 3 -httping -cfcolo "$CF_COLO" -o "$RESULT_CSV"

    if [ ! -s "$RESULT_CSV" ]; then
      log "⚠️ ${CF_COLO} 区域无结果"
      continue
    fi

    local ip lat duplicate
    local grabbed=0
    while IFS=, read -r c1 c2 c3 c4 c5 _rest; do
      ip="$(echo "${c1:-}" | tr -d ' "')"
      lat="$(echo "${c5:-}" | tr -d ' "')"
      [ -z "$ip" ] && continue

      if [ "$ip" = "IP" ] || [ "$ip" = "ip" ] || [ "$ip" = "IP地址" ]; then
        continue
      fi

      if ! echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        continue
      fi

      duplicate=0
      for v in "${valid_ips[@]}"; do
        [ "$ip" = "$v" ] && duplicate=1 && break
      done
      if [ "$duplicate" -eq 0 ]; then
        for n in "${NEW_IPS_DATA[@]}"; do
          [ "$ip" = "${n%%|*}" ] && duplicate=1 && break
        done
      fi
      [ "$duplicate" -eq 1 ] && continue

      NEW_IPS_DATA+=("${ip}|${lat}ms")
      needed_count=$((needed_count-1))
      grabbed=$((grabbed+1))
      log "➕ 选中新 IP: ${ip}（延迟: ${lat}ms）"

      [ "$needed_count" -le 0 ] && break
      [ "$grabbed" -ge 10 ] && break
    done < "$RESULT_CSV"

    [ "$needed_count" -le 0 ] && break
  done

  if [ "${#NEW_IPS_DATA[@]}" -gt 0 ]; then
    log "📝 正在添加 ${#NEW_IPS_DATA[@]} 个新 IP 到 Cloudflare..."
    for data in "${NEW_IPS_DATA[@]}"; do
      local ip latency
      ip="${data%%|*}"
      latency="${data#*|}"
      add_record "$ip" "$latency"
    done
  else
    log "⚠️ 所有区域测速完成，但未获取到可补齐的新 IP"
  fi

  local final_valid_count=$((current_valid_count + ${#ADDED_IPS[@]}))
  send_notification "$final_valid_count"
  log "$(date '+%F %T') 🎯 IPv4 优选完成"

  return 0
}

EXIT_CODE=0
main || EXIT_CODE=$?

ensure_shortcut_and_cron || true

exit "$EXIT_CODE"
