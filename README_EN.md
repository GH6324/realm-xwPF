# Realm Full-Featured One-Click Network Forwarding Management, Pure Script Quick Relay Server Setup

[中文](README.md) | [English](README_EN.md) | [Port Traffic Dog Introduction](port-traffic-dog-README.md)

---

> 🚀 **Network Forwarding Management Script** - Syncs with all features of the latest official Realm version, network link testing, port traffic dog, maintains minimalist essence, visual rule operations for improved efficiency, pure script for building network forwarding services

## Script Interface Preview

<details>
<summary>Click to view interface screenshots</summary>

### xwPF.sh Realm Forwarding Script

![81ce7ea9e40068f6fda04b66ca3bd1ff.gif](https://i.mji.rip/2025/12/12/81ce7ea9e40068f6fda04b66ca3bd1ff.gif)

### Port Traffic Dog

![cc59017896d277a8b35109ae44eac977.gif](https://i.mji.rip/2025/12/12/cc59017896d277a8b35109ae44eac977.gif)

### Relay Network Link Testing Script
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

🧭 TCP Large Packet Route Path Analysis (based on nexttrace)
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
⚡ Network Link Parameter Analysis (based on hping3 & iperf3)
─────────────────────────────────────────────────────────────────────────────────
    PING & Jitter             ⬆️ TCP Uplink Bandwidth                     ⬇️ TCP Downlink Bandwidth
─────────────────────────  ─────────────────────────────  ─────────────────────────────
  Average: 72.3ms          220 Mbps (27.5 MB/s)             10 Mbps (1.2 MB/s)
  Minimum: 69.5ms          Total transfer: 786 MB             Total transfer: 35.4 MB
  Maximum: 75.9ms          Retransmissions: 0                    Retransmissions: 5712
  Jitter: 6.4ms

─────────────────────────────────────────────────────────────────────────────────────────────
 Direction  │ Throughput               │ Packet Loss Rate        │ Jitter
─────────────────────────────────────────────────────────────────────────────────────────────
 ⬆️ UDP Up   │ 219.0 Mbps (27.4 MB/s)    │ 2021/579336 (0.35%)       │ 0.050 ms
 ⬇️ UDP Down │ 10.0 Mbps (1.2 MB/s)      │ 0/26335 (0%)              │ 0.040 ms

─────────────────────────────────────────────────────────────────
Test completion time: 2025-08-28 20:12:29 | Script open source: https://github.com/zywe03/realm-xwPF
```

</details>

## Quick Start

### One-Click Installation

```bash
wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install
```

### Network Restricted? Use Accelerated Mirror

```bash
wget -qO- https://v6.gh-proxy.org/https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install
```
If the mirror fails, retry or replace with another proxy that has built-in acceleration.

## Offline Installation (No Network Access)

<details>
<summary>Click to expand offline installation methods</summary>

For completely network-disconnected environments

**Download Required Files**

Download the following files on a device with network access:
- **Script File**: [xwPF.sh](https://github.com/zywe03/realm-xwPF/raw/main/xwPF.sh) (Right-click → Save as)
- **Realm Binary** (choose based on system architecture):

| Architecture | Applicable Systems | Download Link | Detection Command |
|--------------|-------------------|---------------|-------------------|
| x86_64 | Common 64-bit systems | [realm-x86_64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-gnu.tar.gz) | `uname -m` shows `x86_64` |
| aarch64 | ARM64 systems | [realm-aarch64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/download/v2.7.0/realm-aarch64-unknown-linux-gnu.tar.gz) | `uname -m` shows `aarch64` |
| armv7 | ARM32 systems (e.g., Raspberry Pi) | [realm-armv7-unknown-linux-gnueabihf.tar.gz](https://github.com/zhboner/realm/releases/download/v2.7.0/realm-armv7-unknown-linux-gnueabihf.tar.gz) | `uname -m` shows `armv7l` or `armv6l` |

Create any directory to place the script and archive files (do not place archives in `/usr/local/bin/`). When starting with bash and selecting **1. Install Configuration**, it will prompt: **Enter full path for offline realm installation (press Enter for auto-download):**

</details>

## ✨ Core Features

- **Quick Start** - One-click installation for lightweight hands-on experience with network forwarding
- **Failover** - Uses system tools for automatic failure detection while staying lightweight
- **Load Balancing** - Supports round-robin, IP hash strategies with configurable weight distribution
- **Tunnel Building** - Dual-realm architecture supports TLS, ws, wss for tunnel construction
- **Rule Comments** - Clear commenting functionality, no need for extra memorization
- **Port Traffic Dog** - Monitor port traffic, control speed limits, throttling, with configurable notifications
- **Intuitive MPTCP Configuration** - Clean MPTCP interface display
- **Network Link Script** - Test latency, bandwidth, stability, large packet routing (based on hping3 & iperf3 & nexttrace & bgp.tools)

- **One-Click Export** - Package all files into compressed archive for seamless migration (including comments and all data)
- **One-Click Import** - Recognize exported packages for complete migration
- **Batch Import Recognition** - Import custom Realm rule configurations for easy rule set management
- **Smart Detection** - Automatically detects system architecture, port conflicts, and connection availability

- **Complete Uninstallation** - Phased comprehensive cleanup, "I leave gently, just as I came gently"
- **Full Native Realm Functionality** - Syncs with all native features of the latest Realm version
  - TCP/UDP protocols
  - ws/wss/tls encryption and forwarding
  - Single relay to multiple exits
  - Multiple relays to single exit
  - Proxy Protocol
  - MPTCP
  - Specify relay server entry IP or exit IP (for multi-IP scenarios, one-entry-multiple-exits, multiple-entries-one-exit)
  - Specify relay server entry interface or exit interface (for multi-NIC scenarios)
  - More usage patterns at [zhboner/realm](https://github.com/zhboner/realm)

## Diagrams for Understanding Different Scenarios (Recommended Reading)

<details>
<summary><strong>Single-end Realm Architecture: Forwarding Only (Common)</strong></summary>

Relay server installs Realm, exit server installs business software

Relay server Realm forwards data packets received on the configured listen IP:port to the exit server as-is; encryption/decryption is handled by business software

So the encryption protocol for the entire link is determined by the exit server's business software

![e3c0a9ebcee757b95663fc73adc4e880.png](https://i.mji.rip/2025/07/17/e3c0a9ebcee757b95663fc73adc4e880.png)

</details>

<details>
<summary><strong>Dual-end Realm Architecture: Building Tunnels</strong></summary>

Relay server installs Realm, exit server needs both Realm and business software

An additional layer of Realm-supported encrypted transmission is added between Realm instances

#### Therefore, encryption settings, masquerading domains, etc. on the relay server must match the exit server, otherwise decryption will fail

![4c1f0d860cd89ca79f4234dd23f81316.png](https://i.mji.rip/2025/07/17/4c1f0d860cd89ca79f4234dd23f81316.png)

</details>

<details>
<summary><strong>Load Balancing + Failover</strong></summary>

- Same port forwarding with multiple exit servers
![a9f7c94e9995022557964011d35c3ad4.png](https://i.mji.rip/2025/07/15/a9f7c94e9995022557964011d35c3ad4.png)

- Frontend > Multiple Relays > Single Exit
![2cbc533ade11a8bcbbe63720921e9e05.png](https://i.mji.rip/2025/07/17/2cbc533ade11a8bcbbe63720921e9e05.png)

- `Round Robin` mode

Continuously rotates between exit servers in the rule group

- `IP Hash` mode

Based on source IP hash value, determines traffic direction, ensuring requests from the same IP always go to the same exit server

- Weight equals allocation probability

- Failover

When an exit is detected as failed, it's temporarily removed from the load balancing pool. After recovery, it's automatically added back

Native Realm currently does not support failover

- Script Implementation
```
1. systemd timer trigger (every 4 seconds)
   ↓
2. Execute health check script
   ↓
3. Read rule configuration files
   ↓
4. Perform TCP connectivity check for each target
   ├── nc -z -w3 target port
   └── Fallback: telnet target port
   ↓
5. Update health status file (atomic update)
   ├── Success: success_count++, fail_count=0
   └── Failure: fail_count++, success_count=0
   ↓
6. Determine status changes
   ├── 2 consecutive failures → Mark as failed
   └── 2 consecutive successes + 120s cooldown (prevent flapping) → Mark as recovered
   ↓
7. If status changes, create update marker file
```

Clients can monitor IP changes in real-time using:
`while ($true) { (Invoke-WebRequest -Uri 'http://ifconfig.me/ip' -UseBasicParsing).Content; Start-Sleep -Seconds 1 }` or `while true; do curl -s ifconfig.me; echo; sleep 1; done`

</details>

<details>
<summary>
<strong>Dual-end Realm with System MPTCP</strong>
</summary>

**Q: Does MPTCP endpoint create a new virtual network interface?**
No, it tells the MPTCP protocol stack: this IP address can be used for MPTCP connections to specify paths; data can be transmitted through this IP address and corresponding network interface
Establish multiple paths: allow a single TCP connection to use multiple network paths simultaneously

**Q: Why specify both IP and network interface?**
Network interface: the system needs to know which physical NIC this IP corresponds to for routing
IP address: MPTCP protocol needs to know which IPs can be used to establish subflows
192.168.1.100 dev eth0 subflow fullmesh = tells MPTCP it can establish connections via eth0's IP
10.0.0.50 dev eth1 subflow fullmesh = tells MPTCP it can establish connections via eth1's IP

For more fine-grained control, consider:

Server-side signal endpoints for fine-grained MPTCP control

</details>

<details>
<summary><strong>Port Forwarding vs Chain Proxy (Segmented Proxy)</strong></summary>

Two concepts that are easily confused

**Simple Understanding**

Port forwarding only forwards traffic from one port to another

Chain proxy works like this:

Divided into two proxy segments, hence also called segmented proxy or secondary proxy (detailed configuration may be covered later)

**Each has its advantages** depending on use case | Note: some servers don't allow proxy installation | However, chain proxy can be very flexible in certain scenarios

| Chain Proxy | Port Forwarding |
| :---------- | :-------------- |
| All servers in the chain need proxy software | Relay installs forwarder, exit installs proxy |
| Higher configuration complexity | Lower complexity (L4 forwarding) |
| Overhead from unpacking/packing at each hop | Native TCP/UDP passthrough, theoretically faster |
| More precise outbound control (configure exit at each hop) | Difficult outbound control |

</details>

### Dependency Tools
Principle: prioritize **Linux native lightweight tools**, keeping the system clean and lightweight

| Tool       | Purpose                     | Tool        | Purpose                    |
|------------|-----------------------------|-------------|----------------------------|
| `curl`     | Download and IP retrieval   | `wget`      | Backup download tool       |
| `tar`      | Compression/decompression   | `unzip`     | ZIP decompression          |
| `bc`       | Numerical calculations      | `nc`        | Network connection testing |
| `grep`/`cut` | Text processing           | `inotify`   | File markers               |
| `iproute2` | MPTCP endpoint management   | `jq`        | JSON data processing       |
| `nftables` | Port traffic statistics     | `tc`        | Traffic control            |


## File Structure

File organization after complete installation:

```
📦 System Files
├── /usr/local/bin/
│   ├── realm                    # Realm main program
│   ├── xwPF.sh                  # Management script
│   ├── port-traffic-dog.sh      # Port traffic monitor script
│   ├── pf                       # Quick start command
│   └── dog                      # Port traffic monitor shortcut
│
├── /etc/realm/                  # Realm configuration directory
│   ├── manager.conf             # Status management file
│   ├── config.json              # Realm working configuration
│   ├── rules/                   # Forwarding rules directory
│   │   ├── rule-1.conf          # Rule 1 configuration
│   │   ├── rule-2.conf          # Rule 2 configuration
│   │   └── ...
│   └── health/                  # Health check directory (failover)
│       └── health_status.conf   # Health status file
│
├── /etc/port-traffic-dog/       # Port traffic monitor configuration
│   ├── config.json              # Traffic monitoring configuration
│   ├── traffic_data.json        # Traffic backup data (for restart recovery)
│   ├── notifications/           # Notification module directory
│   │   └── telegram.sh          # Telegram notification module
│   └── logs/                    # Log directory
│       └── traffic.log          # Traffic log
│
├── /etc/systemd/system/
│   ├── realm.service            # Main service file
│   ├── realm-health-check.service  # Health check service
│   └── realm-health-check.timer    # Health check timer
│
├── /etc/sysctl.d/
│   └── 90-enable-MPTCP.conf     # MPTCP system configuration
│
└── /var/log/
    └── port-traffic-dog.log     # Port traffic monitor log
```

## 🤝 Technical Support

- **Other Open Source Projects:** [https://github.com/zywe03](https://github.com/zywe03)
- **Author Homepage:** [https://zywe.de](https://zywe.de)
- **Issue Feedback:** [GitHub Issues](https://github.com/zywe03/realm-xwPF/issues)
- **Casual Chat Group** [TG Chat Group](https://t.me/zywe_chat)

---

**⭐ If this project helps you, please give it a Star!**

[![Star History Chart](https://api.star-history.com/svg?repos=zywe03/realm-xwPF&type=Date)](https://www.star-history.com/#zywe03/realm-xwPF&Date)
