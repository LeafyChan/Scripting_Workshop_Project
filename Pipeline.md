# GitNet: Complete Pipeline and Role Guide
### Everything Each Team Member Needs to Know, Learn, and Build

This document is the single source of truth for the entire project. It reflects
the actual implemented code — not a theoretical spec. Read it fully before
writing or modifying any module.

Read your own role section completely before touching any code.
Read the full pipeline section regardless of your role.

---

## Table of Contents
- [The Full Pipeline](#the-full-pipeline)
- [How Modules Connect](#how-modules-connect)
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
┌───────────────────────────────────────────────────────────┐
│  gitnet (main CLI)                                        │
│  Parses command and flags                                 │
│  Acquires flock — prevents concurrent scans               │
│  Calls run_scan() from scanner.sh                         │
│  Then calls storage_commit() from storage.sh              │
│  Then calls engine_diff() from engine.sh                  │
│  Then calls alerts_process_diff() from alerts.sh          │
└───────────────────────┬───────────────────────────────────┘
                        │
                        ▼
┌───────────────────────────────────────────────────────────┐
│  scanner.sh — run_scan()                                  │
│  arp-scan discovers live hosts + MAC + vendor             │
│  Injects self (scanning machine) into results             │
│  nmap port scans each discovered host                     │
│  Resolves hostnames via reverse DNS                       │
│  Writes structured 7-field CSV to .gitnet/tmp/scan_$$.csv │
└───────────────────────┬───────────────────────────────────┘
                        │
                        ▼
┌───────────────────────────────────────────────────────────┐
│  storage.sh — storage_commit()                            │
│  sha1sum hashes the CSV content                           │
│  Stores CSV in .gitnet/objects/<blob_hash>.csv            │
│  Writes commit metadata to .gitnet/commits/<commit_hash>  │
│  Updates .gitnet/HEAD to new commit hash                  │
│  Logs entry to .gitnet/logs/commits.log                   │
└──────────────┬────────────────────────┬───────────────────┘
               │                        │
               ▼                        ▼
┌─────────────────────────┐  ┌──────────────────────────────┐
│  engine.sh              │  │  reporter.sh                  │
│  engine_diff_raw()      │  │  report_html()                │
│  Compares two CSVs      │  │  Walks commit chain           │
│  by MAC address         │  │  Generates gnuplot charts     │
│  Classifies anomalies   │  │  Embeds charts as base64      │
│  LOW / MED / HIGH       │  │  System health sidebar        │
│  Returns raw pipe lines │  │  Self-contained HTML output   │
│  engine_diff()          │  │  report_dashboard()           │
│  Renders coloured       │  │  Live terminal view           │
│  human-readable output  │  │                              │
└──────────────┬──────────┘  └──────────────────────────────┘
               │
               ▼
┌───────────────────────────────────────────────────────────┐
│  alerts.sh — alerts_process_diff()                        │
│  Reads raw diff lines from engine_diff_raw()              │
│  Classifies each anomaly by severity                      │
│  Writes to .gitnet/logs/alerts.log                        │
│  Sends mailx email if HIGH anomalies detected             │
│  alerts_check_probe_pattern()                             │
│  Scans alert log for repeated NEW_HOST from same MAC      │
│  Fires probe detection alert if threshold exceeded        │
└───────────────────────────────────────────────────────────┘
```

---

## How Modules Connect

This is the most important thing to understand before writing any code.

**The modules do NOT communicate through files at runtime.**
**They communicate through function calls within a single bash process.**

When `./gitnet` is launched, the very first thing it does is source all five
modules:

```bash
source "${SCRIPT_DIR}/core/storage.sh"
source "${SCRIPT_DIR}/core/scanner.sh"
source "${SCRIPT_DIR}/core/engine.sh"
source "${SCRIPT_DIR}/core/reporter.sh"
source "${SCRIPT_DIR}/core/alerts.sh"
```

Every function defined in every module becomes available to every other module.
`engine_diff_commits()` can call `storage_resolve_ref()` directly. `gitnet`
can call `run_scan()`, `storage_commit()`, `engine_diff_raw()`, and
`alerts_process_diff()` all in sequence within the same scan command.

**What this means for parallel development:**

Each person still owns exactly one file. Zero merge conflicts. But since all
modules share one bash namespace when sourced together, there are two rules:

Rule 1: Every function name must be prefixed with the module name.
```bash
# Good — unambiguous ownership
storage_commit()    # lives in storage.sh
scanner_run()       # lives in scanner.sh
engine_diff()       # lives in engine.sh

# Bad — will collide
commit()
run()
diff()
```

Rule 2: Every module-level variable must use a unique prefix or be declared
`local` inside functions. Global variables like `GITNET_DIR` are intentionally
shared and should not be redeclared.

**The only persistent communication between modules is the filesystem:**

```
.gitnet/
├── HEAD                         storage writes, engine and gitnet read
├── objects/<hash>.csv           storage writes, engine and reporter read
├── commits/<hash>               storage writes, engine and reporter read
├── logs/alerts.log              alerts writes, alerts reads
├── logs/commits.log             storage writes
├── logs/health.log              gitnet writes during scan
├── tmp/scan_$$.csv              scanner writes, storage reads, deleted after
└── config                       storage writes, all modules read
```

---

## The CSV Contract

This is the most critical section in the document. Every member must memorise
this format exactly. The code has been written against this spec. Deviating
from it breaks every downstream module.

### Format

```
IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP
```

### Rules

- Seven comma-separated fields per line, always
- First line is always the header row exactly as shown above
- Multiple ports are pipe-separated: `22|80|443`
- Multiple services are pipe-separated in the same order as ports: `ssh|http|https`
- If a host has no open ports, OPEN_PORTS is `none` and SERVICES is `none`
- HOSTNAME is the reverse DNS name or `unknown` if resolution fails
- TIMESTAMP is ISO-8601 UTC format: `2026-10-01T14:32:01Z`
- MAC is always uppercase with colons: `24:2F:D0:BD:17:40`
- No spaces around commas
- No trailing whitespace

### Why `none` not empty string

Empty strings make field counting ambiguous in awk. `none` is explicit and
engine.sh explicitly filters it: `if(op[i]!="none"&&op[i]!="")`. Always use
`none` for missing port and service data, never leave the field blank.

### Full Example

```
IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP
192.168.0.1,24:2F:D0:BD:17:40,Unknown,22|80|443,ssh|http|https,router.local,2026-10-01T14:32:01Z
192.168.0.170,08:9D:F4:4F:3D:0F,Intel Corporate,22,ssh,unknown,2026-10-01T14:32:01Z
192.168.0.248,0C:EF:15:88:F2:A6,Unknown,none,none,unknown,2026-10-01T14:32:01Z
192.168.0.155,14:B5:CD:4E:50:7B,Self,8080,http-proxy,sputnik-v2,2026-10-01T14:32:01Z
```

### Field Reference

| # | Field | Example | Notes |
|---|---|---|---|
| 1 | IP | 192.168.0.1 | IPv4 address |
| 2 | MAC_ADDRESS | 24:2F:D0:BD:17:40 | Always uppercase |
| 3 | MAC_VENDOR | Intel Corporate | `Unknown` or `Randomised-MAC` if not found |
| 4 | OPEN_PORTS | 22\|80\|443 | Pipe-separated, `none` if no open ports |
| 5 | SERVICES | ssh\|http\|https | Pipe-separated, matches OPEN_PORTS order, `none` if none |
| 6 | HOSTNAME | router.local | Reverse DNS result, `unknown` if unresolvable |
| 7 | TIMESTAMP | 2026-10-01T14:32:01Z | ISO-8601 UTC, same for all rows in one scan |

### Engine Validation

engine.sh validates this header on every diff. If your CSV has a different
header, engine.sh will refuse to process it with a clear error:

```bash
engine_validate_csv() checks:
"IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP"
```

Do not rename columns. Do not reorder columns. Do not add columns without
updating engine_validate_csv().

---

## Mock Data Files

Create these files on Day 1. Every member uses them to develop and test
independently without waiting for the real scanner to finish. These files
match the exact 7-field CSV contract the real scanner produces.

Save as `tests/mock_snapshot_1.csv`:
```
IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP
192.168.0.1,24:2F:D0:BD:17:40,Unknown,22|80|443,ssh|http|https,router.local,2026-10-01T10:00:00Z
192.168.0.170,08:9D:F4:4F:3D:0F,Intel Corporate,22,ssh,unknown,2026-10-01T10:00:00Z
192.168.0.248,0C:EF:15:88:F2:A6,Unknown,none,none,unknown,2026-10-01T10:00:00Z
192.168.0.127,7E:B7:CB:EA:7E:09,Randomised-MAC,none,none,unknown,2026-10-01T10:00:00Z
192.168.0.155,14:B5:CD:4E:50:7B,Self,none,none,sputnik-v2,2026-10-01T10:00:00Z
```

Save as `tests/mock_snapshot_2.csv`:
```
IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP
192.168.0.1,24:2F:D0:BD:17:40,Unknown,22|80|443,ssh|http|https,router.local,2026-10-01T11:00:00Z
192.168.0.170,08:9D:F4:4F:3D:0F,Intel Corporate,22|8080,ssh|http-proxy,unknown,2026-10-01T11:00:00Z
192.168.0.206,62:13:D5:E4:31:29,Randomised-MAC,none,none,unknown,2026-10-01T11:00:00Z
192.168.0.127,7E:B7:CB:EA:7E:09,Randomised-MAC,none,none,unknown,2026-10-01T11:00:00Z
192.168.0.155,14:B5:CD:4E:50:7B,Self,8080,http-proxy,sputnik-v2,2026-10-01T11:00:00Z
```

Changes between snapshot 1 and snapshot 2:
- `192.168.0.248` went offline (MAC `0C:EF:15:88:F2:A6` gone)
- `192.168.0.206` appeared as new device (MAC `62:13:D5:E4:31:29` new)
- `192.168.0.170` opened port 8080 (ports changed from `22` to `22|8080`)
- `192.168.0.155` (self) opened port 8080 (python3 -m http.server 8080)

These are exactly the anomaly types engine.sh must detect.

Save as `tests/mock_diff_output.txt` (raw pipe format from engine_diff_raw):
```
NEW_HOST|192.168.0.206||62:13:D5:E4:31:29|Randomised-MAC|none||none||2026-10-01T11:00:00Z
HOST_OFFLINE||192.168.0.248|0C:EF:15:88:F2:A6|Unknown||none||none|2026-10-01T11:00:00Z
PORT_OPENED|192.168.0.170||08:9D:F4:4F:3D:0F|Intel Corporate|8080||http-proxy||2026-10-01T11:00:00Z
PORT_OPENED|192.168.0.155||14:B5:CD:4E:50:7B|Self|8080||http-proxy||2026-10-01T11:00:00Z
```

Raw diff format: 10 pipe-separated fields:
```
TYPE|IP_NEW|IP_OLD|MAC|VENDOR|PORTS_NEW|PORTS_OLD|SVCS_NEW|SVCS_OLD|TIMESTAMP
```

Reporter and alerts use this mock diff to develop without waiting for engine.sh.

---

## Role 1: Scanner

**File:** `core/scanner.sh`
**Functions it exposes:** `run_scan()`, `scan_single_host()`
**Called by:** `gitnet` main CLI inside `cmd_scan()`
**Output:** `${GITNET_DIR}/tmp/scan_$$.csv` (7-field CSV)
**Everyone depends on you. This is the critical path.**

---

### What This Module Does

scanner.sh is the eyes of GitNet. Every time a scan is triggered it goes out
onto the network, finds every live device, records its IP, MAC, vendor,
hostname, and every open port with its service name. It writes all of this
into a 7-field CSV that storage.sh will then hash and commit.

It does four things in sequence:

1. `check_dependencies()` — exits immediately if nmap or arp-scan is missing
2. `run_arp_scan()` — Layer 2 ARP sweep to get all live hosts and their MACs
3. Self-injection — adds the scanning machine itself since arp-scan never returns it
4. `run_nmap_ports()` per host — TCP SYN scan for open ports and services
5. `resolve_hostname()` per host — reverse DNS lookup

The quality of this CSV determines everything downstream. A malformed line
breaks engine.sh's awk parser silently.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals (3 days)**

Variables always quoted:
```bash
NAME="GitNet"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
IP=$(ip -4 addr show dev eth2 | awk '/inet / { split($2,a,"/"); print a[1]; exit }')
```

Conditionals and exit codes:
```bash
if ! sudo arp-scan --version &>/dev/null; then
    echo "arp-scan not installed" >&2
    exit 1
fi

[ -f "$OUTPUT_CSV" ] || { echo "Missing output file" >&2; exit 1; }
```

All scanner status output goes to stderr so stdout stays clean for CSV:
```bash
log_info()  { echo -e "[SCAN] $*" >&2; }
log_error() { echo -e "[ERR]  $*" >&2; }
```

**Stage 2: arp-scan Output Parsing**

arp-scan output looks like:
```
Interface: eth2, type: EN10MB, MAC: 14:b5:cd:4e:50:7b, IPv4: 192.168.0.155
Starting arp-scan 1.10.0 with 256 hosts
192.168.0.1     24:2f:d0:bd:17:40       Unknown
192.168.0.170   08:9d:f4:4f:3d:0f       Intel Corporate
192.168.0.127   7e:b7:cb:ea:7e:09       (Unknown: locally administered)
```

Parse only data lines (start with IP pattern), skip headers:
```bash
sudo arp-scan --interface=eth2 --retry=2 --ignoredups 192.168.0.0/24 \
    | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\t/ {
        ip = $1
        mac = toupper($2)
        vendor = $0
        sub(/^[^\t]+\t[^\t]+\t/, "", vendor)
        gsub(/\(Unknown: locally administered\)/, "Randomised-MAC", vendor)
        vendor = (vendor == "" ? "Unknown" : vendor)
        print ip "\t" mac "\t" vendor
    }'
```

**Stage 3: nmap Grepable Output Parsing**

Run nmap with `-oG -` (grepable to stdout):
```bash
sudo nmap -sS -T4 -p 21,22,80,443,8080 --open -oG - 192.168.0.170
```

Output looks like:
```
Host: 192.168.0.170 ()	Ports: 22/open/tcp//ssh///, 8080/open/tcp//http-proxy///
```

Parse ports and services from the Ports: field:
```bash
echo "$raw" | awk '
/Ports:/ {
    match($0, /Ports: ([^\t]+)/, arr)
    split(arr[1], fields, ", ")
    for (i in fields) {
        split(fields[i], p, "/")
        if (p[2] == "open") {
            ports = (ports == "" ? p[1] : ports "|" p[1])
            svc   = (p[5] == "" ? "unknown" : p[5])
            svcs  = (svcs  == "" ? svc      : svcs  "|" svc)
        }
    }
    print (ports == "" ? "none" : ports) "|" (svcs == "" ? "none" : svcs)
}'
```

**Stage 4: Self-Injection**

arp-scan never returns the machine running the scan because ARP only returns
responses from other devices. We must add ourselves manually so our own open
ports are tracked:

```bash
self_ip=$(ip -4 addr show dev "$iface" | awk '/inet / { split($2,a,"/"); print a[1]; exit }')
self_mac=$(ip link show dev "$iface" | awk '/ether/ { print toupper($2); exit }')

# Only add if not already in results
if ! echo "$arp_results" | grep -q "^${self_ip}"; then
    arp_results="${arp_results}"$'\n'"${self_ip}"$'\t'"${self_mac}"$'\t'"Self"
fi
```

**Stage 5: Building the Final CSV**

Assemble all fields into one printf line per host:
```bash
printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$ip" "$mac" "$vendor" "$ports" "$services" "$hostname" "$ts" \
    >> "$output_csv"
```

---

### What Your Finished Code Must Do

1. Export `run_scan()` function that accepts: interface, subnet, output_csv
2. Auto-detect interface and subnet if not provided
3. Call `check_dependencies()` and exit 1 if tools are missing
4. Run arp-scan with `--retry=2 --ignoredups`
5. Inject self into results with vendor `Self`
6. Run nmap on each discovered host for port and service data
7. Resolve hostname via reverse DNS, use `unknown` on failure
8. Write header row first, then one row per host
9. Use `none` for OPEN_PORTS and SERVICES when no ports are open
10. All progress to stderr, only CSV to stdout (or directly to file)
11. Exit 0 on success, 1 on failure
12. Handle zero hosts discovered gracefully (write header only, log warning)

---

### Test Your Module

```bash
# Direct execution mode
bash core/scanner.sh eth2 192.168.0.0/24 /tmp/test_scan.csv

# Verify 7 fields per data line
awk -F, 'NR>1 && NF!=7 {print "BAD LINE:", NR, NF, "fields:", $0}' /tmp/test_scan.csv

# Verify header
head -1 /tmp/test_scan.csv
# Expected: IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP

# Verify none used for empty ports (no blank fields)
grep -P ',,' /tmp/test_scan.csv && echo "FAIL: blank fields found" || echo "PASS"
```

---

### Common Mistakes to Avoid

Never hardcode the interface. Read from config or accept as argument.
Never leave blank fields. Use `none` for missing port/service data.
Never include arp-scan header lines in output. The awk pattern filters by IP.
Always handle hosts that go offline between arp-scan and nmap.
Always quote variables in awk calls to avoid word-splitting.

---

## Role 2: Storage Engine

**File:** `core/storage.sh`
**Functions it exposes:** `storage_init()`, `storage_commit()`, `storage_log()`,
`storage_show()`, `storage_resolve_ref()`, `storage_get_blob_for_commit()`,
`storage_read_config()`, `storage_write_config()`, `storage_check_init()`,
`storage_status()`, `storage_rotate_logs()`
**Called by:** `gitnet` main CLI for all commit and history operations
**Input:** CSV from scanner.sh via `.gitnet/tmp/scan_$$.csv`
**Output:** Objects in `.gitnet/objects/`, commits in `.gitnet/commits/`, HEAD

---

### What This Module Does

storage.sh is the memory of GitNet. It implements a real Git-style content
addressable object store in pure bash.

When a scan CSV arrives, storage_commit():
1. Hashes the CSV with sha1sum to get the blob hash
2. Stores the CSV as `.gitnet/objects/<blob_hash>.csv` (immutable, chmod 444)
3. Hashes the commit metadata itself to get the commit hash
4. Writes commit metadata to `.gitnet/commits/<commit_hash>`
5. Updates `.gitnet/HEAD` with the new commit hash
6. Appends to `.gitnet/logs/commits.log`

This is exactly how real Git works. Identical network states produce identical
blob hashes so duplicate snapshots are never stored.

The commit metadata format (flat key=value file):
```
blob=<sha1 of CSV>
parent=<sha1 of previous commit | none>
timestamp=2026-10-01T14:32:01Z
message=Baseline scan
hosts=5
```

---

### What You Need to Learn

**Stage 1: Bash Fundamentals (2 days)**

Same as Role 1. Variables, conditionals, loops, pipes, redirection.

**Stage 2: sha1sum and Content Addressable Storage**

```bash
# Hash a file
HASH=$(sha1sum snapshot.csv | awk '{print $1}')

# macOS uses shasum instead
HASH=$(shasum -a 1 snapshot.csv | awk '{print $1}')

# Portable wrapper (the actual implementation)
_sha1() {
    if command -v sha1sum &>/dev/null; then
        sha1sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 1 "$1" | awk '{print $1}'
    fi
}

# Hash a string (for commit hash)
COMMIT_HASH=$(echo "$commit_body" | sha1sum | awk '{print $1}')
```

Why content addressable: same network state always produces same hash. If
you run two scans and nothing changed, the blob hash is identical and storage
skips writing the duplicate.

**Stage 3: Flat Key=Value File Handling**

Reading config values with awk:
```bash
storage_read_config() {
    local key="$1"
    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        $1 == k          { print $2; exit }
    ' "${GITNET_DIR}/config"
}
```

Writing config values with sed in-place:
```bash
storage_write_config() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${GITNET_DIR}/config"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${GITNET_DIR}/config"
    else
        echo "${key}=${value}" >> "${GITNET_DIR}/config"
    fi
}
```

**Stage 4: HEAD and Parent Chain**

HEAD is a plain text file containing one commit hash:
```bash
# Read HEAD
current=$(cat "${GITNET_DIR}/HEAD")

# Update HEAD
echo "$commit_hash" > "${GITNET_DIR}/HEAD"

# Read parent from commit metadata
parent=$(awk -F= '$1=="parent"{print $2}' "${GITNET_DIR}/commits/${current}")
```

Traversing ancestry for HEAD~N:
```bash
# Go back N commits from HEAD
current=$(cat "${GITNET_DIR}/HEAD")
for (( i=0; i<N; i++ )); do
    parent=$(awk -F= '$1=="parent"{print $2}' \
        "${GITNET_DIR}/commits/${current}")
    [[ "$parent" == "none" ]] && { echo "Not enough commits"; exit 1; }
    current="$parent"
done
echo "$current"
```

**Stage 5: flock for Concurrency Safety**

The gitnet CLI wraps the entire scan+commit in flock (not storage.sh itself).
But you need to understand why: if cron triggers an auto-scan while a user
runs a manual scan, both would write to HEAD simultaneously causing corruption.

```bash
# In gitnet cmd_scan():
(
    flock -x -w 10 200 || { echo "Another scan running"; exit 1; }
    # Everything here runs exclusively
    run_scan ...
    storage_commit ...
) 200>"${GITNET_DIR}/lockfile"
```

**Stage 6: Displaying Commit History**

Walk the parent chain from HEAD backwards:
```bash
local current=$(cat "${GITNET_DIR}/HEAD")
while [[ "$current" != "none" ]]; do
    local commit_file="${GITNET_DIR}/commits/${current}"
    [[ -f "$commit_file" ]] || break

    ts=$(awk -F= '$1=="timestamp"{print $2}' "$commit_file")
    msg=$(awk -F= '$1=="message"{print $2}' "$commit_file")
    hosts=$(awk -F= '$1=="hosts"{print $2}' "$commit_file")
    parent=$(awk -F= '$1=="parent"{print $2}' "$commit_file")

    printf "%-10s  %s  %s hosts  %s\n" "${current:0:8}" "$ts" "$hosts" "$msg"

    current="$parent"
done
```

---

### What Your Finished Code Must Do

**storage_init():**
1. Create `.gitnet/objects/`, `.gitnet/commits/`, `.gitnet/logs/`, `.gitnet/tmp/`
2. Write `none` to `.gitnet/HEAD`
3. Write default config file with interface, subnet, alert_email, port_list, etc.
4. Write `.gitnet/.gitignore` to keep objects out of team git repo
5. Safe to re-run, warn if already initialised

**storage_commit():**
1. Accept snapshot CSV path and commit message
2. Compute blob hash with `_sha1()`
3. Copy CSV to `.gitnet/objects/<blob_hash>.csv` with `chmod 444`
4. Skip copy if identical blob already exists (deduplicate)
5. Read parent from current HEAD
6. Count hosts from CSV (rows minus header)
7. Build commit body string, hash it to get commit hash
8. Write commit metadata to `.gitnet/commits/<commit_hash>`
9. Update HEAD, append to commits.log
10. Return commit hash on stdout

**storage_resolve_ref():**
1. `HEAD` returns current commit hash
2. `HEAD~N` traverses N parents and returns that hash
3. Hash prefix (6+ chars) finds matching commit file
4. Exit 1 with clear error if ref not found

**storage_get_blob_for_commit():**
1. Accept commit hash
2. Read blob field from commit metadata
3. Return full path: `.gitnet/objects/<blob_hash>.csv`

---

### Test Your Module

```bash
# Init
bash core/storage.sh init

# Commit mock snapshot 1
bash core/storage.sh commit tests/mock_snapshot_1.csv "First scan"
cat .gitnet/HEAD

# Commit mock snapshot 2
bash core/storage.sh commit tests/mock_snapshot_2.csv "Second scan"

# Verify parent chain
bash core/storage.sh log

# Resolve refs
bash core/storage.sh show HEAD
bash core/storage.sh show HEAD~1

# Verify deduplication: committing same CSV twice should warn, not duplicate
bash core/storage.sh commit tests/mock_snapshot_2.csv "Duplicate test"
ls .gitnet/objects/ | wc -l   # should still be 2, not 3
```

---

## Role 3: Diff and Anomaly Engine

**File:** `core/engine.sh`
**Functions it exposes:** `engine_diff()`, `engine_diff_raw()`,
`engine_classify_severity()`, `engine_validate_csv()`, `engine_diff_commits()`
**Called by:** `gitnet` main CLI after each scan and for `gitnet diff` command
**Input:** Two CSV file paths from `.gitnet/objects/`
**Output:** Coloured terminal diff + raw pipe-separated anomaly lines

**This is the hardest module. The entire analytical value of GitNet lives here.**

---

### What This Module Does

engine.sh is the brain of GitNet. Given two network snapshots, it determines
exactly what changed between them. Not by comparing text lines, but by
comparing devices by their MAC address.

Why MAC and not IP: if a phone's IP changes from `.10` to `.15` due to DHCP,
IP-based comparison would wrongly report one device disappearing and a new
unknown device appearing. MAC-based comparison correctly identifies it as the
same device with a new IP and reports `IP_CHANGED` at severity LOW.

Six anomaly types are classified:

| Type | Severity | Meaning |
|---|---|---|
| `NEW_HOST` | HIGH | MAC never seen before appeared on network |
| `PORT_OPENED` | HIGH | A port that was closed is now open |
| `HOST_OFFLINE` | LOW | MAC present in old snapshot, absent in new |
| `PORT_CLOSED` | MED | A port that was open is now closed |
| `SERVICE_CHANGED` | MED | Same port, different service banner |
| `IP_CHANGED` | LOW | Same MAC, different IP (DHCP reassignment) |

Two output modes:

`engine_diff_raw()` — machine readable, one anomaly per line:
```
TYPE|IP_NEW|IP_OLD|MAC|VENDOR|PORTS_NEW|PORTS_OLD|SVCS_NEW|SVCS_OLD|TIMESTAMP
```

`engine_diff()` — human readable, coloured terminal output, calls diff_raw
internally.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals (3 days)**

Same as previous roles. This module uses bash more heavily than any other.

**Stage 2: awk Associative Arrays**

This is the single most important skill for this module. Spend two days
specifically practising this before writing engine.sh.

Basic associative array:
```bash
awk '{
    count[$1]++
}
END {
    for (key in count) print key, count[key]
}' file.txt
```

**Stage 3: The NR==FNR Pattern for Two-File Comparison**

This is the exact core of engine_diff_raw(). Understand it completely.

```bash
awk -F',' '
NR == FNR {
    # This block runs ONLY while reading the FIRST file
    # NR = total line number across all files
    # FNR = line number within current file
    # NR==FNR is only true when both are equal, i.e. first file only
    if (NR == 1) next          # skip header
    mac = $2
    old_ip[mac]    = $1
    old_ports[mac] = $4
    old_svcs[mac]  = $5
    next
}
# Everything below runs ONLY for the SECOND file
FNR == 1 { next }              # skip header of second file
{
    mac = $2; new_ip = $1
    seen_in_new[mac] = 1

    if (!(mac in old_ip)) {
        print "NEW_HOST|" new_ip "||" mac "|" $3 "|" $4 "||" $5 "||" ts
        next
    }

    if (new_ip != old_ip[mac]) {
        print "IP_CHANGED|" new_ip "|" old_ip[mac] "|" mac "|||||||" ts
    }

    # Port comparison happens here (see Stage 4)
}
END {
    for (mac in old_ip)
        if (!(mac in seen_in_new))
            print "HOST_OFFLINE||" old_ip[mac] "|" mac "||||||" ts
}
' old_snapshot.csv new_snapshot.csv
```

Practise this exact pattern on the mock CSV files before writing engine.sh.

**Stage 4: Port Set Comparison in awk**

Finding which ports opened and which closed between two snapshots:

```bash
awk -v old_ports="22|80|443" -v new_ports="22|80|8080" 'BEGIN {
    # Build sets from pipe-separated strings
    n_old = split(old_ports, op, "|")
    n_new = split(new_ports, np, "|")

    for (i=1; i<=n_old; i++) if (op[i]!="none"&&op[i]!="") old_set[op[i]] = 1
    for (i=1; i<=n_new; i++) if (np[i]!="none"&&np[i]!="") new_set[np[i]] = 1

    # Find opened (in new but not in old)
    for (p in new_set)
        if (!(p in old_set)) print "PORT_OPENED:", p

    # Find closed (in old but not in new)
    for (p in old_set)
        if (!(p in new_set)) print "PORT_CLOSED:", p
}'
# Output:
# PORT_OPENED: 8080
# PORT_CLOSED: 443
```

The actual engine.sh runs this logic inside the main NR==FNR awk program
using `delete om; delete nm` to reset the port sets between hosts.

**Stage 5: Ref Resolution**

engine_diff_commits() accepts refs like HEAD and HEAD~1 and resolves them
via storage_resolve_ref() (available because storage.sh is sourced):

```bash
engine_diff_commits() {
    local ref_old="$1"
    local ref_new="${2:-HEAD}"

    local hash_old hash_new blob_old blob_new
    hash_old=$(storage_resolve_ref "$ref_old") || return 1
    hash_new=$(storage_resolve_ref "$ref_new") || return 1
    blob_old=$(storage_get_blob_for_commit "$hash_old") || return 1
    blob_new=$(storage_get_blob_for_commit "$hash_new") || return 1

    engine_diff "$blob_old" "$blob_new"
}
```

**Stage 6: Severity Classification and Exit Codes**

engine_diff() returns exit code 2 if HIGH severity anomalies were found.
The gitnet CLI uses this to decide whether to trigger alerts:

```bash
# In gitnet cmd_scan():
engine_diff "$old_blob" "$new_blob" 2>/dev/null || true

