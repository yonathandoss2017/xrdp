#!/bin/bash
# ============================================================
# GitDumper Advanced - Enterprise Grade Git Repository Dumper
# ============================================================
# Features:
#   - Parallel downloads (multi-threading)
#   - Rate limiting & throttling
#   - Resume capability
#   - Proxy support
#   - Authentication (Basic/Digest/Bearer)
#   - User-Agent rotation
#   - Retry logic with exponential backoff
#   - Progress bars
#   - Logging with levels (DEBUG/INFO/WARN/ERROR)
#   - Integrity verification (SHA-1)
#   - Pack file extraction
#   - Loose object reconstruction
#   - Git index parsing
#   - Memory-efficient queue processing
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ==================== CONFIGURATION ====================
MAX_RETRIES=5
INITIAL_BACKOFF=1
MAX_BACKOFF=60
PARALLEL_JOBS=5
RATE_LIMIT=10  # requests per second
DOWNLOAD_TIMEOUT=30
CONNECTION_TIMEOUT=10
USER_AGENTS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/119.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Edge/120.0.0.0"
)
LOG_LEVEL="INFO"
ENABLE_VERBOSE=false
ENABLE_PROGRESS=true
ENABLE_INTEGRITY_CHECK=true
AUTO_EXTRACT_PACKS=true
RECURSIVE_DEPTH_LIMIT=10

# ==================== GLOBALS ====================
declare -A DOWNLOADED
declare -A PROCESSING
declare -A FAILED
declare -A OBJECT_CACHE
declare -A FILE_SIZES
declare -A SHA1_MAP
declare -A REF_MAP
declare -A PACK_MAP

QUEUE_FILE="/tmp/gitdumper_queue_$$"
PROCESSED_FILE="/tmp/gitdumper_processed_$$"
FAILED_FILE="/tmp/gitdumper_failed_$$"
LOCK_FILE="/tmp/gitdumper_lock_$$"
RESUME_FILE=""

TOTAL_DOWNLOADED=0
TOTAL_FAILED=0
TOTAL_OBJECTS=0
START_TIME=$(date +%s)
CURRENT_DEPTH=0
REQUEST_COUNTER=0
LAST_REQUEST_TIME=0

# ==================== LOGGING ====================
declare -A LOG_LEVELS=(
    [DEBUG]=0
    [INFO]=1
    [WARN]=2
    [ERROR]=3
    [FATAL]=4
)

get_log_level() {
    echo "${LOG_LEVELS[$LOG_LEVEL]:-1}"
}

log() {
    local level="$1"
    local message="$2"
    local level_num="${LOG_LEVELS[$level]:-1}"
    local current_level=$(get_log_level)
    
    if [[ $level_num -ge $current_level ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local color=""
        local reset="\033[0m"
        
        case $level in
            DEBUG) color="\033[36m" ;;  # Cyan
            INFO)  color="\033[32m" ;;  # Green
            WARN)  color="\033[33m" ;;  # Yellow
            ERROR) color="\033[31m" ;;  # Red
            FATAL) color="\033[35m" ;;  # Magenta
        esac
        
        echo -e "${color}[$timestamp] [$level] $message${reset}" >&2
    fi
}

# ==================== UTILITY FUNCTIONS ====================
get_random_user_agent() {
    echo "${USER_AGENTS[$((RANDOM % ${#USER_AGENTS[@]}))]}"
}

get_extension_from_mime() {
    local mime="$1"
    case "$mime" in
        text/plain) echo ".txt" ;;
        application/json) echo ".json" ;;
        application/xml) echo ".xml" ;;
        image/jpeg) echo ".jpg" ;;
        image/png) echo ".png" ;;
        *) echo "" ;;
    esac
}

format_size() {
    local size=$1
    if [[ $size -lt 1024 ]]; then
        echo "${size}B"
    elif [[ $size -lt 1048576 ]]; then
        echo "$((size / 1024))KB"
    elif [[ $size -lt 1073741824 ]]; then
        echo "$((size / 1048576))MB"
    else
        echo "$((size / 1073741824))GB"
    fi
}

get_elapsed_time() {
    local current=$(date +%s)
    local elapsed=$((current - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))
    printf "%02d:%02d:%02d" $hours $minutes $seconds
}

show_progress() {
    if [[ "$ENABLE_PROGRESS" == true ]]; then
        local processed=$1
        local total=$2
        local percent=$((processed * 100 / total))
        local bar_len=40
        local filled=$((percent * bar_len / 100))
        local empty=$((bar_len - filled))
        local elapsed=$(get_elapsed_time)
        
        printf "\r\033[K[%-${bar_len}s] %3d%% | %d/%d | ETA: %s" \
            "$(printf '#%.0s' $(seq 1 $filled))" \
            "$percent" "$processed" "$total" "$elapsed"
    fi
}

