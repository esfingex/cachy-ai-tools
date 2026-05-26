#!/usr/bin/env bash
# ==============================================================================
#   cachy-ai-tools - cavemem.sh
#   Purpose: Linux CLI for the local CaveMem Node stack (cross-agent memory)
#   Equivalent of cavemem.ps1 (Windows). Talks to local Express + SQLite server.
# ==============================================================================
set -uo pipefail

# ANSI colors (actual ESC byte so heredocs render correctly)
CYAN=$'\e[1;36m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
RED=$'\e[1;31m'
MAGENTA=$'\e[1;35m'
GRAY=$'\e[1;30m'
WHITE=$'\e[1;37m'
RESET=$'\e[0m'

log_info()    { echo -e "${CYAN}[*] $*${RESET}"; }
log_ok()      { echo -e "${GREEN}[OK] $*${RESET}"; }
log_warn()    { echo -e "${YELLOW}[!] $*${RESET}"; }
log_error()   { echo -e "${RED}[ERROR] $*${RESET}" >&2; }

# Resolve real script directory (handles symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# Stack dir: <repo>/cavemem-stack (parent of scripts/)
STACK_DIR="${CAVEMEM_STACK_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/cavemem-stack}"
SERVER_URL="${CAVEMEM_SERVER_URL:-http://127.0.0.1:3000}"
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/cavemem-stack.pid"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/cavemem-stack.log"

# Project context from current dir name
PROJECT_NAME="$(basename "$PWD")"
PROJECT_NAME="${PROJECT_NAME//[^a-zA-Z0-9_-]/_}"

require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        log_error "'curl' is required but not installed."
        exit 1
    fi
}

require_node() {
    if ! command -v node >/dev/null 2>&1; then
        log_error "'node' is required but not installed."
        log_warn "Install with: sudo pacman -S nodejs-lts-jod npm (CachyOS/Arch)"
        exit 1
    fi
}

ensure_server() {
    require_curl
    if curl -sf --max-time 2 "$SERVER_URL/api/health" >/dev/null 2>&1; then
        return 0
    fi

    log_warn "CaveMem server offline. Starting in background..."
    require_node

    if [ ! -f "$STACK_DIR/server.js" ]; then
        log_error "server.js not found at: $STACK_DIR/server.js"
        log_warn "Run 'sudo bash scripts/cavemem-install.sh' first or set CAVEMEM_STACK_DIR."
        exit 1
    fi

    if [ ! -d "$STACK_DIR/node_modules" ]; then
        log_error "Node dependencies not installed. Run 'sudo bash scripts/cavemem-install.sh' first."
        exit 1
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    (cd "$STACK_DIR" && nohup node server.js >>"$LOG_FILE" 2>&1 &) </dev/null
    # Give nohup a moment; capture pid via lsof later if needed.

    # Wait up to ~15s for the model to warm up
    for i in $(seq 1 30); do
        sleep 0.5
        if curl -sf --max-time 1 "$SERVER_URL/api/health" >/dev/null 2>&1; then
            log_ok "Server started on $SERVER_URL"
            return 0
        fi
    done
    log_error "Could not connect to local server. Check $LOG_FILE"
    exit 1
}

show_help() {
    cat <<EOF

  ${MAGENTA}CaveMem - Global AI Memory Stack (Linux)${RESET}
  $(echo -e "${GRAY}============================================${RESET}")
  Project Context: ${CYAN}$PROJECT_NAME${RESET}
  Server: $SERVER_URL
  Stack Dir: $STACK_DIR

  Commands:
    cavemem add <category> <"content"> [-t "tag1,tag2"]
    cavemem edit <id> [-c <category>] [-t <"tag1,tag2">] [<"new content">]
    cavemem query <"semantic search"> [-l N] [-T 0.25]
    cavemem search <"semantic search">       (alias)
    cavemem list  [-l N] [-o N] [-c <category>]
    cavemem status
    cavemem delete <id>
    cavemem web
    cavemem stop                             (stop background server)

  Knowledge Seeds:
    cavemem seed --file <path/to/seed.json>  (import knowledge from JSON — idempotent)
    cavemem seed --file <path> --dry-run     (preview without inserting)

  Maintenance:
    cavemem dedup     [-T 0.92] [-c <cat>]   (scan, list duplicate pairs)
    cavemem merge     <keepId> <dropId> [--append]
    cavemem autodedup [-T 0.92] [--dry]      (auto-merge duplicates)
    cavemem reembed   [--force]              (recompute all vectors; needed after model change)

  Categories: gotcha, rule, flow, config, dependency

  Env overrides: CAVEMEM_SERVER_URL, CAVEMEM_STACK_DIR

EOF
}

