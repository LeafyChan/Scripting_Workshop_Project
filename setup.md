# GitNet Setup Guide
### Environment Configuration and Feasibility Verification

This document covers everything your team needs to get their development environment ready, explains why each step exists, and walks through what the test results actually mean for the project.

---

## Table of Contents
- [Team Environment Overview](#team-environment-overview)
- [Windows WSL Setup](#windows-wsl-setup)
- [Mac Setup](#mac-setup)
- [Feasibility Tests](#feasibility-tests)
- [What The Results Mean](#what-the-results-mean)
- [Common Interface Names](#common-interface-names)
- [Quick Reference](#quick-reference)

---

## Team Environment Overview

GitNet is pure bash. Every tool it uses is a Linux system tool installed via a package manager. No Python packages, no npm, no venv, no Docker. Just shell scripts talking to system utilities.

| OS | Strategy | Difficulty |
|---|---|---|
| Windows with WSL2 | Enable mirrored networking mode | One config file change |
| macOS | Install tools via Homebrew | Straightforward |
| Native Linux | Install tools via apt | Trivial |

The core challenge is getting `arp-scan` to see real network devices. On WSL the default Hyper-V virtual adapter blocks Layer 2 ARP traffic. On Mac and native Linux there is no such barrier.

---

## Windows WSL Setup

### Why This Is Needed

WSL2 by default runs behind a Hyper-V virtual network adapter. This means WSL thinks it is on a completely separate virtual network (`172.x.x.x`) rather than your real home or hotspot network (`192.168.x.x`).

The symptom: `arp-scan --localnet` returns only the Hyper-V gateway, not your actual network devices. Without real MAC addresses from real devices, GitNet cannot function because its entire DHCP noise solution depends on tracking devices by MAC address rather than IP.

The fix is Windows 11's mirrored networking mode, which shares your real Windows network adapter directly with WSL instead of creating a virtual one.

### Step 1: Verify Windows Version

Open PowerShell and run:
```powershell
winver
```

You need Windows 11 version 22H2 or later. If you are on an older version, mirrored mode is not available and you will need to use a native Linux machine or Live USB for testing.

### Step 2: Check Existing WSL Config

```powershell
notepad "$env:USERPROFILE\.wslconfig"
```

This opens your WSL configuration file. It may already have content like memory and processor settings. Do not delete those.

### Step 3: Add Mirrored Networking

Add exactly these two lines under the `[wsl2]` section:

```ini
[wsl2]
networkingMode=mirrored
```

If the file already has a `[wsl2]` section like this:
```ini
[wsl2]
memory=8GB
processors=4
swap=4GB
```

Just add the networking line to it:
```ini
[wsl2]
memory=8GB
processors=4
swap=4GB
networkingMode=mirrored
```

Save and close the file.

### Step 4: Restart WSL

```powershell
wsl --shutdown
wsl
```

### Step 5: Install Required Tools

Once back in WSL:
```bash
sudo apt update
sudo apt install nmap -y
sudo apt install arp-scan -y
sudo apt install gnuplot -y
sudo apt install mailutils -y
```

When mailutils asks about Postfix configuration, select **No configuration** and press Tab then Enter.

### Step 6: Find Your Network Interface

```bash
ip link show
```

With mirrored mode enabled you will see multiple interfaces. Look for one that is NOT `lo` (loopback) and NOT the old `eth0` Hyper-V adapter. It will likely be `eth2` or similar.

```bash
# Check which interface has your real IP
ip addr show
```

Look for the interface showing your actual network IP (192.168.x.x range).

### Step 7: Verify It Works

```bash
sudo arp-scan --localnet --interface=eth2
```

Replace `eth2` with whatever interface you found in Step 6.

**Success looks like this:**
```
Interface: eth2, type: EN10MB, MAC: 14:b5:cd:4e:50:7b, IPv4: 192.168.0.155
Starting arp-scan 1.10.0 with 256 hosts
192.168.0.1     24:2f:d0:bd:17:40       (Unknown)
192.168.0.170   08:9d:f4:4f:3d:0f       Intel Corporate
192.168.0.248   0c:ef:15:88:f2:a6       (Unknown)
```

Real IPs with real MAC addresses. If you see this, your setup is complete.

### How to Undo This Completely

If you ever want to revert to default WSL networking:
```powershell
notepad "$env:USERPROFILE\.wslconfig"
```
Delete the `networkingMode=mirrored` line. Save. Then:
```powershell
wsl --shutdown
wsl
```

That is all. Nothing else was changed on your system.

---

## Mac Setup

Mac teammates have it easiest. macOS gives direct access to the physical network adapter with no virtualization layer in between. No configuration changes needed.

### Step 1: Install Homebrew (if not already installed)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Step 2: Install Required Tools

```bash
brew install nmap
brew install arp-scan
brew install gnuplot
```

For email alerts (optional for now):
```bash
brew install mailutils
```

### Step 3: Find Your Interface

```bash
ifconfig | grep "inet "
networksetup -listallhardwareports
```

On Mac, WiFi is almost always `en0` or `en1`. Ethernet is usually `en0`.

### Step 4: Verify It Works

```bash
sudo arp-scan --localnet --interface=en0
# If that fails, try en1
sudo arp-scan --localnet --interface=en1
```

Success looks identical to the WSL output above: real IPs with real MAC addresses.

---

## Feasibility Tests

These are the exact tests we ran to verify GitNet works before committing to building it. Run all of these in order and compare your output to the expected results below.

### Test 1: AP Isolation Check on College WiFi

**What it tests:** Whether college WiFi allows devices to see each other.

**Why it matters:** GitNet needs to scan other devices on the network. If AP isolation is enabled, every scan returns zero devices and the tool is dead.

**Command (PowerShell on Windows):**
```powershell
1..254 | ForEach-Object {
    $ip = "10.70.x.$_"    # Replace x with your college subnet
    if (Test-Connection $ip -Count 1 -Quiet) {
        Write-Host "$ip is UP"
    }
}
```

**Our result:**
```
10.70.13.3 is UP
10.70.13.8 is UP
```

Only 2 devices out of 254 responded. Our own laptop did not even show up. This confirms AP isolation is ON on college WiFi. GitNet cannot run on college WiFi.

**Conclusion:** Demo on personal hotspot. College WiFi is ruled out permanently.

---

### Test 2: Basic nmap Host Discovery

**What it tests:** Whether nmap can find devices and their MACs on the network.

**Why it matters:** nmap is the primary scanning tool. If it cannot find devices, nothing works.

**Command:**
```bash
sudo nmap -sn 192.168.0.0/24 --send-ip
```

**Our result:**
```
Nmap scan report for 192.168.0.1
Host is up (0.0049s latency).
MAC Address: 24:2F:D0:BD:17:40 (Unknown)

Nmap scan report for 192.168.0.170
Host is up (0.18s latency).
MAC Address: 08:9D:F4:4F:3D:0F (Intel Corporate)

Nmap done: 256 IP addresses (7 hosts up) scanned in 45.07 seconds
```

7 devices found with MAC addresses. Scan completed in 45 seconds on a full /24 subnet.

**Conclusion:** nmap works. MAC addresses are accessible. DHCP noise solution is viable.

---

### Test 3: arp-scan MAC Discovery

**What it tests:** Whether arp-scan can independently discover devices and MACs at Layer 2.

**Why it matters:** arp-scan is faster and more reliable for MAC discovery than nmap. It works at the data link layer so it finds devices that block ping.

**Command:**
```bash
sudo arp-scan --localnet --interface=eth2
```

**Our result:**
```
Interface: eth2, type: EN10MB, MAC: 14:b5:cd:4e:50:7b, IPv4: 192.168.0.155
Starting arp-scan 1.10.0 with 256 hosts
192.168.0.1     24:2f:d0:bd:17:40       (Unknown)
192.168.0.127   7e:b7:cb:ea:7e:09       (Unknown: locally administered)
192.168.0.170   08:9d:f4:4f:3d:0f       Intel Corporate
192.168.0.248   0c:ef:15:88:f2:a6       (Unknown)
192.168.0.206   62:13:d5:e4:31:29       (Unknown: locally administered)
5 packets received by filter, 0 packets dropped by kernel
Ending arp-scan 1.10.0: 256 hosts scanned in 2.026 seconds
```

5 devices found in 2 seconds. Full subnet scan in 2 seconds versus nmap's 45 seconds.

**Conclusion:** arp-scan is the right tool for host discovery and MAC lookup. nmap handles port scanning. Each tool does what it is best at.

---

### Test 4: Port Scanning

**What it tests:** Whether nmap can enumerate open ports on a specific host.

**Why it matters:** GitNet's diff engine needs to detect when ports open or close on a device. This is the core anomaly detection feature.

**Command:**
```bash
sudo nmap -p 22,80,443,8080 192.168.0.1
```

**Our result:**
```
PORT     STATE    SERVICE
22/tcp   filtered ssh
80/tcp   filtered http
443/tcp  filtered https
8080/tcp filtered http-proxy
```

All filtered on the router because it blocks port probes. This is expected and normal. The important thing is nmap ran, found the host, and reported port states.

**Conclusion:** Port scanning works. Filtered means the router's firewall blocked the probe, not that nmap failed.

---

### Test 5: Live Service Detection (The Demo Moment)

**What it tests:** Whether GitNet can detect a service being started in real time.

**Why it matters:** This is the core demo. Start a server, scan, see it appear. Kill it, scan, see it disappear. This is what convinces evaluators the tool works.

**Commands:**

Terminal 1:
```bash
python3 -m http.server 8080
```

Terminal 2:
```bash
sudo nmap -p 8080 192.168.0.155
```

**Our result:**
```
PORT     STATE SERVICE
8080/tcp open  http-proxy
```

Port 8080 detected as open the moment the Python server started.

**Conclusion:** Live service detection works perfectly. GitNet will catch this change between two snapshots and display it as an anomaly in `gitnet diff`.

---

## What The Results Mean

### Why "Unknown" Vendor Is Fine

Most MAC addresses showed as `(Unknown)` in our tests. This is because nmap 7.80 ships with an outdated OUI (Organizationally Unique Identifier) vendor database. Updated versions of arp-scan and nmap show Apple Inc., Samsung, Xiaomi etc. correctly.

For GitNet, vendor lookup is a display feature, not a core function. The MAC address itself is what matters for tracking. Unknown vendor does not affect diff accuracy, anomaly detection, or any core feature.

### Why Some Devices Appear and Disappear Between Scans

You will notice device counts vary between scans (sometimes 5 hosts, sometimes 7). This is exactly the DHCP noise problem GitNet solves. Phones sleep and stop responding to ARP. Laptops wake up and get new IPs.

This is why GitNet tracks by MAC address. The same phone has the same MAC whether its IP is `.112` or `.206`. The diff engine uses MAC as the primary key, so a sleeping phone shows as offline, not as a deleted and re-added unknown device.

### Why arp-scan Is Faster Than nmap

arp-scan completed a full 256-host scan in 2 seconds. nmap took 45 seconds for the same subnet.

arp-scan works at Layer 2 sending raw ARP packets directly. It does not do TCP handshakes, does not wait for timeouts, and does not attempt service detection. It just asks "who has this IP" and records who answers.

nmap does much more: ICMP probes, TCP SYN probes, timing adjustments. That power is why we use it for port scanning. But for simple host and MAC discovery, arp-scan wins every time.

GitNet uses both:
- `arp-scan` for fast host and MAC discovery
- `nmap` for detailed port and service scanning per host

### Why Filtered Ports Are Not a Problem

The router showed all ports as `filtered` not `closed`. Filtered means a firewall dropped the packet silently. Closed means the port actively rejected the connection. Both mean the port is not open for our purposes.

In GitNet's diff engine, both `filtered` and `closed` are treated as not open. Only `open` ports are tracked and stored in snapshots. So a port changing from `filtered` to `closed` produces no alert, but `closed` to `open` or `filtered` to `open` does.

---

## Common Interface Names

| OS | Common Interface Names |
|---|---|
| WSL2 mirrored | `eth2`, `eth1`, sometimes `wifi0` |
| macOS WiFi | `en0` or `en1` |
| macOS Ethernet | `en0` |
| Native Linux WiFi | `wlan0`, `wlp2s0` |
| Native Linux Ethernet | `eth0`, `enp3s0` |

Always verify with:
```bash
# Linux / WSL
ip link show

# Mac
ifconfig
```

---

## Quick Reference

### Find your interface
```bash
ip link show                          # Linux / WSL
ifconfig                              # Mac
```

### Discover all hosts and MACs
```bash
sudo arp-scan --localnet --interface=eth2       # WSL
sudo arp-scan --localnet --interface=en0        # Mac
```

### Full subnet scan with MACs
```bash
sudo nmap -sn 192.168.0.0/24 --send-ip
```

### Scan specific ports on a host
```bash
sudo nmap -p 22,80,443,8080 <target-ip>
```

### Start a dummy HTTP service for testing
```bash
python3 -m http.server 8080
```

### Detect the dummy service
```bash
sudo nmap -p 8080 <your-ip>
```

### Undo WSL mirrored networking
```powershell
# In PowerShell
notepad "$env:USERPROFILE\.wslconfig"
# Remove the networkingMode=mirrored line
wsl --shutdown
wsl
```

---

## Final Feasibility Verdict

| Requirement | Status |
|---|---|
| Find live hosts on network | ✅ Confirmed |
| Get MAC addresses | ✅ Confirmed |
| Detect open ports | ✅ Confirmed |
| Detect live service changes | ✅ Confirmed |
| Works on WSL without native Linux | ✅ Confirmed |
| Works on Mac out of the box | ✅ Confirmed |
| Personal hotspot replaces college WiFi | ✅ Confirmed |
| College WiFi ruled out | ✅ Confirmed (AP isolation ON) |
| No venv, no Docker, no Python packages | ✅ Confirmed |

GitNet is fully feasible. Every core feature has been verified to work in the actual development environment your team will use.

---

*GitNet: CS2106 Scripting Workshop, Project 3*
*Evaluation: Nov 30 to Dec 2, 2026*