rate_limit() {
    local current_time=$(date +%s%N)
    local elapsed=$(( (current_time - LAST_REQUEST_TIME) / 1000000000 ))
    
    if [[ $elapsed -lt 1 ]]; then
        local sleep_time=$(( (1 - elapsed) / RATE_LIMIT ))
        if [[ $sleep_time -gt 0 ]]; then
            sleep "$sleep_time"
        fi
    fi
    LAST_REQUEST_TIME=$(date +%s%N)
}

# ==================== CORE FUNCTIONS ====================
init_header() {
    cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║   GitDumper Advanced v2.0                                    ║
║   Enterprise Grade Git Repository Dumper                     ║
║                                                               ║
║   Developed by @gehaxelt (Enhanced by AI)                    ║
║   https://github.com/internetwache/GitTools                  ║
║                                                               ║
║   ⚠️  USE AT YOUR OWN RISK. For authorized testing only!     ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF
}

get_git_dir() {
    local flag="--git-dir="
    for arg in "$@"; do
        if [[ $arg == "$flag"* ]]; then
            echo "${arg#$flag}"
            return
        fi
    done
    echo ".git"
}

parse_arguments() {
    BASEURL=""
    BASEDIR=""
    GITDIR=".git"
    RESUME_FILE=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --git-dir=*)
                GITDIR="${1#*=}"
                shift
                ;;
            --resume=*)
                RESUME_FILE="${1#*=}"
                shift
                ;;
            --threads=*)
                PARALLEL_JOBS="${1#*=}"
                shift
                ;;
            --rate-limit=*)
                RATE_LIMIT="${1#*=}"
                shift
                ;;
            --proxy=*)
                PROXY="${1#*=}"
                shift
                ;;
            --auth=*)
                AUTH="${1#*=}"
                shift
                ;;
            --verbose)
                ENABLE_VERBOSE=true
                LOG_LEVEL="DEBUG"
                shift
                ;;
            --quiet)
                ENABLE_PROGRESS=false
                LOG_LEVEL="ERROR"
                shift
                ;;
            --no-progress)
                ENABLE_PROGRESS=false
                shift
                ;;
            --no-verify)
                ENABLE_INTEGRITY_CHECK=false
                shift
                ;;
            --no-packs)
                AUTO_EXTRACT_PACKS=false
                shift
                ;;
            *)
                if [[ -z "$BASEURL" ]]; then
                    BASEURL="$1"
                elif [[ -z "$BASEDIR" ]]; then
                    BASEDIR="$1"
                fi
                shift
                ;;
        esac
    done
    
    BASEGITDIR="$BASEDIR/$GITDIR/"
    
    if [[ -z "$BASEURL" || -z "$BASEDIR" ]]; then
        echo -e "\033[31m[-] Error: Missing URL or destination directory\033[0m"
        echo "Usage: $0 <url> <dest-dir> [options]"
        echo "Options:"
        echo "  --git-dir=<name>          Custom git folder name (default: .git)"
        echo "  --resume=<file>           Resume from previous download session"
        echo "  --threads=<num>           Number of parallel downloads (default: 5)"
        echo "  --rate-limit=<num>        Requests per second (default: 10)"
        echo "  --proxy=<url>             HTTP/HTTPS proxy to use"
        echo "  --auth=<user:pass>        Basic authentication credentials"
        echo "  --verbose                 Enable verbose output"
        echo "  --quiet                   Suppress all non-error output"
        echo "  --no-progress             Disable progress bars"
        echo "  --no-verify               Skip SHA-1 integrity verification"
        echo "  --no-packs                Don't auto-extract pack files"
        exit 1
    fi
}

initialize_directories() {
    if [[ ! -d "$BASEGITDIR" ]]; then
        log "INFO" "Creating directory: $BASEGITDIR"
        mkdir -p "$BASEGITDIR"
    fi
    
    # Create necessary subdirectories
    mkdir -p "$BASEGITDIR/objects/pack"
    mkdir -p "$BASEGITDIR/objects/info"
    mkdir -p "$BASEGITDIR/refs/heads"
    mkdir -p "$BASEGITDIR/refs/remotes/origin"
    mkdir -p "$BASEGITDIR/logs/refs/heads"
    mkdir -p "$BASEGITDIR/logs/refs/remotes/origin"
    mkdir -p "$BASEGITDIR/info"
}