# engine_diff() returns:
# 0 = no changes
# 2 = HIGH severity anomalies (new hosts or opened ports)
# 1 = validation error
```

---

### What Your Finished Code Must Do

**engine_validate_csv():**
1. Check file exists
2. Check header matches exactly: `IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP`
3. Return 1 with clear error if either check fails

**engine_diff_raw():**
1. Accept two CSV file paths
2. Validate both with `engine_validate_csv()`
3. Use awk NR==FNR pattern with MAC as primary key
4. Detect all 6 anomaly types
5. Handle port set comparison per host (delete arrays between hosts)
6. Emit one pipe-separated line per anomaly to stdout
7. All 10 fields present even if some are empty

**engine_diff():**
1. Call `engine_diff_raw()` internally
2. Print coloured header with old and new snapshot timestamps and host counts
3. Print each anomaly with colour coded severity icon
4. Print summary counts at bottom
5. Return exit code 2 if any HIGH anomalies detected

**engine_classify_severity():**
1. Accept anomaly type string
2. Return `HIGH`, `MED`, or `LOW`

---

### Test Your Module

```bash
# First need storage.sh to commit mock snapshots
source core/storage.sh
storage_init
storage_commit tests/mock_snapshot_1.csv "Snapshot 1"
HASH1=$(cat .gitnet/HEAD)
storage_commit tests/mock_snapshot_2.csv "Snapshot 2"
HASH2=$(cat .gitnet/HEAD)

