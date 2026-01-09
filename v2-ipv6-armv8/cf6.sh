#!/bin/bash

# ====================================================
# VPS Cloudflare IPv6 优选 - ARMv8 版（自动运行）
# 支持 ARMv8（aarch64）架构设备
#
# 功能（与 IPv4 版一致）：
# 1) 先校验现有 AAAA 记录连通性与延迟（>120ms 或超时即清理）
# 2) 仅在不足目标数量时，轮换数据中心测速补齐
# 3) 日志自动截断回滚（>400KB 保留最后 200KB）
# 4) 可选：自建微信推送接口通知（不配置则不推送）
# 5) 创建快捷命令 + 每 4 小时定时任务
#
# 注意：
# - 需要你准备 ARMv8 版 cfst，可执行文件路径：/root/cf2/ipv6/cfst
# - 需要 jq：OpenWrt 可用 opkg install jq -y
# - IPv6 连通性检测：优先 nc -6；无 nc 时用 curl -6 -k 握手检测
# ====================================================

set -euo pipefail
ulimit -n 65535

# ===== 目录与文件 =====
WORK_DIR="/root/cf2/ipv6"    # 这个地方改成你放在软件哪个目录一样就可以了
CFST="$WORK_DIR/cfst"

IPV6_FILE="$WORK_DIR/ipv6.txt"
RESULT_CSV="$WORK_DIR/result_ipv6.csv"
LOG="$WORK_DIR/log.txt"

TEMP_EXISTING_IPS="$WORK_DIR/existing_ips.txt"   # 格式：ID IP
TEMP_CHECK_IPS="$WORK_DIR/check_ips.txt"         # 预留

# ===== Cloudflare 认证信息 =====
CF_API_TOKEN="YOUR_CLOUDFLARE_API_TOKEN"
CF_ZONE_ID="YOUR_CLOUDFLARE_ZONE_ID"
CF_RECORD_NAME="ip.eee.xx.kg"                    # 目标 DNS 记录（AAAA）

# ===== 自建微信推送配置（可选，不用就留空）=====
WECHAT_API_URL=""               # 例如：https://域名/wxsend
WECHAT_AUTH_TOKEN=""            # 例如：Bearer xxxx 或你接口需要的 token
WECHAT_BODY_TEMPLATE='{"title":"Cloudflare IPv6 优选更新","content":"$MSG"}'

# ===== 目标保留 IP 数量 =====
MAX_IPS=2

# ===== 规则参数 =====
MAX_LATENCY_MS=120
CHECK_PORT=443
MAX_RETRIES=2

# ===== 优选数据中心 =====
COLOS=("NRT" "SIN" "SJC")

# ===== 快捷命令 & 定时任务（避免跟 IPv4 冲突，使用 cf6/cf6.sh）=====
SCRIPT_NAME="cf6.sh"
SHORTCUT_NAME="cf6"

# ===== 通知记录 =====
DELETED_IPS=()  # "IP|原因"
ADDED_IPS=()    # "IP|延迟"

mkdir -p "$WORK_DIR"

# BusyBox/部分系统不支持小数 sleep，用兼容函数
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
get_file_size_bytes() {
  local f="$1"
  local s
  s="$(stat -c %s "$f" 2>/dev/null || true)"
  if [ -n "$s" ]; then
    echo "$s"
    return 0
  fi
  wc -c < "$f" 2>/dev/null || echo 0
}

