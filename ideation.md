### Git-Style Version Control for Live Network Statea

> _"Enterprise tools like Batfish do network state versioning, but they need Docker, Python, and enterprise hardware. We built the same concept in pure bash that works on any network, any machine, right now."_

---

## What Is GitNet?

Normal Git watches **files**. When you edit `main.c`, Git notices. You can commit the change, diff it against yesterday, revert it if something breaks.

GitNet watches your **network** instead. Every device online, every open port, every running service: snapshotted, hashed, committed, and diffable. Exactly like Git, but the "working tree" is your local network.

Instead of:

```
main.c → line 42 changed from "int x = 0" to "int x = 1"
```

You get:

```
192.168.43.12 (MacBook, Apple Inc.) → port 8080/TCP OPENED
192.168.43.9  (Samsung Phone)       → WENT OFFLINE
192.168.43.3  (Raspberry Pi)        → SSH service DISAPPEARED
```

The real-world name for this problem is **Network Configuration Drift Detection**. Enterprise tools like Batfish, Oxidized, and Suzieq solve it, but they require Docker, Python, Cisco hardware, and weeks of setup. GitNet is the pure bash, zero-dependency version that runs on any Linux machine connected to any network.

---

## Integrated Projects

GitNet is submitted under **Project 3 (Network Scanner & Analyzer)** and natively integrates three additional projects from the CS2106 Scripting Workshop:

|Integrated Project|Where It Lives In GitNet|How|
|---|---|---|
|Project 3 - Network Scanner|`core/scanner.sh`|Core scanning engine, the entire foundation|
|Project 6 - Log Analyzer & Anomaly Detector|`core/alerts.sh`|Pattern matching on scan history, brute-force detection, email alerts|
|Project 1 - System Health Monitor|`core/reporter.sh`|System stats (CPU/RAM/disk) logged alongside every scan commit|
|Project 5 - Automated Testing Framework|`tests/`|Full test suite for GitNet itself with color-coded pass/fail output|

None of these are bolted on. Each one emerges naturally from what GitNet needs to do.

---

## Architecture

```
gitnet/
├── gitnet                   # Main CLI entry point & argument router
├── core/
│   ├── scanner.sh           # Module 1: Network scanning engine
│   ├── storage.sh           # Module 2: Git style snapshot versioning
│   ├── engine.sh            # Module 3: Relational diff & anomaly detection
│   ├── alerts.sh            # Module 4: Log analysis, pattern matching, email alerts
│   └── reporter.sh          # Module 5: HTML/CSV reports, gnuplot charts, system health
├── tests/
│   ├── run_tests.sh         # Test runner with parallel execution & color output
│   └── cases/              # Input CSVs and expected diff outputs
└── .gitnet/                 # Created on `gitnet init` - never touch manually
    ├── config               # Target subnet, interface, alert thresholds, email
    ├── HEAD                 # Hash pointer to latest commit
    ├── commits/             # Flat-file commit metadata (hash, timestamp, message)
    ├── objects/             # SHA1 hashed raw network snapshot CSVs
    └── logs/                # Persistent scan + system health logs (rotated weekly)
```

### Full Data Flow

```
┌─────────────────────────────────────────────────────────┐
│                    gitnet scan -m "msg"                  │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│  scanner.sh                                              │
│  arp-scan → live hosts + MAC addresses                   │
│  nmap     → open ports + service banners per host        │
│  OUI DB   → MAC vendor lookup (Apple, Samsung, etc.)     │
│  Output   → structured CSV snapshot                      │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│  storage.sh                                              │
│  sha1sum  → hash the CSV                                 │
│  Store    → .gitnet/objects/<hash>.csv                   │
│  Commit   → .gitnet/commits/<timestamp> (metadata)       │
│  Update   → .gitnet/HEAD                                 │
└──────────┬──────────────────────────┬───────────────────┘
           │                          │
           ▼                          ▼
┌────────────────────┐   ┌────────────────────────────────┐
│  engine.sh         │   │  reporter.sh                    │
│  Compare snapshots │   │  HTML report generation         │
│  by MAC address    │   │  gnuplot trend charts           │
│  Flag anomalies    │   │  System health sidebar          │
│  Output diff       │   │  CSV export                     │
└────────┬───────────┘   └────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│  alerts.sh                                               │
│  Pattern match on diff output                            │
│  Frequency analysis (repeated anomalies = brute force)   │
│  Threshold check → fire mailx email if exceeded          │
│  Append to persistent log → .gitnet/logs/                │
└─────────────────────────────────────────────────────────┘
```