# Parse named flags from remaining args.
# Usage: get_flag <name> <args...>
get_flag() {
    local name="$1"; shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -"$name"|--"$name")
                if [ "$#" -ge 2 ]; then echo "$2"; return 0; fi
                ;;
        esac
        shift
    done
    return 1
}

# Build positional args (non-flag, non-flag-value) from remaining args
get_positionals() {
    local skip=0
    local out=()
    for arg in "$@"; do
        if [ $skip -eq 1 ]; then skip=0; continue; fi
        case "$arg" in
            -*) skip=1 ;;
            *) out+=("$arg") ;;
        esac
    done
    printf '%s\n' "${out[@]}"
}

# JSON-escape a string for inclusion in a JSON value (using python3 or jq fallback)
json_escape() {
    local raw="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$raw"
    elif command -v jq >/dev/null 2>&1; then
        printf '%s' "$raw" | jq -Rs .
    else
        # Fallback: minimal escape (no control chars / unicode)
        local out="${raw//\\/\\\\}"
        out="${out//\"/\\\"}"
        out="${out//$'\n'/\\n}"
        out="${out//$'\r'/\\r}"
        out="${out//$'\t'/\\t}"
        printf '"%s"' "$out"
    fi
}

cmd_add() {
    local category="${1:-}" content="${2:-}"; shift 2 2>/dev/null || true
    local tags
    tags="$(get_flag t "$@" || get_flag tags "$@" || echo "")"

    if [ -z "$category" ] || [ -z "$content" ]; then
        log_error 'Usage: cavemem add <category> <"content"> [-t "a,b"]'
        exit 1
    fi

    local body
    body=$(printf '{"project":%s,"category":%s,"content":%s,"tags":%s}' \
        "$(json_escape "$PROJECT_NAME")" \
        "$(json_escape "$category")" \
        "$(json_escape "$content")" \
        "$(json_escape "$tags")")

    local resp
    resp=$(curl -sS -X POST "$SERVER_URL/api/memories" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$body")

    if echo "$resp" | grep -q '"success":true'; then
        log_ok "Memory added to project '$PROJECT_NAME'"
        echo "$resp"
    else
        log_error "Failed to save memory: $resp"
        exit 1
    fi
}

cmd_edit() {
    local id="${1:-}"; shift || true
    if [ -z "$id" ]; then
        log_error 'Usage: cavemem edit <id> [-c <category>] [-t <"tags">] [<"new content">]'
        exit 1
    fi

    local category content tags
    category="$(get_flag c "$@" || get_flag category "$@" || echo "")"
    tags="$(get_flag t "$@" || get_flag tags "$@" || echo "")"

    # First positional after flags is treated as content
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -*) shift 2 || true ;;
            *) content="$1"; break ;;
        esac
    done

    local body="{\"project\":$(json_escape "$PROJECT_NAME")"
    [ -n "${category:-}" ] && body+=",\"category\":$(json_escape "$category")"
    [ -n "${content:-}" ]  && body+=",\"content\":$(json_escape "$content")"
    [ -n "${tags:-}" ]     && body+=",\"tags\":$(json_escape "$tags")"
    body+="}"

    if [ "$body" = "{\"project\":$(json_escape "$PROJECT_NAME")}" ]; then
        log_error 'Provide at least one of: -c <category>, -t <"tags">, or new content'
        exit 1
    fi

    local resp
    resp=$(curl -sS -X PUT "$SERVER_URL/api/memories/$id" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "$body")

    if echo "$resp" | grep -q '"success":true' && echo "$resp" | grep -q '"updated":true'; then
        log_ok "Memory $id updated"
    else
        log_warn "Update did not change anything: $resp"
    fi
}

