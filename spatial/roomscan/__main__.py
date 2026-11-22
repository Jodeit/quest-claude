"""roomscan command line.

  roomscan serve                         MCP over stdio (for `claude mcp add`)
  roomscan serve --http 0.0.0.0:8765     MCP over HTTP for the network; prints the bearer token
  roomscan convert scan.json out.ifc     one-off conversion, no server [--edits edits.json]
  roomscan summary scan.json             the plan data an LLM would see
  roomscan plan scan.json plan.png       floor plan picture (.png or .svg)
  roomscan sample out.json               write the sample RoomPlan export
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _load(path: str) -> dict:
    return json.loads(Path(path).read_text())


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="roomscan", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="run the MCP server")
    s.add_argument("--http", metavar="HOST:PORT", help="serve streamable HTTP instead of stdio")
    s.add_argument("--token", help="bearer token for HTTP (default: generated once, kept in $ROOMSCAN_HOME/token)")
    s.add_argument("--public-url", help="the URL clients reach this server at, for download links")
    s.add_argument("--home", help="where scans are kept (default $ROOMSCAN_HOME or ~/.local/share/roomscan)")

    c = sub.add_parser("convert", help="RoomPlan JSON -> IFC")
    c.add_argument("scan")
    c.add_argument("out")
    c.add_argument("--edits")

    m = sub.add_parser("summary", help="print the plan data as JSON")
    m.add_argument("scan")
    m.add_argument("--edits")

    p = sub.add_parser("plan", help="draw the floor plan")
    p.add_argument("scan")
    p.add_argument("out")
    p.add_argument("--edits")
    p.add_argument("--story", type=int, default=0)

    x = sub.add_parser("sample", help="write the sample RoomPlan export")
    x.add_argument("out", nargs="?", default="-")

    a = ap.parse_args(argv)

    if a.cmd == "serve":
        from .server import load_or_make_token, serve_http, serve_stdio
        from .store import Store

        store = Store(Path(a.home) if a.home else None)
        if not a.http:
            serve_stdio(store)
            return 0
        host, _, port = a.http.rpartition(":")
        token = a.token or load_or_make_token(store)
        print(f"roomscan: MCP at http://{host or '0.0.0.0'}:{port}/mcp", file=sys.stderr)
        print(f"roomscan: bearer token {token}", file=sys.stderr)
        serve_http(store, host or "0.0.0.0", int(port), token, a.public_url)
        return 0

    if a.cmd == "sample":
        from .sample import make_sample

        text = json.dumps(make_sample(), indent=1)
        if a.out == "-":
            print(text)
        else:
            Path(a.out).write_text(text + "\n")
        return 0

    from .capture import read_capture

    cap = read_capture(_load(a.scan))
    edits = _load(a.edits) if getattr(a, "edits", None) else None

    if a.cmd == "convert":
        from .ifc import validate, write_ifc
        import ifcopenshell

        r = write_ifc(cap, Path(a.out), edits, Path(a.scan).stem)
        r["validation_errors"] = validate(ifcopenshell.open(a.out))
        r["warnings"] = cap.warnings
        print(json.dumps(r, indent=1))
        return 1 if r["validation_errors"] else 0

    if a.cmd == "summary":
        from .summary import summarise

        print(json.dumps(summarise(cap, edits)))
        return 0

    if a.cmd == "plan":
        from .summary import plan_png, plan_svg

        out = Path(a.out)
        if out.suffix == ".svg":
            out.write_text(plan_svg(cap, edits, a.story))
        else:
            out.write_bytes(plan_png(cap, edits, a.story))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
