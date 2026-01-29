#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cloudflare IPv4/IPv6 双栈优选 - 青龙面板专用版 (Python)
适配架构: AMD64 / ARM64 / ARM32 (自动检测)
功能: 
  1. 自动下载对应架构的 CloudflareST 测速工具
  2. 优先复用现有 IP (体检模式)，仅在不达标时执行优选
  3. 双栈支持 (IPv4 + IPv6)
  4. 微信/Telegram 推送通知
"""

import os
import sys
import time
import json
import shutil
import platform
import tarfile
import subprocess
import requests
from loguru import logger

# ================= 配置区域 (可在青龙面板环境变量中覆盖) =================

# 默认阈值 (若环境变量未设置，则使用此处的默认值)
DEFAULT_MAX_LATENCY = 150   # 延迟上限 (ms)
DEFAULT_MIN_SPEED = 5.0     # 速度下限 (MB/s)
DEFAULT_MAX_IPS = 5         # 优选 IP 数量

# 默认目标域名 (若环境变量未设置，则使用此处的默认值)
DEFAULT_IPV4_DOMAIN = "ipv4.eee.xx.kg"
DEFAULT_IPV6_DOMAIN = "ipv6.eee.xx.kg"

# =======================================================================

class Config:
    def __init__(self):
        # 1. 基础配置
        self.max_latency = int(os.environ.get("CF_MAX_LATENCY", DEFAULT_MAX_LATENCY))
        self.min_speed = float(os.environ.get("CF_MIN_SPEED", DEFAULT_MIN_SPEED))
        self.max_ips = int(os.environ.get("CF_MAX_IPS", DEFAULT_MAX_IPS))
        
        # 2. Cloudflare API
        self.cf_token = os.environ.get("CF_API_TOKEN")
        self.cf_zone_id = os.environ.get("CF_ZONE_ID")
        
        # 代理配置: 优先 CF_API_PROXY -> HTTP_PROXY -> ALL_PROXY
        self.cf_proxy = os.environ.get("CF_API_PROXY") or os.environ.get("HTTP_PROXY") or os.environ.get("ALL_PROXY")
        if self.cf_proxy:
            self.cf_proxy = self.cf_proxy.strip()
            logger.info(f"🌐 代理已启用: {self.cf_proxy}")
        else:
            logger.info("⚠️ 未检测到代理配置，将尝试直连")
        
        # 3. 目标域名
        self.ipv4_domain = os.environ.get("CF_DNS_IPV4", DEFAULT_IPV4_DOMAIN)
        self.ipv6_domain = os.environ.get("CF_DNS_IPV6", DEFAULT_IPV6_DOMAIN)
        
        # 4. 通知配置
        self.wx_url = os.environ.get("WECHAT_API_URL")
        self.wx_token = os.environ.get("WECHAT_AUTH_TOKEN")
        self.tg_token = os.environ.get("TG_BOT_TOKEN")
        self.tg_chat_id = os.environ.get("TG_CHAT_ID")
        self.tg_api_host = os.environ.get("TG_API_HOST", "https://api.telegram.org") # 支持反代

        # 5. 路径配置
        self.base_dir = "/ql/data/scripts/cf_optimizer"  # 青龙脚本数据目录
        if not os.path.exists("/ql/data"): # 兼容非青龙环境
             self.base_dir = os.path.join(os.getcwd(), "cf_data")
             
        self.ipv4_dir = os.path.join(self.base_dir, "ipv4")
        self.ipv6_dir = os.path.join(self.base_dir, "ipv6")
        
        # v2.2.5 被撤回/不存在，v2.2.3 也有问题，尝试 v2.2.4
        self.cfst_version = "v2.2.4"
        self.colors = ["NRT", "SIN", "SJC", "HKG"]
        
        # 检查必要参数
        if not self.cf_token or not self.cf_zone_id:
            logger.error("❌ 未配置 CF_API_TOKEN 或 CF_ZONE_ID，请检查环境变量")
            sys.exit(1)

        # 设置 API 请求 Session (处理代理)
        self.session = requests.Session()
        if self.cf_proxy:
            self.session.proxies = {
                "http": self.cf_proxy,
                "https": self.cf_proxy
            }
            logger.info(f"API 请求将使用代理: {self.cf_proxy}")

# ... (CloudflareST and CloudflareDNS classes remain unchanged) ...

    def notify(self, summary):
        """发送通知 (微信 + Telegram)"""
        proxies = None
        if self.cfg.cf_proxy:
            proxies = {"http": self.cfg.cf_proxy, "https": self.cfg.cf_proxy}

        # 1. 微信推送
        if self.cfg.wx_url and self.cfg.wx_token:
            logger.info("📨 发送微信推送...")
            content_wx = f"Cloudflare 优选报告\n{summary}"
            params_wx = {
                "token": self.cfg.wx_token,
                "title": "CF IP 优选",
                "content": content_wx
            }
            try:
                resp = requests.get(self.cfg.wx_url, params=params_wx, timeout=10, proxies=proxies)
                if resp.status_code == 405:
                    resp = requests.post(self.cfg.wx_url, json=params_wx, timeout=10, proxies=proxies)
            except Exception as e:
                logger.error(f"微信推送失败: {e}")

        # 2. Telegram 推送
        if self.cfg.tg_token and self.cfg.tg_chat_id:
            logger.info("📨 发送 Telegram 推送...")
            tg_url = f"{self.cfg.tg_api_host}/bot{self.cfg.tg_token}/sendMessage"
            # TG 消息需要转义特殊字符防止 Markdown 解析错误，这里简单处理或者用纯文本
            content_tg = f"🌐 *Cloudflare IP 优选完成*\n\n{summary}"
            
            payload = {
                "chat_id": self.cfg.tg_chat_id,
                "text": content_tg,
                "parse_mode": "Markdown" # 或者 HTML
            }
            
            try:
                requests.post(tg_url, json=payload, timeout=15, proxies=proxies)
            except Exception as e:
                logger.error(f"Telegram 推送失败: {e}")

class CloudflareST:
    def __init__(self, config, ip_version=4):
        self.cfg = config
        self.ip_version = ip_version
        self.work_dir = self.cfg.ipv4_dir if ip_version == 4 else self.cfg.ipv6_dir
        
        if not os.path.exists(self.work_dir):
            os.makedirs(self.work_dir)
            
        self.tool_path = os.path.join(self.work_dir, "CloudflareST")
        self.ip_file = os.path.join(self.work_dir, f"ip{ip_version}.txt")
        self.result_csv = os.path.join(self.work_dir, "result.csv")
        
    def detect_arch(self):
        """检测系统架构并返回对应的 CloudflareST 下载文件名"""
        machine = platform.machine().lower()
        
        # 用户自定义仓库的文件名格式: cfstamd64, cfstarm64, cfstarmv7
        if machine in ["x86_64", "amd64"]:
            return "cfstamd64"
        elif machine in ["aarch64", "arm64"]:
            return "cfstarm64"
        elif "arm" in machine: # armv7l, armv6, etc.
             return "cfstarmv7"
        else:
            logger.error(f"❌ 不支持的架构: {machine}")
            return None

    def download_tool(self):
        """下载 CloudflareST (直接下载二进制)"""
        if os.path.exists(self.tool_path) and os.access(self.tool_path, os.X_OK):
            return True
            
        filename = self.detect_arch()
        if not filename:
            return False
            
        # 定义下载源列表 (用户自定义仓库 + 镜像)
        # 注意: 仓库里是直接的二进制文件，不是压缩包
        base_path = "raw.githubusercontent.com/djkyc/cftest/refs/heads/main/cfst_linux/"
        urls = [
            f"https://docker.djsb.nyc.mn/{base_path}/{filename}",
            f"{base_path}/{filename}"
            ]
        
        for url in urls:
            logger.info(f"📥 尝试下载: {url}")
            try:
                # 下载 (应用代理配置)
                proxies = None
                if self.cfg.cf_proxy:
                    proxies = {"http": self.cfg.cf_proxy, "https": self.cfg.cf_proxy}
                    
                resp = requests.get(url, stream=True, timeout=30, proxies=proxies)
                
                # 检查状态码
                if resp.status_code != 200:
                    logger.warning(f"❌ 下载失败 HTTP {resp.status_code}")
                    continue

                # 直接写入到 tool_path (因为它本身就是二进制)
                with open(self.tool_path, "wb") as f:
                    shutil.copyfileobj(resp.raw, f)
                
                # 赋予执行权限
                os.chmod(self.tool_path, 0o755)
                logger.success("✅ 测速工具安装成功")
                return True
                
            except Exception as e:
                logger.warning(f"❌ 下载异常: {e}")
                continue
        else:
             logger.error("❌ 所有下载源均失败")
             return False

    def download_ip_list(self):
        """下载官方 IP 库"""
        if os.path.exists(self.ip_file) and os.path.getsize(self.ip_file) > 10:
            return # 已存在且不为空
            
        url = f"https://www.cloudflare.com/ips-v{'4' if self.ip_version == 4 else '6'}"
        try:
            logger.info(f"📥 正在下载 IPv{self.ip_version} IP库...")
            # 应用代理
            proxies = None
            if self.cfg.cf_proxy:
                proxies = {"http": self.cfg.cf_proxy, "https": self.cfg.cf_proxy}
                
            resp = requests.get(url, timeout=10, proxies=proxies)
            if resp.status_code == 200:
                with open(self.ip_file, "w", encoding="utf-8") as f:
                    f.write(resp.text)
                logger.success("✅ IP库下载成功")
            else:
                logger.warning("⚠️ IP库下载失败，状态码非200")
        except Exception as e:
             logger.warning(f"⚠️ IP库下载异常: {e}")

    def run_test(self, colo=None):
        """运行测速"""
        # 预处理 IP 文件 (去重去空行去注释)
        clean_file = os.path.join(self.work_dir, "clean_ips.txt")
        if os.path.exists(self.ip_file):
            with open(self.ip_file, 'r', encoding='utf-8') as f_in, open(clean_file, 'w', encoding='utf-8') as f_out:
                for line in f_in:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        f_out.write(line + "\n")
        else:
            logger.error(f"❌ 未找到 IP 文件: {self.ip_file}")
            return []

        # 统计 IP 数量
        ip_count = 0
        with open(clean_file, 'r', encoding='utf-8') as f:
            ip_count = sum(1 for _ in f)
        logger.info(f"   📄 IP库有效行数: {ip_count}")

        # 构建命令
        # -dn 5: 只测速延迟最低的5个
        # -dt 8: 下载测试时间8秒
        # -t 3: ping次数
        # -httping: 使用 httping 模式 (更准)
        # -url: 指定大文件地址
        cmd = [
            self.tool_path,
            "-f", clean_file,
            "-dn", "5",
            "-dt", "8",
            "-t", "3",
            "-httping",
            "-url", "https://speed.cloudflare.com/__down?bytes=50000000",
            "-p", "5", # 显示5个结果
            "-o", self.result_csv
        ]
        
        if colo:
            cmd.extend(["-cfcolo", colo])
            
        try:
            # 捕获输出以便调试
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
            
            if proc.returncode != 0:
                logger.warning(f"⚠️ CloudflareST 非正常退出 (Code {proc.returncode})")
                
            results = []
            if os.path.exists(self.result_csv):
                 with open(self.result_csv, 'r', encoding='utf-8') as f:
                     # 跳过标题行，解析 CSV
                     # 格式通常是: IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码
                     for line in f:
                         if "IP" in line: continue # Title
                         parts = line.strip().split(',')
                         if len(parts) >= 6:
                             ip = parts[0]
                             latency = float(parts[4])
                             speed = float(parts[5])
                             if speed > 0: # 只记录有效的
                                results.append({
                                    "ip": ip,
                                    "latency": latency,
                                    "speed": speed
                                })
            
            # 如果没结果，打印日志
            if not results:
                logger.warning(f"⚠️ 无测速结果 (IP数:{ip_count})")
                # 打印最后几行输出帮忙诊断
                if proc.stdout:
                    stdout_preview = '\n'.join(proc.stdout.strip().splitlines()[-3:])
                    logger.info(f"STDOUT (Last 3 lines):\n{stdout_preview}")
                # stderr 通常是进度条，太吵了，不打印

            return results
        except Exception as e:
            logger.warning(f"测速运行异常: {e}")
            return []

class CloudflareDNS:
    def __init__(self, config):
        self.cfg = config
        self.api_url = f"https://api.cloudflare.com/client/v4/zones/{self.cfg.cf_zone_id}/dns_records"
        self.headers = {
            "Authorization": f"Bearer {self.cfg.cf_token}",
            "Content-Type": "application/json"
        }

    def get_records(self, name, rtype="A"):
        """获取现有记录"""
        params = {"name": name, "type": rtype}
        try:
            resp = self.cfg.session.get(self.api_url, headers=self.headers, params=params, timeout=15)
            data = resp.json()
            if data.get("success"):
                return data.get("result", [])
            else:
                logger.error(f"❌ 获取 DNS 记录失败: {data.get('errors')}")
                return []
        except Exception as e:
            logger.error(f"API 请求异常: {e}")
            return []

    def add_record(self, name, ip, rtype="A"):
        """添加记录"""
        data = {
            "type": rtype,
            "name": name,
            "content": ip,
            "ttl": 1, 
            "proxied": False
        }
        try:
            resp = self.cfg.session.post(self.api_url, headers=self.headers, json=data, timeout=15)
            if resp.json().get("success"):
                logger.success(f"✅ 添加成功: {name} -> {ip}")
                return True
        except Exception as e:
            logger.error(f"添加记录异常: {e}")
        return False

    def delete_record(self, record_id, reason=""):
        """删除记录"""
        url = f"{self.api_url}/{record_id}"
        try:
            resp = self.cfg.session.delete(url, headers=self.headers, timeout=15)
            if resp.json().get("success"):
                logger.info(f"🗑️ 删除成功 ({reason}): ID {record_id}")
        except Exception as e:
            logger.error(f"删除记录异常: {e}")

class Optimizer:
    def __init__(self):
        self.cfg = Config()
        self.dns = CloudflareDNS(self.cfg)
        self.is_arm32 = "arm" in platform.machine().lower() and "64" not in platform.machine().lower()

    def check_ip_validity(self, ip, port=443):
        """检查 IP 连通性 (TCP)"""
        import socket
        try:
            sock = socket.socket(socket.AF_INET if ":" not in ip else socket.AF_INET6, socket.SOCK_STREAM)
            sock.settimeout(3)
            result = sock.connect_ex((ip, port))
            sock.close()
            return result == 0
        except:
            return False

    def run_single_stack(self, ip_version):
        """执行单栈优选流程"""
        domain_name = self.cfg.ipv4_domain if ip_version == 4 else self.cfg.ipv6_domain
        rtype = "A" if ip_version == 4 else "AAAA"
        max_ips = self.cfg.max_ips
        
        logger.info(f"🚀 开始 IPv{ip_version} 优选 | 目标: {domain_name}")
        
        # 1. 准备环境
        cfst = CloudflareST(self.cfg, ip_version)
        if not cfst.download_tool():
            return f"IPv{ip_version}: ❌ 工具下载失败"
        cfst.download_ip_list()
        
        # 2. 检查现有记录
        existing_records = self.dns.get_records(domain_name, rtype)
        valid_records = []
        
        logger.info(f"🔍 现有记录: {len(existing_records)} 个")
        
        for rec in existing_records:
            ip = rec['content']
            rid = rec['id']
            
            # 简单连通性检查
            if self.check_ip_validity(ip):
                # 如果是 IPv4，可以尝试 ping 检查延迟 (可选)
                valid_records.append(ip)
                logger.info(f"✅ 现有 IP 有效: {ip}")
            else:
                logger.warning(f"⚠️ 现有 IP 失效: {ip}")
                self.dns.delete_record(rid, "连通性测试失败")
        
        current_count = len(valid_records)
        needed = max_ips - current_count
        
        if needed <= 0:
            logger.success(f"🎉 现有有效 IP 已达标 ({current_count}/{max_ips})，无需更新")
            return f"IPv{ip_version}: ✅ 有效 {current_count}/{max_ips}"
            
        logger.info(f"📉 需要补充 {needed} 个新 IP")
        
        # 3. 执行测速
        new_candidates = []
        
        # 尝试遍历数据中心
        for col in self.cfg.colors:
            # logger.info(f"⚡ 测速区域: {col}...")
            results = cfst.run_test(col)
            
            for res in results:
                # 筛选逻辑
                if res['latency'] < self.cfg.max_latency and res['speed'] > self.cfg.min_speed:
                    if res['ip'] not in valid_records and res['ip'] not in [x['ip'] for x in new_candidates]:
                        new_candidates.append(res)
                        # logger.success(f"➕ 选中新 IP: {res['ip']} (延迟:{res['latency']}ms, 速度:{res['speed']}MB/s)")
                        if len(new_candidates) >= needed:
                            break
            
            if len(new_candidates) >= needed:
                break
                
        # 4. 添加记录
        added_count = 0
        report_lines = []
        
        # 记录现有 Keep 的 IP
        for ip in valid_records:
            report_lines.append(f"   - [保留] {ip}")
            
        # 记录新增的 IP
        for cand in new_candidates[:needed]:
            if self.dns.add_record(domain_name, cand['ip'], rtype):
                added_count += 1
                report_lines.append(f"   - [新增] {cand['ip']} (延迟:{cand['latency']}ms, 速度:{cand['speed']}MB/s)")
                
        final_count = current_count + added_count
        
        # 构建最终报告
        header = f"IPv{ip_version}: ✅ 最终有效 {final_count}/{max_ips} (新增 {added_count})"
        if report_lines:
            return f"{header}\n" + "\n".join(report_lines)
        return header

    def notify(self, summary):
        """发送通知"""
        if not self.cfg.wx_url or not self.cfg.wx_token:
            return
            
        logger.info("📨 发送微信推送...")
        content = f"Cloudflare 双栈优选报告py版\n{summary}"
        
        params = {
            "token": self.cfg.wx_token,
            "title": "CF IP 优选",
            "content": content
        }
        
        try:
            # 尝试 GET (应用代理)
            proxies = None
            if self.cfg.cf_proxy:
                proxies = {"http": self.cfg.cf_proxy, "https": self.cfg.cf_proxy}

            resp = requests.get(self.cfg.wx_url, params=params, timeout=10, proxies=proxies)
            if resp.status_code == 405:
                resp = requests.post(self.cfg.wx_url, json=params, timeout=10, proxies=proxies)
        except Exception as e:
            logger.error(f"推送失败: {e}")

    def run(self):
        msg_v4 = self.run_single_stack(4)
        logger.info("-" * 30)
        msg_v6 = self.run_single_stack(6)
        
        summary = f"{msg_v4}\n{msg_v6}"
        logger.info("=" * 30)
        logger.info(summary)
        
        self.notify(summary)

if __name__ == "__main__":
    app = Optimizer()
    app.run()
