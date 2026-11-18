#!/usr/bin/env python3
"""Read Chromium DOM state through CDP without injecting any input.

This is the readback half of the QMP input test: keyboard and mouse events are
sent only by QMP, then this probe records ``#kb``, its echo, the click counter
and the current URL.  CDP is never used to dispatch events or mutate the page.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from cdp_input import CdpError, Driver, Ws, wait_target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=61006)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--connect-timeout", type=float, default=60.0)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        target = wait_target(args.host, args.port, args.connect_timeout)
        url = target["webSocketDebuggerUrl"].replace("localhost", args.host)
        url = url.replace(":9222/", f":{args.port}/")
        cdp = Ws(url, args.output)
        cdp.connect()
        try:
            driver = Driver(cdp, args.output)
            state = driver.state()
            driver.checkpoint("final-state", state)
            print(json.dumps(state, ensure_ascii=False, sort_keys=True))
            return 0
        finally:
            cdp.close()
    except (OSError, ValueError, CdpError) as exc:
        with args.output.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.time(), "kind": "result",
                                 "value": {"ok": False, "error": str(exc)}},
                                ensure_ascii=False) + "\n")
        print(f"cdp_probe: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
