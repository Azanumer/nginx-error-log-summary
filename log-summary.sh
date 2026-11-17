#!/usr/bin/env bash
#
# nginx-error-log-summary — summarize an Nginx error log.
#
# Shows: total entries, counts by severity, the most frequent normalized
# error messages (client IP, request, upstream and host details stripped
# so identical problems group together), top PHP fatal-error files, and
# counts of upstream timeouts and SSL errors.
#
# Usage:
#   log-summary.sh [--file /var/log/nginx/error.log] [--since 2026-11-01]
#                  [--top 10] [--json]
#
# Exit codes: 0 ok, 1 usage / unreadable file, 2 no matching entries.
#
set -euo pipefail

PROG="$(basename "$0")"
FILE="/var/log/nginx/error.log"
SINCE=""
TOP=10
JSON=0

usage() {
    cat <<EOF
Usage: $PROG [--file PATH] [--since YYYY-MM-DD] [--top N] [--json]

Options:
  --file PATH        Nginx error log to read (default: /var/log/nginx/error.log)
  --since DATE       Only entries on or after this date (YYYY-MM-DD)
  --top N            How many top messages / PHP files to show (default: 10)
  --json             Machine-readable JSON output instead of text
  -h, --help         Show this help
EOF
}

die() {
    echo "$PROG: $*" >&2
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --file)
            [[ $# -ge 2 ]] || die "--file needs a path"
            FILE="$2"; shift 2 ;;
        --since)
            [[ $# -ge 2 ]] || die "--since needs a date (YYYY-MM-DD)"
            SINCE="$2"; shift 2 ;;
        --top)
            [[ $# -ge 2 ]] || die "--top needs a number"
            [[ "$2" =~ ^[0-9]+$ ]] && [[ "$2" -gt 0 ]] || die "--top must be a positive integer"
            TOP="$2"; shift 2 ;;
        --json)
            JSON=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1 (see --help)" ;;
    esac
done

[[ -r "$FILE" ]] || die "cannot read log file: $FILE"

# Normalize --since to the log's YYYY/MM/DD form for string comparison
# (zero-padded dates compare correctly as strings).
SINCE_NORM=""
if [[ -n "$SINCE" ]]; then
    [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--since must be YYYY-MM-DD"
    SINCE_NORM="${SINCE//-//}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# One awk pass: aggregate severity counts, normalized message counts,
# PHP fatal-error files, and special counters into separate files.
awk -v since="$SINCE_NORM" \
    -v sev_file="$TMP/sev" \
    -v msg_file="$TMP/msg" \
    -v php_file="$TMP/php" \
    -v tot_file="$TMP/totals" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
{
    date = substr($0, 1, 10)
    if (since != "" && date < since) next
    total++

    # Severity: the [level] token after the timestamp.
    sev = "unknown"
    if (match($0, /\[(emerg|alert|crit|error|warn|notice|info|debug)\]/)) {
        sev = substr($0, RSTART + 1, RLENGTH - 2)
    }
    sev_count[sev]++

    # Message: strip "date time [level] pid#tid: " and the "*connid " prefix.
    msg = $0
    sub(/^[^ ]+ [^ ]+ \[[^]]+\] [0-9]+#[0-9]+: /, "", msg)
    sub(/^\*[0-9]+ /, "", msg)

    # Strip per-request details so identical problems group together.
    gsub(/, client: [^,]*/, "", msg)
    gsub(/, server: [^,]*/, "", msg)
    gsub(/, request: "[^"]*"/, "", msg)
    gsub(/, upstream: "[^"]*"/, "", msg)
    gsub(/, host: "[^"]*"/, "", msg)
    gsub(/, referrer: "[^"]*"/, "", msg)
    msg = trim(msg)
    msg_count[msg]++

    if (msg ~ /upstream timed out/) timeouts++
    if (msg ~ /SSL_do_handshake|SSL: error|no "ssl_certificate" is defined/) ssl_errors++

    # PHP fatal errors: group by the file the error came from.
    if (msg ~ /PHP message: PHP Fatal error/) {
        file = "unknown"
        if (match(msg, / in [^ ]+ on line [0-9]+/)) {
            file = substr(msg, RSTART + 4, RLENGTH - 4)
            sub(/ on line [0-9]+$/, "", file)
        }
        php_count[file]++
    }
}
END {
    # Create all output files even when a category is empty, so the
    # downstream sort never fails on a missing file.
    printf "" > sev_file
    printf "" > msg_file
    printf "" > php_file
    print total + 0 > tot_file
    print timeouts + 0 > tot_file
    print ssl_errors + 0 > tot_file
    for (s in sev_count) print sev_count[s] "\t" s > sev_file
    for (m in msg_count) print msg_count[m] "\t" m > msg_file
    for (f in php_count) print php_count[f] "\t" f > php_file
}
' "$FILE"

read -r TOTAL TIMEOUTS SSL_ERRORS < <(paste -sd' ' "$TMP/totals" 2>/dev/null || echo "0 0 0")
# paste joins the three lines; fall back if the file is somehow short.
TOTAL="${TOTAL:-0}"

if [[ "$TOTAL" -eq 0 ]]; then
    if [[ "$JSON" -eq 1 ]]; then
        echo '{"total":0,"timeouts":0,"ssl_errors":0,"by_severity":{},"top_messages":[],"top_php_fatal_files":[]}'
    else
        echo "No matching entries in $FILE."
    fi
    exit 2
fi

# Sorted top-N lists (count desc, message asc for stable ties).
sort -t$'\t' -k1,1nr -k2,2 "$TMP/sev" > "$TMP/sev_sorted"
sort -t$'\t' -k1,1nr -k2,2 "$TMP/msg" | head -n "$TOP" > "$TMP/msg_top"
sort -t$'\t' -k1,1nr -k2,2 "$TMP/php" | head -n "$TOP" > "$TMP/php_top"

json_escape() {
    # Escape backslash, double-quote and tab for JSON strings.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

if [[ "$JSON" -eq 1 ]]; then
    printf '{"total":%s,"timeouts":%s,"ssl_errors":%s,"by_severity":{' "$TOTAL" "$TIMEOUTS" "$SSL_ERRORS"
    first=1
    while IFS=$'\t' read -r count sev; do
        [[ $first -eq 1 ]] && first=0 || printf ','
        printf '"%s":%s' "$(json_escape "$sev")" "$count"
    done < "$TMP/sev_sorted"
    printf '},"top_messages":['
    first=1
    while IFS=$'\t' read -r count msg; do
        [[ $first -eq 1 ]] && first=0 || printf ','
        printf '{"count":%s,"message":"%s"}' "$count" "$(json_escape "$msg")"
    done < "$TMP/msg_top"
    printf '],"top_php_fatal_files":['
    first=1
    while IFS=$'\t' read -r count file; do
        [[ $first -eq 1 ]] && first=0 || printf ','
        printf '{"count":%s,"file":"%s"}' "$count" "$(json_escape "$file")"
    done < "$TMP/php_top"
    printf ']}\n'
    exit 0
fi

# --- Text report ---
echo "Nginx error log: $FILE"
[[ -n "$SINCE" ]] && echo "Since: $SINCE"
echo "Total entries: $TOTAL"
echo
echo "By severity:"
while IFS=$'\t' read -r count sev; do
    printf '  %-8s %s\n' "$sev" "$count"
done < "$TMP/sev_sorted"
echo
echo "Top $TOP messages:"
while IFS=$'\t' read -r count msg; do
    printf '  %6s  %s\n' "$count" "$msg"
done < "$TMP/msg_top"
if [[ -s "$TMP/php_top" ]]; then
    echo
    echo "Top PHP fatal-error files:"
    while IFS=$'\t' read -r count file; do
        printf '  %6s  %s\n' "$count" "$file"
    done < "$TMP/php_top"
fi
echo
echo "Upstream timeouts: $TIMEOUTS"
echo "SSL errors:        $SSL_ERRORS"
