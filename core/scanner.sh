#!/usr/bin/env bash

GITNET_DIR="${GITNET_DIR:-.gitnet}"
SCANNER_CSV_HEADER="IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP"
SCANNER_DEFAULT_PORTS="21,22,23,25,53,80,110,139,443,445,3306,3389,5900,8000,8080,8443"

case ":$PATH:" in
    *:/usr/sbin:*) ;;
    *) PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin:/opt/homebrew/sbin" ;;
esac

log_info()  { echo -e "[SCAN] $*" >&2; }
log_warn()  { echo -e "[WARN] $*" >&2; }
log_error() { echo -e "[ERR]  $*" >&2; }

_scanner_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

_scanner_read_config() {
    local key="$1"

    [ -f "${GITNET_DIR}/config" ] || return 0

    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        $1 == k          { print substr($0, length(k) + 2); exit }
    ' "${GITNET_DIR}/config"
}

check_dependencies() {
    local missing=0
    local tool

    for tool in nmap arp-scan awk; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Required tool not installed: $tool"
            missing=1
        fi
    done

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        log_error "Not running as root and sudo is not available"
        missing=1
    fi

    return "$missing"
}

_scanner_detect_interface() {
    local iface=""

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip -4 route show default 2>/dev/null | awk '
            { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    fi

    if [ -z "$iface" ] && command -v route >/dev/null 2>&1; then
        iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
    fi

    echo "$iface"
}

_scanner_iface_cidr() {
    local iface="$1"
    local out=""
    local addr mask hex val
    local prefix=0

    if command -v ip >/dev/null 2>&1; then
        out=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { print $2; exit }')
    fi

    if [ -z "$out" ] && command -v ifconfig >/dev/null 2>&1; then
        addr=$(ifconfig "$iface" 2>/dev/null | awk '/inet / { print $2; exit }')
        mask=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {
            for (i = 1; i < NF; i++) if ($i == "netmask") { print $(i + 1); exit }
        }')

        if [ -n "$addr" ] && [ -n "$mask" ]; then
            hex="${mask#0x}"
            val=$((16#$hex))

            while [ "$val" -gt 0 ]; do
                prefix=$((prefix + (val & 1)))
                val=$((val >> 1))
            done

            out="${addr}/${prefix}"
        fi
    fi

    echo "$out"
}

_scanner_iface_ip() {
    local cidr

    cidr=$(_scanner_iface_cidr "$1")
    echo "${cidr%/*}"
}

_scanner_iface_mac() {
    local iface="$1"
    local mac=""

    if command -v ip >/dev/null 2>&1; then
        mac=$(ip link show dev "$iface" 2>/dev/null | awk '/ether/ { print toupper($2); exit }')
    fi

    if [ -z "$mac" ] && command -v ifconfig >/dev/null 2>&1; then
        mac=$(ifconfig "$iface" 2>/dev/null | awk '/ether/ { print toupper($2); exit }')
    fi

    echo "$mac"
}

_scanner_cidr_to_network() {
    local cidr="$1"
    local ip prefix a b c d ipnum mask net

    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    case "$prefix" in
        ''|*[!0-9]*) return 1 ;;
    esac

    [ "$prefix" -le 32 ] || return 1

    IFS=. read -r a b c d <<< "$ip"
    ipnum=$(( (a << 24) | (b << 16) | (c << 8) | d ))

    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    net=$(( ipnum & mask ))

    printf '%d.%d.%d.%d/%d\n' \
        $(( (net >> 24) & 255 )) \
        $(( (net >> 16) & 255 )) \
        $(( (net >> 8) & 255 )) \
        $(( net & 255 )) \
        "$prefix"
}

run_arp_scan() {
    local iface="$1"
    local subnet="$2"
    local raw rc

    raw=$(_scanner_priv arp-scan --interface="$iface" --retry=2 --ignoredups "$subnet" 2>&1 </dev/null)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log_error "arp-scan failed on interface '$iface' (exit $rc)"
        printf '%s\n' "$raw" | head -n 5 >&2
        return 1
    fi

    printf '%s\n' "$raw" | awk '
        BEGIN { FS = "\t"; OFS = "\t" }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\t/ {
            ip     = $1
            mac    = toupper($2)
            vendor = $3

            if (vendor ~ /locally administered/) vendor = "Randomised-MAC"

            gsub(/^\(/, "", vendor)
            gsub(/\)$/, "", vendor)
            gsub(/,/, " ", vendor)
            gsub(/[ ]+/, " ", vendor)
            gsub(/^[ ]+|[ ]+$/, "", vendor)

            if (vendor == "") vendor = "Unknown"

            print ip, mac, vendor
        }'
}

run_nmap_ports() {
    local ip="$1"
    local ports="${2:-$SCANNER_DEFAULT_PORTS}"
    local raw

    raw=$(_scanner_priv nmap -sS -T4 -Pn -p "$ports" --open -oG - "$ip" 2>/dev/null </dev/null) || true

    printf '%s\n' "$raw" | awk '
        BEGIN { FS = "\t" }
        /^Host:.*Ports:/ {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^Ports: /) field = substr($i, 8)

            n = split(field, items, /, */)

            for (j = 1; j <= n; j++) {
                split(items[j], p, "/")

                if (p[2] == "open") {
                    ports = (ports == "" ? p[1] : ports "|" p[1])

                    svc = p[5]
                    if (svc == "") svc = "unknown"
                    gsub(/[,|]/, "-", svc)

                    svcs = (svcs == "" ? svc : svcs "|" svc)
                }
            }
        }
        END {
            print (ports == "" ? "none" : ports) "\t" (svcs == "" ? "none" : svcs)
        }'
}

resolve_hostname() {
    local ip="$1"
    local name=""
    local tmo=""

    command -v timeout >/dev/null 2>&1 && tmo="timeout 3"

    if command -v getent >/dev/null 2>&1; then
        name=$($tmo getent hosts "$ip" 2>/dev/null | awk '{ print $2; exit }')
    fi

    if [ -z "$name" ] || [ "$name" = "$ip" ]; then
        name=""

        if command -v host >/dev/null 2>&1; then
            name=$($tmo host "$ip" 2>/dev/null \
                | awk '/domain name pointer/ { sub(/\.$/, "", $NF); print $NF; exit }')
        fi
    fi

    name=$(printf '%s' "$name" | tr -d ',|[:space:]')

    if [ -z "$name" ] || [ "$name" = "$ip" ]; then
        name="unknown"
    fi

    echo "$name"
}

scan_single_host() {
    local ip="$1"
    local mac="$2"
    local vendor="$3"
    local ts="$4"
    local port_list="${5:-$SCANNER_DEFAULT_PORTS}"
    local result ports svcs hostname

    result=$(run_nmap_ports "$ip" "$port_list")
    ports="${result%%$'\t'*}"
    svcs="${result#*$'\t'}"

    [ -n "$ports" ] || ports="none"
    [ -n "$svcs" ]  || svcs="none"

    hostname=$(resolve_hostname "$ip")

    if [ "$vendor" = "Self" ] && [ "$hostname" = "unknown" ]; then
        hostname=$(hostname -s 2>/dev/null | tr -d ',|[:space:]')
        [ -n "$hostname" ] || hostname="unknown"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$ip" "$mac" "$vendor" "$ports" "$svcs" "$hostname" "$ts"
}

run_scan() {
    local iface="$1"
    local subnet="$2"
    local output_csv="$3"
    local port_list ts cidr arp_results self_ip self_mac
    local ip mac vendor tmp_out bad
    local total=0
    local count=0
    local print_path=0

    check_dependencies || return 1

    [ -n "$iface" ] || iface=$(_scanner_read_config "interface")
    [ -n "$iface" ] || iface=$(_scanner_detect_interface)

    if [ -z "$iface" ]; then
        log_error "Could not determine the network interface"
        return 1
    fi

    [ -n "$subnet" ] || subnet=$(_scanner_read_config "subnet")

    if [ -z "$subnet" ]; then
        cidr=$(_scanner_iface_cidr "$iface")

        if [ -z "$cidr" ]; then
            log_error "Interface '$iface' has no IPv4 address"
            return 1
        fi

        subnet=$(_scanner_cidr_to_network "$cidr") || {
            log_error "Could not compute the network from '$cidr'"
            return 1
        }
    fi

    port_list=$(_scanner_read_config "port_list")
    [ -n "$port_list" ] || port_list="$SCANNER_DEFAULT_PORTS"

    if [ -z "$output_csv" ]; then
        output_csv="${GITNET_DIR}/tmp/scan_$$.csv"
        print_path=1
    fi

    mkdir -p "$(dirname "$output_csv")" || {
        log_error "Cannot create the output directory"
        return 1
    }

    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_info "Interface: $iface | Subnet: $subnet | Ports: $port_list"

    arp_results=$(run_arp_scan "$iface" "$subnet") || return 1

    self_ip=$(_scanner_iface_ip "$iface")
    self_mac=$(_scanner_iface_mac "$iface")

    if [ -n "$self_ip" ] && [ -n "$self_mac" ]; then
        if ! printf '%s\n' "$arp_results" \
                | awk -F'\t' -v ip="$self_ip" '$1 == ip { f = 1 } END { exit !f }'; then
            arp_results="${arp_results}"$'\n'"${self_ip}"$'\t'"${self_mac}"$'\t'"Self"
        fi
    else
        log_warn "Could not read own IP or MAC on '$iface'; scanning machine not added"
    fi

    arp_results=$(printf '%s\n' "$arp_results" \
        | grep -v '^[[:space:]]*$' \
        | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)

    tmp_out="${output_csv}.partial.$$"

    printf '%s\n' "$SCANNER_CSV_HEADER" > "$tmp_out" || {
        log_error "Cannot write $tmp_out"
        return 1
    }

    if [ -z "$arp_results" ]; then
        log_warn "No hosts found on $subnet; writing header only"
    else
        total=$(printf '%s\n' "$arp_results" | wc -l | tr -d ' ')
        log_info "Found $total host(s)"

        while IFS=$'\t' read -r ip mac vendor; do
            [ -n "$ip" ] || continue

            count=$((count + 1))
            log_info "[$count/$total] $ip"

            scan_single_host "$ip" "$mac" "$vendor" "$ts" "$port_list" >> "$tmp_out"
        done <<< "$arp_results"
    fi

    bad=$(awk -F, 'NR > 1 && NF != 7' "$tmp_out" | wc -l | tr -d ' ')

    if [ "$bad" -ne 0 ]; then
        log_error "$bad row(s) do not have 7 fields. Partial file kept: $tmp_out"
        return 1
    fi

    mv -f "$tmp_out" "$output_csv" || {
        log_error "Cannot move the result to $output_csv"
        return 1
    }

    log_info "Done: $count host(s) written to $output_csv"

    [ "$print_path" -eq 1 ] && echo "$output_csv"

    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_scan "$@"
    exit $?
fi