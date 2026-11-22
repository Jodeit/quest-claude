import json
import math
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from roomscan.sample import ORIGIN, YAW, make_sample  # noqa: E402


@pytest.fixture
def sample() -> dict:
    return make_sample()


@pytest.fixture
def sample_path(tmp_path, sample) -> Path:
    p = tmp_path / "living-room.json"
    p.write_text(json.dumps(sample))
    return p


def to_room(x: float, y: float) -> tuple[float, float]:
    """IFC plan coords -> the sample room's own frame (its (0,0) corner, x along the south wall)."""
    x, y = x - ORIGIN[0], y - ORIGIN[1]
    c, s = math.cos(-YAW), math.sin(-YAW)
    return (c * x - s * y, s * x + c * y)
