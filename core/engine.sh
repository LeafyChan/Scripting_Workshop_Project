#!/usr/bin/env bash

engine_validate_csv() {
    local file="$1"

    [ -z "$file" ] && { echo "engine_validate_csv: file path required" >&2; return 1; }
    [ ! -f "$file" ] && { echo "engine_validate_csv: file not found: $file" >&2; return 1; }

    local header
    header=$(head -n 1 "$file")

    if [ "$header" != "IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP" ]; then
        echo "engine_validate_csv: invalid header in $file" >&2
        echo "  expected: IP,MAC_ADDRESS,MAC_VENDOR,OPEN_PORTS,SERVICES,HOSTNAME,TIMESTAMP" >&2
        echo "  got:      $header" >&2
        return 1
    fi
}

engine_classify_severity() {
    case "$1" in
        NEW_HOST|PORT_OPENED)        echo "HIGH" ;;
        PORT_CLOSED|SERVICE_CHANGED) echo "MED"  ;;
        *)                           echo "LOW"  ;;
    esac
}

engine_diff_raw() {
    local old_csv="$1"
    local new_csv="$2"

    [ -z "$old_csv" ] || [ -z "$new_csv" ] && { echo "engine_diff_raw: two CSV paths required" >&2; return 1; }

    engine_validate_csv "$old_csv" || return 1
    engine_validate_csv "$new_csv" || return 1

    local ts_new
    ts_new=$(awk -F, 'NR==2 { print $7; exit }' "$new_csv")
    [ -n "$ts_new" ] || ts_new=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    awk -F',' -v ts="$ts_new" '
    NR == FNR {
        if (NR == 1) next
        mac = $2
        old_ip[mac]    = $1
        old_ports[mac] = $4
        old_svcs[mac]  = $5
        old_vendor[mac]= $3
        next
    }

    FNR == 1 { next }

    {
        mac       = $2
        new_ip    = $1
        new_ports = $4
        new_svcs  = $5
        new_vendor= $3
        seen_in_new[mac] = 1

        if (!(mac in old_ip)) {
            print "NEW_HOST|" new_ip "||" mac "|" new_vendor "|" new_ports "||" new_svcs "||" ts
            next
        }

        if (new_ip != old_ip[mac]) {
            print "IP_CHANGED|" new_ip "|" old_ip[mac] "|" mac "|" new_vendor "|||||" ts
        }

        delete om; delete nm; delete osvc; delete nsvc

        n_old = split(old_ports[mac], op, "|")
        n_os  = split(old_svcs[mac],  os, "|")
        n_new = split(new_ports[mac], np, "|")
        n_ns  = split(new_svcs[mac],  ns, "|")

        for (i = 1; i <= n_old; i++) {
            if (op[i] != "none" && op[i] != "") {
                om[op[i]] = 1
                osvc[op[i]] = (i <= n_os ? os[i] : "unknown")
            }
        }
        for (i = 1; i <= n_new; i++) {
            if (np[i] != "none" && np[i] != "") {
                nm[np[i]] = 1
                nsvc[np[i]] = (i <= n_ns ? ns[i] : "unknown")
            }
        }

        for (p in nm) {
            if (!(p in om))
                print "PORT_OPENED|" new_ip "||" mac "|" new_vendor "|" p "||" nsvc[p] "||" ts
        }

        for (p in om) {
            if (!(p in nm)) {
                print "PORT_CLOSED|" new_ip "|" old_ip[mac] "|" mac "|" new_vendor "||" p "||" osvc[p] "|" ts
            } else if (osvc[p] != nsvc[p] && osvc[p] != "" && nsvc[p] != "") {
                print "SERVICE_CHANGED|" new_ip "||" mac "|" new_vendor "|" p "|" p "|" nsvc[p] "|" osvc[p] "|" ts
            }
        }
    }

    END {
        for (mac in old_ip)
            if (!(mac in seen_in_new))
                print "HOST_OFFLINE||" old_ip[mac] "|" mac "|" old_vendor[mac] "||||" old_ports[mac] "|" ts
    }
    ' "$old_csv" "$new_csv"
}

