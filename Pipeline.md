# GitNet: Complete Pipeline and Role Guide
### Everything Each Team Member Needs to Know, Learn, and Build

This document is the single source of truth for the entire project. It covers
the full pipeline from a raw network scan to a polished HTML report, what each
module does technically, what each person needs to learn before writing their
module, and exactly what their finished code must produce.

Read your own role section completely before writing a single line of code.
Read the full pipeline section regardless of your role.

---

## Table of Contents
- [The Full Pipeline](#the-full-pipeline)
- [The CSV Contract](#the-csv-contract)
- [Mock Data Files](#mock-data-files)
- [Role 1: Scanner](#role-1-scanner)
- [Role 2: Storage Engine](#role-2-storage-engine)
- [Role 3: Diff and Anomaly Engine](#role-3-diff-and-anomaly-engine)
- [Role 4: Reporter](#role-4-reporter)
- [Role 5: CLI and Alerts](#role-5-cli-and-alerts)
- [Integration Checklist](#integration-checklist)
- [Demo Day Checklist](#demo-day-checklist)

---

## The Full Pipeline

Understanding the full pipeline is mandatory for every member regardless of
which module they own. You cannot write a good module if you do not understand
what feeds into it and what consumes its output.

```
USER RUNS: ./gitnet scan -m "Baseline scan"
                │
                ▼
┌───────────────────────────────────────────────────────┐
│  ROLE 5: gitnet (main CLI)                            │
│  Parses the command and flags                         │
│  Calls scanner.sh with the right arguments            │
└───────────────────────┬───────────────────────────────┘
                        │
                        ▼
┌───────────────────────────────────────────────────────┐
│  ROLE 1: scanner.sh                                   │
│  Runs arp-scan to find all live hosts and MACs        │
│  Runs nmap on each host to find open ports            │
│  Looks up MAC vendor from OUI database                │
│  Writes everything into a clean structured CSV        │
│  Output: /tmp/gitnet_snapshot.csv                     │
└───────────────────────┬───────────────────────────────┘
                        │
                        ▼
┌───────────────────────────────────────────────────────┐
│  ROLE 2: storage.sh                                   │
│  Reads the CSV from scanner.sh                        │
│  Generates SHA1 hash of the CSV content               │
│  Stores CSV in .gitnet/objects/<hash>.csv             │
│  Writes commit metadata to .gitnet/commits/           │
│  Updates .gitnet/HEAD to point to new commit          │
│  Output: commit stored, HEAD updated                  │
└───────────────────────┬───────────────────────────────┘
                        │
           ┌────────────┴────────────┐
           │                         │
           ▼                         ▼
┌──────────────────────┐  ┌─────────────────────────────┐
│  ROLE 3: engine.sh   │  │  ROLE 4: reporter.sh        │
│  Reads two snapshot  │  │  Reads commit history        │
│  CSVs from objects/  │  │  Reads diff output           │
│  Compares by MAC     │  │  Reads system health stats   │
│  Outputs diff report │  │  Generates HTML report       │
│  Flags anomalies     │  │  Generates gnuplot charts    │
└──────────┬───────────┘  └─────────────────────────────┘
           │
           ▼
┌───────────────────────────────────────────────────────┐
│  ROLE 5: alerts.sh                                    │
│  Reads diff output from engine.sh                     │
│  Counts anomaly frequency in logs                     │
│  Fires email via mailx if threshold crossed           │
│  Appends to .gitnet/logs/                             │
└───────────────────────────────────────────────────────┘
```

Every arrow in this diagram is a file being passed between modules. No module
calls functions inside another module. They only talk through files. This is
what makes parallel development possible.

---

## The CSV Contract

This is the most important section in the document. Every member must memorize
this format. Deviating from it breaks every downstream module.

### Format

```
IP,MAC,VENDOR,PORTS,SERVICES,TIMESTAMP
```

### Rules

- Fields are comma separated
- Multiple ports are pipe separated: `22|80|443`
- Multiple services are pipe separated in the same order as ports: `SSH|HTTP|HTTPS`
- If a host has no open ports, PORTS and SERVICES are empty strings
- TIMESTAMP is ISO 8601 format: `2026-10-01T14:32:01`
- MAC is always uppercase with colons: `24:2F:D0:BD:17:40`
- No spaces anywhere in a line
- No header row in the actual snapshot files

### Example

```
192.168.0.1,24:2F:D0:BD:17:40,Unknown,22|80|443,SSH|HTTP|HTTPS,2026-10-01T14:32:01
192.168.0.170,08:9D:F4:4F:3D:0F,Intel Corporate,22,SSH,2026-10-01T14:32:01
192.168.0.248,0C:EF:15:88:F2:A6,Unknown,,,2026-10-01T14:32:01
192.168.0.206,62:13:D5:E4:31:29,Unknown,,,2026-10-01T14:32:01
```

### Field Reference

| Field | Position | Example | Notes |
|---|---|---|---|
| IP | $1 | 192.168.0.1 | IPv4 address |
| MAC | $2 | 24:2F:D0:BD:17:40 | Always uppercase |
| VENDOR | $3 | Intel Corporate | Unknown if not found |
| PORTS | $4 | 22\|80\|443 | Pipe separated, empty if none |
| SERVICES | $5 | SSH\|HTTP\|HTTPS | Pipe separated, matches PORTS order |
| TIMESTAMP | $6 | 2026-10-01T14:32:01 | ISO 8601 |

---

## Mock Data Files

Create these files on Day 1. Every member uses them to develop independently
without waiting for the real scanner to be finished.

Save as `tests/mock_snapshot_1.csv`:
```
192.168.0.1,24:2F:D0:BD:17:40,Unknown,22|80|443,SSH|HTTP|HTTPS,2026-10-01T10:00:00
192.168.0.170,08:9D:F4:4F:3D:0F,Intel Corporate,22,SSH,2026-10-01T10:00:00
192.168.0.248,0C:EF:15:88:F2:A6,Unknown,,,2026-10-01T10:00:00
192.168.0.127,7E:B7:CB:EA:7E:09,Unknown,,,2026-10-01T10:00:00
```

Save as `tests/mock_snapshot_2.csv`:
```
192.168.0.1,24:2F:D0:BD:17:40,Unknown,22|80|443,SSH|HTTP|HTTPS,2026-10-01T11:00:00
192.168.0.170,08:9D:F4:4F:3D:0F,Intel Corporate,22|8080,SSH|HTTP,2026-10-01T11:00:00
192.168.0.206,62:13:D5:E4:31:29,Unknown,,,2026-10-01T11:00:00
192.168.0.127,7E:B7:CB:EA:7E:09,Unknown,,,2026-10-01T11:00:00
```

Changes between snapshot 1 and snapshot 2:
- Device `192.168.0.248` went offline (MAC gone from snapshot 2)
- Device `192.168.0.206` appeared (MAC new in snapshot 2)
- Device `192.168.0.170` opened port 8080 (ports changed from `22` to `22|8080`)

These are exactly the three anomaly types engine.sh must detect.

Save as `tests/mock_diff_output.txt`:
```
==================================================
GITNET NETWORK DRIFT REPORT [abc123 to def456]
Scanned: 2026-10-01T11:00:00 | Subnet: 192.168.0.0/24
==================================================

[!] ANOMALY DETECTED: New open port
    Host   : 192.168.0.170
    MAC    : 08:9D:F4:4F:3D:0F (Intel Corporate)
    Change : Port 8080/TCP (HTTP) OPENED

[+] NEW DEVICE DETECTED
    Host   : 192.168.0.206
    MAC    : 62:13:D5:E4:31:29 (Unknown)

[-] DEVICE OFFLINE
    Host   : 192.168.0.248
    MAC    : 0C:EF:15:88:F2:A6 (Unknown)

==================================================
Summary: 1 anomaly | 1 new device | 1 offline
==================================================
```

Reporter and alerts use this mock diff output to develop without waiting for
engine.sh to be finished.

---

## Role 1: Scanner

**File:** `core/scanner.sh`
**Command it powers:** `gitnet scan -m "message"`
**Output:** `/tmp/gitnet_snapshot.csv`
**Everyone depends on you. This is the critical path.**

---

### What This Module Does

scanner.sh is the eyes of GitNet. Every time a scan is triggered it goes out
onto the network, finds every live device, records its IP, MAC address, vendor,
and every open port with its service name. It writes all of this into a clean
CSV file that storage.sh will then hash and commit.

The quality of scanner.sh determines the quality of everything downstream. If
the CSV has inconsistent formatting, extra spaces, or missing fields, every
other module breaks. Write it defensively.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals**

Learn these before anything else. Spend three days here if needed.

Variables and quoting:
```bash
# Always quote variables to handle spaces
NAME="GitNet"
echo "$NAME"

# Command substitution
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
IP=$(hostname -I | awk '{print $1}')
```

Conditionals:
```bash
# Check if a command succeeded
if sudo arp-scan --version &>/dev/null; then
    echo "arp-scan is installed"
else
    echo "arp-scan not found"
    exit 1
fi

# Check if file exists
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Output file missing"
    exit 1
fi
```

Loops:
```bash
# Loop over lines in a file
while IFS= read -r line; do
    echo "Processing: $line"
done < hosts.txt

# Loop over a list
for IP in 192.168.0.1 192.168.0.2 192.168.0.3; do
    echo "Scanning $IP"
done
```

Pipes and redirection:
```bash
# Pipe output through multiple commands
sudo arp-scan --localnet --interface=eth2 | grep -v "^Starting" | grep -v "^Interface"

# Redirect output to file
echo "data" > file.txt      # overwrite
echo "more" >> file.txt     # append
command 2>/dev/null         # discard errors
```

**Stage 2: awk for Text Parsing**

This is the most important skill for scanner.sh. arp-scan and nmap produce
messy multi-line output. awk turns it into clean structured CSV.

Understand field splitting:
```bash
# arp-scan output looks like:
# 192.168.0.1    24:2F:D0:BD:17:40    Unknown
# $1 = IP, $2 = MAC, $3 = VENDOR

echo "192.168.0.1    24:2F:D0:BD:17:40    Unknown" | awk '{print $1","$2","$3}'
# Output: 192.168.0.1,24:2F:D0:BD:17:40,Unknown
```

Pattern matching in awk:
```bash
# Only process lines that start with a number (IP address lines)
sudo arp-scan --localnet --interface=eth2 | awk '/^[0-9]/ {print $1","$2","$3}'
```

Multifield joining:
```bash
# nmap port output: "22/tcp  open  ssh"
# We want: 22 and ssh extracted
echo "22/tcp  open  ssh" | awk '{split($1,a,"/"); print a[1]","$3}'
# Output: 22,ssh
```

**Stage 3: nmap Output Parsing**

Practice parsing nmap's grepable output format which is cleanest for scripting:

```bash
# Run nmap with grepable output
sudo nmap -sV -p- --open -T4 -oG - 192.168.0.1

# Output looks like:
# Host: 192.168.0.1 ()  Ports: 22/open/tcp//ssh///, 80/open/tcp//http///

# Extract just the ports section
sudo nmap -sV -p- --open -T4 -oG - 192.168.0.1 | grep "^Host:" | awk '{print $5}'
```

**Stage 4: Combining arp-scan and nmap**

The scanner does two passes:
1. arp-scan to get all live hosts and their MACs quickly
2. nmap on each discovered host to get open ports

```bash
# Step 1: get hosts
HOSTS=$(sudo arp-scan --localnet --interface=eth2 | awk '/^[0-9]/ {print $1}')

# Step 2: for each host, scan ports
for HOST in $HOSTS; do
    PORTS=$(sudo nmap -p- --open -T4 -oG - $HOST | grep "Ports:" | ...)
done
```

**Stage 5: Building the Final CSV**

Practice writing clean CSV from combined data:

```bash
# Template for one CSV line
printf "%s,%s,%s,%s,%s,%s\n" "$IP" "$MAC" "$VENDOR" "$PORTS" "$SERVICES" "$TIMESTAMP"
```

---

### What Your Finished Code Must Do

1. Accept interface as argument: `scanner.sh eth2` or read from `.gitnet/config`
2. Run arp-scan and collect IP, MAC, VENDOR for every live host
3. Run nmap on each discovered host and collect open ports and services
4. For hosts with no open ports, write empty strings for PORTS and SERVICES
5. Write one line per host to `/tmp/gitnet_snapshot.csv` in exact CSV contract format
6. Print a progress message to stderr so the user knows it is working
7. Exit with code 0 on success, 1 on failure
8. Handle the case where arp-scan finds zero hosts gracefully

---

### Test Your Module Like This

```bash
# Run your scanner
bash core/scanner.sh eth2

# Check the output
cat /tmp/gitnet_snapshot.csv

# Verify format: should have 6 comma-separated fields per line
awk -F, 'NF != 6 {print "BAD LINE:", NR, $0}' /tmp/gitnet_snapshot.csv

# If no output, format is correct
```

---

### Common Mistakes to Avoid

Never hardcode the interface. Read it from config or accept as argument.
Never leave trailing spaces in CSV fields. They break awk field matching downstream.
Never include the arp-scan header lines in output. Filter them with awk or grep.
Always handle the case where a host goes offline between arp-scan and nmap.

---

## Role 2: Storage Engine

**File:** `core/storage.sh`
**Commands it powers:** `gitnet init`, `gitnet commit`, `gitnet log`
**Input:** `/tmp/gitnet_snapshot.csv` from scanner.sh
**Output:** Commit stored in `.gitnet/objects/`, HEAD updated

---

### What This Module Does

storage.sh is the memory of GitNet. Every time a scan produces a CSV snapshot,
storage.sh takes that CSV, generates a SHA1 hash of its contents, stores it as
a permanent object, and records metadata about the commit. This is exactly how
Git works internally. The hash is the commit ID. The objects directory is the
object store. HEAD points to the latest commit.

When someone runs `gitnet log`, storage.sh reads through all commit metadata
and displays a history of every scan that was ever taken.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals**

Same as Role 1. Variables, conditionals, loops, pipes, redirection. Spend two
days here before moving forward.

**Stage 2: File and Directory Operations**

Creating directory structures:
```bash
# Create nested directories in one command
mkdir -p .gitnet/objects
mkdir -p .gitnet/commits
mkdir -p .gitnet/logs

# Check if directory already exists
if [ -d ".gitnet" ]; then
    echo "Already initialized"
    exit 1
fi
```

Reading and writing files:
```bash
# Write to a file
echo "hash=abc123" > .gitnet/commits/1696150321
echo "message=Baseline scan" >> .gitnet/commits/1696150321

# Read a specific value from a flat key=value file
HASH=$(grep "^hash=" .gitnet/commits/1696150321 | cut -d= -f2)

# Update HEAD
echo "abc123" > .gitnet/HEAD
CURRENT_HEAD=$(cat .gitnet/HEAD)
```

**Stage 3: SHA1 Hashing**

Understanding content addressable storage:
```bash
# Hash a file
sha1sum snapshot.csv
# Output: abc123def456...  snapshot.csv

# Extract just the hash
HASH=$(sha1sum snapshot.csv | cut -d' ' -f1)
echo $HASH
# Output: abc123def456...

# Why this is powerful: identical content always produces identical hash
# Two scans that found exactly the same network state produce the same hash
# This means we never store duplicate snapshots
```

**Stage 4: Commit Metadata Format**

Design your commit metadata file format. Keep it simple:

```
hash=3f8a1c9b4d2e7f0a1b5c8d3e6f9a2b4c
timestamp=2026-10-01T14:32:01
message=Baseline scan
host_count=4
```

One key=value pair per line. Easy to read with grep and cut.

**Stage 5: Building gitnet log**

Reading commit history in reverse chronological order:
```bash
# List all commits sorted by timestamp (newest first)
ls -t .gitnet/commits/ | while read commit_file; do
    HASH=$(grep "^hash=" ".gitnet/commits/$commit_file" | cut -d= -f2)
    MSG=$(grep "^message=" ".gitnet/commits/$commit_file" | cut -d= -f2)
    TIME=$(grep "^timestamp=" ".gitnet/commits/$commit_file" | cut -d= -f2)
    printf "%s  %s  %s\n" "${HASH:0:8}" "$TIME" "$MSG"
done
```

**Stage 6: flock for Concurrency Safety**

When cron runs a scan at the same time a user runs one manually, both will try
to write to HEAD simultaneously. flock prevents this:

```bash
LOCKFILE=".gitnet/lockfile"

(
    flock -x -w 10 200 || { echo "Another scan is running"; exit 1; }
    
    # Everything inside here runs exclusively
    # Only one process can be here at a time
    do_the_commit
    
) 200>"$LOCKFILE"
```

---

### What Your Finished Code Must Do

**gitnet init:**
1. Check if `.gitnet/` already exists, exit with error if so
2. Create `.gitnet/objects/`, `.gitnet/commits/`, `.gitnet/logs/`
3. Create `.gitnet/HEAD` with empty content
4. Create `.gitnet/config` with default values (interface, subnet, alert email)
5. Print a success message

**gitnet commit (called internally after scan):**
1. Read `/tmp/gitnet_snapshot.csv`
2. Generate SHA1 hash of the file
3. Check if this exact hash already exists in objects (no duplicate commits)
4. Copy CSV to `.gitnet/objects/<hash>.csv`
5. Write commit metadata to `.gitnet/commits/<unix_timestamp>`
6. Update `.gitnet/HEAD` with the new hash
7. Use flock throughout to prevent race conditions

**gitnet log:**
1. Read all files in `.gitnet/commits/` sorted newest first
2. Display each commit as: `<short_hash>  <timestamp>  <message>  (<host_count> hosts)`
3. If no commits exist, print helpful message

---

### Test Your Module Like This

```bash
# Initialize
bash core/storage.sh init
ls -la .gitnet/

# Commit a mock snapshot
cp tests/mock_snapshot_1.csv /tmp/gitnet_snapshot.csv
bash core/storage.sh commit "First test commit"

# Check it was stored
ls .gitnet/objects/
ls .gitnet/commits/
cat .gitnet/HEAD

# Commit a second snapshot
cp tests/mock_snapshot_2.csv /tmp/gitnet_snapshot.csv
bash core/storage.sh commit "Second test commit"

# View log
bash core/storage.sh log
```

---

## Role 3: Diff and Anomaly Engine

**File:** `core/engine.sh`
**Command it powers:** `gitnet diff <commit1> <commit2>`
**Input:** Two CSV files from `.gitnet/objects/`
**Output:** Formatted diff report to stdout

**This is the hardest module technically. The entire value of GitNet lives here.**

---

### What This Module Does

engine.sh is the brain of GitNet. Given two network snapshots, it figures out
exactly what changed between them. Not by comparing lines of text like standard
diff does, but by comparing devices by their MAC address.

This distinction is everything. Standard diff would see a device changing IP
from `.10` to `.15` as one device disappearing and a completely new device
appearing. engine.sh sees the same MAC address in both snapshots and correctly
reports it as the same device with a changed IP.

Three types of change must be detected:
- New device: MAC exists in snapshot 2 but not snapshot 1
- Device offline: MAC exists in snapshot 1 but not snapshot 2
- Device changed: MAC exists in both but something is different (IP, ports, services)

---

### What You Need to Learn

**Stage 1: Bash Fundamentals**

Same as previous roles. Variables, conditionals, loops, pipes. Two days minimum.

**Stage 2: awk Deeply**

This module lives and dies by awk. You must be genuinely comfortable with it.

Basic awk structure:
```bash
awk 'BEGIN { setup }
     /pattern/ { action }
     END { cleanup }
    ' file
```

Associative arrays, the most important concept for this module:
```bash
# Count occurrences of each word
echo -e "apple\nbanana\napple\ncherry\nbanana\napple" | awk '
{
    count[$1]++
}
END {
    for (word in count) {
        print word, count[word]
    }
}
'
```

The NR==FNR pattern for comparing two files, the exact technique used in engine.sh:
```bash
# NR = total line number across all files
# FNR = line number within current file
# NR==FNR is only true while reading the FIRST file

awk 'NR==FNR {
         # This block runs only for file1
         # Store everything keyed by MAC address
         data[$2] = $0
         next
     }
     # Everything below runs only for file2
     !($2 in data) {
         print "NEW in file2:", $0
     }
     ($2 in data) && data[$2] != $0 {
         print "CHANGED:", $0
     }
    ' file1.csv file2.csv
```

Practice this exact pattern on the mock CSV files before writing engine.sh.

**Stage 3: Port Comparison Logic**

The trickiest part is comparing port lists. If a device had ports `22|80` and
now has `22|80|8080`, engine.sh needs to report `8080 OPENED`. If it had
`22|80|443` and now has `22|80`, it needs to report `443 CLOSED`.

Practice splitting pipe-separated values in awk:
```bash
# Split a pipe-separated port list into an array
echo "22|80|443" | awk '{
    n = split($0, ports, "|")
    for (i=1; i<=n; i++) {
        print "Port:", ports[i]
    }
}'
```

Finding what is in one list but not the other:
```bash
# Given old_ports="22|80|443" and new_ports="22|80|8080"
# Find opened ports (in new but not old)
# Find closed ports (in old but not new)

awk 'BEGIN {
    split("22|80|443", old, "|")
    split("22|80|8080", new, "|")
    
    for (i in old) old_set[old[i]] = 1
    for (i in new) new_set[new[i]] = 1
    
    for (port in new_set) {
        if (!(port in old_set)) print "OPENED:", port
    }
    for (port in old_set) {
        if (!(port in new_set)) print "CLOSED:", port
    }
}'
```

**Stage 4: Output Formatting**

Your diff output must be readable and consistent because alerts.sh and
reporter.sh parse it with grep. Agree on the exact format and never deviate.

```bash
# Use printf for consistent alignment
printf "%-10s %-20s %s\n" "[!]" "ANOMALY:" "Port 8080 opened"
printf "%-10s %-20s %s\n" "[+]" "NEW DEVICE:" "192.168.0.206"
printf "%-10s %-20s %s\n" "[-]" "OFFLINE:" "192.168.0.248"
```

**Stage 5: Resolving Commit Hashes**

engine.sh needs to accept either full hashes or relative references like
HEAD~1 and HEAD~2 and resolve them to actual CSV file paths:

```bash
resolve_commit() {
    local REF="$1"
    
    if [ "$REF" = "HEAD" ]; then
        cat .gitnet/HEAD
    elif [[ "$REF" =~ ^HEAD~([0-9]+)$ ]]; then
        # Go N commits back in history
        N="${BASH_REMATCH[1]}"
        ls -t .gitnet/commits/ | sed -n "$((N+1))p" | xargs -I{} grep "^hash=" ".gitnet/commits/{}" | cut -d= -f2
    else
        # Assume it is a hash prefix, find the full hash
        ls .gitnet/objects/ | grep "^$REF"
    fi
}
```

---

### What Your Finished Code Must Do

1. Accept two commit references: `engine.sh <commit1> <commit2>`
2. Resolve each reference to a full hash and find the CSV in objects/
3. Compare the two CSVs by MAC address using awk NR==FNR pattern
4. Detect and report new devices with IP and MAC
5. Detect and report offline devices with last known IP and MAC
6. Detect and report changed devices with specific changes listed:
   - IP address changed
   - Port opened (list which port and service)
   - Port closed (list which port)
7. Print summary line: `N anomalies | N new devices | N offline`
8. Exit with code 0 if no changes, 1 if changes detected (useful for scripting)

---

### Test Your Module Like This

```bash
# First commit both mock snapshots using storage.sh
cp tests/mock_snapshot_1.csv /tmp/gitnet_snapshot.csv
bash core/storage.sh commit "Snapshot 1"
HASH1=$(cat .gitnet/HEAD)

cp tests/mock_snapshot_2.csv /tmp/gitnet_snapshot.csv
bash core/storage.sh commit "Snapshot 2"
HASH2=$(cat .gitnet/HEAD)

# Now diff them
bash core/engine.sh $HASH1 $HASH2

# Expected output should show:
# [!] Port 8080 opened on 192.168.0.170
# [+] New device 192.168.0.206
# [-] Device 192.168.0.248 offline
```

---

## Role 4: Reporter

**File:** `core/reporter.sh`
**Commands it powers:** `gitnet show <hash>`, `gitnet report --format html`
**Input:** Commit history from `.gitnet/commits/`, diff output from engine.sh
**Output:** HTML report file, gnuplot PNG chart, formatted CLI table

---

### What This Module Does

reporter.sh is the face of GitNet. It takes raw data from commits and diffs and
turns it into something a human actually wants to look at. The HTML report is
what gets opened on a browser during the demo. The gnuplot chart shows active
host count over time. The system health sidebar shows CPU and RAM usage of the
machine running GitNet.

This module has the most visual impact on the evaluators even though it is not
the most technically complex. Spend time making the output look professional.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals**

Same as all other roles. Variables, conditionals, loops, pipes. Two days.

**Stage 2: Reading Commit History**

You need to read all commits and extract data from them:

```bash
# Read all commits and build a data table
ls -t .gitnet/commits/ | while read commit_file; do
    HASH=$(grep "^hash=" ".gitnet/commits/$commit_file" | cut -d= -f2)
    TIME=$(grep "^timestamp=" ".gitnet/commits/$commit_file" | cut -d= -f2)
    COUNT=$(grep "^host_count=" ".gitnet/commits/$commit_file" | cut -d= -f2)
    SHORT="${HASH:0:8}"
    echo "$SHORT $TIME $COUNT"
done
```

**Stage 3: HTML Generation with Here Documents**

A here document lets you write a multiline string directly in bash:

```bash
generate_html() {
    local OUTPUT="$1"
    local TIMESTAMP="$2"
    
    cat << EOF > "$OUTPUT"
<!DOCTYPE html>
<html>
<head>
    <title>GitNet Report</title>
    <style>
        body { font-family: monospace; background: #1a1a1a; color: #e0e0e0; }
        .anomaly { color: #ff6b6b; }
        .new { color: #69db7c; }
        .offline { color: #ffa94d; }
        table { border-collapse: collapse; width: 100%; }
        td, th { padding: 8px; border: 1px solid #444; }
    </style>
</head>
<body>
    <h1>GitNet Network Drift Report</h1>
    <p>Generated: $TIMESTAMP</p>
    <!-- Content goes here -->
</body>
</html>
EOF
}
```

Variables inside here documents are expanded automatically. This is how you
inject bash variables into HTML.

**Stage 4: gnuplot for Charts**

gnuplot reads a data file and produces a PNG image:

```bash
# First build the data file from commit history
ls -t .gitnet/commits/ | while read f; do
    SCAN_NUM=$((SCAN_NUM+1))
    COUNT=$(grep "^host_count=" ".gitnet/commits/$f" | cut -d= -f2)
    echo "$SCAN_NUM $COUNT"
done > /tmp/host_history.dat

# Then generate the chart
gnuplot << 'GNUPLOT'
set terminal png size 900,400 background "#1a1a1a"
set output "/tmp/gitnet_chart.png"
set title "Active Hosts Over Time" textcolor "#e0e0e0"
set xlabel "Scan Number" textcolor "#e0e0e0"
set ylabel "Host Count" textcolor "#e0e0e0"
set border lc "#444444"
set grid lc "#333333"
plot "/tmp/host_history.dat" using 1:2 with linespoints \
     lc "#69db7c" pt 7 ps 1.5 title "Hosts"
GNUPLOT
```

**Stage 5: System Health Stats**

The system health sidebar reads current machine stats:

```bash
# CPU usage
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)

# Memory usage
MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')
MEM_PCT=$(echo "scale=1; $MEM_USED * 100 / $MEM_TOTAL" | bc)

# Disk usage
DISK=$(df -h / | awk 'NR==2 {print $5}')
```

**Stage 6: column -t for CLI Tables**

For the terminal output, column -t aligns columns automatically:

```bash
# Print a nicely aligned table
{
    echo "HASH TIMESTAMP HOSTS MESSAGE"
    echo "---- --------- ----- -------"
    # ... data rows
} | column -t
```

---

### What Your Finished Code Must Do

**gitnet show:**
1. Accept a commit hash or HEAD
2. Display the snapshot CSV as a formatted table using column -t
3. Show commit metadata (hash, timestamp, message, host count)

**gitnet report --format html:**
1. Read all commit history
2. Build host count data file for gnuplot
3. Generate gnuplot PNG chart
4. Get current system health stats
5. Generate complete HTML report containing:
   - Summary table of all commits
   - gnuplot chart embedded as image
   - System health sidebar
   - Latest diff output if available
6. Save to `gitnet_report.html` and open in browser if possible

**gitnet report --format csv:**
1. Export full commit history as CSV for external use

---

### Test Your Module Like This

```bash
# Make sure you have some commits first (use storage.sh)
bash core/reporter.sh show HEAD
bash core/reporter.sh report --format html

# Open the HTML file
# On WSL:
explorer.exe gitnet_report.html
# On Mac:
open gitnet_report.html
```

---

## Role 5: CLI and Alerts

**Files:** `gitnet` (main entry point) + `core/alerts.sh`
**Commands it powers:** All of them
**Input:** User arguments, diff output from engine.sh
**Output:** Correct module called, email alerts sent, cron jobs managed

---

### What This Module Does

The main `gitnet` file is the front door of the entire project. Every command
the user types goes through here first. It parses the command and flags, runs
validation, and calls the right module with the right arguments.

alerts.sh runs after every diff. It reads the diff output, counts how many
times the same anomaly has appeared in recent history, and fires an email if
anything crosses a threshold. It also maintains the persistent log file.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals**

More than any other role, you need to be solid on bash fundamentals because you
are writing the glue that holds everything together. Variables, conditionals,
loops, pipes, exit codes. Spend three days here.

**Stage 2: Argument Parsing with case**

The main CLI uses a case statement to route commands:

```bash
#!/bin/bash

COMMAND="$1"
shift   # Remove first argument, remaining args available as $@

case "$COMMAND" in
    init)
        bash core/storage.sh init
        ;;
    scan)
        # Parse flags for scan command
        while getopts "m:i:" opt; do
            case $opt in
                m) MESSAGE="$OPTARG" ;;
                i) INTERFACE="$OPTARG" ;;
            esac
        done
        bash core/scanner.sh "$INTERFACE"
        bash core/storage.sh commit "$MESSAGE"
        bash core/engine.sh HEAD~1 HEAD | bash core/alerts.sh
        ;;
    diff)
        COMMIT1="$1"
        COMMIT2="$2"
        bash core/engine.sh "$COMMIT1" "$COMMIT2"
        ;;
    log)
        bash core/storage.sh log
        ;;
    show)
        bash core/reporter.sh show "$1"
        ;;
    report)
        bash core/reporter.sh report "$@"
        ;;
    schedule)
        bash core/alerts.sh schedule "$@"
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Run './gitnet help' for usage"
        exit 1
        ;;
esac
```

**Stage 3: getopts for Flags**

getopts parses flags like `-m "message"` and `-i eth2`:

```bash
parse_scan_args() {
    local OPTIND
    while getopts "m:i:h" opt "$@"; do
        case $opt in
            m) MESSAGE="$OPTARG" ;;
            i) INTERFACE="$OPTARG" ;;
            h) show_scan_help; exit 0 ;;
            ?) echo "Unknown flag: -$OPTARG"; exit 1 ;;
        esac
    done
}
```

**Stage 4: Reading Config File**

The config file stores defaults so users do not need to pass flags every time:

```bash
# .gitnet/config format:
# interface=eth2
# subnet=192.168.0.0/24
# alert_email=team@email.com
# alert_threshold=3

load_config() {
    CONFIG_FILE=".gitnet/config"
    if [ -f "$CONFIG_FILE" ]; then
        INTERFACE=$(grep "^interface=" "$CONFIG_FILE" | cut -d= -f2)
        SUBNET=$(grep "^subnet=" "$CONFIG_FILE" | cut -d= -f2)
        ALERT_EMAIL=$(grep "^alert_email=" "$CONFIG_FILE" | cut -d= -f2)
        THRESHOLD=$(grep "^alert_threshold=" "$CONFIG_FILE" | cut -d= -f2)
    fi
}
```

**Stage 5: grep for Pattern Matching in Alerts**

alerts.sh reads diff output and counts anomalies:

```bash
# Count anomalies in the diff
ANOMALY_COUNT=$(grep -c "^\[!\]" /tmp/gitnet_diff.txt)
NEW_COUNT=$(grep -c "^\[\+\]" /tmp/gitnet_diff.txt)
OFFLINE_COUNT=$(grep -c "^\[-\]" /tmp/gitnet_diff.txt)

# Check if threshold crossed
if [ "$ANOMALY_COUNT" -gt "$THRESHOLD" ]; then
    send_alert
fi
```

Frequency analysis on persistent logs for brute force detection:

```bash
# Check if same MAC appeared as new device more than 5 times in last hour
MAC="AA:BB:CC:DD:EE:FF"
COUNT=$(grep "NEW DEVICE.*$MAC" .gitnet/logs/gitnet.log | \
        awk -v cutoff="$(date -d '1 hour ago' +%s)" \
        'BEGIN{FS=","} {if ($6 > cutoff) count++} END{print count+0}')

if [ "$COUNT" -gt 5 ]; then
    send_alert "Suspicious: $MAC appeared $COUNT times in last hour"
fi
```

**Stage 6: mailx for Email Alerts**

```bash
send_alert() {
    local SUBJECT="$1"
    local BODY_FILE="$2"
    
    if [ -z "$ALERT_EMAIL" ]; then
        echo "No alert email configured" >&2
        return
    fi
    
    mailx -s "GitNet Alert: $SUBJECT" "$ALERT_EMAIL" < "$BODY_FILE"
}
```

**Stage 7: cron for Scheduling**

```bash
schedule_scans() {
    local INTERVAL="$1"   # e.g. "30m" or "1h"
    local GITNET_PATH=$(realpath ./gitnet)
    
    # Convert interval to cron syntax
    case "$INTERVAL" in
        *m) MINUTES="${INTERVAL%m}"; CRON_EXPR="*/$MINUTES * * * *" ;;
        *h) HOURS="${INTERVAL%h}"; CRON_EXPR="0 */$HOURS * * *" ;;
    esac
    
    # Add to crontab without duplicates
    (crontab -l 2>/dev/null | grep -v "gitnet scan"; \
     echo "$CRON_EXPR $GITNET_PATH scan -m 'Auto scan'") | crontab -
    
    echo "Scheduled: $CRON_EXPR"
}
```

---

### What Your Finished Code Must Do

**gitnet (main CLI):**
1. Route every command to the right module
2. Parse all flags correctly and pass them to modules
3. Load config from `.gitnet/config` as defaults
4. Check that `.gitnet/` exists before any command except init
5. Show a clean help message for every command
6. Handle unknown commands gracefully with helpful error message

**alerts.sh:**
1. Read diff output from stdin or file
2. Count anomalies, new devices, offline devices
3. Append summary to `.gitnet/logs/gitnet.log` with timestamp
4. Check frequency of same anomaly in recent log history
5. Send email via mailx if anomaly count exceeds threshold
6. Rotate log file if it exceeds 10MB

**gitnet schedule:**
1. Accept interval argument (`--interval 30m`, `--interval 1h`)
2. Add cron job without creating duplicates
3. Print confirmation of schedule

---

### Test Your Module Like This

```bash
# Test help
./gitnet help
./gitnet --help
./gitnet

# Test unknown command
./gitnet invalidcommand

# Test full pipeline
./gitnet init
./gitnet scan -m "Test scan"
./gitnet log
./gitnet diff HEAD~1 HEAD
./gitnet report --format html

# Test scheduling
./gitnet schedule --interval 30m
crontab -l    # verify cron job was added
```

---

## Integration Checklist

Run through this checklist during Week 5 to 6 when connecting all modules:

**Scanner to Storage**
- [ ] scanner.sh writes CSV to `/tmp/gitnet_snapshot.csv`
- [ ] storage.sh reads from `/tmp/gitnet_snapshot.csv`
- [ ] CSV format matches the contract exactly
- [ ] storage.sh correctly hashes and stores the CSV

**Storage to Engine**
- [ ] engine.sh can resolve HEAD and HEAD~1 to actual hashes
- [ ] engine.sh finds the CSV files in `.gitnet/objects/`
- [ ] Diff output matches the format alerts.sh and reporter.sh expect

**Engine to Alerts**
- [ ] alerts.sh correctly counts `[!]`, `[+]`, `[-]` lines
- [ ] Email sends when threshold is crossed
- [ ] Log file is written with correct format

**Engine to Reporter**
- [ ] reporter.sh can read diff output
- [ ] HTML report includes diff section
- [ ] gnuplot chart generates correctly

**CLI to Everything**
- [ ] Every command routes to correct module
- [ ] Config file values used as defaults
- [ ] Error messages are helpful not cryptic
- [ ] Exit codes are correct (0 = success, 1 = failure)

---

## Demo Day Checklist

Run this exact sequence during rehearsal and on evaluation day:

```bash
# 1. Setup
# Turn on personal hotspot
# Connect all team laptops and phones to it
# SSH into demo machine or sit at it directly

# 2. Initialize
./gitnet init

# 3. Baseline scan (evaluator watching)
./gitnet scan -m "Baseline scan"
./gitnet log

# 4. Show the baseline snapshot
./gitnet show HEAD

# 5. Make a live change (team member 2 opens HTTP server)
python3 -m http.server 8080 &

# 6. Scan again
./gitnet scan -m "Post change scan"

# 7. THE MOMENT
./gitnet diff HEAD~1 HEAD

# Expected output:
# [!] ANOMALY: Port 8080 OPENED on <ip> (<mac>)

# 8. Generate report
./gitnet report --format html
# Open gitnet_report.html in browser

# 9. Show history
./gitnet log

# 10. Optional: connect a phone, scan, show new device detected
# Disconnect phone, scan, show device offline
```

Total demo time: under 3 minutes if rehearsed properly.

---

*GitNet: CS2106 Scripting Workshop, Project 3*
*Evaluation: Nov 30 to Dec 2, 2026*
*Team of 5, pure bash, no Docker, no Python packages, no dependencies beyond standard Linux tools*