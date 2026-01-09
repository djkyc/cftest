#!/bin/bash
# ====================================================
# VPS Cloudflare IPv4 优选 - 自动运行版
# 作者: djcky支持armv7 32位 cloudone 快捷命令 cf
#说明：已添加定时任务（每4小时运行一次）
# ====================================================

# 放宽文件句柄限制
ulimit -n 65535
WORK_DIR="/opt/cf"
CFST="$WORK_DIR/cfst"
IPV4_FILE="$WORK_DIR/ip.txt"
RESULT_CSV="$WORK_DIR/result_ipv4.csv"
LOG="$WORK_DIR/log.txt"

# ===== Cloudflare 认证信息 =====
CF_API_TOKEN="RHATceeeeeeg" #Cloudflare API Token
CF_ZONE_ID="0fca3e58687f3b3eb2772c56712eeee" #域名区域id
CF_RECORD_NAME="ip.yee.xx.kg" #托管的域名前面加任何,子域名。托管的ye.xx.kg=这里就写cf.ye.xx.kg

# ===== 检查依赖 =====
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 未检测到 jq，请先安装：opkg install jq -y" | tee -a "$LOG"
    exit 1
fi

# ===== 验证 CF Token 有效性 =====
echo "🔍 验证 Cloudflare API Token..." | tee -a "$LOG"
VERIFY=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result.status')
if [ "$VERIFY" != "active" ]; then
    echo "❌ Token 验证失败，请检查 CF_API_TOKEN 是否正确。" | tee -a "$LOG"
    exit 1
else
    echo "✅ Token 有效，继续执行..." | tee -a "$LOG"
fi

# ===== 数据中心列表 =====
COLOS=("NRT" "SIN" "SJC")
BEST_IPV4_ARRAY=()

for CF_COLO in "${COLOS[@]}"; do
    echo "$(date '+%F %T') 开始 IPv4 HTTPing 测速（${CF_COLO}）..." | tee -a "$LOG"

    > "$RESULT_CSV"

    $CFST -f "$IPV4_FILE" -dn 5 -t 3 -httping -cfcolo "$CF_COLO" -o "$RESULT_CSV"

    if [ ! -s "$RESULT_CSV" ]; then
        echo "⚠️ ${CF_COLO} 区域无可用结果，继续下一个..." | tee -a "$LOG"
        continue
    fi

    COUNT=$(awk -F, 'NR>1 {print $1}' "$RESULT_CSV" | wc -l)
    if [ "$COUNT" -lt 2 ]; then
        echo "⚠️ ${CF_COLO} 区域可用 IP 数量不足 (${COUNT})..." | tee -a "$LOG"
        continue
    fi

    BEST_IPV4_ARRAY=($(awk -F, 'NR>1 && NR<=3 {print $1}' "$RESULT_CSV"))
    echo "✅ 选定 ${CF_COLO} 区域最佳 2 个 IP：" | tee -a "$LOG"
    awk -F, 'NR>1 && NR<=3 {print "  - " $1 " 延迟:" $5 "ms"}' "$RESULT_CSV" | tee -a "$LOG"
    break
done

if [ "${#BEST_IPV4_ARRAY[@]}" -lt 2 ]; then
    echo "❌ 所有地区无可用 IP，脚本退出。" | tee -a "$LOG"
    exit 1
fi

# ===== 删除旧记录 =====
old_ids=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[].id')

for id in $old_ids; do
    curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/$id" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" >/dev/null 2>&1
done
echo "✅ 已删除旧的 A 记录" | tee -a "$LOG"

# ===== 上报前 2 个 IPv4 =====
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
        echo "✅ 已上报 A 记录: ${CF_RECORD_NAME} -> $ip" | tee -a "$LOG"
    else
        echo "❌ 上报失败: $ip ($(echo "$resp" | jq -r '.errors[]?.message'))" | tee -a "$LOG"
    fi
done

echo "$(date '+%F %T') 🎯 VPS IPv4 优选完成，已上报 2 个最佳 IP" | tee -a "$LOG"

# ===== 自动创建快捷命令 cf =====
if [ ! -f /usr/bin/cf ]; then
    echo '#!/bin/bash' > /usr/bin/cf
    echo "bash $WORK_DIR/cf.sh" >> /usr/bin/cf
    chmod +x /usr/bin/cf
    echo "✅ 已创建命令快捷方式：cf" | tee -a "$LOG"
fi

# ===== 自动添加定时任务（每4小时执行一次） =====
CRON_FILE="/etc/crontabs/root"
if ! grep -q "bash $WORK_DIR/cf.sh" "$CRON_FILE" 2>/dev/null; then
    echo "0 */4 * * * bash $WORK_DIR/cf.sh >/dev/null 2>&1" >> "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "✅ 已添加定时任务（每4小时运行一次）" | tee -a "$LOG"
fi