engine_diff() {
    local old_csv="$1"
    local new_csv="$2"

    engine_validate_csv "$old_csv" || return 1
    engine_validate_csv "$new_csv" || return 1

    local RED='\033[31m' YELLOW='\033[33m' CYAN='\033[36m'
    local GREEN='\033[32m' BOLD='\033[1m' RESET='\033[0m'

    local ts_old ts_new hosts_old hosts_new
    ts_old=$(awk    -F, 'NR==2{print $7;exit}' "$old_csv")
    ts_new=$(awk    -F, 'NR==2{print $7;exit}' "$new_csv")
    hosts_old=$(awk 'NR>1{c++}END{print c+0}' "$old_csv")
    hosts_new=$(awk 'NR>1{c++}END{print c+0}' "$new_csv")

    printf '\n%bGitNet Diff%b\n' "$BOLD" "$RESET"
    printf '  old: %s  (%s hosts)\n' "$ts_old" "$hosts_old"
    printf '  new: %s  (%s hosts)\n\n' "$ts_new" "$hosts_new"

    local raw_diff
    raw_diff=$(engine_diff_raw "$old_csv" "$new_csv")

    if [ -z "$raw_diff" ]; then
        printf '%bNo changes detected.%b\n\n' "$GREEN" "$RESET"
        return 0
    fi

    local high=0 med=0 low=0

    while IFS='|' read -r type ip_new ip_old mac vendor \
                         ports_new ports_old svcs_new svcs_old ts; do
        local sev icon color
        sev=$(engine_classify_severity "$type")

        case "$sev" in
            HIGH) icon='[!]'; color="$RED";    ((high++)) ;;
            MED)  icon='[~]'; color="$YELLOW"; ((med++))  ;;
            LOW)  icon='[-]'; color="$CYAN";   ((low++))  ;;
        esac

        printf '%b%s %s%b\n' "$color" "$icon" "$type" "$RESET"

        case "$type" in
            NEW_HOST)
                printf '    IP  : %s\n'        "$ip_new"
                printf '    MAC : %s  (%s)\n'  "$mac" "$vendor"
                [ "$ports_new" != "none" ] && [ -n "$ports_new" ] && \
                    printf '    Port: %s  (%s)\n' "$ports_new" "$svcs_new"
                ;;
            HOST_OFFLINE)
                printf '    IP  : %s\n'       "$ip_old"
                printf '    MAC : %s  (%s)\n' "$mac" "$vendor"
                ;;
            PORT_OPENED)
                printf '    IP  : %s\n'          "$ip_new"
                printf '    MAC : %s  (%s)\n'    "$mac" "$vendor"
                printf '    Port: +%s  (%s)\n'   "$ports_new" "$svcs_new"
                ;;
            PORT_CLOSED)
                printf '    IP  : %s\n'          "${ip_new:-$ip_old}"
                printf '    MAC : %s  (%s)\n'    "$mac" "$vendor"
                printf '    Port: -%s  (%s)\n'   "$ports_old" "$svcs_old"
                ;;
            SERVICE_CHANGED)
                printf '    IP  : %s\n'          "${ip_new:-$ip_old}"
                printf '    MAC : %s  (%s)\n'    "$mac" "$vendor"
                printf '    Port: %s\n'          "$ports_new"
                printf '    Svc : %s -> %s\n'    "$svcs_old" "$svcs_new"
                ;;
            IP_CHANGED)
                printf '    MAC : %s  (%s)\n'    "$mac" "$vendor"
                printf '    IP  : %s -> %s\n'    "$ip_old" "$ip_new"
                ;;
        esac
        printf '\n'
    done <<< "$raw_diff"

    printf 'Summary  %bHIGH:%s%b  %bMED:%s%b  %bLOW:%s%b\n\n' \
        "$RED" "$high" "$RESET" "$YELLOW" "$med" "$RESET" "$CYAN" "$low" "$RESET"

    [ "$high" -gt 0 ] && return 2
    return 0
}

engine_diff_commits() {
    local ref_old="$1"
    local ref_new="${2:-HEAD}"

    [ -z "$ref_old" ] && { echo "engine_diff_commits: ref_old required" >&2; return 1; }

    local hash_old hash_new blob_old blob_new
    hash_old=$(storage_resolve_ref "$ref_old")       || return 1
    hash_new=$(storage_resolve_ref "$ref_new")       || return 1
    blob_old=$(storage_get_blob_for_commit "$hash_old") || return 1
    blob_new=$(storage_get_blob_for_commit "$hash_new") || return 1

    engine_diff "$blob_old" "$blob_new"
}

storage_get_blob_for_commit() {
    local commit_hash="$1"
    local gitnet_dir="${GITNET_DIR:-.gitnet}"
    local commit_file="${gitnet_dir}/commits/${commit_hash}"

    [ -z "$commit_hash" ] && { echo "storage_get_blob_for_commit: hash required" >&2; return 1; }
    [ ! -f "$commit_file" ] && { echo "storage_get_blob_for_commit: commit not found: $commit_hash" >&2; return 1; }

    local blob_hash
    blob_hash=$(grep '^blob=' "$commit_file" | cut -d'=' -f2)

    [ -z "$blob_hash" ] && { echo "storage_get_blob_for_commit: no blob in commit $commit_hash" >&2; return 1; }

    local object_file="${gitnet_dir}/objects/${blob_hash}.csv"
    [ ! -f "$object_file" ] && { echo "storage_get_blob_for_commit: object not found: ${blob_hash}.csv" >&2; return 1; }

    echo "$object_file"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd="${1:-help}"; shift || true
    case "$cmd" in
        raw)      engine_diff_raw          "$@" ;;
        diff)     engine_diff              "$@" ;;
        commits)  engine_diff_commits      "$@" ;;
        classify) engine_classify_severity "$@" ;;
        validate) engine_validate_csv      "$@" ;;
        *)
            printf 'Usage: bash core/engine.sh {raw|diff|commits|classify|validate} [args]\n' >&2
            exit 1
            ;;
    esac
    exit $?
fi