---

## Can All Modules Be Built in Parallel?

**Yes, completely.** This is one of GitNet's strongest design decisions.

The modules communicate only through files (CSVs, flat-file commits). No shared state, no function calls across files. This means:

|Member|Builds|Depends On|Can Start Day 1?|
|---|---|---|---|
|Member 1|`scanner.sh`|Nothing|✅ Yes|
|Member 2|`storage.sh`|Needs CSV format spec from M1|✅ Yes (mock CSV)|
|Member 3|`engine.sh`|Needs CSV format spec from M1|✅ Yes (mock CSVs)|
|Member 4|`reporter.sh`|Needs diff output format from M3|✅ Yes (mock diff)|
|Member 5|`gitnet` + `alerts.sh`|Needs all modules to exist|✅ Yes (stub calls)|

**The contract between modules is just the CSV format.** Agree on this on Day 1:

```
IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,TIMESTAMP
192.168.43.12,AA:BB:CC:DD:EE:FF,Apple Inc.,22|80|8080,SSH|HTTP|HTTP-Alt,2026-11-01T14:32:01
```

Every member writes their module against this spec using mock data. Integration week = plug real outputs in. Zero conflicts because nobody touches anyone else's file.

---

## Does It Work on a Hotspot?

**Yes, and a hotspot is actually the ideal environment.** Here's why every concern that applies to college Wi-Fi disappears on your personal hotspot:

### College Wi-Fi Problems → Hotspot Solutions

**AP Isolation** College Wi-Fi enables Access Point Isolation. Devices on the same network cannot see or ping each other. `arp-scan` returns nothing. Your tool is dead before it starts. On a personal hotspot, AP isolation is disabled by default. Every connected device is visible and scannable.

**IDS / Network Admin Bans** Running automated `nmap` port sweeps on a university network triggers Intrusion Detection Systems. Your IP gets MAC-blacklisted before evaluation day. On your hotspot, you are the network admin. There is no IDS. Scan as aggressively as you want.

**Sudo / Root Restrictions** `arp-scan` and raw-packet nmap require root privileges. Evaluation machines may not give you sudo. Bring your own laptop. You have root. Problem gone.

**DHCP IP Churn** Even on a hotspot, phones sleep and wake, changing IPs. Naive IP-based tracking would scream false positives constantly. GitNet tracks by MAC address, not IP. A phone's MAC never changes. Even if its IP shifts from `.10` to `.15`, GitNet correctly identifies it as the same device.

### Demo Setup

```
Your Hotspot (192.168.43.0/24)
        │
        ├── Your laptop (running GitNet, has root)
        ├── Team laptop 2 (running python3 -m http.server 8080)
        ├── Team laptop 3 (SSH server enabled)
        ├── Team phone 1 (connected)
        └── Team phone 2 (will connect/disconnect during demo)
```

You control every device on this network. Every scan is predictable. Every demo moment is rehearsable.

---

## Tools Used: What, Why, and Why It's The Right Choice

### `nmap` - Port Scanner

**What it is:** The industry-standard open-source network scanner. Used by penetration testers, network administrators, and security researchers worldwide.

**Why we use it:** As defined in Project 3 of the CS2106 assignment document, `nmap` is the specified tool for port scanning. It does in one command what would take hundreds of raw bash socket calls: it scans ports, identifies services, grabs banners, and outputs in parseable formats.

**Why it's the best choice for us:** `nmap -oG` (grepable output) lets us pipe directly into `awk` without any complex parsing. No other tool gives us port + service detection in a single scan with such clean output.

```bash
nmap -p- --open -T4 -oG - 192.168.43.0/24
# -oG -     → grepable output to stdout, perfect for awk piping
# --open    → only show open ports, reduces noise
# -T4       → aggressive timing, fast enough for demo
```

---

### `arp-scan` - Host Discovery & MAC Address Lookup

**What it is:** A low-level ARP packet tool that discovers all live hosts on a local network and returns their MAC addresses and vendor information.

