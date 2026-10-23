#!/usr/bin/env bash
_alerts_root() {
    printf '%s\n' "${GITNET_DIR:-.gitnet}"
}

_alerts_log_file() {
    printf '%s/logs/alerts.log\n' "$(_alerts_root)"
}

_alerts_config_value() {
    local key="$1"
    local config_file="$(_alerts_root)/config"

    # Use storage.sh's helper when a compatible implementation is loaded.
    if declare -F storage_read_config >/dev/null 2>&1; then
        storage_read_config "$key"
        return
    fi

    [[ -f "$config_file" ]] || return 0
    awk -F= -v wanted="$key" '
        /^[[:space:]]*#/ { next }
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$config_file"
}

_alerts_write_log() {
    local type="$1"
    local severity="$2"
    local detail="$3"
    local timestamp="$4"
    local log_file

    log_file="$(_alerts_log_file)"
    mkdir -p "$(dirname "$log_file")" || return 1
    printf '%s | %s | %s | %s\n' \
        "$timestamp" "$severity" "$type" "$detail" >> "$log_file"
}

_alerts_send_email() {
    local subject="$1"
    local body="$2"
    local recipient mailer

    recipient="$(_alerts_config_value alert_email)"
    [[ -z "$recipient" ]] && return 0

    if command -v mailx >/dev/null 2>&1; then
        mailer="mailx"
    elif command -v mail >/dev/null 2>&1; then
        mailer="mail"
    else
        echo "[GitNet] Warning: neither mailx nor mail is installed; email not sent." >&2
        return 1
    fi

    printf '%s\n' "$body" | "$mailer" -s "[GitNet Alert] $subject" "$recipient"
}

_alerts_describe_event() {
    local type="$1" ip_new="$2" ip_old="$3" mac="$4" vendor="$5"
    local ports_new="$6" ports_old="$7" svcs_new="$8" svcs_old="$9"

    ALERTS_SEVERITY="LOW"
    ALERTS_DETAIL="Network change detected: $type"

    case "$type" in
        NEW_HOST)
            ALERTS_SEVERITY="HIGH"
            ALERTS_DETAIL="New host ${ip_new} (MAC: ${mac} / ${vendor}) appeared on the network"
            ;;
        PORT_OPENED)
            ALERTS_SEVERITY="HIGH"
            ALERTS_DETAIL="Port ${ports_new} opened on ${ip_new} (MAC: ${mac}; service: ${svcs_new})"
            ;;
        HOST_OFFLINE)
            ALERTS_SEVERITY="LOW"
            ALERTS_DETAIL="Host ${ip_old} (MAC: ${mac} / ${vendor}) went offline"
            ;;
        PORT_CLOSED)
            ALERTS_SEVERITY="MED"
            ALERTS_DETAIL="Port ${ports_old} closed on ${ip_new:-$ip_old} (MAC: ${mac}; previous service: ${svcs_old})"
            ;;
        SERVICE_CHANGED)
            ALERTS_SEVERITY="MED"
            ALERTS_DETAIL="Service changed on ${ip_new:-$ip_old} (MAC: ${mac}; ports: ${ports_new:-$ports_old}; ${svcs_old} -> ${svcs_new})"
            ;;
        IP_CHANGED)
            ALERTS_SEVERITY="LOW"
            ALERTS_DETAIL="Host ${mac} changed IP from ${ip_old} to ${ip_new}"
            ;;
        *)
            ALERTS_SEVERITY="LOW"
            ALERTS_DETAIL="Unclassified network event '$type' for ${mac:-unknown} at ${ip_new:-$ip_old}"
            ;;
    esac
}

alerts_process_diff() {
    local raw_diff="${1:-}"
    local type ip_new ip_old mac vendor ports_new ports_old svcs_new svcs_old ts
    local severity detail high_count=0 event_count=0 email_body probe_threshold
    local line

    [[ -z "$raw_diff" ]] && return 0

    email_body="GitNet detected high-severity network changes:
"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        # Read exactly the 10 fields defined by engine_diff_raw().
        IFS='|' read -r type ip_new ip_old mac vendor \
            ports_new ports_old svcs_new svcs_old ts <<< "$line"

        if [[ -z "$type" || -z "$mac" || -z "$ts" ]]; then
            echo "[GitNet] Warning: skipping malformed diff record: $line" >&2
            continue
        fi

        _alerts_describe_event "$type" "$ip_new" "$ip_old" "$mac" "$vendor" \
            "$ports_new" "$ports_old" "$svcs_new" "$svcs_old"
        severity="$ALERTS_SEVERITY"
        detail="$ALERTS_DETAIL"

        if ! _alerts_write_log "$type" "$severity" "$detail" "$ts"; then
            echo "[GitNet] Error: could not write alert log." >&2
            return 1
        fi

        ((event_count += 1))
        if [[ "$severity" == "HIGH" ]]; then
            ((high_count += 1))
            email_body+=$'\n'"[$severity] $type: $detail (at $ts)"
        fi
    done <<< "$raw_diff"

    if (( event_count > 0 )); then
        echo "[GitNet] Logged $event_count network event(s)." >&2
    fi

    if (( high_count > 0 )); then
        _alerts_send_email "$high_count high-severity network change(s)" "$email_body" || \
            echo "[GitNet] Warning: email alert could not be delivered." >&2
    fi

    probe_threshold="$(_alerts_config_value probe_threshold)"
    [[ "$probe_threshold" =~ ^[0-9]+$ ]] || probe_threshold=5
    alerts_check_probe_pattern 60 "$probe_threshold"
}

