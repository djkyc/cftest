#!/bin/bash
# ====================================================
# Cloudflare IPv6 优选（ARMv8 版本，HTTPing）
# 作者: djcky  — ARMv8 优化版 
# ====================================================

ulimit -n 65535

WORK_DIR="/opt/cf/ip6"
CFST="$WORK_DIR/cfst"
IPV6_FILE="$WORK_DIR/ipv6.txt"
RESULT_CSV="$WORK_DIR/result_ipv6.csv"
LOG="$WORK_DIR/log.txt"
mkdir -p "$WORK_DIR"

# ===== Cloudflare API 信息 =====
CF_API_TOKEN="你的CF_API_TOKEN"
CF_ZONE_ID="你的CF_ZONE_ID"
CF_RECORD_NAME="ip6.eee.xx.kg"

# ===== 检查依赖 =====
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 未检测到 jq，请先安装：opkg install jq -y" | tee -a "$LOG"
    exit 1
fi

if [ ! -x "$CFST" ]; then
    echo "❌ 未找到 ARMv8 版 cfst，请放置到：$CFST" | tee -a "$LOG"
    exit 1
fi

# 检查 cfst 二进制架构是否为 ARMv8
CFST_ARCH=$(file "$CFST")
if ! echo "$CFST_ARCH" | grep -q "aarch64"; then
    echo "❌ 错误：cfst 不是 ARMv8/aarch64 版本！" | tee -a "$LOG"
    echo "请放入正确架构的 cfst 可执行文件。" | tee -a "$LOG"
    exit 1
fi

# ===== 检查 IPv6 是否可用 =====
if ! curl -6 -s --connect-timeout 4 https://www.cloudflare.com/ >/dev/null; then
    echo "❌ IPv6 出口不可用，无法测速" | tee -a "$LOG"
    exit 1
fi

# ===== 测试数据中心列表 =====
COLOS=("SIN" "HKG" "NRT")
BEST_IP_ARRAY=()

# ===== 循环测速 =====
for CF_COLO in "${COLOS[@]}"; do
    echo "$(date '+%F %T') 开始 IPv6 HTTPing 测速 (${CF_COLO})" | tee -a "$LOG"

    > "$RESULT_CSV"

    # ARMv8 直接运行 cfst 即可
    $CFST -f "$IPV6_FILE" -t 3 -tl 9999 -httping -cfcolo "$CF_COLO" -o "$RESULT_CSV"

    if [ ! -s "$RESULT_CSV" ]; then
        echo "⚠️ ${CF_COLO} 无可用结果" | tee -a "$LOG"
        continue
    fi

    COUNT=$(awk -F, 'NR>1 {print $1}' "$RESULT_CSV" | wc -l)
    if [ "$COUNT" -lt 5 ]; then
        echo "⚠️ ${CF_COLO} 可用 IPv6 不足 5 个 (${COUNT})" | tee -a "$LOG"
        continue
    fi

    BEST_IP_ARRAY=($(awk -F, 'NR>1 && NR<=9 {print $1}' "$RESULT_CSV"))

    echo "✅ ${CF_COLO} 最佳 IPv6 前 8 个：" | tee -a "$LOG"
    awk -F, 'NR>1 && NR<=9 {print "  - " $1 " 延迟:" $5 "ms"}' "$RESULT_CSV" | tee -a "$LOG"
    break
done

# ===== 确保至少有 8 个结果 =====
if [ "${#BEST_IP_ARRAY[@]}" -lt 5 ]; then
    echo "❌ 所有区域测速完成，但未获得足够 IPv6" | tee -a "$LOG"
    exit 1
fi

# ===== 删除旧 AAAA 记录 =====
old_ids=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=AAAA&name=${CF_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[].id')

for id in $old_ids; do
    curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/$id" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" >/dev/null
done

echo "✅ 已删除旧 IPv6 AAAA 记录" | tee -a "$LOG"

# ===== 添加新的 AAAA 记录 =====
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
        echo "✅ 添加 AAAA: ${CF_RECORD_NAME} -> $ip" | tee -a "$LOG"
    else
        echo "❌ 添加失败: $ip ($(echo "$resp" | jq -r '.errors[]?.message'))" | tee -a "$LOG"
    fi
done

echo "$(date '+%F %T') 🎯 IPv6 优选完成，已上报 8 个最佳 IPv6" | tee -a "$LOG"

# ===== 创建快捷命令 cf6 =====
if [ ! -f /usr/bin/cf6 ]; then
    echo "#!/bin/bash" > /usr/bin/cf6
    echo "bash $WORK_DIR/cf6.sh" >> /usr/bin/cf6
    chmod +x /usr/bin/cf6
    echo "✅ 快捷命令 cf6 已创建" | tee -a "$LOG"
fi

# ===== 添加定时任务（每 8 小时执行） =====
CRON_FILE="/etc/crontabs/root"
CRON_CMD="0 */8 * * * bash $WORK_DIR/cf6.sh >/dev/null 2>&1"

if ! grep -qF "$CRON_CMD" "$CRON_FILE" 2>/dev/null; then
    echo "$CRON_CMD" >> "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null || true
    echo "✅ 定时任务已添加（每 8 小时）" | tee -a "$LOG"
fi

exit 0
