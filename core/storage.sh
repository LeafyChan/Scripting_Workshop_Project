#!/usr/bin/env bash

storage_init() {
    if [ -d ".gitnet" ]; then
        echo "GitNet repository already initialized." >&2
    fi

    mkdir -p .gitnet/objects
    mkdir -p .gitnet/commits
    mkdir -p .gitnet/logs
    mkdir -p .gitnet/tmp

    if [ ! -f ".gitnet/HEAD" ]; then
        echo "none" > .gitnet/HEAD
    fi

    if [ ! -f ".gitnet/config" ]; then
        cat > .gitnet/config <<EOF
interface=
subnet=
alert_email=
port_list=
EOF
    fi

    if [ ! -f ".gitnet/.gitignore" ]; then
        cat > .gitnet/.gitignore <<EOF
objects/
commits/
logs/
tmp/
EOF
    fi
}

storage_commit() {
    local csv_file="$1"
    local message="$2"

    if [ -z "$csv_file" ]; then
        echo "Error: CSV file is required" >&2
        return 1
    fi

    if [ ! -f "$csv_file" ]; then
        echo "Error: CSV file not found: $csv_file" >&2
        return 1
    fi
        local header
    header=$(head -n 1 "$csv_file")

    if [ "$header" != "IP,MAC,VENDOR,PORTS,SERVICES,TIMESTAMP" ]; then
        echo "Error: Invalid CSV header" >&2
        return 1
    fi
        local snapshot_hash
    snapshot_hash=$(sha1sum "$csv_file" | awk '{print $1}')

    echo "Snapshot SHA-1: $snapshot_hash" >&2
    
    local object_file=".gitnet/objects/$snapshot_hash.csv"

    if [ ! -f "$object_file" ]; then
       cp "$csv_file" "$object_file"
       chmod 444 "$object_file"
    fi  

    local parent="none"

    if [ -f ".gitnet/HEAD" ]; then
        parent=$(cat .gitnet/HEAD)
    fi

    if [ -z "$parent" ]; then
        parent="none"
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local hosts
    hosts=$(tail -n +2 "$csv_file" | wc -l)

    local commit_data
    commit_data="blob=$snapshot_hash
parent=$parent
timestamp=$timestamp
message=$message
hosts=$hosts"

    local commit_hash
    commit_hash=$(printf '%s' "$commit_data" | sha1sum | awk '{print $1}')

    echo "Commit SHA-1: $commit_hash" >&2

    local commit_file=".gitnet/commits/$commit_hash"

    printf '%s\n' "$commit_data" > "$commit_file"

    printf '%s\n' "$commit_hash" > .gitnet/HEAD

    printf '%s\t%s\t%s\n' "$commit_hash" "$timestamp" "$message" >> .gitnet/logs/commits.log
    printf '%s\n' "$commit_hash"
    
}

storage_resolve_ref() {
    local ref="$1"

    if [ "$ref" = "HEAD" ]; then
        local current
        current=$(cat .gitnet/HEAD)

        if [ -z "$current" ] || [ "$current" = "none" ]; then
            echo "Error: No commits yet" >&2
            return 1
        fi

        echo "$current"
        return 0
    fi
    if [[ "$ref" =~ ^HEAD~([0-9]+)$ ]]; then
        local steps="${BASH_REMATCH[1]}"
        local current

        current=$(cat .gitnet/HEAD)

        if [ -z "$current" ] || [ "$current" = "none" ]; then
            echo "Error: No commits yet" >&2
            return 1
        fi

        for ((i=0; i<steps; i++)); do
            current=$(storage_get_parent "$current")

            if [ -z "$current" ] || [ "$current" = "none" ]; then
                echo "Error: Reference out of range" >&2
                return 1
            fi
        done

        echo "$current"
        return 0
    fi

        if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
        if [ -f ".gitnet/commits/$ref" ]; then
            echo "$ref"
            return 0
        fi

        echo "Error: Commit not found: $ref" >&2
        return 1
    fi
    if [[ "$ref" =~ ^[0-9a-fA-F]{6,}$ ]]; then
        local match=""
        local count=0
        local commit_file
        local commit_name

        for commit_file in .gitnet/commits/*; do
            [ -f "$commit_file" ] || continue

            commit_name=$(basename "$commit_file")

            if [[ "$commit_name" == "$ref"* ]]; then
                match="$commit_name"
                ((count++))
            fi
        done

        if [ "$count" -eq 0 ]; then
            echo "Error: Commit not found: $ref" >&2
            return 1
        fi

        if [ "$count" -gt 1 ]; then
            echo "Error: Ambiguous commit reference: $ref" >&2
            return 1
        fi

        echo "$match"
        return 0
    fi

    echo "Error: Invalid commit reference: $ref" >&2
    return 1
        
}

storage_get_parent() {
    local commit_hash="$1"

    if [ -z "$commit_hash" ]; then
        echo "Error: Commit hash is required" >&2
        return 1
    fi

    local commit_file=".gitnet/commits/$commit_hash"

    if [ ! -f "$commit_file" ]; then
        echo "Error: Commit not found: $commit_hash" >&2
        return 1
    fi

    local parent
    parent=$(grep '^parent=' "$commit_file" | cut -d'=' -f2)

    if [ -z "$parent" ]; then
        echo "none"
    else
        echo "$parent"
    fi
}

storage_get() {
    local ref="$1"

    if [ -z "$ref" ]; then
        echo "Error: Commit reference is required" >&2
        return 1
    fi
    local commit_hash
    commit_hash=$(storage_resolve_ref "$ref")

    local commit_file=".gitnet/commits/$commit_hash"

    if [ ! -f "$commit_file" ]; then
        echo "Error: Commit not found: $commit_hash" >&2
        return 1
    fi

    local blob_hash
    blob_hash=$(grep '^blob=' "$commit_file" | cut -d'=' -f2)


    local object_file=".gitnet/objects/$blob_hash.csv"

    if [ ! -f "$object_file" ]; then
        echo "Error: Snapshot object not found: $blob_hash" >&2
        return 1
    fi

    cat "$object_file"
}

storage_list() {
    local current
    current=$(cat .gitnet/HEAD)

    if [ -z "$current" ] || [ "$current" = "none" ]; then
        echo "No commits yet."
        return 0
    fi

    while [ "$current" != "none" ]; do
        local commit_file=".gitnet/commits/$current"

        if [ ! -f "$commit_file" ]; then
            echo "Error: Commit not found: $current" >&2
            return 1
        fi

        local timestamp
        local message
        local hosts
        local parent

        timestamp=$(grep 'timestamp=' "$commit_file" | cut -d'=' -f2- | xargs)
        message=$(grep 'message=' "$commit_file" | cut -d'=' -f2- | xargs)
        hosts=$(grep 'hosts=' "$commit_file" | cut -d'=' -f2- | xargs)
        parent=$(grep 'parent=' "$commit_file" | cut -d'=' -f2- | xargs)

        if [ -z "$parent" ]; then
            parent="none"
        fi
        printf "%s  %s  %s hosts  %s\n" \
            "${current:0:8}" "$timestamp" "$hosts" "$message"

        current="$parent"
    done
}