alerts_check_probe_pattern() {
    local window_minutes="${1:-60}"
    local threshold="${2:-5}"
    local log_file now_epoch since_epoch since_iso probe_results
    local state_file mac count last_notified current_bucket
    local probe_body="" found=0

    [[ "$window_minutes" =~ ^[0-9]+$ ]] || window_minutes=60
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=5
    (( threshold > 0 )) || threshold=5

    log_file="$(_alerts_log_file)"
    [[ -f "$log_file" ]] || return 0

    now_epoch=$(date +%s)
    since_epoch=$((now_epoch - window_minutes * 60))
    since_iso=$(date -u -d "@$since_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || \
        since_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    probe_results=$(awk -F' \\| ' -v since_iso="$since_iso" -v threshold="$threshold" '
        NF >= 4 {
            ts = $1
            severity = $2
            type = $3
            detail = $4
            if (type != "NEW_HOST" || ts < since_iso) next
            tmp = detail
            sub(/.*MAC: /, "", tmp)
            sub(/[^0-9A-Fa-f:].*/, "", tmp)
            if (tmp ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) count[toupper(tmp)]++
        }
        END {
            for (mac in count)
                if (count[mac] >= threshold)
                    print mac "|" count[mac]
        }
    ' "$log_file")

    [[ -z "$probe_results" ]] && return 0

    state_file="$(_alerts_root)/logs/probe-alerts.state"
    touch "$state_file" 2>/dev/null || return 0
    current_bucket=$(date -u +"%Y-%m-%dT%H")
    while IFS='|' read -r mac count; do
        [[ -z "$mac" ]] && continue
        last_notified=$(awk -F'|' -v m="$mac" '$1 == m { value=$2 } END { print value }' "$state_file")
        [[ "$last_notified" == "$current_bucket" ]] && continue

        local detail="Repeated NEW_HOST events from MAC ${mac}: ${count} appearance(s) within ${window_minutes} minutes (threshold: ${threshold})"
        _alerts_write_log "PROBE_DETECTED" "HIGH" "$detail" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '%s|%s\n' "$mac" "$current_bucket" >> "$state_file"
        probe_body+=$'\n'"[HIGH] $detail"
        found=1
    done <<< "$probe_results"

    if (( found )); then
        _alerts_send_email "Possible network probe detected" \
            "GitNet detected repeated new-host events that may indicate probing:
${probe_body}" || \
            echo "[GitNet] Warning: probe email alert could not be delivered." >&2
    fi
}

alerts_status() {
    local count="${1:-20}"
    local log_file line severity

    [[ "$count" =~ ^[0-9]+$ ]] || {
        echo "Usage: alerts_status [count]" >&2
        return 2
    }
    (( count > 0 )) || {
        echo "Usage: alerts_status [count>0]" >&2
        return 2
    }

    log_file="$(_alerts_log_file)"
    if [[ ! -f "$log_file" ]]; then
        echo "No alert log yet."
        return 0
    fi

    tail -n "$count" "$log_file" | while IFS= read -r line; do
        severity=$(printf '%s\n' "$line" | awk -F' \\| ' '{print $2}')
        case "$severity" in
            HIGH) printf '\033[31m%s\033[0m\n' "$line" ;;
            MED)  printf '\033[33m%s\033[0m\n' "$line" ;;
            LOW)  printf '\033[36m%s\033[0m\n' "$line" ;;
            *)    printf '%s\n' "$line" ;;
        esac
    done
}

alerts_set_email() {
    local email="${1:-}"
    local config_file="$(_alerts_root)/config"
    local tmp_file

    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "Usage: alerts_set_email valid-address@example.com" >&2
        return 2
    fi
    [[ -f "$config_file" ]] || {
        echo "Error: GitNet is not initialized. Run 'gitnet init' first." >&2
        return 1
    }

    if declare -F storage_write_config >/dev/null 2>&1; then
        storage_write_config "alert_email" "$email"
    elif grep -q '^alert_email=' "$config_file"; then
        tmp_file=$(mktemp) || return 1
        awk -F= -v value="$email" '
            BEGIN { OFS="=" }
            $1 == "alert_email" { print "alert_email", value; found=1; next }
            { print }
            END { if (!found) print "alert_email", value }
        ' "$config_file" > "$tmp_file" && cat "$tmp_file" > "$config_file"
        rm -f "$tmp_file"
    else
        printf 'alert_email=%s\n' "$email" >> "$config_file"
    fi

    echo "[GitNet] Alert email configured." >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --status|status)
            alerts_status "${2:-20}"
            ;;
        --probe|probe)
            alerts_check_probe_pattern "${2:-60}" "${3:-5}"
            ;;
        --email|email)
            alerts_set_email "${2:-}"
            ;;
        *)
            echo "Usage: $0 {--status [count]|--probe [window_minutes] [threshold]|--email address}" >&2
            exit 2
            ;;
    esac
fi