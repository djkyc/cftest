![Screenshot of a comment on a GitHub issue showing an image, added in the Markdown, of an Octocat smiling and raising a tentacle.](https://github.com/dj56959566/cftest/blob/main/photo_2025-10-30_16-03-29.jpg?raw=true)

# Cloudflare IPv4/IPv6 双栈优选脚本 3.0版  

## 下载3.0cf.7z解压ssh登陆。把文件目录名改为cf直接放在root/目录下即可

自动优选 Cloudflare IP 并更新 DNS 记录，支持 IPv4 和 IPv6 双栈。

## 功能特点

- ✅ **智能检测**：先验证现有 IP 有效性，有效则跳过优选
- ✅ **双栈支持**：依次执行 IPv4 和 IPv6 优选
- ✅ **多数据中心**：支持 NRT/SIN/SJC 等多个 Cloudflare 节点
- ✅ **自动定时**：每 4 小时自动运行
- ✅ **微信推送**：合并双栈结果发送通知

## 文件结构

```
/root/cf/
├── cf.sh                 # 主脚本
├── ipv4/
│   ├── cfstipv4          # IPv4 测速工具
│   ├── ip4.txt           # IPv4 IP库
│   ├── result_ipv4.csv   # 测速结果（自动生成）
│   └── log_ipv4.txt      # 日志（自动生成）
└── ipv6/
    ├── cfstipv6          # IPv6 测速工具
    ├── ipv6.txt          # IPv6 IP库
    ├── result_ipv6.csv   # 测速结果（自动生成）
    └── log_ipv6.txt      # 日志（自动生成）
```

## 配置说明

编辑 `cf.sh` 修改以下配置：

```bash
# Cloudflare API 认证
CF_API_TOKEN="your_token"  区域 ID
CF_ZONE_ID="your_zone_id"  特定区域后面选上你要邦定的域名即可

# 目标域名
IPV4_RECORD_NAME="ipv4.example.com"
IPV6_RECORD_NAME="ipv6.example.com"

# 保留 IP 数量
IPV4_MAX_IPS=5
IPV6_MAX_IPS=5

# 延迟阈值（毫秒）
MAX_LATENCY_MS=120

# 微信推送（可选）
WECHAT_API_URL="https://your-api/wxsend"
WECHAT_AUTH_TOKEN="your_token"
```

## 使用方法

### 手动运行

```bash
bash /root/cf/cf.sh
```

### 快捷命令

首次运行后自动创建 `cf` 命令：

```bash
cf
```

### 查看日志

```bash
cat /root/cf/ipv4/log_ipv4.txt
cat /root/cf/ipv6/log_ipv6.txt
```

### 查看定时任务

```bash
crontab -l | grep cf.sh
```

## 依赖安装

```bash
# Debian/Ubuntu
apt install jq curl -y

# OpenWrt
opkg install jq curl
```

## 测速工具下载

从 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest/releases) 下载对应架构版本：

- ARMv8: `CloudflareST_linux_arm64.tar.gz`
- x86_64: `CloudflareST_linux_amd64.tar.gz`

```bash
# ARMv8 示例
cd /root/cf/ipv4
wget https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/CloudflareST_linux_arm64.tar.gz
tar -xzf CloudflareST_linux_arm64.tar.gz
mv CloudflareST cfstipv4
chmod +x cfstipv4

# IPv6 同理
cp cfstipv4 ../ipv6/cfstipv6
```

## 运行效果

```
════════════════════════════════════════════════
  Cloudflare IP 双栈优选完成
════════════════════════════════════════════════
  IPv4: 🔄 删除0/添加2 | 有效 5/5
  IPv6: 🔄 删除0/添加2 | 有效 5/5
════════════════════════════════════════════════
```

---
# * 软路由里跑 openwrt V2.0版升级了许多小功能可以测试。

 # 1.armv7 32bit 旁路由 玩克云 实战 ipv4优先ip自定义邦定域名，成为优选域名每四小时执行一次。

A.把这个和刚刚那个放在一个文件一个文件夹

三个文件

放到玩克云中  opt/cf/

cfst 

cfst.sh

ip.txt

2.给权限

chmod +x cf.sh

chmod +x cfst

B.安装这些依赖

opkg update

opkg install curl jq wget bc -y

C. 获取Cloudflare API Token

 1 访问 Cloudflare API Tokens (https://dash.cloudflare.com/profile/api-tokens)
   
 2 点击 "Create Token"
 
 3 选择 "Edit zone DNS" 模板
 
 4 在 "Zone Resources" 中选择 "Include All zones"
 
 5 点击 "Continue to summary" → "Create Token"
 
 6 复制生成的Token


cd opt/cf
 

D.最后  直接运行 bash cf.sh

![uAxv8koPchRfSY9Xe4j3lf2XIikKGdxx.webp](https://cdn.nodeimage.com/i/uAxv8koPchRfSY9Xe4j3lf2XIikKGdxx.webp)


# ----------------------------------------------------------------------------------------------------------------------------------

# 2.armv7 32bit 玩客云旁路由定时扫ipv6上传帮定cf域名，成为优选域名每三小时执行一次。

文件在ipv6夹中
