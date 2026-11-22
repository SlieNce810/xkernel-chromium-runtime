#!/bin/sh
# Read and validate one xkernel procfs memory snapshot.
#
# Usage
#   xk_memory_snapshot.sh ROOT_PID OUTPUT [RUN_ID]

set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 ROOT_PID OUTPUT [RUN_ID]" >&2
    exit 2
fi

ROOT_PID="$1"
OUTPUT="$2"
RUN_ID="${3:-snapshot-run}"
SOURCE="/proc/$ROOT_PID/xk_memory_snapshot"
TMP="$OUTPUT.tmp"
CSV="$OUTPUT.csv"

case "$ROOT_PID" in
    ''|*[!0-9]*) echo "invalid root pid: $ROOT_PID" >&2; exit 2 ;;
esac

rm -f "$TMP" "$CSV"
cat "$SOURCE" > "$TMP"

head -n 1 "$TMP" | grep -q 'snapshot version=1 ' \
    || { echo "snapshot version is missing" >&2; rm -f "$TMP"; exit 4; }
grep -q 'complete=1' "$TMP" \
    || { echo "snapshot is incomplete" >&2; rm -f "$TMP"; exit 4; }
tail -n 1 "$TMP" | grep -q '^snapshot-end rows=[1-9][0-9]*$' \
    || { echo "snapshot-end is missing or empty" >&2; rm -f "$TMP"; exit 4; }

mv "$TMP" "$OUTPUT"
printf 'run_id,clock_id,t_ns,root_pid,root_start,tree_generation,pid,ppid,process_start,role,rss_pages,pss_pages,uss_pages,shared_pages\n' > "$CSV"
EXPECTED_ROWS="$(sed -n 's/^snapshot-end rows=//p' "$OUTPUT")"
case "$EXPECTED_ROWS" in
    ''|*[!0-9]*) echo "snapshot-end row count is invalid" >&2; rm -f "$OUTPUT" "$CSV"; exit 4 ;;
esac

awk -v run_id="$RUN_ID" -v expected_rows="$EXPECTED_ROWS" '
    BEGIN { rows = 0 }
    /^snapshot version=1 / {
        for (i = 1; i <= NF; i++) {
            split($i, pair, "="); value[pair[1]] = pair[2]
        }
        meta_clock = value["clock_id"]
        meta_t = value["t_ns"]
        meta_root = value["root_pid"]
        meta_start = value["root_start"]
        meta_generation = value["tree_generation"]
        next
    }
    /^process / {
        delete row
        for (i = 1; i <= NF; i++) {
            split($i, pair, "="); row[pair[1]] = pair[2]
        }
        if (row["pid"] == "" || row["ppid"] == "" || row["start"] == "") exit 4
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", run_id, meta_clock, meta_t,
            meta_root, meta_start, meta_generation, row["pid"], row["ppid"], row["start"],
            row["role"], row["rss_pages"], row["pss_pages"], row["uss_pages"], row["shared_pages"]
        rows++
    }
    END { if (rows != expected_rows) exit 5 }
' "$OUTPUT" >> "$CSV"

test -s "$CSV"
echo "XK_MEMORY_SNAPSHOT_PASS root_pid=$ROOT_PID output=$OUTPUT rows=$EXPECTED_ROWS"
