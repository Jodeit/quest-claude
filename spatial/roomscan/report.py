"""Client report: a twin (twin.json + img/) -> one self-contained, printable HTML page."""

from __future__ import annotations

import base64
import html
import json
import math
import mimetypes
from datetime import datetime
from pathlib import Path
from string import Template

M_TO_IN = 39.37007874
BRAND = "Graceful Spaces"
DIMS = (("width", 0), ("height", 1), ("depth", 2))  # twin size is [w, h, d] in metres


def fmt_in(inches: float | None) -> str:
    """Feet and inches to the half inch: 30.4 -> 2' 6½\""""
    if inches is None or not math.isfinite(inches):
        return "–"
    try:
        half = round(abs(inches) * 2)
    except OverflowError:
        return "–"
    ft, rem = divmod(half, 24)
    whole, h = divmod(rem, 2)
    s = (f"{ft}' " if ft else "") + f"{whole}" + ("½" if h else "") + '"'
    return ("-" if inches < 0 and half else "") + s


def fmt_delta(d: float) -> str:
    r = round(d * 2) / 2
    if r == 0:
        return "matches"
    return f"{'+' if r > 0 else '-'}{abs(r):g}\""


def esc(x) -> str:
    return html.escape(str(x if x is not None else ""))


def money(x: float) -> str:
    return f"${x:,.2f}"


def _img(base: Path, rel: str | None) -> str | None:
    if not rel:
        return None
    p = base / rel
    if not p.is_file():
        return None
    mime = mimetypes.guess_type(p.name)[0] or "image/jpeg"
    return f"data:{mime};base64," + base64.b64encode(p.read_bytes()).decode()


def load_twin(path: Path) -> tuple[dict, Path]:
    path = Path(path)
    f = path / "twin.json" if path.is_dir() else path
    return json.loads(f.read_text()), f.parent


def _area_sqft(poly: list) -> float:
    a = 0.0
    for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
        a += x1 * y2 - x2 * y1
    return abs(a) / 2 * 10.7639


def _pretty_date(s) -> str:
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).strftime("%B %-d, %Y")
    except ValueError:
        return str(s or "")


def unit_name(o: dict, names: dict) -> str:
    key = str(o.get("key", ""))
    n = key.split(" ", 1)
    auto = f"{o.get('label') or n[-1]} {n[0]}" if n[0].isdigit() and len(n) > 1 else (o.get("label") or key)
    return o.get("name") or names.get(key) or auto


def _nonneg(x, default):
    """A finite number >= 0, else the default (NaN, inf, negative and junk are ignored)."""
    try:
        v = float(x)
    except (TypeError, ValueError):
        return default
    return v if math.isfinite(v) and v >= 0 else default


def unit_products(o: dict, seed: dict) -> list[dict]:
    rows = list(o.get("products") or []) + [p for p in (seed.get("products") or [])
                                            if isinstance(p, dict) and str(p.get("spot")) == o["key"]]
    out = []
    for p in rows:
        if not isinstance(p, dict):
            continue
        qty = _nonneg(p.get("qty", 1) if p.get("qty") not in (None, "") else 1, 1.0)
        price = _nonneg(p.get("price"), None) if p.get("price") not in (None, "") else None
        out.append(dict(name=p.get("product") or p.get("name") or "", qty=qty, price=price))
    return out


def measure_rows(o: dict, tape: dict | None) -> list[dict]:
    m = o.get("measurement") or {}
    tol = m.get("tolerance_in_by_dim") or {}
    rows = []
    for dim, i in DIMS:
        scan = o["size"][i] * M_TO_IN
        t = (tape or {}).get(dim)
        t = float(t) if t not in (None, "") else None
        rows.append(dict(dim=dim, scan=scan, tape=t, delta=None if t is None else t - scan,
                         tol=tol.get(dim, m.get("tolerance_in"))))
    return rows


def _badge(row: dict, m: dict) -> str:
    if row["tape"] is not None:
        return '<span class="badge ok">Confirmed with tape</span>'
    if m.get("confirm_with_tape"):
        return '<span class="badge warn">Please confirm with tape</span>'
    return '<span class="badge mute">Scan estimate</span>'


def _unit_html(o: dict, base: Path, names: dict, seed: dict, tape: dict) -> str:
    m = o.get("measurement") or {}
    title = unit_name(o, names)
    photos = o.get("photos") or []
    imgs = [u for u in (_img(base, p.get("path")) for p in photos) if u]
    if not imgs:
        f = _img(base, (o.get("front") or {}).get("image"))
        imgs = [f] if f else []
    out = [f'<section class="unit"><h2>{esc(title)}</h2>']
    if imgs:
        out.append(f'<img class="hero" alt="{esc(title)}" src="{imgs[0]}">')
        if len(imgs) > 1:
            out.append('<div class="thumbs">' + "".join(f'<img alt="" src="{u}">' for u in imgs[1:4]) + "</div>")
    out.append('<h3>Scan vs tape</h3><table><thead><tr><th>Dimension</th><th class="n">Scan</th>'
               '<th class="n">Tape</th><th class="n">Delta</th><th>Status</th></tr></thead><tbody>')
    for r in measure_rows(o, tape.get(o["key"])):
        tol = f' <span class="note">±{r["tol"]:g}"</span>' if r["tol"] is not None else ""
        out.append(f'<tr><td>{r["dim"].title()}</td><td class="n">{fmt_in(r["scan"])}{tol}</td>'
                   f'<td class="n">{fmt_in(r["tape"])}</td>'
                   f'<td class="n">{"–" if r["delta"] is None else fmt_delta(r["delta"])}</td><td>{_badge(r, m)}</td></tr>')
    out.append("</tbody></table>")
    if m.get("confidence"):
        out.append(f'<p class="note">Scan confidence: {esc(m["confidence"])}.'
                   + (f' {esc(m["reason"])}' if m.get("reason") else "") + "</p>")
    prods = unit_products(o, seed)
    if prods:
        out.append('<h3>Products</h3><table><thead><tr><th>Product</th><th class="n">Qty</th>'
                   '<th class="n">Price</th><th class="n">Subtotal</th></tr></thead><tbody>')
        total = 0.0
        for p in prods:
            sub = None if p["price"] is None else p["price"] * p["qty"]
            total += sub or 0
            out.append(f'<tr><td>{esc(p["name"])}</td><td class="n">{p["qty"]:g}</td>'
                       f'<td class="n">{"–" if p["price"] is None else money(p["price"])}</td>'
                       f'<td class="n">{"–" if sub is None else money(sub)}</td></tr>')
        out.append(f'</tbody><tfoot><tr><td colspan="3">Total</td><td class="n">{money(total)}</td></tr></tfoot></table>')
    out.append("</section>")
    return "".join(out)


