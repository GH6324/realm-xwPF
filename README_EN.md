# realm Full-Featured One-Click Network Forwarding Management, Quick Relay Server Setup, Three Scripts Building Complete Relay Ecosystem

[中文](README.md) | [English](README_EN.md)

---

> 🚀 **Network Forwarding Management Script** - Integrates all features of the latest official realm version, network connectivity testing, port traffic monitor, maintains minimalist essence, visual rule operations for improved efficiency, pure script-based complete relay ecosystem

## 📸 Three Scripts Interface Preview 📸

<details>
<summary>Click to view interface screenshots</summary>

### xwPF.sh realm forwarding script

**Main Interface**
![bc670bfc66faa167f43ac261184415c9.png](https://i.mji.rip/2025/08/28/bc670bfc66faa167f43ac261184415c9.png)

**Forwarding Configuration Management**
![91b443454ee6bbbb0926c1f2b33e8727.png](https://i.mji.rip/2025/08/28/91b443454ee6bbbb0926c1f2b33e8727.png)

**Load Balancing & Failover**
![Load Balancing + Failover](https://i.mji.rip/2025/07/17/e545e7ee444a0a2aa3592d080678696c.png)

**MPTCP Settings Interface**
![ead4f6fe61a1f3128a6b9f18dadf6a63.png](https://i.mji.rip/2025/08/28/ead4f6fe61a1f3128a6b9f18dadf6a63.png)

### Port Traffic Monitor

**Main Interface**
![1e811dd521314e01a2e533b72580c7a4.png](https://i.mji.rip/2025/08/28/1e811dd521314e01a2e533b72580c7a4.png)

### Relay Network Connectivity Testing Script
```
===================== Network Link Testing Complete Report =====================

✍️ Parameter Test Report
─────────────────────────────────────────────────────────────────
  Local (client) initiated test
  Target: 92.112.*.*:5201
  Test direction: Client ↔ Server
  Single test duration: 30 seconds
  System: Debian GNU/Linux 12 | Kernel: 6.1.0-35-cloud-amd64
  Local: cubic+htb (congestion control algorithm+queue)
  TCP receive buffer (rmem): 4096   131072  6291456
  TCP send buffer (wmem): 4096   16384   4194304

🧭 TCP Large Packet Routing Path Analysis (based on nexttrace)
─────────────────────────────────────────────────────────────────
 AS path: AS979 > AS209699
 ISP: Private Customer - SBC Internet Services
 Geographic path: Japan > Singapore
 Map link: https://assets.nxtrace.org/tracemap/b4a9ec9f-8b69-5793-a9b6-0cd0981d8de0.html
─────────────────────────────────────────────────────────────────
🌐 BGP Peering Relationship Analysis (based on bgp.tools)
─────────────────────────────────────────────────────────────────
Upstream nodes: 9 │ Peer nodes: 44

AS979       │AS21859     │AS174       │AS2914      │AS3257      │AS3356      │AS3491
NetLab      │Zenlayer    │Cogent      │NTT         │GTT         │Lumen       │PCCW

AS5511      │AS6453      │AS6461      │AS6762      │AS6830      │AS12956     │AS1299
Orange      │TATA        │Zayo        │Sparkle     │Liberty     │Telxius     │Arelion

AS3320
DTAG
─────────────────────────────────────────────────────────────────
 Image link: https://bgp.tools/pathimg/979-55037bdd89ab4a8a010e70f46a2477ba7456640ec6449f518807dd2e
─────────────────────────────────────────────────────────────────
⚡ Network Performance Analysis (based on hping3 & iperf3)
─────────────────────────────────────────────────────────────────────────────────
    PING & Jitter             ⬆️ TCP Uplink Bandwidth               ⬇️ TCP Downlink Bandwidth
─────────────────────────  ─────────────────────────────  ─────────────────────────────
  Average: 72.3ms          220 Mbps (27.5 MB/s)             10 Mbps (1.2 MB/s)
  Minimum: 69.5ms          Total transfer: 786 MB           Total transfer: 35.4 MB
  Maximum: 75.9ms          Retransmissions: 0               Retransmissions: 5712
  Jitter: 6.4ms

─────────────────────────────────────────────────────────────────────────────────────────────
 Direction  │ Throughput               │ Packet Loss             │ Jitter
─────────────────────────────────────────────────────────────────────────────────────────────
 ⬆️ UDP Up   │ 219.0 Mbps (27.4 MB/s)    │ 2021/579336 (0.35%)       │ 0.050 ms
 ⬇️ UDP Down │ 10.0 Mbps (1.2 MB/s)      │ 0/26335 (0%)              │ 0.040 ms

─────────────────────────────────────────────────────────────────
Test completion time: 2025-08-28 20:12:29 | Script open source: https://github.com/zywe03/realm-xwPF
```

</details>

## 🚀 Quick Start

### One-Click Installation

```bash
wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install
```

## 🧭 Offline Installation for No Network Access

<details>
<summary>Click to expand offline installation methods</summary>

Suitable for completely network-disconnected environments

**Download Required Files**

Download the following files on a device with network access:
- **Script File Download**: [xwPF.sh](https://github.com/zywe03/realm-xwPF/raw/main/xwPF.sh) (Right-click → Save as)
- **Realm Program Download** (choose according to system architecture):

| Architecture | Applicable Systems | Download Link | Detection Command |
|--------------|-------------------|---------------|-------------------|
| x86_64 | Common 64-bit systems | [realm-x86_64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-gnu.tar.gz) | `uname -m` shows `x86_64` |
| aarch64 | ARM64 systems | [realm-aarch64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/download/v2.7.0/realm-aarch64-unknown-linux-gnu.tar.gz) | `uname -m` shows `aarch64` |
| armv7 | ARM32 systems (like Raspberry Pi) | [realm-armv7-unknown-linux-gnueabihf.tar.gz](https://github.com/zhboner/realm/releases/download/v2.7.0/realm-armv7-unknown-linux-gnueabihf.tar.gz) | `uname -m` shows `armv7l` or `armv6l` |

Create any directory to place the script and compressed package files. When starting with bash command and selecting **1. Install Configuration**, it will automatically detect and install the **realm file in the script's directory** first.

</details>

## ✨ Core Features

- **🚀 Quick Experience** - One-click installation for quick lightweight hands-on experience with network forwarding
- **🔄 Failover** - Uses system tools to achieve automatic failure detection while maintaining lightweight design
- **⚖️ Load Balancing** - Supports round-robin, IP hash strategies with configurable weight distribution
- **🕳️ Tunnel Building** - Dual-realm architecture supports TLS, ws encrypted transmission for tunnel construction
- **✍️ Rule Comments** - Clear commenting functionality, no need for additional memorization
- **🔔 Port Traffic Monitor** - Monitor port traffic statistics, control port bandwidth limiting, flow control, configurable notification methods
- **💻 Intuitive MPTCP System Configuration** - Clear MPTCP interface display
- **🛜 Network Connectivity Script** - Test network latency, bandwidth, stability, large packet routing analysis (based on hping3 & iperf3 & nexttrace & bgp.tools)

- **📋 One-Click Export** - Package all files into compressed archive for free migration (including comments and all information for complete migration)
- **📒 One-Click Import** - Recognize exported compressed packages for complete free migration
- **🔧 Intelligent Detection** - Automatic detection of system architecture, port conflicts, connection availability

- **📝 Intelligent Log Management** - Automatic log size limitation to prevent excessive disk usage
- **🗑️ Complete Uninstallation** - Phased comprehensive cleanup, "I leave gently, just as I came gently"
- **⚡ Full Native Realm Functionality** - Supports all native features of the latest realm version
- tcp/udp protocols
- ws/wss/tls encryption
- Single relay to multiple exits
- Multiple relays to single exit
- Proxy Protocol
- MPTCP
- Specify a specific entry IP for the relay server and a specific exit IP (suitable for multi-IP situations and one-entry-multiple-exits and multiple-entries-one-exit scenarios)
- More usage patterns refer to [zhboner/realm](https://github.com/zhboner/realm)

## 🗺️ Diagrams to Understand Working Principles in Different Scenarios (Recommended Reading)

<details>
<summary><strong>Single-end realm architecture only responsible for forwarding (common)</strong></summary>

Relay server installs realm, exit server installs business software

Relay server realm only forwards data packets received on the configured listening IP:port to the exit server as-is, encryption/decryption is handled by business software

So the encryption protocol for the entire link is determined by the exit server's business software

![e3c0a9ebcee757b95663fc73adc4e880.png](https://i.mji.rip/2025/07/17/e3c0a9ebcee757b95663fc73adc4e880.png)

</details>

<details>
<summary><strong>Dual-end realm architecture building tunnels</strong></summary>

Relay server installs realm, exit server needs to install realm and business software

An additional layer of realm-supported encrypted transmission is added between realm instances

#### So the encryption chosen by relay server realm, masquerading domains, etc., must be consistent with the exit server, otherwise decryption will fail

![4c1f0d860cd89ca79f4234dd23f81316.png](https://i.mji.rip/2025/07/17/4c1f0d860cd89ca79f4234dd23f81316.png)

</details>

<details>
<summary><strong>Load Balancing + Failover</strong></summary>

- Same port forwarding with multiple exit servers
![a9f7c94e9995022557964011d35c3ad4.png](https://i.mji.rip/2025/07/15/a9f7c94e9995022557964011d35c3ad4.png)

- Frontend > Multiple Relays > Single Exit
![2cbc533ade11a8bcbbe63720921e9e05.png](https://i.mji.rip/2025/07/17/2cbc533ade11a8bcbbe63720921e9e05.png)

- `Round Robin` mode (roundrobin)

Continuously switches between exit servers in the rule group

- `IP Hash` mode (iphash)

Based on source IP hash value, determines traffic direction, ensuring requests from the same IP always go to the same exit server

- Weight represents allocation probability

- Failover

When a certain exit is detected as failed, it's temporarily removed from the load balancing list. After recovery, it will be automatically added back to the load balancing list

Native realm currently does not support failover

- Script's Implementation Principle
```
1. systemd timer trigger (every 4 seconds)
   ↓
2. Execute health check script
   ↓
3. Read rule configuration files
   ↓
4. Perform TCP connectivity detection for each target
   ├── nc -z -w3 target port
   └── Backup: telnet target port
   ↓
5. Update health status file (atomic update)
   ├── Success: success_count++, fail_count=0
   └── Failure: fail_count++, success_count=0
   ↓
6. Determine status changes
   ├── 2 consecutive failures → Mark as failed
   └── 2 consecutive successes + 120s cooldown (avoid jitter switching) → Mark as recovered
   ↓
7. If status changes, create update marker file
```

Clients can use command `while ($true) { (Invoke-WebRequest -Uri 'http://ifconfig.me/ip' -UseBasicParsing).Content; Start-Sleep -Seconds 1 }` or `while true; do curl -s ifconfig.me; echo; sleep 1; done` to monitor IP changes in real-time and confirm mode effectiveness.

</details>

<details>
<summary>
<strong>Dual-end realm calling system MPTCP</strong>
</summary>

**Q: Does MPTCP endpoint create a new virtual network interface?**
No, it tells the MPTCP protocol stack: this IP address can be used for MPTCP connections to specify paths: data can be transmitted through this IP address and corresponding network interface
Establish multiple paths: allow a single TCP connection to use multiple network paths simultaneously

**Q: Why specify both IP and network interface?**
Network interface: the system needs to know which physical network interface this IP address corresponds to for routing selection
IP address: the MPTCP protocol needs to know which IP addresses can be used to establish subflows
192.168.1.100 dev eth0 subflow fullmesh = tells MPTCP it can establish connections through eth0 interface's this IP
10.0.0.50 dev eth1 subflow fullmesh = tells MPTCP it can establish connections through eth1 interface's this IP

If you want more fine-grained control, consider:

Server-side also setting signal endpoints:
Fine-grained MPTCP control

</details>

<details>
<summary><strong>Port Forwarding vs Chain Proxy (Segmented Proxy)</strong></summary>

Two concepts that are easily confused

**Simple Understanding**

Port forwarding only forwards traffic from one port to another port

Chain proxy is like this

Divided into two proxy segments, hence also called segmented proxy, secondary proxy (detailed configuration may be covered later)

**Each has its advantages** depending on use case | Note some servers don't allow proxy installation | However chain proxy can be very flexible in certain scenarios

| Chain Proxy | Port Forwarding |
| :---------- | :-------------- |
| All servers in the chain need proxy software installed | Relay server installs forwarding, exit server installs proxy |
| Higher configuration file complexity | Lower configuration file complexity (L4 layer forwarding) |
| Overhead from unpacking/packing at each hop | Native TCP/UDP passthrough, theoretically faster |
| More precise outbound control and traffic splitting (configure exit at each hop) | Difficult outbound control |

</details>

### Dependency Tools
Principle: prioritize **Linux native lightweight tools**, keeping the system clean and lightweight

| Tool | Purpose | Auto Install |
|------|---------|--------------|
| `curl` | Download and IP retrieval | ✅ |
| `wget` | Backup download tool | ✅ |
| `tar` | Compression/decompression tool | ✅ |
| `unzip` | ZIP decompression | ✅ |
| `systemctl` | Commander coordinating work | ✅ |
| `bc` | Numerical calculations | ✅ |
| `nc` | Network connection testing | ✅ |
| `grep`/`cut` | Text processing and recognition | ✅ |
| `inotify` | Marker files | ✅ |
| `iproute2` | MPTCP endpoint management | ✅ |
| `jq` | JSON data processing | ✅ |
| `nftables` | Port traffic statistics | ✅ |
| `tc` | Traffic control and limiting | ✅ |

## 📁 File Structure

File organization structure after installation:

```
📦 System Files
├── /usr/local/bin/
│   ├── realm                    # Realm main program
│   ├── xwPF.sh                  # Management script main body
│   ├── port-traffic-dog.sh      # Port traffic monitor script
│   ├── pf                       # Quick start command
│   └── dog                      # Port traffic monitor quick command
│
├── /etc/realm/                  # Realm configuration directory
│   ├── manager.conf             # Status management file (core)
│   ├── config.json              # Realm working configuration file
│   ├── rules/                   # Forwarding rules directory
│   │   ├── rule-1.conf          # Rule 1 configuration
│   │   ├── rule-2.conf          # Rule 2 configuration
│   │   └── ...
│   └── health/                  # Health check directory (failover)
│       └── health_status.conf   # Health status file
│
├── /etc/port-traffic-dog/       # Port traffic monitor configuration directory
│   ├── config.json              # Traffic monitoring configuration file
│   ├── data/                    # Traffic data directory
│   │   ├── traffic_2024-01.json # Monthly traffic data
│   │   └── ...
│   ├── snapshots/               # Traffic snapshot directory
│   │   ├── snapshot_20240115.json # Daily snapshot data
│   │   └── ...
│   ├── notifications/           # Notification module directory
│   │   └── telegram.sh          # Telegram notification module
│   └── logs/                    # Log directory
│       └── notification.log     # Notification log
│
├── /etc/systemd/system/
│   ├── realm.service            # Main service file
│   ├── realm-health-check.service  # Health check service
│   └── realm-health-check.timer    # Health check timer
│
├── /etc/sysctl.d/
│   └── 90-enable-MPTCP.conf     # MPTCP system configuration file
│
└── /var/log/
    ├── realm.log                # Realm service log
    └── port-traffic-dog.log     # Port traffic monitor log
```

## 🤝 Technical Support

- **Other Open Source Projects:** [https://github.com/zywe03](https://github.com/zywe03)
- **Author Homepage:** [https://zywe.de](https://zywe.de)
- **Issue Feedback:** [GitHub Issues](https://github.com/zywe03/realm-xwPF/issues)
- **Casual Chat Group** [TG Chat Group](https://t.me/zywe_chat)

## 🙏 Acknowledgments

- [zhboner/realm](https://github.com/zhboner/realm) - Providing the core Realm program
- "https://ghfast.top/""https://ghproxy.gpnu.org/""https://gh.222322.xyz/" - Providing public accelerated sources
- All users who provided feedback and suggestions for the project

---

**⭐ If this project helps you, please give it a Star for support!**

[![Star History Chart](https://api.star-history.com/svg?repos=zywe03/realm-xwPF&type=Date)](https://www.star-history.com/#zywe03/realm-xwPF&Date)
