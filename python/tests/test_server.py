from pathlib import Path

import pytest

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ai_server import AggressiveAiModel, dummy_rule_ai, _handle_packet, AiModel, ServerConfig  # noqa: E402
from features import flatten_feature_packet  # noqa: E402
from trade_logger import LogPaths  # noqa: E402


def test_ping_returns_ok(tmp_path: Path) -> None:
    logs = LogPaths(tmp_path)
    model = AiModel(tmp_path)
    cfg = ServerConfig(data_dir=tmp_path, models_dir=tmp_path)
    resp = _handle_packet({"type": "ping"}, cfg=cfg, model=model, aggressive=None, logs=logs, transport="test")
    assert resp["status"] == "ok"


def test_handle_invalid_packet_type(tmp_path: Path) -> None:
    logs = LogPaths(tmp_path)
    model = AiModel(tmp_path)
    cfg = ServerConfig(data_dir=tmp_path, models_dir=tmp_path)
    resp = _handle_packet(
        {"type": "nope", "time": "x", "symbol": "XAUUSD", "features": {}},
        cfg=cfg,
        model=model,
        aggressive=None,
        logs=logs,
        transport="test",
    )
    assert resp["signal"] == "HOLD"


def test_min_agg_pwin_filters_trade(tmp_path: Path) -> None:
    """When aggressive model is loaded, min_agg_pwin can force HOLD before MIN_CONF."""
    models = Path(__file__).resolve().parents[1] / "models"
    am = AggressiveAiModel(models / "model_aggressive.pkl")
    if not am.load_if_available():
        pytest.skip("model_aggressive.pkl not present")

    logs = LogPaths(tmp_path)
    model = AiModel(tmp_path)
    cfg = ServerConfig(data_dir=tmp_path, models_dir=tmp_path, min_agg_pwin=0.99)

    # OHLCV oldest->newest: mild drift for ret_std; last bar bullish with decisive body (dummy_rule BUY path).
    ohlcv: list[list[float]] = []
    for i in range(19):
        p = 2648.0 + i * 0.02
        ohlcv.append([p, p + 0.35, p - 0.25, p + 0.12, 100.0])
    ohlcv.append([2650.0, 2650.65, 2649.75, 2650.55, 100.0])

    base_features = {
        "bid": 2650.0,
        "ask": 2650.17,
        "spread_points": 17,
        "hour_gmt": 10,
        "m1_ema9": 2651.0,
        "m1_ema21": 2640.0,
        "m1_ema50": 2630.0,
        "m1_rsi14": 58.0,
        "m1_atr14": 2.5,
        "m1_adx14": 30.0,
        "m1_plusdi": 25.0,
        "m1_minusdi": 12.0,
        "m5_ema20": 2645.0,
        "m5_ema50": 2635.0,
        "m5_rsi14": 52.0,
        "m5_atr14": 3.0,
        "m5_adx14": 28.0,
        "m5_plusdi": 22.0,
        "m5_minusdi": 14.0,
        "volume_lots": 0.02,
        "m1_ohlcv": ohlcv,
    }
    # dummy_rule_ai reads raw features (not CSV-flattened); merge derived m1_c* keys like MT5+flatten would.
    flat = flatten_feature_packet({"type": "features", "features": base_features})
    merged = {**base_features, **{k: flat[k] for k in flat if k.startswith("m1_c") or k in ("m1_ret_std_20", "m1_ret_abs_mean_20")}}
    packet = {
        "type": "features",
        "symbol": "XAUUSD",
        "time": "2026-01-01T12:00:00",
        "features": merged,
    }
    resp = _handle_packet(packet, cfg=cfg, model=model, aggressive=am, logs=logs, transport="test")
    assert resp["signal"] == "HOLD"
    assert "agg_pwin" in resp.get("reason", "")


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