# Get blob paths
BLOB1=$(storage_get_blob_for_commit "$HASH1")
BLOB2=$(storage_get_blob_for_commit "$HASH2")

# Test raw diff
source core/engine.sh
engine_diff_raw "$BLOB1" "$BLOB2"

# Expected: lines starting with NEW_HOST, HOST_OFFLINE, PORT_OPENED

# Test human diff
engine_diff "$BLOB1" "$BLOB2"

# Test via ref resolution
engine_diff_commits HEAD~1 HEAD

# Verify exit code
engine_diff "$BLOB1" "$BLOB2"; echo "Exit code: $?"
# Expected: Exit code: 2 (HIGH anomalies present)
```

---

## Role 4: Reporter

**File:** `core/reporter.sh`
**Functions it exposes:** `report_html()`, `report_csv()`,
`report_system_health()`, `report_dashboard()`
**Called by:** `gitnet` main CLI for `gitnet report` command
**Input:** Commit history from `.gitnet/commits/`, diff output from engine.sh
**Output:** `gitnet_reports/report.html`, `gitnet_reports/history.csv`

---

### What This Module Does

reporter.sh is the face of GitNet. It turns raw commit history and diffs into
things a human actually wants to look at.

Four functions:

`report_system_health()` — reads CPU, RAM, disk, uptime from the OS and
returns them as a parseable string: `cpu=12.3 ram=45.6 disk=23 uptime=2days`.
Called by gitnet during every scan to log health alongside network state.

`report_html()` — walks the full commit chain, calls `engine_diff_raw()` between
consecutive commits to count anomalies per scan, generates two gnuplot charts
(host count trend, anomaly frequency trend), embeds them as base64 in a
self-contained dark-theme HTML file with a commit history table and system
health bars. No external dependencies: the HTML file works offline.

`report_csv()` — exports the commit history as a flat CSV for spreadsheet
analysis.

`report_dashboard()` — a live terminal view that clears the screen, draws a
system health bar chart, and shows the latest snapshot as a column-aligned
table. Useful for checking network state at a glance without opening a browser.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals (2 days)**

Same as all other roles. Variables, conditionals, loops, pipes.

**Stage 2: Reading System Health Stats**

Linux CPU from /proc/stat (two-sample method):
```bash
s1=$(awk '/^cpu / {print $2+$3+$4+$5, $5}' /proc/stat)
sleep 1
s2=$(awk '/^cpu / {print $2+$3+$4+$5, $5}' /proc/stat)
cpu=$(awk -v s1="$s1" -v s2="$s2" 'BEGIN {
    split(s1, a, " "); split(s2, b, " ")
    total = b[1]-a[1]; idle = b[2]-a[2]
    printf "%.1f", (total-idle)/total*100
}')
```

Memory usage:
```bash
ram=$(free | awk '/^Mem:/ { printf "%.1f", $3/$2*100 }')
```

Disk usage:
```bash
disk=$(df -h / | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')
```

macOS alternatives use `vm_stat` and `top -l 1`. Both are handled in the
actual implementation with OS detection.

**Stage 3: Walking the Commit Chain**

The commit chain is a linked list: HEAD points to latest commit, each commit
has a parent field pointing to the previous one.

```bash
local current=$(cat "${GITNET_DIR}/HEAD")
while [[ "$current" != "none" ]]; do
    local commit_file="${GITNET_DIR}/commits/${current}"
    [[ -f "$commit_file" ]] || break

    blob=$(awk -F= '$1=="blob"{print $2}' "$commit_file")
    ts=$(awk -F= '$1=="timestamp"{print $2}' "$commit_file")
    msg=$(awk -F= '$1=="message"{print $2}' "$commit_file")
    hosts=$(awk -F= '$1=="hosts"{print $2}' "$commit_file")
    parent=$(awk -F= '$1=="parent"{print $2}' "$commit_file")

    # Process this commit
    echo "$ts $hosts $msg"

    current="$parent"
done
```

To get chronological order (oldest first), collect all into an array then
iterate in reverse. This is exactly what `_collect_history_data()` does.

**Stage 4: gnuplot Chart Generation**

gnuplot reads a space-separated data file and writes a PNG:

```bash
# Build data file: scan_number host_count
scan=1
while IFS= read -r line; do
    hosts=$(echo "$line" | awk '{print $2}')
    echo "$scan $hosts" >> /tmp/host_trend.dat
    (( scan++ ))
done < commit_history.txt

# Generate chart
gnuplot << 'GNUPLOT'
set terminal png size 800,350 enhanced font "Sans,11"
set output "/tmp/chart_hosts.png"
set title "Active Hosts Over Time"
set xlabel "Scan Number"
set ylabel "Host Count"
set grid ytics
set key off
plot "/tmp/host_trend.dat" using 1:2 with linespoints lc rgb "#2196F3" lw 2 pt 7
GNUPLOT
```

**Stage 5: Base64 Embedding for Self-Contained HTML**

Embedding the PNG chart directly in HTML so the report works without external files:

```bash
# Encode PNG as base64
chart_b64=$(base64 -w0 chart_hosts.png)

# Embed in HTML
echo "<img src=\"data:image/png;base64,${chart_b64}\" alt=\"Host Trend\">"
```

On macOS, `base64` does not take `-w0`. Use `base64 chart_hosts.png` without
the flag. The actual implementation handles both.

**Stage 6: Here Documents for HTML Generation**

Generating multi-line HTML with bash variable interpolation:

```bash
cat > report.html << HTML
<!DOCTYPE html>
<html>
<head><title>GitNet Report - ${ts}</title></head>
<body>
  <h1>GitNet Network Report</h1>
  <p>Generated: ${ts}</p>
  <p>Total scans: ${total_commits}</p>
  <p>CPU: ${h_cpu}%  RAM: ${h_ram}%  Disk: ${h_disk}%</p>
</body>
</html>
HTML
```

Variables inside the here document are expanded automatically. Use single
quotes on the delimiter (`<< 'HTML'`) only if you want literal dollar signs.

---

### What Your Finished Code Must Do

**report_system_health():**
1. Sample CPU using /proc/stat on Linux, top on macOS
2. Read RAM using `free` on Linux, `vm_stat` on macOS
3. Read disk with `df -h /`
4. Read uptime with `uptime`
5. Print one line: `cpu=N ram=N disk=N uptime=N`

**report_html():**
1. Call `_collect_history_data()` to walk commit chain
2. For each consecutive commit pair, call `engine_diff_raw()` to count anomalies
3. Write host count and anomaly count data files for gnuplot
4. Generate two PNG charts with gnuplot
5. Base64-encode both charts
6. Get current system health via `report_system_health()`
7. Write self-contained HTML with embedded charts, commit table, health bars
8. Return path to HTML file on stdout

**report_csv():**
1. Walk commit chain
2. Write header: `commit_hash,blob_hash,timestamp,message,host_count,parent`
3. Write one row per commit
4. Return path to CSV file on stdout

**report_dashboard():**
1. Clear screen
2. Print ASCII banner
3. Call `report_system_health()` and draw progress bars
4. Read latest snapshot from HEAD
5. Display as column-aligned table with `column -t -s','`

---

### Test Your Module

```bash
# Requires commits to exist first
source core/storage.sh
source core/engine.sh
source core/reporter.sh

storage_init
storage_commit tests/mock_snapshot_1.csv "Scan 1"
storage_commit tests/mock_snapshot_2.csv "Scan 2"

# System health
report_system_health

# HTML report
report_html
# Open the report
xdg-open gitnet_reports/report.html   # Linux
open gitnet_reports/report.html       # Mac

# CSV export
report_csv
cat gitnet_reports/history.csv

# Terminal dashboard
report_dashboard
```

---

## Role 5: CLI and Alerts

**Files:** `gitnet` (main entry point) + `core/alerts.sh`
**Functions gitnet exposes:** All `cmd_*` functions
**Functions alerts exposes:** `alerts_process_diff()`, `alerts_check_probe_pattern()`,
`alerts_status()`
**Called by:** User directly. alerts functions called by gitnet after each scan.

---

### What This Module Does

The `gitnet` file is the front door of the entire project. Every command the
user types goes through here. It sources all other modules, parses arguments,
acquires the flock lock for scans, and orchestrates the full pipeline.

`alerts.sh` runs after every diff. It reads the raw pipe-separated diff output
from `engine_diff_raw()`, classifies each anomaly by severity, writes to the
persistent alert log, and fires an email via mailx if HIGH anomalies are found.

It also implements frequency analysis: `alerts_check_probe_pattern()` scans
the last N minutes of `alerts.log` for repeated `NEW_HOST` events from the
same MAC address. If the count exceeds a threshold it fires a probe detection
alert. This is the Project 6 (Log Analyzer) integration.

---

### What You Need to Learn

**Stage 1: Bash Fundamentals (3 days)**

More than any other role you need bash fundamentals solid because you are
writing the glue holding everything together.

**Stage 2: case Statement Command Routing**

```bash
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        init)     cmd_init     "$@" ;;
        scan)     cmd_scan     "$@" ;;
        log)      cmd_log      "$@" ;;
        diff)     cmd_diff     "$@" ;;
        show)     cmd_show     "$@" ;;
        report)   cmd_report   "$@" ;;
        schedule) cmd_schedule "$@" ;;
        alert)    cmd_alert    "$@" ;;
        status)   storage_status   ;;
        config)   cmd_config   "$@" ;;
        version)  cmd_version       ;;
        help|-h|--help) cmd_help "$@" ;;
        *)
            echo "Unknown command: $command"
            exit 1
            ;;
    esac
}

