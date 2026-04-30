from __future__ import annotations

from typing import Any, Dict, List, Tuple

import numpy as np
import pandas as pd


def _safe_float(x: Any, default: float = np.nan) -> float:
    try:
        if x is None:
            return default
        return float(x)
    except Exception:
        return default


def _safe_int(x: Any, default: int = 0) -> int:
    try:
        if x is None:
            return default
        return int(x)
    except Exception:
        return default


def flatten_feature_packet(packet: Dict[str, Any]) -> Dict[str, Any]:
    """
    Returns a flat dict suitable for CSV logging / ML.
    This does not compute any new indicators; it just flattens the EA-provided feature set.
    """
    f = packet.get("features", {}) or {}

    out: Dict[str, Any] = {}
    out["bid"] = _safe_float(f.get("bid"))
    out["ask"] = _safe_float(f.get("ask"))
    out["spread_points"] = _safe_int(f.get("spread_points"))
    out["balance"] = _safe_float(f.get("balance"))
    out["equity"] = _safe_float(f.get("equity"))
    out["free_margin"] = _safe_float(f.get("free_margin"))
    out["hour_gmt"] = _safe_int(f.get("hour_gmt"))
    out["open_ea_trades"] = _safe_int(f.get("open_ea_trades"))
    out["trades_today"] = _safe_int(f.get("trades_today"))

    for key in [
        "m1_ema9",
        "m1_ema21",
        "m1_ema50",
        "m1_rsi14",
        "m1_atr14",
        "m1_adx14",
        "m1_plusdi",
        "m1_minusdi",
        "m5_ema20",
        "m5_ema50",
        "m5_rsi14",
        "m5_atr14",
        "m5_adx14",
        "m5_plusdi",
        "m5_minusdi",
    ]:
        out[key] = _safe_float(f.get(key))

    # Flatten last 20 M1 OHLCV candles (oldest->newest expected).
    candles: List[Any] = f.get("m1_ohlcv", []) or []
    for i in range(20):
        prefix = f"m1_c{i+1}"
        if i < len(candles) and isinstance(candles[i], (list, tuple)) and len(candles[i]) >= 5:
            o, h, l, c, v = candles[i][:5]
            out[f"{prefix}_o"] = _safe_float(o)
            out[f"{prefix}_h"] = _safe_float(h)
            out[f"{prefix}_l"] = _safe_float(l)
            out[f"{prefix}_c"] = _safe_float(c)
            out[f"{prefix}_v"] = _safe_float(v)
        else:
            out[f"{prefix}_o"] = np.nan
            out[f"{prefix}_h"] = np.nan
            out[f"{prefix}_l"] = np.nan
            out[f"{prefix}_c"] = np.nan
            out[f"{prefix}_v"] = np.nan

    return out


def packet_to_dataframe_row(packet: Dict[str, Any]) -> pd.DataFrame:
    base = {
        "time": packet.get("time", ""),
        "symbol": packet.get("symbol", ""),
        "type": packet.get("type", ""),
        **flatten_feature_packet(packet),
    }
    return pd.DataFrame([base])


def select_model_features(df: pd.DataFrame) -> Tuple[pd.DataFrame, List[str]]:
    """
    Choose a stable subset of numeric features for ML.
    Keeps naming predictable even when some candle fields are missing.
    """
    ignore = {"time", "symbol", "type"}
    numeric_cols: List[str] = []
    for c in df.columns:
        if c in ignore:
            continue
        if pd.api.types.is_numeric_dtype(df[c]):
            numeric_cols.append(c)
    numeric_cols = sorted(numeric_cols)
    return df[numeric_cols].copy(), numeric_cols

