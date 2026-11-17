#!/usr/bin/env bash

GITNET_DIR="${GITNET_DIR:-.gitnet}"
REPORT_DIR="${REPORT_DIR:-gitnet_reports}"

_report_read_config() {
    local key="$1"
    if declare -F storage_read_config >/dev/null 2>&1; then
        storage_read_config "$key"
        return
    fi
    local config_file="${GITNET_DIR}/config"
    [ -f "$config_file" ] || return 0
    awk -F= -v k="$key" '/^[[:space:]]*#/{next} $1==k{sub(/^[^=]*=/,"");print;exit}' "$config_file"
}

report_system_health() {
    local cpu ram disk uptime_str os
    os=$(uname -s 2>/dev/null)

    if [ "$os" = "Linux" ] && [ -f /proc/stat ]; then
        local s1 s2
        s1=$(awk '/^cpu /{print $2+$3+$4+$5, $5; exit}' /proc/stat)
        sleep 1
        s2=$(awk '/^cpu /{print $2+$3+$4+$5, $5; exit}' /proc/stat)
        cpu=$(awk -v s1="$s1" -v s2="$s2" 'BEGIN{
            split(s1,a," "); split(s2,b," ")
            total=b[1]-a[1]; idle=b[2]-a[2]
            if(total==0){print "0.0";exit}
            printf "%.1f",(total-idle)/total*100
        }')
    elif [ "$os" = "Darwin" ]; then
        cpu=$(top -l 1 -s 0 2>/dev/null \
            | awk '/CPU usage:/{gsub(/%/,""); for(i=1;i<=NF;i++) if($i~/^[0-9.]+$/ && $(i+1)=="user,"){printf "%.1f",$i;exit}}')
    fi
    cpu="${cpu:-0.0}"

    if [ "$os" = "Linux" ]; then
        ram=$(free 2>/dev/null | awk '/^Mem:/{if($2>0) printf "%.1f",$3/$2*100; else print "0.0"}')
    elif [ "$os" = "Darwin" ]; then
        local page_size total_pages pages_free
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
        total_pages=$(sysctl -n hw.memsize 2>/dev/null | awk -v ps="$page_size" '{print int($1/ps)}')
        pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\.$/,"",$NF); print $NF+0}')
        ram=$(awk -v tf="$total_pages" -v pf="$pages_free" 'BEGIN{if(tf>0) printf "%.1f",(1-pf/tf)*100; else print "0.0"}')
    fi
    ram="${ram:-0.0}"

    disk=$(df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5+0}')
    disk="${disk:-0}"

    uptime_str=$(uptime 2>/dev/null | sed 's/.*up //;s/,.*load.*//' | tr -d ' ')
    uptime_str="${uptime_str:-unknown}"

    printf 'cpu=%s ram=%s disk=%s uptime=%s\n' "$cpu" "$ram" "$disk" "$uptime_str"
}