main "$@"
```

`shift || true` removes the first positional argument and passes the rest as
`$@` to each command handler.

**Stage 3: getopts for Flag Parsing**

```bash
cmd_scan() {
    local message="Auto scan"
    local interface="" subnet=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--message)   message="${2:-Auto scan}"; shift 2 ;;
            -i|--interface) interface="$2";            shift 2 ;;
            -s|--subnet)    subnet="$2";               shift 2 ;;
            -q|--quiet)     exec 2>/dev/null;          shift   ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Now message, interface, subnet are set
}
```

**Stage 4: flock for Concurrency**

The entire scan pipeline runs inside a flock-protected subshell:

```bash
local lock_file="${GITNET_DIR}/lockfile"
(
    flock -x -w 10 200 || {
        echo "Another scan is already running"
        exit 1
    }

    # Everything here is exclusive
    run_scan "$interface" "$subnet" "$tmp_csv"
    storage_commit "$tmp_csv" "$message"
    engine_diff "$old_blob" "$new_blob"
    alerts_process_diff "$raw_diff"
    alerts_check_probe_pattern

) 200>"$lock_file"
```

`200` is the file descriptor. `200>"$lock_file"` opens the lockfile on FD 200.
`flock -x -w 10 200` acquires an exclusive lock on FD 200, waiting up to 10
seconds.

**Stage 5: Parsing Raw Diff in alerts_process_diff()**

The raw diff from engine_diff_raw() is a multi-line string of pipe-separated
records. alerts_process_diff() reads it line by line:

```bash
alerts_process_diff() {
    local raw_diff="$1"
    [[ -z "$raw_diff" ]] && return 0

    while IFS='|' read -r type ip_new ip_old mac vendor \
                         ports_new ports_old svcs_new svcs_old ts; do
        case "$type" in
            NEW_HOST)
                sev="HIGH"
                detail="New host ${ip_new} (MAC: ${mac} / ${vendor})"
                (( new_host_count++ )) || true
                ;;
            PORT_OPENED)
                sev="HIGH"
                detail="Port ${ports_new} opened on ${ip_new} (${svcs_new})"
                (( port_open_count++ )) || true
                ;;
            HOST_OFFLINE)
                sev="LOW"
                detail="Host ${ip_old} (MAC: ${mac}) went offline"
                ;;
        esac

        _write_alert_log "$type" "$sev" "$detail"
    done <<< "$raw_diff"
}
```

**Stage 6: Frequency Analysis with awk (Project 6 integration)**

`alerts_check_probe_pattern()` reads alerts.log and looks for repeated NEW_HOST
events from the same MAC within a time window:

```bash
awk -F' | ' -v since_iso="$since_iso" -v threshold="$probe_threshold" '
    NF < 4 { next }
    {
        ts = $1; type = $3; detail = $4
        if (type != "NEW_HOST") next
        if (ts < since_iso) next       # ISO-8601 sorts lexicographically
        # Extract MAC from detail string
        tmp = detail
        sub(/.*MAC: /, "", tmp)
        sub(/ .*/, "", tmp)
        mac = tmp
        if (mac ~ /^[0-9A-Fa-f:]+$/) count[mac]++
    }
    END {
        for (mac in count)
            if (count[mac] >= threshold)
                print "PROBE|" mac "|" count[mac]
    }
