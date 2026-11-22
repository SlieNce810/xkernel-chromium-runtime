#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_SOURCE="$ROOT/scripts/tests/fixtures/lifecycle_preload_smoke.c"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

gcc -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC \
    "$ROOT/scripts/t490/lifecycle_event_preload.c" \
    -ldl -o "$TEST_DIR/lifecycle_event_preload.so"
gcc -std=c11 -O2 -Wall -Wextra -Werror \
    "$TEST_SOURCE" -o "$TEST_DIR/lifecycle_preload_smoke"

printf 'lifecycle preload smoke page\n' > "$TEST_DIR/page.html"
for wait_kind in epoll poll ppoll; do
    XK_METRICS_RUN_ID=lifecycle-preload-smoke \
    XK_METRICS_NAV_ID=nav-00 \
    XK_METRICS_PAGE_PATH="$TEST_DIR/page.html" \
    XK_METRICS_PAGE_URL="file://$TEST_DIR/page.html" \
    XK_METRICS_EVENT_PATH="$TEST_DIR/events-$wait_kind.jsonl" \
    LIFECYCLE_TEST_WAIT="$wait_kind" \
    LD_PRELOAD="$TEST_DIR/lifecycle_event_preload.so" \
        "$TEST_DIR/lifecycle_preload_smoke" "$TEST_DIR/page.html"
done
XK_METRICS_RUN_ID=lifecycle-preload-smoke \
XK_METRICS_NAV_ID=nav-00 \
XK_METRICS_PAGE_PATH="$TEST_DIR/page.html" \
XK_METRICS_PAGE_URL="file://$TEST_DIR/page.html" \
XK_METRICS_EVENT_PATH="$TEST_DIR/zygote-events.jsonl" \
LD_PRELOAD="$TEST_DIR/lifecycle_event_preload.so" \
    "$TEST_DIR/lifecycle_preload_smoke" --type=zygote "$TEST_DIR/page.html"

python3 - "$TEST_DIR" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for wait_kind in ("epoll", "poll", "ppoll"):
    events = [json.loads(line) for line in (root / f"events-{wait_kind}.jsonl").read_text().splitlines()]
    names = [event["event"] for event in events]
    assert names == ["navigation_requested", "browser_main_loop_ready"], (wait_kind, names)
    assert all(event["clock_id"] == "LINUX_CLOCK_MONOTONIC" for event in events)
    assert all(event["run_id"] == "lifecycle-preload-smoke" for event in events)
    assert len({event["event_id"] for event in events}) == len(events)
    assert all(event["t_ns"] > 0 for event in events)
fork_events = [json.loads(line) for line in (root / "zygote-events.jsonl").read_text().splitlines()]
request = next(event for event in fork_events if event["event"] == "zygote_fork_boundary")
ready = next(event for event in fork_events if event["event"] == "renderer_ready")
assert request["request_id"] == ready["request_id"]
assert request["child_pid"] == ready["pid"]
assert ready["role"] == "renderer"
assert ready["renderer_id"] == ready["process_instance"]
print("LIFECYCLE_PRELOAD_NATIVE_SMOKE=PASS waits=epoll,poll,ppoll fork-ready=paired")
PY
