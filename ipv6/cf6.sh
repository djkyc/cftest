#!/bin/bash
# ====================================================
# VPS Cloudflare IPv6 优选 - HTTPing 延迟测速
# 作者: djcky 改写版
# ====================================================

ulimit -n 65535

WORK_DIR="/opt/cf/ip6"
CFST="$WORK_DIR/cfst"
IPV6_FILE="$WORK_DIR/ipv6.txt"
RESULT_CSV="$WORK_DIR/result_ipv6.csv"
LOG="$WORK_DIR/log.txt"
mkdir -p "$WORK_DIR"

# ===== Cloudflare 认证信息 =====
CF_API_TOKEN="你的CF_API_TOKEN"
CF_ZONE_ID="你的CF_ZONE_ID"
CF_RECORD_NAME="ip6.eee.xx.kg"

# ===== 检测依赖 =====
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 未检测到 jq，请先安装：opkg install jq -y" | tee -a "$LOG"
    exit 1
fi

if ! curl -6 -s --connect-timeout 5 https://www.cloudflare.com/ >/dev/null 2>&1; then
    echo "❌ VPS IPv6 出口不可用，测速无法进行" | tee -a "$LOG"
    exit 1
fi


# ===== 数据中心列表 =====
COLOS=("SIN" "HKG" "NRT")
BEST_IP_ARRAY=()

# ===== 轮换数据中心测速，选取前 8 个 IP =====
for CF_COLO in "${COLOS[@]}"; do
    echo "$(date '+%F %T') 开始 IPv6 HTTPing 测速: ${CF_COLO}" | tee -a "$LOG"

    > "$RESULT_CSV"

    $CFST -f "$IPV6_FILE" -t 3 -tl 9999 -httping -dd -cfcolo "$CF_COLO" -o "$RESULT_CSV"

    if [ ! -f "$RESULT_CSV" ] || [ ! -s "$RESULT_CSV" ]; then
        echo "⚠️ 当前地区 ${CF_COLO} 无可用 IP，切换下一个..." | tee -a "$LOG"
        continue
    fi

    COUNT=$(awk -F, 'NR>1 {print $1}' "$RESULT_CSV" | wc -l)
    if [ "$COUNT" -lt 5 ]; then
        echo "⚠️ 当前地区 ${CF_COLO} 可用 IP 少于 5 个（${COUNT} 个），切换下一个..." | tee -a "$LOG"
        continue
    fi

    BEST_IP_ARRAY=($(awk -F, 'NR>1 && NR<=9 {print $1}' "$RESULT_CSV"))
    echo "✅ 选定 ${CF_COLO} 的前 8 个 IPv6：" | tee -a "$LOG"
    awk -F, 'NR>1 && NR<=9 {print "  - " $1 " 延迟:" $5 "ms"}' "$RESULT_CSV" | tee -a "$LOG"
    break
done

if [ "${#BEST_IP_ARRAY[@]}" -lt 5 ]; then
    echo "❌ 全部地区测速完成，但未获得至少 5 个可用 IPv6，退出" | tee -a "$LOG"
    exit 1
fi

# ===== 删除已有 AAAA 记录 =====
old_ids=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=AAAA&name=${CF_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[].id')

for id in $old_ids; do
    curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/$id" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" >/dev/null 2>&1
done
echo "✅ 已删除旧 AAAA 记录" | tee -a "$LOG"

# ===== 上报前 8 个 IPv6 =====
for ip in "${BEST_IP_ARRAY[@]}"; do
    resp=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"AAAA\",
            \"name\": \"${CF_RECORD_NAME}\",
            \"content\": \"${ip}\",
            \"ttl\": 1,
            \"proxied\": false
        }")

    if echo "$resp" | grep -q '"success":true'; then
        echo "✅ 已添加 AAAA 记录: ${CF_RECORD_NAME} -> $ip" | tee -a "$LOG"
    else
        echo "❌ 添加失败: $ip ($(echo "$resp" | jq -r '.errors[]?.message'))" | tee -a "$LOG"
    fi
done

echo "$(date '+%F %T') 🎯 IPv6 优选完成，已上报 8 个最佳 IP" | tee -a "$LOG"

# ===== 创建快捷命令 cf6 =====
if [ ! -f /usr/bin/cf6 ]; then
    echo "#!/bin/bash" > /usr/bin/cf6
    echo "bash $WORK_DIR/cf6.sh" >> /usr/bin/cf6
    chmod +x /usr/bin/cf6
    echo "✅ 快捷命令 cf6 已创建" | tee -a "$LOG"
fi

# ===== 添加定时任务（每3小时） =====
CRON_FILE="/etc/crontabs/root"
CRON_CMD="0 */3 * * * bash $WORK_DIR/cf6.sh >/dev/null 2>&1"
if ! grep -qF "$CRON_CMD" "$CRON_FILE" 2>/dev/null; then
    echo "$CRON_CMD" >> "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    echo "✅ 定时任务已添加（每3小时）" | tee -a "$LOG"
fi

exit 0