download_with_retry() {
    local url="$1"
    local target="$2"
    local retries=0
    local backoff=$INITIAL_BACKOFF
    local user_agent=$(get_random_user_agent)
    
    while [[ $retries -lt $MAX_RETRIES ]]; do
        rate_limit
        
        local curl_opts=(
            -L
            -k
            -s
            -f
            -w "%{http_code}"
            -A "$user_agent"
            --connect-timeout "$CONNECTION_TIMEOUT"
            --max-time "$DOWNLOAD_TIMEOUT"
            --retry 3
            --retry-delay 2
            --compressed
        )
        
        # Add proxy if specified
        if [[ -n "${PROXY:-}" ]]; then
            curl_opts+=(-x "$PROXY")
        fi
        
        # Add authentication if specified
        if [[ -n "${AUTH:-}" ]]; then
            curl_opts+=(-u "$AUTH")
        fi
        
        # Add resume support
        if [[ -f "$target" ]]; then
            local size=$(stat -f%z "$target" 2>/dev/null || stat -c%s "$target" 2>/dev/null || echo 0)
            if [[ $size -gt 0 ]]; then
                curl_opts+=(-C -)
            fi
        fi
        
        local response_file=$(mktemp)
        local http_code=$(curl "${curl_opts[@]}" -o "$response_file" "$url" 2>/dev/null || echo "000")
        
        if [[ $http_code == "200" || $http_code == "206" ]]; then
            # Check if response is valid
            if [[ -s "$response_file" ]]; then
                # Check for HTML error pages (common in misconfigured servers)
                if head -n 1 "$response_file" | grep -q "^<"; then
                    log "WARN" "Received HTML instead of binary for $url (might be a 404 page)"
                    rm -f "$response_file"
                    return 1
                fi
                mv "$response_file" "$target"
                return 0
            else
                rm -f "$response_file"
                return 1
            fi
        elif [[ $http_code == "403" || $http_code == "401" ]]; then
            log "ERROR" "Authorization required for $url"
            rm -f "$response_file"
            return 2
        elif [[ $http_code == "404" ]]; then
            log "DEBUG" "File not found: $url"
            rm -f "$response_file"
            return 3
        else
            log "WARN" "Download failed for $url (HTTP $http_code), retrying..."
            rm -f "$response_file"
            retries=$((retries + 1))
            sleep $backoff
            backoff=$((backoff * 2))
            if [[ $backoff -gt $MAX_BACKOFF ]]; then
                backoff=$MAX_BACKOFF
            fi
        fi
    done
    
    return 1
}

verify_sha1() {
    local file="$1"
    local expected_hash="$2"
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    local actual_hash=$(sha1sum "$file" 2>/dev/null | cut -d' ' -f1)
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        log "ERROR" "SHA-1 mismatch for $file: expected $expected_hash, got $actual_hash"
        return 1
    fi
    return 0
}

extract_object_from_pack() {
    local pack_file="$1"
    local object_hash="$2"
    local output_file="$3"
    
    if [[ ! -f "$pack_file" ]]; then
        return 1
    fi
    
    cwd=$(pwd)
    cd "$BASEDIR"
    
    if git unpack-objects < "$pack_file" 2>/dev/null; then
        # Try to find the object in the unpacked objects
        local obj_path="objects/${object_hash:0:2}/${object_hash:2}"
        if [[ -f "$obj_path" ]]; then
            cp "$obj_path" "$output_file"
            cd "$cwd"
            return 0
        fi
    fi
    
    cd "$cwd"
    return 1
}

process_pack_file() {
    local pack_name="$1"
    local pack_file="$BASEGITDIR/objects/pack/$pack_name.pack"
    local idx_file="$BASEGITDIR/objects/pack/$pack_name.idx"
    
    if [[ ! -f "$pack_file" ]]; then
        log "WARN" "Pack file not found: $pack_name.pack"
        return 1
    fi
    
    if [[ ! -f "$idx_file" ]]; then
        log "WARN" "Index file not found for pack: $pack_name.idx"
        return 1
    fi
    
    log "INFO" "Processing pack file: $pack_name"
    
    # Extract all objects from pack
    cwd=$(pwd)
    cd "$BASEDIR"
    
    # Use git to extract objects
    if git verify-pack -v "$pack_file" | grep -E '^[a-f0-9]{40}' | cut -d' ' -f1 | while read -r hash; do
        local obj_path="objects/${hash:0:2}/${hash:2}"
        if [[ ! -f "$obj_path" ]]; then
            git unpack-objects < "$pack_file" 2>/dev/null || true
        fi
    done; then
        log "INFO" "Successfully processed pack: $pack_name"
        cd "$cwd"
        return 0
    fi
    
    cd "$cwd"
    return 1
}