if [ -f "$LOG" ]; then
  log_size="$(get_file_size_bytes "$LOG")"
  if [ "${log_size:-0}" -gt 409600 ]; then
    tail -c 204800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    log "?? 日志文件超过 400KB，已执行截断回滚。"
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
    msg+="?? Cloudflare IPv6 优选日报\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="?? 域名: ${CF_RECORD_NAME}\n"
    msg+="? 时间: ${timestamp}\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="? 状态: 所有 IPv6 均有效，无需更新。\n"
    msg+="?? 当前有效 IPv6: ${current_count}/${MAX_IPS}"
  elif [ "$current_count" -lt "$MAX_IPS" ]; then
    msg+="?? Cloudflare IPv6 优选异常\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="?? 域名: ${CF_RECORD_NAME}\n"
    msg+="? 时间: ${timestamp}\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="?? 状态: 优选 IPv6 不足（缺 $((MAX_IPS-current_count)) 个）\n"
    msg+="??? 已清理: ${deleted_count} 个\n"
    msg+="? 已添加: ${added_count} 个（测速资源不足）\n"
    msg+="?? 当前有效 IPv6: ${current_count}/${MAX_IPS}"
  else
    msg+="?? Cloudflare IPv6 优选更新\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"
    msg+="?? 域名: ${CF_RECORD_NAME}\n"
    msg+="? 时间: ${timestamp}\n"
    msg+="━━━━━━━━━━━━━━━━━━\n"

    if [ "$deleted_count" -gt 0 ]; then
      msg+="??? 已清理失效 IPv6 [${deleted_count}]：\n"
      for item in "${DELETED_IPS[@]}"; do
        local ip reason
        ip="$(echo "$item" | cut -d'|' -f1)"
        reason="$(echo "$item" | cut -d'|' -f2)"
        msg+="   - ${ip} (${reason})\n"
      done
      msg+="\n"
    fi

    if [ "$added_count" -gt 0 ]; then
      msg+="? 已添加新 IPv6 [${added_count}]：\n"
      for item in "${ADDED_IPS[@]}"; do
        local ip latency
        ip="$(echo "$item" | cut -d'|' -f1)"
        latency="$(echo "$item" | cut -d'|' -f2)"
        msg+="   - ${ip} (${latency})\n"
      done
      msg+="\n"
    fi

    msg+="?? 当前有效 IPv6: ${current_count}/${MAX_IPS}"
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

  log "?? 正在发送微信推送..."
  curl -s -X POST "$WECHAT_API_URL" \
    -H "Authorization: ${WECHAT_AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1 || true
}

# ====================================================
# Cloudflare API（AAAA）
# ====================================================
get_current_records() {
  curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=AAAA&name=${CF_RECORD_NAME}" \
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

  log "??? 已删除失效记录: ${ip_val} (${reason})"
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
      \"type\": \"AAAA\",
      \"name\": \"${CF_RECORD_NAME}\",
      \"content\": \"${ip}\",
      \"ttl\": 1,
      \"proxied\": false
    }")"

  if echo "$resp" | grep -q '"success":true'; then
    log "? 上报成功：${CF_RECORD_NAME} -> ${ip}"
    ADDED_IPS+=("${ip}|${latency}")
  else
    log "? 上报失败: ${ip} ($(echo "$resp" | jq -r '.errors[]?.message' 2>/dev/null | head -n1))"
  fi
}

# ====================================================
# IPv6 工具函数：格式校验/连通性/ping
# ====================================================
is_ipv6() {
  local ip="$1"
  # 非严苛校验：包含冒号且仅包含 0-9a-fA-F:.
  # 足够过滤 CSV 里的 header/脏值
  echo "$ip" | grep -Eq '^[0-9A-Fa-f:.]+$' && echo "$ip" | grep -q ':'
}

check_connectivity() {
  local ip="$1"
  local retry=0

  while [ "$retry" -lt "$MAX_RETRIES" ]; do
    if [ "$retry" -gt 0 ]; then
      log "   ?? 重试 IP: ${ip}（第 ${retry} 次）"
      sleep 2
    fi

    # 1) 优先 nc（IPv6 用 -6 更稳）
    if command -v nc >/dev/null 2>&1; then
      if nc -6 -z -w 5 "$ip" "$CHECK_PORT" >/dev/null 2>&1; then
        return 0
      fi
      # 有些 nc 没有 -6 参数，退回普通 nc
      if nc -z -w 5 "$ip" "$CHECK_PORT" >/dev/null 2>&1; then
        return 0
      fi
    fi

    # 2) 退路：用 curl -6 做握手（443 用 https，80 用 http）
    if command -v curl >/dev/null 2>&1; then
      if [ "$CHECK_PORT" -eq 443 ]; then
        if curl -g -6 -k --connect-timeout 5 -m 5 -sI "https://[${ip}]/" >/dev/null 2>&1; then
          return 0
        fi
      else
        if curl -g -6 --connect-timeout 5 -m 5 -sI "http://[${ip}]:${CHECK_PORT}/" >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi

    retry=$((retry+1))
  done

  return 1
}

get_ping_avg_latency_ms() {
  local ip="$1"
  local out avg

  # 优先 ping6
  if command -v ping6 >/dev/null 2>&1; then
    out="$(ping6 -c 3 -W 2 -q "$ip" 2>/dev/null || true)"
  elif command -v ping >/dev/null 2>&1; then
    # busybox ping 支持 -6 的情况下
    out="$(ping -6 -c 3 -W 2 -q "$ip" 2>/dev/null || true)"
    if [ -z "$out" ]; then
      # 有的系统 ping -6 不支持，就直接返回空
      echo ""
      return 0
    fi
  else
    echo ""
    return 0
  fi

  [ -z "$out" ] && { echo ""; return 0; }

  # rtt min/avg/max/mdev = x/y/z/w ms
  avg="$(echo "$out" | awk -F'/' '/rtt|round-trip/ { gsub(/[^0-9.\/]/,""); print $5; exit }' 2>/dev/null || true)"
  echo "${avg:-}"
}