' "${GITNET_DIR}/logs/alerts.log"
```

**Stage 7: cron Scheduling**

```bash
cmd_schedule() {
    local interval="$1"   # e.g. "30m" or "2h"

    local cron_expr
    if [[ "$interval" =~ ^([0-9]+)m$ ]]; then
        cron_expr="*/${BASH_REMATCH[1]} * * * *"
    elif [[ "$interval" =~ ^([0-9]+)h$ ]]; then
        cron_expr="0 */${BASH_REMATCH[1]} * * *"
    fi

    local gitnet_path=$(realpath "${BASH_SOURCE[0]}")
    local working_dir=$(pwd)
    local cron_line="${cron_expr} cd ${working_dir} && ${gitnet_path} scan -m 'Auto scan'"

    # Remove old gitnet entries then add new one
    ( crontab -l 2>/dev/null | grep -v "gitnet scan"; echo "$cron_line" ) | crontab -
}
```

**Stage 8: mailx Email Sending**

```bash
_send_email() {
    local subject="$1"
    local body_file="$2"

    local email=$(storage_read_config "alert_email")
    [[ -z "$email" ]] && return 0

    # Try mailx first, fall back to mail
    local mailer="mailx"
    command -v mailx &>/dev/null || mailer="mail"

    $mailer -s "[GitNet Alert] ${subject}" "$email" < "$body_file"
}
```

---

### What Your Finished Code Must Do

**gitnet main CLI:**
1. Source all five core modules at startup
2. Route every command to correct `cmd_*` function
3. Parse all flags correctly per command
4. Load config defaults from `.gitnet/config`
5. Check `.gitnet/` exists before any command except `init` and `help`
6. Wrap scan pipeline in flock with 10-second timeout
7. Show helpful error for unknown commands
8. `gitnet version` shows all tool paths and install status

**alerts_process_diff():**
1. Accept raw diff string (pipe-separated lines from engine_diff_raw)
2. Parse each line with `IFS='|' read -r type ip_new ip_old mac ...`
3. Classify severity per type
4. Write structured entry to `.gitnet/logs/alerts.log`
5. Count HIGH anomalies and send email if any found

**alerts_check_probe_pattern():**
1. Read `.gitnet/logs/alerts.log`
2. Filter to current time window using ISO-8601 string comparison
3. Count NEW_HOST events per MAC address
4. Fire probe alert if any MAC exceeds threshold

**alerts_status():**
1. Accept optional count argument
2. Tail `.gitnet/logs/alerts.log` for last N entries
3. Print with colour coded severity

**cmd_schedule():**
1. Parse `--interval Nm` and `--interval Nh`
2. Convert to cron expression
3. Remove existing gitnet cron entries before adding new one
4. Support `--remove` and `--status` flags

---

### Test Your Module

```bash
# Test full pipeline
./gitnet init
./gitnet scan -m "Test scan"
./gitnet log
./gitnet diff HEAD~1 HEAD
./gitnet report --format html --open

