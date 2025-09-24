# 端口流量狗 (Port Traffic Dog)

> 一只轻巧的'守护犬'，时刻守护你的端口流量，让端口流量监控变得简单高效！

🔔 **端口流量狗**是一款轻量化的Linux端口流量监控和管理工具，基于nftables和TC(Traffic Control)技术，提供精确的端口级流量统计、带宽限制和配额管理功能。

## 脚本界面预览

**主界面**
![1e811dd521314e01a2e533b72580c7a4.png](https://i.mji.rip/2025/08/28/1e811dd521314e01a2e533b72580c7a4.png)

## 适用场景

### 🌐 网络服务监控
- 中转、Web服务器、代理服务、游戏服务器等各类网络服务
- 为其他没有流量管理的程序,附加轻量化准确流量管理

### 💰 流量计费管理
- **VPS流量控制**: 防止VPS流量超限产生额外费用
- **成本控制**: 通过流量限制控制网络使用成本

## ✨ 核心特性

### 流量监控
- **精确统计**: 基于nftables的端口级流量统计
- **双向支持**: 支持单向/双向流量统计模式
- **端口段支持**: 支持单端口和端口段(如100-200)监控
- **实时统计**: 提供实时累计流量数据
- **持久化**: 突然服务器故障关机(重启),也能无感继续稳定正常工作

### 流量控制
- **带宽限制**: 基于TC的端口带宽限制(Mbps/Gbps)，支持流量突发处理
- **流量配额**: 基于nftables quota的月流量配额控制(支持MB/GB/TB)
- **自动重置**: 可单独为端口配置月度流量自动重置(默认每月1日，支持1-31日自定义)
- **超限阻断**: 流量超限自动阻断连接，也可手动立即重置

### 数据管理
- **一键导出/导入**: 完整数据包实现自由迁移
- **历史记录**: 流量重置历史记录
- **日志轮转**: 自动日志清理和轮转

###  通知系统
- **Telegram通知**: 支持Telegram机器人通知
- **状态通知**: 可配置间隔的状态通知
- **扩展支持**: 预留邮箱和企业微信通知接口(敬请期待)

### 端口备注管理
- **多用户环境**: 为不同用户备注管理，不再需要额外记忆

## 🚀 一键安装

> 属于完整独立脚本，可单独安装使用(快捷键:dog)

### 方式一：直接安装
```bash
wget -O port-traffic-dog.sh https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

### 方式二：使用加速源
```bash
wget -O port-traffic-dog.sh https://ghfast.top/https://raw.githubusercontent.com/zywe03/realm-xwPF/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

## 系统要求

### 自动安装的依赖
遵循**Linux原生轻量化工具**原则，保持系统干净整洁：

- `nftables` - 现代网络过滤框架，替代iptables
- `iproute2` - 网络工具套件(包含tc、ss、ip命令)
- `jq` - JSON处理工具
- `gawk` - GNU AWK文本处理工具
- `bc` - 基础计算器，用于流量单位转换
- `unzip` - 解压缩工具

## 说明

### 流量统计模式
- **单向统计**: 仅统计出站流量
- **双向统计**: 统计入站+出站流量


### 配置文件位置
- **主配置**: `/etc/port-traffic-dog/config.json` - 端口配置、通知设置等
- **数据目录**: `/etc/port-traffic-dog/data/` - 流量数据存储
- **数据文件**: `/etc/port-traffic-dog/data/daily_*.db` - 流量数据记录
- **日志目录**: `/etc/port-traffic-dog/logs/` - 运行日志和通知日志
- **通知模块**: `/etc/port-traffic-dog/notifications/` - Telegram等通知脚本

## Telegram通知配置

### 1. 创建Telegram机器人
1. 在Telegram中找到 @BotFather
2. 发送 `/newbot` 创建新机器人
3. 获取Bot Token

### 2. 获取Chat ID
1. 将机器人添加到群组或私聊
2. 发送任意消息给机器人
3. 访问 `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. 从返回结果中找到chat_id

### 3. 配置通知
在脚本主菜单选择：
8. 通知管理 → 1. Telegram机器人通知

配置项：
- Bot Token
- Chat ID
- 服务器名称
- 状态通知(可选间隔：1分钟到24小时)


### 贡献代码
欢迎各种形式的贡献：Bug修复、新功能、文档改进等

## 开源协议

本项目基于MIT协议开源，详见 [LICENSE](https://github.com/zywe03/realm-xwPF/blob/main/LICENSE) 文件。