**Why we use it:** As defined in Project 3 of the CS2106 assignment document, `arp-scan` is the specified tool for network scanning. It works at Layer 2 (data link layer), below IP, so it finds hosts that block ICMP ping. A device can ignore ping and still show up in `arp-scan`.

**Why it's the best choice for us:** It's the only reliable way to get MAC addresses (which we need for DHCP-noise-resistant tracking) in a single command. `nmap` can get MACs too but requires root and is slower for pure host discovery.

```bash
arp-scan --localnet --interface=wlan0
# Returns: IP, MAC, Vendor, exactly our CSV columns 1, 2, 3
```

---

### `sha1sum` - Snapshot Hashing

**What it is:** A standard Unix utility that computes SHA-1 cryptographic hashes of files.

**Why we use it:** As defined in Project 8 of the CS2106 assignment document, `sha1sum` is the specified tool for the Mini Git implementation. Every Git object (commit, tree, blob) is identified by its SHA-1 hash. We use the same mechanism: each network snapshot CSV is hashed, and the hash becomes its unique identifier in `.gitnet/objects/`.

**Why it's the best choice for us:** It's available on every Linux system, requires no installation, and gives us content addressable storage (the same network state always produces the same hash) for free.

```bash
HASH=$(sha1sum snapshot.csv | cut -d' ' -f1)
cp snapshot.csv ".gitnet/objects/$HASH.csv"
# Identical network states → identical hash → deduplication for free
```

---

### `awk` - State Parsing & Relational Diffing

**What it is:** A text-processing language built into every Unix system, designed for column-structured data.

**Why we use it:** As defined in Projects 3, 6, and 18 of the CS2106 assignment document, `awk` is the specified tool for data processing and analysis. Our CSV snapshots are perfectly column-structured, so `awk` treats them as a native data format.

**Why it's the best choice for us:** The diff engine's core challenge is relational comparison: find the same device across two snapshots even if its IP changed. `awk` associative arrays make this trivial:

```bash
# Load old snapshot into associative array keyed by MAC
awk -F, 'NR==FNR { hosts[$2]=$0; next }
         !($2 in hosts)     { print "[+] NEW HOST: " $1 " MAC:" $2 }
         ($2 in hosts) &&
         hosts[$2] != $0    { print "[~] CHANGED: " $1 }
        ' old.csv new.csv
# MAC address ($2) is the key - IP changes are automatically handled
```

No other tool does this as cleanly in pure bash.

---

### `sed` - Output Formatting & Log Cleanup

**What it is:** Stream editor for filtering and transforming text.

**Why we use it:** As defined in Projects 6, 18, and 19 of the CS2106 assignment document, `sed` is specified for text cleanup and reformatting. We use it to clean `nmap` output, reformat timestamps, and strip noise from scan results before storage.

**Why it's the best choice for us:** One-liner transformations that would take 10 lines of bash string manipulation take one `sed` expression. Especially useful for normalizing `nmap`'s varied output formats into our clean CSV spec.

---

### `grep` - Pattern Matching & Anomaly Detection

**What it is:** Global Regular Expression Print. Searches text for patterns.

**Why we use it:** As defined in Projects 6, 13, and 20 of the CS2106 assignment document, `grep` is specified for pattern matching and anomaly detection. Our `alerts.sh` uses `grep` to scan persistent logs for suspicious patterns: repeated new host appearances (someone probing the network), rapid port churn, or known malicious signatures.

**Why it's the best choice for us:** `grep -c` (count matches) and `grep -E` (extended regex) give us frequency analysis in one command - the core of brute-force detection.

```bash
# Detect if same MAC appeared as NEW HOST more than 5 times in last hour
COUNT=$(grep -c "\[+\] NEW HOST.*$MAC" .gitnet/logs/today.log)
[ "$COUNT" -gt 5 ] && send_alert "Possible network probe from $MAC"
```

---

### `cron` - Automated Scheduling

**What it is:** Unix job scheduler that runs commands at defined intervals.

**Why we use it:** As defined in Project 1 of the CS2106 assignment document, `cron` is specified for automated monitoring. GitNet uses it to run `gitnet scan` automatically every N minutes so the network is continuously versioned without manual intervention.

**Why it's the best choice for us:** Zero dependencies, available on every Linux system, battle-tested for decades. The alternative (a `while true; do sleep; done` loop) is fragile and dies with the terminal session.

