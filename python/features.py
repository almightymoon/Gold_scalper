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
    Flattens the EA-provided feature set and adds a small set of derived features
    (session, candle body ratios, simple volatility regime, EMA9 slope estimate).
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
    out["volume_lots"] = _safe_float(f.get("volume_lots"))

    # GMT session bucket: 0=Asian, 1=London, 2=NY, 3=Overlap
    hour = int(out["hour_gmt"])
    out["session"] = 0 if hour < 7 else (1 if hour < 12 else (3 if hour < 14 else (2 if hour < 21 else 0)))

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

    # Candle body ratio (indecision filter): |close-open|/(high-low)
    for i in range(1, 21):
        o = out.get(f"m1_c{i}_o", np.nan)
        h = out.get(f"m1_c{i}_h", np.nan)
        l = out.get(f"m1_c{i}_l", np.nan)
        c = out.get(f"m1_c{i}_c", np.nan)
        rng = (h - l) if (np.isfinite(h) and np.isfinite(l) and (h - l) > 0) else np.nan
        out[f"m1_c{i}_body_ratio"] = (abs(c - o) / rng) if np.isfinite(rng) else np.nan

    # Simple volatility regime from last 20 closes: std of 1-bar returns
    closes = np.array([out.get(f"m1_c{i}_c", np.nan) for i in range(1, 21)], dtype=float)
    if np.isfinite(closes).sum() >= 10:
        rets = np.diff(closes) / np.where(closes[:-1] != 0, closes[:-1], np.nan)
        out["m1_ret_std_20"] = float(np.nanstd(rets))
        out["m1_ret_abs_mean_20"] = float(np.nanmean(np.abs(rets)))
    else:
        out["m1_ret_std_20"] = np.nan
        out["m1_ret_abs_mean_20"] = np.nan

    # EMA9 slope estimate (recomputed from closes to avoid needing prev EMA from EA):
    # slope = ema9[t] - ema9[t-3]
    def _ema(series: np.ndarray, span: int) -> np.ndarray:
        alpha = 2.0 / (span + 1.0)
        out_ema = np.full_like(series, np.nan, dtype=float)
        valid = np.isfinite(series)
        if valid.sum() == 0:
            return out_ema
        idxs = np.where(valid)[0]
        first = idxs[0]
        out_ema[first] = series[first]
        for j in range(first + 1, len(series)):
            if not np.isfinite(series[j]):
                out_ema[j] = out_ema[j - 1]
            else:
                out_ema[j] = alpha * series[j] + (1 - alpha) * out_ema[j - 1]
        return out_ema

    ema9 = _ema(closes, 9)
    if np.isfinite(ema9[-1]) and np.isfinite(ema9[-4]):
        out["m1_ema9_slope_3"] = float(ema9[-1] - ema9[-4])
    else:
        out["m1_ema9_slope_3"] = np.nan

    return out


def packet_to_dataframe_row(packet: Dict[str, Any]) -> pd.DataFrame:
    base = {
        "time": packet.get("time", ""),
        "symbol": packet.get("symbol", ""),
        "type": packet.get("type", ""),
        **flatten_feature_packet(packet),
    }
    return pd.DataFrame([base])


# Must match `model_train_aggressive.build_dataset` column order for inference.
AGGRESSIVE_FEATURE_COLUMNS: List[str] = [
    "ema_gap",
    "rsi",
    "spread_pts",
    "sl_dist",
    "tp_dist",
    "volume",
    "side_is_buy",
]


def aggressive_feature_dataframe(
    ema9: float,
    ema21: float,
    rsi: float,
    spread_pts: float,
    price: float,
    sl: float,
    tp: float,
    side: str,
    volume: float,
) -> pd.DataFrame:
    """
    One-row frame for `model_aggressive.pkl` (RandomForest trained on trades_ml OPEN rows).
    Mirrors model_train_aggressive.build_dataset feature definitions.
    """
    e9 = _safe_float(ema9, default=np.nan)
    e21 = _safe_float(ema21, default=np.nan)
    r = _safe_float(rsi, default=np.nan)
    sp = float(_safe_int(spread_pts, default=0))
    px = _safe_float(price, default=np.nan)
    slp = _safe_float(sl, default=np.nan)
    tpp = _safe_float(tp, default=np.nan)
    vol = _safe_float(volume, default=np.nan)
    side_u = str(side).upper()
    is_buy = 1 if side_u == "BUY" else 0

    def _fz(x: float) -> float:
        return 0.0 if (not np.isfinite(x)) else float(x)

    row = {
        "ema_gap": _fz(e9 - e21),
        "rsi": _fz(r),
        "spread_pts": _fz(sp),
        "sl_dist": _fz(abs(px - slp)),
        "tp_dist": _fz(abs(tpp - px)),
        "volume": _fz(vol),
        "side_is_buy": is_buy,
    }
    return pd.DataFrame([row])


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