# Test scheduling
./gitnet schedule --interval 30m
crontab -l | grep gitnet
./gitnet schedule --remove
crontab -l | grep gitnet   # should be empty

# Test alerts
./gitnet alert --email test@example.com
./gitnet alert --status
./gitnet alert --probe

# Test config
./gitnet config interface eth2
./gitnet config interface

# Test version
./gitnet version

# Test unknown command
./gitnet invalidcommand
echo "Exit code: $?"   # should be 1
```

---

## Integration Checklist

Run this during Week 5 when connecting all modules for the first time.

**Scanner to Storage**
- [ ] `run_scan()` writes CSV to `${GITNET_DIR}/tmp/scan_$$.csv`
- [ ] CSV has exactly 7 fields per data row
- [ ] Header matches: `IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP`
- [ ] `none` used for empty ports and services, no blank fields
- [ ] `storage_commit()` reads the tmp CSV, hashes, stores correctly
- [ ] `storage_commit()` returns commit hash on stdout

**Storage to Engine**
- [ ] `storage_resolve_ref("HEAD")` returns current commit hash
- [ ] `storage_resolve_ref("HEAD~1")` returns parent hash
- [ ] `storage_get_blob_for_commit()` returns valid CSV file path
- [ ] `engine_validate_csv()` passes on real scanner output

**Engine to Alerts**
- [ ] `engine_diff_raw()` produces pipe-separated lines matching 10-field format
- [ ] `alerts_process_diff()` parses all 6 anomaly types correctly
- [ ] Alert log written to `.gitnet/logs/alerts.log`
- [ ] Email fires when HIGH anomalies present (if email configured)

**Engine to Reporter**
- [ ] `_collect_history_data()` correctly walks commit chain
- [ ] `engine_diff_raw()` called between consecutive blobs produces anomaly counts
- [ ] gnuplot chart data files have correct format (two columns: scan_num count)
- [ ] HTML report opens in browser and charts are visible

**gitnet CLI to Everything**
- [ ] All five modules source without error
- [ ] Every command routes to correct function
- [ ] flock prevents concurrent scans (test by running two scans simultaneously)
- [ ] Config values used as defaults when flags not provided
- [ ] Error messages on missing `.gitnet/` directory

---

## Demo Day Checklist

Run this exact sequence during rehearsal and on evaluation day.

```bash
# Environment setup
# Turn on personal hotspot
# Connect all 5 team laptops to it
# Sit at the demo laptop (the one with WSL mirrored networking or native Linux)