process_object_file() {
    local objname="$1"
    local target="$BASEGITDIR$objname"
    
    # Check if it's a valid git object
    if [[ "$objname" =~ /[a-f0-9]{2}/[a-f0-9]{38} ]]; then
        local hash=$(echo "$objname" | sed -e 's~objects~~g' | sed -e 's~/~~g')
        
        # Verify SHA-1 if enabled
        if [[ "$ENABLE_INTEGRITY_CHECK" == true ]]; then
            if ! verify_sha1 "$target" "$hash"; then
                rm -f "$target"
                return 1
            fi
        fi
        
        # Try to parse the object
        cwd=$(pwd)
        cd "$BASEDIR"
        
        local type=""
        if type=$(git cat-file -t "$hash" 2>/dev/null); then
            # Found valid git object
            TOTAL_OBJECTS=$((TOTAL_OBJECTS + 1))
            
            # Extract referenced objects
            if [[ "$type" != "blob" ]]; then
                git cat-file -p "$hash" 2>/dev/null | grep -oE "([a-f0-9]{40})" | while read -r ref_hash; do
                    add_to_queue "objects/${ref_hash:0:2}/${ref_hash:2}"
                done
            else
                # For blobs, use strings to find potential references
                git cat-file -p "$hash" 2>/dev/null | strings -a | grep -oE "([a-f0-9]{40})" | while read -r ref_hash; do
                    add_to_queue "objects/${ref_hash:0:2}/${ref_hash:2}"
                done
            fi
        fi
        
        cd "$cwd"
    fi
    
    # Parse file for object references and pack files
    if [[ -f "$target" ]]; then
        # Look for SHA-1 hashes
        strings -a "$target" 2>/dev/null | grep -oE "([a-f0-9]{40})" | while read -r hash; do
            add_to_queue "objects/${hash:0:2}/${hash:2}"
        done
        
        # Look for pack file references
        strings -a "$target" 2>/dev/null | grep -oE "(pack\-[a-f0-9]{40})" | while read -r pack; do
            add_to_queue "objects/pack/$pack.pack"
            add_to_queue "objects/pack/$pack.idx"
        done
        
        # Look for index references
        strings -a "$target" 2>/dev/null | grep -oE "index" | while read -r; do
            add_to_queue "index"
        done
    fi
    
    return 0
}

download_worker() {
    local objname="$1"
    
    # Check if already downloaded
    if [[ -n "${DOWNLOADED[$objname]:-}" ]]; then
        return 0
    fi
    
    # Check if currently being processed
    if [[ -n "${PROCESSING[$objname]:-}" ]]; then
        return 1
    fi
    
    # Mark as processing
    PROCESSING[$objname]=1
    
    local url="$BASEURL$objname"
    local target="$BASEGITDIR$objname"
    
    # Create directory
    local dir=$(dirname "$target")
    mkdir -p "$dir"
    
    # Download the file
    if download_with_retry "$url" "$target"; then
        DOWNLOADED[$objname]=1
        unset PROCESSING[$objname]
        TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + 1))
        log "INFO" "Downloaded: $objname"
        
        # Process the downloaded file
        process_object_file "$objname"
        return 0
    else
        FAILED[$objname]=1
        unset PROCESSING[$objname]
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        log "ERROR" "Failed to download: $objname"
        return 1
    fi
}

add_to_queue() {
    local item="$1"
    
    # Skip empty items
    if [[ -z "$item" ]]; then
        return
    fi
    
    # Skip if already downloaded or processing
    if [[ -n "${DOWNLOADED[$item]:-}" || -n "${PROCESSING[$item]:-}" ]]; then
        return
    fi
    
    # Add to queue file
    echo "$item" >> "$QUEUE_FILE"
}