# ====================================================
# 快捷命令 + 定时任务（每 4 小时）
# ====================================================
ensure_shortcut_and_cron() {
  # 快捷命令：/usr/bin/cf6
  if [ ! -f "/usr/bin/${SHORTCUT_NAME}" ]; then
    echo '#!/bin/bash' > "/usr/bin/${SHORTCUT_NAME}"
    echo "bash $WORK_DIR/$SCRIPT_NAME" >> "/usr/bin/${SHORTCUT_NAME}"
    chmod +x "/usr/bin/${SHORTCUT_NAME}"
    log "? 创建命令快捷方式：${SHORTCUT_NAME}"
  fi

  # 定时任务（每 4 小时）
  local CRON_FILE="/etc/crontabs/root"
  local CMD="bash $WORK_DIR/$SCRIPT_NAME"
  if ! grep -q "$CMD" "$CRON_FILE" 2>/dev/null; then
    echo "0 */4 * * * $CMD >/dev/null 2>&1" >> "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    log "? 已添加定时任务（每 4 小时）"
  fi
}

# ====================================================
# 主逻辑
# ====================================================
main() {
  # ARMv8 简单提示（不强制）
  if command -v uname >/dev/null 2>&1; then
    arch="$(uname -m 2>/dev/null || true)"
    if [ -n "$arch" ] && [ "$arch" != "aarch64" ]; then
      log "?? 当前架构: $arch（此脚本面向 ARMv8/aarch64，但也可能仍可运行）"
    fi
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "? 未安装 jq，请先执行：opkg install jq -y"
    return 1
  fi

  if [ ! -x "$CFST" ]; then
    log "? 未检测到 ARMv8 版 cfst，请放入：$CFST"
    log "   提示：chmod +x $CFST"
    return 1
  fi

  if [ ! -f "$IPV6_FILE" ]; then
    log "? 未找到 IPv6 候选文件：$IPV6_FILE"
    log "   请把候选 IPv6 写入该文件（一行一个 IPv6）"
    return 1
  fi

  # 验证 Token
  log "?? 验证 Cloudflare API Token..."
  local VERIFY
  VERIFY="$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result.status')"

  if [ "${VERIFY}" != "active" ]; then
    log "? Token 验证失败，请检查。"
    return 1
  fi
  log "? Token 有效，继续执行..."

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "$(date '+%F %T') 开始执行 IPv6 智能优选..."

  # 1) 获取当前线上 AAAA 记录
  log "?? 检查当前 Cloudflare AAAA 记录..."
  local records_json
  records_json="$(get_current_records)"
  echo "$records_json" | jq -r '.result[] | "\(.id) \(.content)"' > "$TEMP_EXISTING_IPS" || true

  local existing_count
  if [ ! -s "$TEMP_EXISTING_IPS" ]; then
    existing_count=0
  else
    existing_count="$(wc -l < "$TEMP_EXISTING_IPS" | tr -d ' ')"
  fi
  log "?? 当前存在记录数: ${existing_count}"

  local valid_ips=()
  local invalid_rows=()

  # 2) 校验现有 IP（TCP + ping）
  if [ "$existing_count" -gt 0 ]; then
    log "? 正在验证现有 IPv6 有效性（TCP:${CHECK_PORT} + ping 延迟 < ${MAX_LATENCY_MS}ms）..."
    while read -r id ip; do
      [ -z "${id}" ] && continue
      [ -z "${ip}" ] && continue

      if ! is_ipv6 "$ip"; then
        log "?? 跳过非 IPv6 内容: ${ip}"
        continue
      fi

      if check_connectivity "$ip"; then
        local avg_latency
        avg_latency="$(get_ping_avg_latency_ms "$ip")"

        if [ -n "$avg_latency" ]; then
          local is_fast
          is_fast="$(awk -v lat="$avg_latency" -v th="$MAX_LATENCY_MS" 'BEGIN{if(lat < th) print 1; else print 0}')"
          if [ "$is_fast" -eq 1 ]; then
            log "? 有效 IPv6: ${ip}（延迟: ${avg_latency}ms）"
            valid_ips+=("$ip")
          else
            log "?? 高延迟 IPv6: ${ip}（延迟: ${avg_latency}ms > ${MAX_LATENCY_MS}ms）"
            invalid_rows+=("${id}|${ip}|>${MAX_LATENCY_MS}ms")
          fi
        else
          log "? 有效 IPv6: ${ip}（TCP 连接正常，ping 不可用）"
          valid_ips+=("$ip")
        fi
      else
        log "?? 失效 IPv6: ${ip}（TCP ${CHECK_PORT} 无法连接，已重试 ${MAX_RETRIES} 次）"
        invalid_rows+=("${id}|${ip}|Timeout")
      fi

      sleep_compat 0.3
    done < "$TEMP_EXISTING_IPS"
  else
    log "?? Cloudflare 上没有 AAAA 记录，将进行补齐更新"
  fi

  # 3) 删除失效记录
  if [ "${#invalid_rows[@]}" -gt 0 ]; then
    log "??? 正在删除 ${#invalid_rows[@]} 个失效记录..."
    for row in "${invalid_rows[@]}"; do
      local rec_id rec_ip rec_reason
      rec_id="$(echo "$row" | cut -d'|' -f1)"
      rec_ip="$(echo "$row" | cut -d'|' -f2)"
      rec_reason="$(echo "$row" | cut -d'|' -f3)"
      delete_record "$rec_id" "$rec_ip" "$rec_reason"
    done
  fi

  local current_valid_count="${#valid_ips[@]}"
  log "? 当前有效 IPv6 数: ${current_valid_count}"

  # 4) 不足才补齐
  local needed_count=$((MAX_IPS - current_valid_count))
  if [ "$needed_count" -le 0 ]; then
    log "?? 有效 IPv6 已达到或超过目标 (${MAX_IPS})，无需更新。"
    send_notification "$current_valid_count"
    log "$(date '+%F %T') ?? IPv6 优选完成"
    return 0
  fi
  log "?? 需要补充 ${needed_count} 个新 IPv6"

  # 5) 轮换数据中心测速补齐
  local NEW_IPS_DATA=() # "IP|Latency"
  local CF_COLO

  for CF_COLO in "${COLOS[@]}"; do
    log "$(date '+%F %T') 开始 IPv6 测速（${CF_COLO}）..."

    > "$RESULT_CSV"

    # cfst 通常会根据输入 IP 自动识别 IPv6；如你的 cfst 需要显式参数，请在此处追加（例如：-v6 或 -ipv6）
    $CFST -f "$IPV6_FILE" -dn 5 -t 3 -httping -cfcolo "$CF_COLO" -o "$RESULT_CSV"

    if [ ! -s "$RESULT_CSV" ]; then
      log "?? ${CF_COLO} 区域无结果"
      continue
    fi

    local ip lat duplicate
    local grabbed=0
    while IFS=, read -r c1 c2 c3 c4 c5 _rest; do
      ip="$(echo "${c1:-}" | tr -d ' "')"
      lat="$(echo "${c5:-}" | tr -d ' "')"
      [ -z "$ip" ] && continue

      # 跳过 header
      if [ "$ip" = "IP" ] || [ "$ip" = "ip" ] || [ "$ip" = "IP地址" ]; then
        continue
      fi

      if ! is_ipv6 "$ip"; then
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
      log "? 选中新 IPv6: ${ip}（延迟: ${lat}ms）"

      [ "$needed_count" -le 0 ] && break
      [ "$grabbed" -ge 10 ] && break
    done < "$RESULT_CSV"

    [ "$needed_count" -le 0 ] && break
  done

  # 6) 添加新 IPv6 到 Cloudflare
  if [ "${#NEW_IPS_DATA[@]}" -gt 0 ]; then
    log "?? 正在添加 ${#NEW_IPS_DATA[@]} 个新 IPv6 到 Cloudflare..."
    for data in "${NEW_IPS_DATA[@]}"; do
      local ip latency
      ip="${data%%|*}"
      latency="${data#*|}"
      add_record "$ip" "$latency"
    done
  else
    log "?? 所有区域测速完成，但未获取到可补齐的新 IPv6"
  fi

  local final_valid_count=$((current_valid_count + ${#ADDED_IPS[@]}))
  send_notification "$final_valid_count"
  log "$(date '+%F %T') ?? IPv6 优选完成"
  return 0
}

EXIT_CODE=0
main || EXIT_CODE=$?

# 快捷命令 + 定时任务
ensure_shortcut_and_cron || true

exit "$EXIT_CODE"