```bash
# Add to crontab: scan every 30 minutes
(crontab -l; echo "*/30 * * * * /path/to/gitnet scan -m 'Auto scan'") | crontab -
```

---

### `mailx` - Email Alerts

**What it is:** Command-line mail client for sending emails from shell scripts.

**Why we use it:** As defined in Projects 1 and 6 of the CS2106 assignment document, `mailx` is the specified tool for email alerting. When `alerts.sh` detects a threshold breach (new host, opened port, suspicious pattern), it fires an email immediately.

**Why it's the best choice for us:** One-liner email sending from bash. No SMTP libraries, no Python, no configuration files beyond `/etc/mailx.rc`.

```bash
mailx -s "GitNet Alert: Unauthorized Port Opened" admin@team.com < alert_body.txt
```

---

### `gnuplot` - Trend Charts

**What it is:** Command-line data visualization tool that generates publication-quality graphs.

**Why we use it:** As defined in Project 1 of the CS2106 assignment document, `gnuplot` is the specified tool for report visualization. Our `reporter.sh` uses it to plot active host count over time, open port trends, and anomaly frequency, turning raw commit history into visual intelligence.

**Why it's the best choice for us:** Generates PNG/SVG charts from a data file in 5 lines of script. No browser, no JavaScript, no dependencies. The output drops directly into our HTML report.

```bash
gnuplot <<EOF
set terminal png size 800,400
set output "host_trend.png"
set title "Active Hosts Over Time"
set xlabel "Scan #"; set ylabel "Host Count"
plot "history.dat" using 1:2 with linespoints title "Hosts"
EOF
```

---

### `flock` - Concurrency Lock

**What it is:** File locking utility that prevents race conditions between concurrent processes.

**Why we use it:** When `cron` triggers an automatic scan at the same time a team member runs a manual `gitnet scan`, both processes would try to write to `.gitnet/HEAD` simultaneously, corrupting the commit history. `flock` prevents this, exactly like Git's `.git/index.lock`.

**Why it's the best choice for us:** One line of bash. No semaphore libraries, no complex IPC.

```bash
(
  flock -x 200 || exit 1
  # Everything inside here is atomic
  run_scan && commit_snapshot
) 200>.gitnet/lockfile
```

---

## Team Work Split

|Member|Module|File|Commands|Key Deliverable|
|---|---|---|---|---|
|1|Scanner|`core/scanner.sh`|`gitnet scan`|Clean CSV: IP, MAC, Vendor, Ports, Services|
|2|Storage|`core/storage.sh`|`gitnet init`, `gitnet commit`, `gitnet log`|SHA1 object store, commit history, HEAD pointer|
|3|Diff Engine|`core/engine.sh`|`gitnet diff <c1> <c2>`|MAC-aware relational diff, anomaly classification|
|4|Reporter|`core/reporter.sh`|`gitnet show`, `gitnet report`|HTML reports, gnuplot charts, system health sidebar|
|5|CLI + Alerts|`gitnet` + `core/alerts.sh`|`gitnet schedule`, `gitnet alert`|Argument router, cron scheduler, email alerts, log analysis|

### Week-by-Week Plan

```
Week 1-2:   Agree on CSV spec. Everyone writes their module against mock data.
Week 3-4:   Core functionality done. M1 output feeds M2. M2 feeds M3.
Week 5-6:   Integration. Plug real outputs in. Fix interface mismatches.
Week 7:     Testing framework. Edge cases. Error handling.
Week 8:     Polish. HTML report styling. Demo rehearsal on hotspot.
Demo Day:   Nov 30 to Dec 2, 2026.
```

---

## Commands Reference

```bash
./gitnet init                        # Initialize .gitnet/ repository
./gitnet scan -m "message"           # Scan network + commit snapshot
./gitnet log                         # Show commit history
./gitnet diff HEAD~1 HEAD            # Compare last two snapshots
./gitnet diff <hash1> <hash2>        # Compare any two commits
./gitnet show <hash>                 # View a specific snapshot
./gitnet report --format html        # Generate HTML report
./gitnet report --format csv         # Export history as CSV
./gitnet schedule --interval 30m     # Set up cron auto-scanning
./gitnet alert --email you@email.com # Configure email alerts
./gitnet test                        # Run test suite
```

---

## Demo Script (Evaluation Day)