cmd_query() {
    local q="${1:-}"; shift || true
    if [ -z "$q" ]; then
        log_error 'Usage: cavemem query "<text>" [-l N] [-T 0.25]'
        exit 1
    fi
    local limit threshold
    limit="$(get_flag l "$@" || get_flag limit "$@" || echo 5)"
    threshold="$(get_flag T "$@" || get_flag threshold "$@" || echo "")"

    local q_enc
    q_enc=$(printf %s "$q" | jq -sRr @uri 2>/dev/null || python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$q")

    local url="$SERVER_URL/api/search?project=$PROJECT_NAME&q=$q_enc&limit=$limit"
    [ -n "$threshold" ] && url+="&threshold=$threshold"

    local resp
    resp=$(curl -sS "$url")

    echo ""
    echo -e "${MAGENTA}[Search] Results for: '$q'${RESET}"
    echo -e "${CYAN}   Project Context: $PROJECT_NAME${RESET}"
    echo -e "${GRAY}   ------------------------------------------------------------${RESET}"

    if [ "$resp" = "[]" ] || [ -z "$resp" ]; then
        echo -e "${YELLOW}   No relevant semantic matches found.${RESET}"
        return
    fi

    if command -v jq >/dev/null 2>&1; then
        echo "$resp" | jq -r '.[] |
            "   [\((.score*100)|round)%] [ID: \(.id)] [\(.category|ascii_upcase)] > \(.content)" +
            (if (.tags|length) > 0 then "\n   Tags: #" + (.tags|join(" #")) else "" end) +
            "\n   ------------------------------------------------------------"'
    else
        echo "$resp"
    fi
    echo ""
}

cmd_list() {
    local limit offset cat_filter
    limit="$(get_flag l "$@" || get_flag limit "$@" || echo 200)"
    offset="$(get_flag o "$@" || get_flag offset "$@" || echo 0)"
    cat_filter="$(get_flag c "$@" || get_flag category "$@" || echo "")"

    local url="$SERVER_URL/api/memories?project=$PROJECT_NAME&limit=$limit&offset=$offset"
    [ -n "$cat_filter" ] && url+="&category=$cat_filter"

    local resp
    resp=$(curl -sS "$url")

    echo ""
    echo -e "${MAGENTA}[List] Memories for project: '$PROJECT_NAME'${RESET}"
    echo -e "${GRAY}   ------------------------------------------------------------${RESET}"

    if command -v jq >/dev/null 2>&1; then
        local total
        total=$(echo "$resp" | jq -r '.total // 0')
        if [ "$total" = "0" ]; then
            echo -e "${YELLOW}   Empty. Add with 'cavemem add'.${RESET}"
        else
            echo "$resp" | jq -r '.memories[] |
                "   [ID: \(.id)] [\(.category|ascii_upcase)] \(.content)" +
                (if (.tags|length) > 0 then "\n   Tags: #" + (.tags|join(" #")) else "" end) +
                "\n   ------------------------------------------------------------"'
            echo -e "${GRAY}   Showing $(echo "$resp" | jq '.memories|length') of $total total${RESET}"
        fi
    else
        echo "$resp"
    fi
    echo ""
}

cmd_status() {
    local resp
    resp=$(curl -sS "$SERVER_URL/api/status?project=$PROJECT_NAME")

    echo ""
    echo -e "${MAGENTA}[Stats] Project Status: '$PROJECT_NAME'${RESET}"
    echo -e "${GRAY}   ------------------------------------------------------------${RESET}"

    if command -v jq >/dev/null 2>&1; then
        local count size kb
        count=$(echo "$resp" | jq -r '.stats.count')
        size=$(echo "$resp" | jq -r '.stats.sizeBytes')
        kb=$(awk -v s="$size" 'BEGIN{printf "%.2f", s/1024}')
        echo -e "   Database File : ${WHITE}$(echo "$resp" | jq -r '.stats.projectName').db${RESET}"
        echo -e "   Total Items   : ${WHITE}${count}${RESET}"
        echo -e "   File Size     : ${WHITE}${kb} KB${RESET}"
        echo ""
        echo -e "${CYAN}   By Categories:${RESET}"
        echo "$resp" | jq -r '.stats.categories | to_entries[] | "     - \(.key) : \(.value)"' || echo "     No items recorded."
    else
        echo "$resp"
    fi
    echo -e "${GRAY}   ------------------------------------------------------------${RESET}"
    echo ""
}

cmd_delete() {
    local id="${1:-}"
    if [ -z "$id" ]; then
        log_error "Usage: cavemem delete <id>"
        exit 1
    fi
    local resp
    resp=$(curl -sS -X DELETE "$SERVER_URL/api/memories/$id?project=$PROJECT_NAME")
    if echo "$resp" | grep -q '"deleted":true'; then
        log_ok "Memory ID $id deleted from project '$PROJECT_NAME'"
    else
        log_warn "Memory ID $id not found (resp: $resp)"
    fi
}

cmd_web() {
    local url="$SERVER_URL/?project=$PROJECT_NAME"
    log_ok "Opening CaveMem panel at $url"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then open "$url"
    else echo "Open manually: $url"; fi
}

cmd_stop() {
    if command -v pkill >/dev/null 2>&1; then
        if pkill -f "node $STACK_DIR/server.js" 2>/dev/null || pkill -f "node server.js" 2>/dev/null; then
            log_ok "Stopped CaveMem background server."
        else
            log_warn "No running CaveMem server process found."
        fi
    else
        log_error "pkill not available. Stop the server manually."
    fi
}

cmd_dedup() {
    local threshold cat_filter
    threshold="$(get_flag T "$@" || get_flag threshold "$@" || echo "")"
    cat_filter="$(get_flag c "$@" || get_flag category "$@" || echo "")"

    local url="$SERVER_URL/api/dedup?project=$PROJECT_NAME"
    [ -n "$threshold" ] && url+="&threshold=$threshold"
    [ -n "$cat_filter" ] && url+="&category=$cat_filter"

    local resp
    resp=$(curl -sS "$url")

    echo ""
    echo -e "${MAGENTA}[Dedup] Scanning project '$PROJECT_NAME'${RESET}"
    echo -e "${GRAY}   ------------------------------------------------------------${RESET}"

    if command -v jq >/dev/null 2>&1; then
        local count
        count=$(echo "$resp" | jq -r '.count // 0')
        local th
        th=$(echo "$resp" | jq -r '.threshold // 0.92')
        echo -e "   Threshold: $th"
        if [ "$count" = "0" ]; then
            echo -e "${GREEN}   No duplicate pairs above threshold.${RESET}"
        else
            echo -e "${YELLOW}   Found $count duplicate pair(s):${RESET}"
            echo ""
            echo "$resp" | jq -r '.pairs[] |
                "   [SIM \((.score*100)|round)%]" +
                "\n     [ID \(.a.id) | \(.a.category|ascii_upcase)] \(.a.content)" +
                "\n     [ID \(.b.id) | \(.b.category|ascii_upcase)] \(.b.content)" +
                "\n     -> cavemem merge \(.a.id) \(.b.id)" +
                "\n   ------------------------------------------------------------"'
        fi
    else
        echo "$resp"
    fi
    echo ""
}

cmd_merge() {
    local keep_id="${1:-}" drop_id="${2:-}"
    if [ -z "$keep_id" ] || [ -z "$drop_id" ]; then
        log_error "Usage: cavemem merge <keepId> <dropId> [--append]"
        exit 1
    fi
    local append=false
    for a in "$@"; do
        if [ "$a" = "-append" ] || [ "$a" = "--append" ]; then append=true; break; fi
    done

    local body
    body=$(printf '{"project":%s,"keepId":%d,"dropId":%d,"appendContent":%s}' \
        "$(json_escape "$PROJECT_NAME")" "$keep_id" "$drop_id" "$append")

    local resp
    resp=$(curl -sS -X POST "$SERVER_URL/api/dedup/merge" \
        -H "Content-Type: application/json; charset=utf-8" -d "$body")

    if echo "$resp" | grep -q '"success":true'; then
        log_ok "Merged: kept #$keep_id, dropped #$drop_id"
        if command -v jq >/dev/null 2>&1; then
            local tags
            tags=$(echo "$resp" | jq -r '.mergedTags | join(", ")')
            echo "   Tags: $tags"
        fi
    else
        log_error "Merge failed: $resp"
        exit 1
    fi
}

cmd_autodedup() {
    local threshold dry=false
    threshold="$(get_flag T "$@" || get_flag threshold "$@" || echo "")"
    for a in "$@"; do
        if [ "$a" = "-dry" ] || [ "$a" = "--dry" ] || [ "$a" = "-dry-run" ] || [ "$a" = "--dry-run" ]; then dry=true; break; fi
    done

    local body
    if [ -n "$threshold" ]; then
        body=$(printf '{"project":%s,"threshold":%s,"dryRun":%s}' \
            "$(json_escape "$PROJECT_NAME")" "$threshold" "$dry")
    else
        body=$(printf '{"project":%s,"dryRun":%s}' \
            "$(json_escape "$PROJECT_NAME")" "$dry")
    fi

    local resp
    resp=$(curl -sS -X POST "$SERVER_URL/api/dedup/auto" \
        -H "Content-Type: application/json; charset=utf-8" -d "$body")

    echo ""
    if command -v jq >/dev/null 2>&1; then
        local mode pairs merged
        mode=$([ "$(echo "$resp" | jq -r '.dryRun')" = "true" ] && echo "DRY RUN" || echo "EXECUTED")
        pairs=$(echo "$resp" | jq -r '.pairsFound')
        merged=$(echo "$resp" | jq -r '.merged')
        echo -e "${MAGENTA}[AutoDedup $mode]${RESET} Pairs found: $pairs | Merges: $merged"
        echo "$resp" | jq -r '.actions[]? | "   [SIM \((.score*100)|round)%] kept #\(.kept), dropped #\(.dropped)"'
    else
        echo "$resp"
    fi
    echo ""
}

cmd_seed() {
    require_node
    local seed_script
    seed_script="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/cavemem-seed.js"

    if [ ! -f "$seed_script" ]; then
        log_error "cavemem-seed.js not found at: $seed_script"
        exit 1
    fi

    # Pass all args through to the seed script
    node "$seed_script" "$@"
}

cmd_reembed() {
    local force=false
    for a in "$@"; do
        if [ "$a" = "-force" ] || [ "$a" = "--force" ]; then force=true; break; fi
    done

    local body
    body=$(printf '{"project":%s,"force":%s}' "$(json_escape "$PROJECT_NAME")" "$force")

    log_warn "Recomputing all vectors for '$PROJECT_NAME' (force=$force)..."
    local resp
    resp=$(curl -sS --max-time 600 -X POST "$SERVER_URL/api/reembed" \
        -H "Content-Type: application/json; charset=utf-8" -d "$body")

    if command -v jq >/dev/null 2>&1; then
        local total updated failed dim
        total=$(echo "$resp" | jq -r '.total')
        updated=$(echo "$resp" | jq -r '.updated')
        failed=$(echo "$resp" | jq -r '.failed')
        dim=$(echo "$resp" | jq -r '.detectedDim')
        log_ok "Reembed done: total=$total updated=$updated failed=$failed dim=$dim"
        if [ "$failed" != "0" ] && [ "$failed" != "null" ]; then
            echo "$resp" | jq -r '.errors[] | "   ID \(.id): \(.error)"'
        fi
    else
        echo "$resp"
    fi
}

# Main dispatch
ACTION="${1:-}"

case "${ACTION,,}" in
    ""|-h|--help|help) show_help; exit 0 ;;
    stop) cmd_stop; exit 0 ;;
esac

ensure_server

case "${ACTION,,}" in
    add)              shift; cmd_add "$@" ;;
    edit)             shift; cmd_edit "$@" ;;
    query|search)     shift; cmd_query "$@" ;;
    list)             shift; cmd_list "$@" ;;
    status)           cmd_status ;;
    delete)           shift; cmd_delete "$@" ;;
    web)              cmd_web ;;
    seed)             shift; cmd_seed "$@" ;;
    dedup)            shift; cmd_dedup "$@" ;;
    merge)            shift; cmd_merge "$@" ;;
    autodedup)        shift; cmd_autodedup "$@" ;;
    reembed)          shift; cmd_reembed "$@" ;;
    *) log_error "Action '$ACTION' not recognized."; show_help; exit 1 ;;
esac