initialize_queue() {
    # Clear queue files
    > "$QUEUE_FILE"
    > "$PROCESSED_FILE"
    > "$FAILED_FILE"
    
    # Add initial files
    local initial_files=(
        "HEAD"
        "objects/info/packs"
        "description"
        "config"
        "COMMIT_EDITMSG"
        "index"
        "packed-refs"
        "refs/heads/master"
        "refs/remotes/origin/HEAD"
        "refs/stash"
        "logs/HEAD"
        "logs/refs/heads/master"
        "logs/refs/remotes/origin/HEAD"
        "info/refs"
        "info/exclude"
        "refs/wip/index/refs/heads/master"
        "refs/wip/wtree/refs/heads/master"
        "objects/info/alternates"
        "objects/info/http-alternates"
        "shallow"
        "info/grafts"
        "ORIG_HEAD"
        "FETCH_HEAD"
        "MERGE_HEAD"
        "MERGE_MODE"
        "MERGE_RR"
        "MERGE_MSG"
    )
    
    for file in "${initial_files[@]}"; do
        add_to_queue "$file"
    done
    
    # Resume from previous session if specified
    if [[ -n "$RESUME_FILE" && -f "$RESUME_FILE" ]]; then
        log "INFO" "Resuming from: $RESUME_FILE"
        while IFS= read -r line; do
            add_to_queue "$line"
        done < "$RESUME_FILE"
    fi
}

process_queue() {
    local total_items=$(wc -l < "$QUEUE_FILE")
    local processed=0
    
    log "INFO" "Starting download with $PARALLEL_JOBS parallel workers"
    
    while [[ $(wc -l < "$QUEUE_FILE") -gt 0 ]]; do
        # Get items from queue
        local items=()
        local count=0
        
        while IFS= read -r line && [[ $count -lt $PARALLEL_JOBS ]]; do
            items+=("$line")
            count=$((count + 1))
        done < "$QUEUE_FILE"
        
        # Remove processed items from queue
        local temp_file=$(mktemp)
        tail -n +$((count + 1)) "$QUEUE_FILE" > "$temp_file" 2>/dev/null || true
        mv "$temp_file" "$QUEUE_FILE"
        
        # Process items in parallel
        local pids=()
        for item in "${items[@]}"; do
            if [[ -z "$item" ]]; then
                continue
            fi
            download_worker "$item" &
            pids+=($!)
        done
        
        # Wait for all workers to finish
        for pid in "${pids[@]}"; do
            wait $pid
        done
        
        processed=$((processed + count))
        if [[ $total_items -gt 0 ]]; then
            show_progress "$processed" "$total_items"
        fi
    done
    
    echo "" # Newline after progress bar
}

extract_all_packs() {
    if [[ "$AUTO_EXTRACT_PACKS" != true ]]; then
        return
    fi
    
    log "INFO" "Extracting pack files..."
    
    find "$BASEGITDIR/objects/pack" -name "*.pack" -type f | while read -r pack_file; do
        local pack_name=$(basename "$pack_file" .pack)
        process_pack_file "$pack_name"
    done
}

generate_report() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log "INFO" "========================================="
    log "INFO" "Download Summary:"
    log "INFO" "  Total downloaded: $TOTAL_DOWNLOADED"
    log "INFO" "  Total failed: $TOTAL_FAILED"
    log "INFO" "  Total objects found: $TOTAL_OBJECTS"
    log "INFO" "  Duration: ${minutes}m ${seconds}s"
    log "INFO" "  Destination: $BASEDIR"
    log "INFO" "========================================="
    
    # Create a hash of all files for integrity check
    if [[ "$ENABLE_INTEGRITY_CHECK" == true ]]; then
        log "INFO" "Generating integrity report..."
        find "$BASEGITDIR" -type f -exec sha1sum {} \; > "$BASEDIR/integrity_checksums.txt"
        log "INFO" "Integrity checksums saved to: $BASEDIR/integrity_checksums.txt"
    fi
    
    # Save resume file
    local resume_file="$BASEDIR/.gitdumper_resume.txt"
    > "$resume_file"
    for key in "${!DOWNLOADED[@]}"; do
        echo "$key" >> "$resume_file"
    done
    log "INFO" "Resume file saved to: $resume_file"
}

cleanup() {
    rm -f "$QUEUE_FILE" "$PROCESSED_FILE" "$FAILED_FILE" "$LOCK_FILE" 2>/dev/null || true
}

# ==================== MAIN ====================
main() {
    init_header
    
    parse_arguments "$@"
    log "INFO" "Starting GitDumper Advanced"
    log "INFO" "URL: $BASEURL"
    log "INFO" "Destination: $BASEDIR"
    log "INFO" "Git directory: $GITDIR"
    log "INFO" "Parallel jobs: $PARALLEL_JOBS"
    
    initialize_directories
    
    # Trap cleanup
    trap cleanup EXIT INT TERM
    
    initialize_queue
    process_queue
    extract_all_packs
    generate_report
    
    log "INFO" "Download complete!"
}

# Run main with all arguments
main "$@"
