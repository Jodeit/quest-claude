import json
import re

from roomscan.__main__ import main
from roomscan.report import fmt_delta, fmt_in


def make_twin(d):
    (d / "img" / "spots").mkdir(parents=True)
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