# Step 1: Show the project structure
ls -la
ls -la core/

# Step 2: Initialize
./gitnet init
cat .gitnet/config

# Step 3: Baseline scan
./gitnet scan -m "Baseline scan"
./gitnet log
./gitnet show HEAD

# Step 4: Make a live change (team member starts HTTP server)
# On team laptop 2:
python3 -m http.server 8080 &

# Step 5: Second scan
./gitnet scan -m "Post change scan"

# Step 6: THE MOMENT — live diff
./gitnet diff HEAD~1 HEAD

# Expected output includes:
# [!] PORT_OPENED
#     IP    : 192.168.43.X
#     MAC   : XX:XX:XX:XX:XX:XX  (vendor)
#     Port  : +8080/tcp  (http-proxy)

# Step 7: Report
./gitnet report --format html --open

# Step 8: Optional extras for evaluators
# Connect a phone to the hotspot
./gitnet scan -m "Phone connected"
./gitnet diff HEAD~1 HEAD
# Shows NEW_HOST

# Disconnect the phone
./gitnet scan -m "Phone disconnected"
./gitnet diff HEAD~1 HEAD
# Shows HOST_OFFLINE

# Step 9: Show alert log
./gitnet alert --status

# Step 10: Show scheduling
./gitnet schedule --interval 30m
crontab -l | grep gitnet
./gitnet schedule --remove
```

Total demo time: under 4 minutes if rehearsed properly.

---

## File Size Reference

Actual line counts of the implemented modules:

| File | Lines | Complexity |
|---|---|---|
| `core/scanner.sh` | 377 | Medium-High |
| `core/storage.sh` | 483 | Medium |
| `core/engine.sh` | 334 | High |
| `core/alerts.sh` | 306 | Medium |
| `core/reporter.sh` | 531 | Medium-High |
| `gitnet` | 564 | Medium |
| **Total** | **2595** | |

---

*GitNet: CS2106 Scripting Workshop, Project 3*
*Evaluation: Nov 30 to Dec 2, 2026*
*Team of 5 | Pure bash | No Docker | No Python packages | No dependencies beyond standard Linux tools*