**Environment:** 5 team laptops + phones on personal hotspot.

```bash
# 1. Initialize and baseline
./gitnet init
./gitnet scan -m "Baseline, clean network"

# 2. Team member opens HTTP server (evaluator watching)
python3 -m http.server 8080 &

# 3. Scan again
./gitnet scan -m "Post-change scan"

# 4. THE MOMENT
./gitnet diff HEAD~1 HEAD
```

**Output:**

```
==================================================
GITNET NETWORK DRIFT REPORT [3f8a1c → 9b1c4a]
Scanned: 2026-11-30 14:32:01 | Subnet: 192.168.43.0/24
==================================================

[!] ANOMALY DETECTED: New open port
    Host    : 192.168.43.12
    MAC     : AA:BB:CC:DD:EE:FF  (Apple Inc.)
    Change  : Port 8080/TCP (HTTP) OPENED

==================================================
Summary: 1 anomaly | 0 new devices | 0 offline
Alert sent to: team@email.com
==================================================
```

Kill server → diff shows port closed. Connect phone → new device. Disconnect → offline. **Live. Real time. In front of evaluators.**

---

## Is This Resume Worthy?

**Yes, genuinely, not just academically.**

### One-line version

> Built **GitNet**: a pure bash network monitoring tool that applies Git style versioning to live network state, detecting configuration drift across devices in real time.

### Full resume bullets

```
GitNet - Network State Version Control System               Oct to Nov 2026
Team of 5 | Tools: bash, nmap, arp-scan, awk, sed, sha1sum, gnuplot, cron, mailx

• Architected a modular 5-component bash system that snapshots live network state
  (hosts, MACs, open ports, services) and versions it using a Git inspired SHA1
  content addressable object store

• Implemented MAC address based relational diff engine in awk that correctly
  identifies device changes despite DHCP IP churn, eliminating false positives
  that plague naive IP-based monitoring approaches

• Integrated log based anomaly detection (grep frequency analysis) that identifies
  suspicious patterns (repeated new hosts, port churn) and fires automated email
  alerts via mailx when thresholds are exceeded

• Built automated cron scheduled scanning with flock based concurrency control
  preventing race conditions between scheduled and manual scans

• Generated HTML reports and gnuplot trend charts from commit history, with
  system health metrics (CPU/RAM/disk) logged alongside every network snapshot

• Real-world equivalent: lightweight pure bash alternative to enterprise tools
  Batfish and Oxidized. Zero Docker, zero Python, zero enterprise hardware required
```

### Why interviewers care

|What You Built|What It Signals|
|---|---|
|Modular architecture, clean file interfaces|You think in systems, not just scripts|
|MAC-vs-IP insight for DHCP noise|You understood why naive approaches fail before building|
|flock for concurrency|You thought about production failure modes, not just happy path|
|SHA1 content addressable storage|You understand how real version control works under the hood|
|Pure bash constraint|Low-level systems knowledge, no library crutches|
|5-person parallel development|You can coordinate in a team without stepping on each other|

Any interviewer in **DevOps, NetDevOps, SRE, or Systems/Infrastructure** will immediately recognize what you built. You can name-drop Batfish and Oxidized in the interview and watch them nod.

---

## Academic Context

Submitted under **Project 3: Network Scanner & Analyzer** CS2106 Scripting Workshop | Evaluation: Nov 30 to Dec 2, 2026

Satisfies all Project 3 rubric requirements:

- ✅ Ping sweeps and port scanning via `scanner.sh` via nmap/arp-scan
- ✅ Open service detection - `scanner.sh` HTTP/SSH identification
- ✅ MAC address vendor lookup - `scanner.sh` OUI database lookup
- ✅ Export results to CSV - `storage.sh` structured CSV snapshots
- ✅ **Above & beyond:** Git versioning layer, relational diff engine, anomaly detection, HTML reports, email alerts, gnuplot charts, system health integration, automated test suite

Additional projects integrated:

- ✅ Project 6 (Log Analyzer) - `alerts.sh` pattern matching and frequency analysis
- ✅ Project 1 (System Health Monitor) - `reporter.sh` CPU/RAM/disk sidebar
- ✅ Project 5 (Testing Framework) - `tests/` parallel test runner

---

_Built with pure bash. No Docker. No Python. No dependencies beyond standard Linux tools._