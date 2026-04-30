import json
from pathlib import Path

import pytest

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ai_server import dummy_rule_ai, _handle_packet, AiModel, ServerConfig  # noqa: E402
from trade_logger import LogPaths  # noqa: E402


def test_ping_returns_ok(tmp_path: Path) -> None:
    logs = LogPaths(tmp_path)
    model = AiModel(tmp_path)
    resp = _handle_packet({"type": "ping"}, model=model, logs=logs, transport="test")
    assert resp["status"] == "ok"


def test_handle_invalid_packet_type(tmp_path: Path) -> None:
    logs = LogPaths(tmp_path)
    model = AiModel(tmp_path)
    resp = _handle_packet({"type": "nope", "time": "x", "symbol": "XAUUSD", "features": {}}, model=model, logs=logs, transport="test")
    assert resp["signal"] == "HOLD"


def test_dummy_rule_ai_returns_valid_signal() -> None:
    packet = {
        "type": "features",
        "symbol": "XAUUSD",
        "time": "2026-01-01T00:00:00",
        "features": {
            "m1_ema9": 10,
            "m1_ema21": 9,
            "m5_ema20": 10,
            "m5_ema50": 9,
            "m1_rsi14": 55,
            "m1_adx14": 20,
            "spread_points": 15,
            "m1_atr14": 2.0,
        },
    }
    resp = dummy_rule_ai(packet)
    assert resp["signal"] in {"BUY", "SELL", "HOLD"}
    assert 0.0 <= float(resp["confidence"]) <= 1.0
    assert int(resp["sl_points"]) >= 0
    assert int(resp["tp_points"]) >= 0

