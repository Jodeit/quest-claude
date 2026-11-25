import json
import re

from roomscan.__main__ import main
from roomscan.report import fmt_delta, fmt_in


def make_twin(d):
    (d / "img" / "spots").mkdir(parents=True, exist_ok=True)
    (d / "img" / "spots" / "1.jpg").write_bytes(b"\xff\xd8fakejpeg")
    o = lambda k, label, photos: dict(
        key=k, label=label, name=None, size=[0.76, 2.0, 0.35], photos=photos,
        measurement=dict(tolerance_in=1.6, confidence="medium", confirm_with_tape=k == "2 Storage",
                         tolerance_in_by_dim=dict(width=0.9, height=1.6, depth=0.9), reason=None))
    t = dict(name="Office", date="2026-11-24T14:03:59Z", units="imperial", floor_y=0, ceiling_y=2.5,
             floor=dict(polygon=[[0, 0], [3, 0], [3, 4], [0, 4]]), walls=[],
             openings=[dict(kind="window", width=1, height=1), dict(kind="door", width=1, height=2)],
             objects=[o("1 Storage", "Storage", [dict(path="img/spots/1.jpg")]), o("2 Storage", "Storage", []),
                      o("3 Chair", "Chair", [])],
             seed=dict(names={"2 Storage": "Pantry <b>"},
                       products=[dict(spot="1 Storage", product="Bin", qty=3, price=12.5)], measured={}))
    (d / "twin.json").write_text(json.dumps(t))
    return d / "twin.json"


def test_format():
    assert fmt_in(30.4) == "2' 6½\""
    assert fmt_in(24) == "2' 0\""
    assert fmt_in(5.3) == "5½\""
    assert fmt_delta(0.2) == "matches" and fmt_delta(1.3) == "+1.5\""


def test_report(tmp_path):
    p = make_twin(tmp_path)
    tape = tmp_path / "tape.json"
    tape.write_text(json.dumps({"1 Storage": {"width": 30, "depth": 14, "height": 79}}))
    out = tmp_path / "r.html"
    assert main(["report", str(tmp_path), str(out), "--tape", str(tape)]) == 0
    h = out.read_text()
    assert "data:image/jpeg;base64," in h and "src=\"img/" not in h
    assert h.count('class="unit"') == 2  # chair has no section
    assert "Confirmed with tape" in h and "Please confirm with tape" in h
    assert "Pantry &lt;b&gt;" in h and "$37.50" in h
    assert re.search(r"2' 6\"", h)
    assert "@media print" in h
    assert main(["report", str(p), str(tmp_path / "b.html")]) == 0


def _report(tmp_path, twin_edit=None, tape=None, raw_tape=None):
    p = make_twin(tmp_path)
    if twin_edit:
        t = json.loads(p.read_text())
        twin_edit(t)
        p.write_text(json.dumps(t))
    tp = None
    if tape is not None or raw_tape is not None:
        tp = tmp_path / "tape.json"
        tp.write_text(raw_tape if raw_tape is not None else json.dumps(tape))
    from roomscan.report import build_report
    r = build_report(tmp_path, tmp_path / "r.html", tp)
    return r, (tmp_path / "r.html").read_text()


def test_bad_products_and_numbers(tmp_path):
    def edit(t):
        t["seed"]["products"] = ["junk", 5, None,
                                 dict(spot="1 Storage", product="Neg", qty=-2, price=-9),
                                 dict(spot="1 Storage", product="Wide", qty="inf", price="nan"),
                                 dict(spot="1 Storage", product="Ok", qty=2, price=10)]
    _, h = _report(tmp_path, edit)
    assert "$20.00" in h and "$inf" not in h and "$nan" not in h and "inf</td>" not in h
    assert "-$" not in h and "$-" not in h


def test_objects_without_key(tmp_path):
    def edit(t):
        t["objects"].append(dict(label="Storage", size=[1, 1, 1], products=[dict(name="X", qty=1, price=1)]))
        t["objects"].append("junk")
    r, h = _report(tmp_path, edit)
    assert h.count('class="unit"') == 3


def test_tape_validation(tmp_path):
    import pytest
    from roomscan.report import build_report
    with pytest.raises(FileNotFoundError, match="tape file not found"):
        build_report(make_twin(tmp_path).parent, tmp_path / "r.html", tmp_path / "nope.json")
    with pytest.raises(ValueError, match="not valid JSON"):
        _report(tmp_path, raw_tape="{oops")
    good = dict(width=30, depth=14, height=79)
    r, h = _report(tmp_path, tape={"1 Storage": good, "2 Storage": dict(width=0, depth=1, height=1),
                                   "3 Chair": "x", "9 Ghost": good, "x": dict(width=float("nan"), depth=1, height=1)})
    assert h.count("Confirmed with tape") >= 3  # 1 Storage's badges only
    assert any("9 Ghost" in w and "matches no unit" in w for w in r["warnings"])
    assert sum("ignored" in w for w in r["warnings"]) == 3


def test_fmt_in_guards():
    assert fmt_in(float("inf")) == "–" and fmt_in(float("nan")) == "–"


def test_app_measurements_shape_and_location_products(tmp_path):
    def edit(t):
        t["seed"]["measured"] = {"confirmed": {"2 Storage|width": 0.762, "2 Storage|depth": 0.3556,
                                               "Wall W1": 3.0, "2 Storage|height": -1, "9 Ghost|width": 1},
                                 "custom": []}
        t["seed"]["products"] = [dict(location="2 Storage", product="Basket", qty=2, price=5)]
    r, h = _report(tmp_path, edit)
    assert "$10.00" in h and "Basket" in h
    assert "2' 6\"" in h  # 0.762 m is 30 in, shown as tape, not read as inches
    assert h.count("Confirmed with tape") >= 2 and "Please confirm with tape" in h  # height still unmeasured
    from roomscan.report import app_tape
    t = app_tape({"confirmed": {"3 Storage|width": 1.0}, "4 Chair": {"width": 10, "depth": 0}})
    assert abs(t["3 Storage"]["width"] - 39.37) < 0.01 and t["4 Chair"] == {"width": 10}