def _positive(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and x > 0


def load_tape(tape_path: Path | None) -> tuple[dict, list[str]]:
    """tape.json -> {key: {width, depth, height}} keeping only entries whose three numbers are finite and > 0."""
    if not tape_path:
        return {}, []
    p = Path(tape_path)
    if not p.is_file():
        raise FileNotFoundError(f"tape file not found: {p}")
    try:
        raw = json.loads(p.read_text())
    except ValueError as e:
        raise ValueError(f"tape file {p} is not valid JSON: {e}") from None
    if not isinstance(raw, dict):
        raise ValueError(f"tape file {p} must be a JSON object of unit key -> {{width, depth, height}}")
    tape, warns = {}, []
    for k, v in raw.items():
        if isinstance(v, dict) and all(_positive(v.get(d)) for d in ("width", "depth", "height")):
            tape[k] = v
        else:
            warns.append(f"tape entry {k!r} ignored: needs finite positive width, depth and height")
    return tape, warns


def build_report(twin_path: Path, out: Path, tape_path: Path | None = None) -> dict:
    t, base = load_twin(twin_path)
    tape, warnings = load_tape(tape_path)
    tape_keys = list(tape)
    seed = t.get("seed") or {}
    for k, v in (seed.get("measured") or {}).items():  # tape taken in the app, unless tape.json overrides
        if isinstance(v, dict) and all(_positive(v.get(d)) for d in ("width", "depth", "height")):
            tape.setdefault(k, v)
    names = seed.get("names") or {}
    name = t.get("name") or "Room"
    units = [dict(o, key=str(o["key"]) if o.get("key") not in (None, "") else str(i + 1))
             for i, o in enumerate(t.get("objects") or []) if isinstance(o, dict)]
    for k in tape_keys:
        if k not in {o["key"] for o in units}:
            warnings.append(f"tape key {k!r} matches no unit")
    opens = t.get("openings") or []
    ceil = (t["ceiling_y"] - t["floor_y"]) * M_TO_IN if "ceiling_y" in t and "floor_y" in t else None
    area = _area_sqft((t.get("floor") or {}).get("polygon") or []) if (t.get("floor") or {}).get("polygon") else 0
    n_tape = sum(1 for o in units if tape.get(o["key"]))
    n_conf = sum(1 for o in units if (o.get("measurement") or {}).get("confirm_with_tape") and not tape.get(o["key"]))
    stats = [(f"{area:.0f} sq ft", "Floor area") if area else None,
             (fmt_in(ceil), "Ceiling height") if ceil else None,
             (str(len(units)), "Items scanned"),
             (str(sum(1 for x in opens if x.get("kind") == "window")), "Windows"),
             (str(sum(1 for x in opens if x.get("kind") == "door")), "Doors"),
             (str(n_tape), "Confirmed with tape")]
    body = [f'<div class="cover"><div class="brand">{BRAND}</div><h1>{esc(name)}</h1>'
            f'<div class="sub">Space report · {esc(_pretty_date(t.get("date")))}</div></div>',
            '<section class="sum"><h2>Summary</h2><div class="stats">'
            + "".join(f'<div class="stat"><b>{esc(a)}</b><span>{esc(b)}</span></div>' for a, b in filter(None, stats))
            + "</div><p>Measurements come from a LiDAR scan and are shown to the nearest half inch. "
              "Where we have taken a tape measure to a unit, both numbers are listed with the difference.</p>"
            + (f'<p class="note">{n_conf} unit(s) still need a tape check before ordering.</p>' if n_conf else "")
            + "</section>"]
    body += [_unit_html(o, base, names, seed, tape) for o in units if _is_storage(o) or tape.get(o["key"])]
    page = Template((Path(__file__).parent / "report_page.html").read_text())
    out = Path(out)
    out.write_text(page.safe_substitute(title=esc(f"{name} report · {BRAND}"), body="".join(body)))
    return {"report": str(out), "units": len(body) - 2, "bytes": out.stat().st_size, "warnings": warnings}


def _is_storage(o: dict) -> bool:
    """Furniture the scan found that isn't storage (chairs, tables) has no organizing section unless it has products or a tape entry."""
    return str(o.get("label", "")).lower() in ("storage", "shelf", "shelves", "cabinet", "closet", "dresser") or bool(o.get("products"))
