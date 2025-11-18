#!/bin/bash

# ====================================================
# VPS Cloudflare IPv4 优选 - ARMv8 版（自动运行）
# 作者: djcky（适配 ARMv8 by ）
# 支持 ARMv8（aarch64）架构设备
# ====================================================

ulimit -n 65535

WORK_DIR="/opt/cf"
CFST="$WORK_DIR/cfst"
IPV4_FILE="$WORK_DIR/ip.txt"
RESULT_CSV="$WORK_DIR/result_ipv4.csv"
LOG="$WORK_DIR/log.txt"

# ===== Cloudflare 认证信息 =====
CF_API_TOKEN=""     # Cloudflare API Token
CF_ZONE_ID=""            # Zone ID
CF_RECORD_NAME="ip.eee.xx.kg"                          # 目标 DNS 记录

# ===== 检查依赖 =====
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 未安装 jq，请先执行：opkg install jq -y" | tee -a "$LOG"
    exit 1
fi

if [ ! -x "$CFST" ]; then
    echo "❌ 未检测到 ARMv8 版 cfst，请放入：$CFST" | tee -a "$LOG"
    exit 1
fi

# ===== 验证 CF Token =====
echo "🔍 验证 Cloudflare API Token..." | tee -a "$LOG"
VERIFY=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result.status')

if [ "$VERIFY" != "active" ]; then
    echo "❌ Token 验证失败，请检查。" | tee -a "$LOG"
    exit 1
fi

echo "✅ Token 有效，继续执行..." | tee -a "$LOG"

# ===== 优选的 Cloudflare 数据中心：东京/新加坡/硅谷 =====
COLOS=("NRT" "SIN" "SJC")
BEST_IPV4_ARRAY=()

for CF_COLO in "${COLOS[@]}"; do
    echo "$(date '+%F %T') 开始 IPv4 测速（${CF_COLO}）..." | tee -a "$LOG"

    > "$RESULT_CSV"

    # ----- ARMv8适配：cfst 直接运行即可 -----
    $CFST -f "$IPV4_FILE" -dn 5 -t 3 -httping -cfcolo "$CF_COLO" -o "$RESULT_CSV"

    if [ ! -s "$RESULT_CSV" ]; then
        echo "⚠️ ${CF_COLO} 区域无结果" | tee -a "$LOG"
        continue
    fi

    COUNT=$(awk -F, 'NR>1 {print $1}' "$RESULT_CSV" | wc -l)
    if [ "$COUNT" -lt 2 ]; then
        echo "⚠️ ${CF_COLO} 可用 IP 不足 (${COUNT})" | tee -a "$LOG"
        continue
    fi

    BEST_IPV4_ARRAY=($(awk -F, 'NR>1 && NR<=3 {print $1}' "$RESULT_CSV"))
    echo "✅ ${CF_COLO} 最佳 IP：" | tee -a "$LOG"
    awk -F, 'NR>1 && NR<=3 {print "  - " $1 " 延迟:" $5 "ms"}' "$RESULT_CSV" | tee -a "$LOG"

    break
done

if [ "${#BEST_IPV4_ARRAY[@]}" -lt 2 ]; then
    echo "❌ 所有区域均无可用 IPv4" | tee -a "$LOG"
    exit 1
fi

# ===== 删除旧 A 记录 =====
old_ids=$(curl -s -X GET \
"https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}" \
-H "Authorization: Bearer ${CF_API_TOKEN}" \
-H "Content-Type: application/json" | jq -r '.result[].id')

for id in $old_ids; do
    curl -s -X DELETE \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/$id" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" >/dev/null 2>&1
done

echo "✅ 已删除旧 A 记录" | tee -a "$LOG"

# ===== 上报前 2 个最佳 IP =====
for ip in "${BEST_IPV4_ARRAY[@]}"; do
    resp=$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
        \"type\": \"A\",
        \"name\": \"${CF_RECORD_NAME}\",
        \"content\": \"${ip}\",
        \"ttl\": 1,
        \"proxied\": false
    }")

    if echo "$resp" | grep -q '"success":true'; then
        echo "✅ 上报成功：${CF_RECORD_NAME} -> $ip" | tee -a "$LOG"
    else
        echo "❌ 上报失败: $ip ($(echo "$resp" | jq -r '.errors[]?.message'))" | tee -a "$LOG"
    fi
done

echo "$(date '+%F %T') 🎯 IPv4 优选完成" | tee -a "$LOG"

# ===== 创建快捷命令 cf =====
if [ ! -f /usr/bin/cf ]; then
    echo '#!/bin/bash' > /usr/bin/cf
    echo "bash $WORK_DIR/cf.sh" >> /usr/bin/cf
    chmod +x /usr/bin/cf
    echo "✅ 创建命令快捷方式：cf" | tee -a "$LOG"
fi

# ===== 添加定时任务（每 4 小时） =====
CRON_FILE="/etc/crontabs/root"
if ! grep -q "bash $WORK_DIR/cf.sh" "$CRON_FILE" 2>/dev/null; then
    echo "0 */4 * * * bash $WORK_DIR/cf.sh >/dev/null 2>&1" >> "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "✅ 已添加定时任务（每 4 小时）" | tee -a "$LOG"
fi