_collect_history_data() {
    local current
    current=$(cat "${GITNET_DIR}/HEAD" 2>/dev/null)
    [ -z "$current" ] || [ "$current" = "none" ] && return 0

    local -a hashes blobs timestamps host_counts messages

    while [ "$current" != "none" ]; do
        local commit_file="${GITNET_DIR}/commits/${current}"
        [ -f "$commit_file" ] || break

        local blob ts hosts msg parent
        blob=$(grep   '^blob='      "$commit_file" | cut -d'=' -f2)
        ts=$(grep     '^timestamp=' "$commit_file" | cut -d'=' -f2-)
        hosts=$(grep  '^hosts='     "$commit_file" | cut -d'=' -f2-)
        msg=$(grep    '^message='   "$commit_file" | cut -d'=' -f2-)
        parent=$(grep '^parent='    "$commit_file" | cut -d'=' -f2-)

        hashes+=("$current")
        blobs+=("$blob")
        timestamps+=("$ts")
        host_counts+=("$hosts")
        messages+=("$msg")

        current="${parent:-none}"
    done

    local i
    for (( i=${#hashes[@]}-1; i>=0; i-- )); do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${hashes[$i]}" "${blobs[$i]}" "${timestamps[$i]}" \
            "${host_counts[$i]}" "${messages[$i]}"
    done
}

report_html() {
    mkdir -p "$REPORT_DIR" || { echo "report_html: cannot create $REPORT_DIR" >&2; return 1; }

    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/gitnet_report_XXXXXX)

    local history_data
    history_data=$(_collect_history_data)

    if [ -z "$history_data" ]; then
        echo "report_html: no commits found" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    local host_dat="${tmp_dir}/hosts.dat"
    local anom_dat="${tmp_dir}/anomalies.dat"
    local table_rows="${tmp_dir}/rows.html"
    local scan_num=0 prev_blob=""
    local total_commits=0
    > "$table_rows"

    while IFS=$'\t' read -r commit_hash blob_hash ts hosts msg; do
        ((scan_num++)); ((total_commits++))

        local anom_count=0
        if [ -n "$prev_blob" ]; then
            local prev_path="${GITNET_DIR}/objects/${prev_blob}.csv"
            local curr_path="${GITNET_DIR}/objects/${blob_hash}.csv"
            if [ -f "$prev_path" ] && [ -f "$curr_path" ]; then
                anom_count=$(engine_diff_raw "$prev_path" "$curr_path" 2>/dev/null | wc -l | tr -d ' ')
            fi
        fi

        echo "${scan_num} ${hosts}"      >> "$host_dat"
        echo "${scan_num} ${anom_count}" >> "$anom_dat"

        cat >> "$table_rows" << ROW
<tr>
  <td><code>${commit_hash:0:8}</code></td>
  <td>${ts}</td>
  <td>${hosts}</td>
  <td>${anom_count}</td>
  <td>${msg}</td>
</tr>
ROW
        prev_blob="$blob_hash"
    done <<< "$history_data"

    local chart_hosts_b64="" chart_anom_b64=""

    if command -v gnuplot >/dev/null 2>&1; then
        local chart_hosts="${tmp_dir}/hosts.png"
        local chart_anom="${tmp_dir}/anom.png"

        gnuplot << GNUPLOT
set terminal png size 760,280 enhanced font "Sans,10" background "#1e1e2e"
set output "${chart_hosts}"
set title "Active Hosts Over Time" textcolor rgb "#cdd6f4"
set xlabel "Scan" textcolor rgb "#cdd6f4"
set ylabel "Hosts" textcolor rgb "#cdd6f4"
set border lc rgb "#6c7086"
set xtics textcolor rgb "#cdd6f4"
set ytics textcolor rgb "#cdd6f4"
set grid ytics lc rgb "#313244"
set key off
plot "${host_dat}" using 1:2 with linespoints lc rgb "#89b4fa" lw 2 pt 7 ps 1
GNUPLOT

        gnuplot << GNUPLOT
set terminal png size 760,280 enhanced font "Sans,10" background "#1e1e2e"
set output "${chart_anom}"
set title "Anomalies Per Scan" textcolor rgb "#cdd6f4"
set xlabel "Scan" textcolor rgb "#cdd6f4"
set ylabel "Anomalies" textcolor rgb "#cdd6f4"
set border lc rgb "#6c7086"
set xtics textcolor rgb "#cdd6f4"
set ytics textcolor rgb "#cdd6f4"
set grid ytics lc rgb "#313244"
set key off
plot "${anom_dat}" using 1:2 with linespoints lc rgb "#fab387" lw 2 pt 7 ps 1
GNUPLOT

        [ -f "$chart_hosts" ] && chart_hosts_b64=$(base64 -w0 "$chart_hosts" 2>/dev/null || base64 "$chart_hosts" 2>/dev/null)
        [ -f "$chart_anom"  ] && chart_anom_b64=$(base64  -w0 "$chart_anom"  2>/dev/null || base64 "$chart_anom"  2>/dev/null)
    fi

    local health_line
    health_line=$(report_system_health 2>/dev/null)
    local h_cpu h_ram h_disk h_up
    h_cpu=$(echo  "$health_line" | grep -oP 'cpu=\K[^ ]+')
    h_ram=$(echo  "$health_line" | grep -oP 'ram=\K[^ ]+')
    h_disk=$(echo "$health_line" | grep -oP 'disk=\K[^ ]+')
    h_up=$(echo   "$health_line" | grep -oP 'uptime=\K[^ ]+')

    local cpu_pct ram_pct
    cpu_pct=$(printf '%.0f' "${h_cpu:-0}" 2>/dev/null || echo 0)
    ram_pct=$(printf '%.0f' "${h_ram:-0}" 2>/dev/null || echo 0)

    local generated_ts
    generated_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local hosts_img anom_img
    if [ -n "$chart_hosts_b64" ]; then
        hosts_img='<img src="data:image/png;base64,'"${chart_hosts_b64}"'" alt="hosts" style="max-width:100%">'
    else
        hosts_img='<p class="nc">gnuplot not installed</p>'
    fi
    if [ -n "$chart_anom_b64" ]; then
        anom_img='<img src="data:image/png;base64,'"${chart_anom_b64}"'" alt="anomalies" style="max-width:100%">'
    else
        anom_img='<p class="nc">gnuplot not installed</p>'
    fi

    local output_file="${REPORT_DIR}/report.html"
    cat > "$output_file" << HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GitNet Report — ${generated_ts}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#1e1e2e;color:#cdd6f4;font-family:system-ui,sans-serif;display:flex;min-height:100vh}
aside{width:220px;background:#181825;padding:1.5rem 1rem;display:flex;flex-direction:column;gap:1.2rem;border-right:1px solid #313244}
aside h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:#6c7086;margin-bottom:.3rem}
.lbl{font-size:.78rem;color:#a6adc8;margin-bottom:.2rem}
.track{background:#313244;border-radius:4px;height:10px;overflow:hidden;margin-bottom:.7rem}
.fill{height:100%;border-radius:4px}
.cpu{background:#89b4fa}.ram{background:#a6e3a1}.dsk{background:#fab387}
.val{font-size:.75rem;color:#6c7086;margin-top:-0.5rem;margin-bottom:.5rem}
.sub{font-size:.82rem;color:#cba6f7}
main{flex:1;padding:2rem;overflow-x:auto}
h1{font-size:1.3rem;color:#cba6f7;margin-bottom:.2rem}
.ts{font-size:.8rem;color:#6c7086;margin-bottom:1.8rem}
.card{background:#181825;border:1px solid #313244;border-radius:8px;padding:1rem;margin-bottom:1.4rem}
.card h3{font-size:.88rem;color:#a6adc8;margin-bottom:.7rem}
.nc{color:#6c7086;font-size:.8rem}
table{width:100%;border-collapse:collapse;font-size:.8rem}
thead th{background:#181825;color:#a6adc8;text-align:left;padding:.45rem .7rem;border-bottom:1px solid #313244;font-weight:600}
tbody tr:nth-child(even){background:#181825}
tbody td{padding:.4rem .7rem;border-bottom:1px solid #1e1e2e}
code{font-family:monospace;font-size:.82em;background:#313244;padding:1px 4px;border-radius:3px}
</style>
</head>
<body>
<aside>
  <div>
    <h2>Health</h2>
    <div class="lbl">CPU</div>
    <div class="track"><div class="fill cpu" style="width:${cpu_pct}%"></div></div>
    <div class="val">${h_cpu}%</div>
    <div class="lbl">RAM</div>
    <div class="track"><div class="fill ram" style="width:${ram_pct}%"></div></div>
    <div class="val">${h_ram}%</div>
    <div class="lbl">Disk /</div>
    <div class="track"><div class="fill dsk" style="width:${h_disk}%"></div></div>
    <div class="val">${h_disk}%</div>
  </div>
  <div><h2>Uptime</h2><div class="sub">${h_up}</div></div>
  <div><h2>Scans</h2><div class="sub">${total_commits} commits</div></div>
</aside>
<main>
  <h1>GitNet Report</h1>
  <p class="ts">Generated: ${generated_ts}</p>
  <div class="card"><h3>Active Hosts</h3>${hosts_img}</div>
  <div class="card"><h3>Anomalies Per Scan</h3>${anom_img}</div>
  <div class="card">
    <h3>Commit History</h3>
    <table>
      <thead><tr><th>Commit</th><th>Timestamp</th><th>Hosts</th><th>Anomalies</th><th>Message</th></tr></thead>
      <tbody>$(cat "$table_rows")</tbody>
    </table>
  </div>
</main>
</body>
</html>
HTML

    rm -rf "$tmp_dir"
    echo "$output_file"
}

report_csv() {
    mkdir -p "$REPORT_DIR" || { echo "report_csv: cannot create $REPORT_DIR" >&2; return 1; }

    local output_file="${REPORT_DIR}/history.csv"
    printf 'commit_hash,blob_hash,timestamp,message,host_count,parent\n' > "$output_file"

    local history_data
    history_data=$(_collect_history_data)
    [ -z "$history_data" ] && { echo "$output_file"; return 0; }

    while IFS=$'\t' read -r commit_hash blob_hash ts hosts msg; do
        local parent="none"
        local commit_file="${GITNET_DIR}/commits/${commit_hash}"
        [ -f "$commit_file" ] && parent=$(grep '^parent=' "$commit_file" | cut -d'=' -f2)
        local safe_msg
        safe_msg=$(printf '%s' "$msg" | sed 's/"/""/g')
        printf '%s,%s,%s,"%s",%s,%s\n' "$commit_hash" "$blob_hash" "$ts" "$safe_msg" "$hosts" "$parent" >> "$output_file"
    done <<< "$history_data"

    echo "$output_file"
}

_report_draw_bar() {
    local label="$1" value="$2" width=40
    local filled
    filled=$(awk -v v="$value" -v w="$width" 'BEGIN{printf "%d",(v/100)*w}')
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$filled" -lt 0 ]        && filled=0

    local bar="" i
    for (( i=0; i<filled; i++ ));  do bar+="█"; done
    for (( i=filled; i<width; i++ )); do bar+="░"; done

    printf '  %s [%s] %s%%\n' "$label" "$bar" "$value"
}

report_dashboard() {
    clear

    printf '\033[1m\033[35m  GitNet — Network Monitor\033[0m\n'
    printf '  %s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local health_line
    health_line=$(report_system_health 2>/dev/null)
    local h_cpu h_ram h_disk h_up
    h_cpu=$(echo  "$health_line" | grep -oP 'cpu=\K[^ ]+')
    h_ram=$(echo  "$health_line" | grep -oP 'ram=\K[^ ]+')
    h_disk=$(echo "$health_line" | grep -oP 'disk=\K[^ ]+')
    h_up=$(echo   "$health_line" | grep -oP 'uptime=\K[^ ]+')

    _report_draw_bar "CPU " "${h_cpu:-0}"
    _report_draw_bar "RAM " "${h_ram:-0}"
    _report_draw_bar "DISK" "${h_disk:-0}"
    printf '  Uptime: %s\n\n' "${h_up:-unknown}"

    local current
    current=$(cat "${GITNET_DIR}/HEAD" 2>/dev/null)

    if [ -z "$current" ] || [ "$current" = "none" ]; then
        printf '  No scans yet.\n'
        return 0
    fi

    local commit_file="${GITNET_DIR}/commits/${current}"
    local blob_hash
    blob_hash=$(grep '^blob=' "$commit_file" | cut -d'=' -f2)
    local object_file="${GITNET_DIR}/objects/${blob_hash}.csv"

    if [ ! -f "$object_file" ]; then
        printf '  Snapshot not found: %s\n' "$object_file"
        return 1
    fi

    local ts hosts
    ts=$(awk    -F, 'NR==2{print $7;exit}' "$object_file")
    hosts=$(awk 'NR>1{c++}END{print c+0}' "$object_file")

    printf '\033[1m  Latest: %s  (%s hosts)\033[0m\n\n' "$ts" "$hosts"

    awk -F, 'NR==1{
        printf "  %-15s  %-17s  %-18s  %-20s  %-25s\n",$1,$2,$3,$4,$5
        printf "  %-15s  %-17s  %-18s  %-20s  %-25s\n",\
            "---------------","------------------","------------------",\
            "--------------------","-------------------------"
        next
    }
    { printf "  %-15s  %-17s  %-18s  %-20s  %-25s\n",$1,$2,$3,$4,$5 }' "$object_file"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd="${1:-help}"; shift || true
    case "$cmd" in
        health)    report_system_health ;;
        html)      report_html ;;
        csv)       report_csv ;;
        dashboard) report_dashboard ;;
        *)
            printf 'Usage: bash core/reporter.sh {health|html|csv|dashboard}\n' >&2
            exit 1
            ;;
    esac
    exit $?
fi