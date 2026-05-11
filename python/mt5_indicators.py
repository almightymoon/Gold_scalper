"""
Pandas/numpy technical indicators for MT5 live feature packets.
Wilder-style smoothing matches common TA defaults (RSI/ATR/ADX).
"""

from __future__ import annotations

from typing import Tuple

import numpy as np
import pandas as pd


def ema(series: pd.Series, span: int) -> pd.Series:
    return series.ewm(span=span, adjust=False).mean()


def rsi_wilder(close: pd.Series, period: int = 14) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = (-delta).clip(lower=0.0)
    avg_gain = gain.ewm(alpha=1.0 / period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1.0 / period, min_periods=period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    out = 100.0 - (100.0 / (1.0 + rs))
    return out


def atr_wilder(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14) -> pd.Series:
    prev_close = close.shift(1)
    tr = pd.concat(
        [
            (high - low).abs(),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    return tr.ewm(alpha=1.0 / period, min_periods=period, adjust=False).mean()


def _wilder_rma(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(alpha=1.0 / period, min_periods=period, adjust=False).mean()


def _true_range(high: pd.Series, low: pd.Series, close: pd.Series) -> pd.Series:
    prev_close = close.shift(1)
    return pd.concat(
        [
            (high - low).abs(),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)


def _adx_di(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14) -> Tuple[pd.Series, pd.Series, pd.Series]:
    prev_high = high.shift(1)
    prev_low = low.shift(1)
    up_move = high - prev_high
    down_move = prev_low - low

    plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
    plus_dm = pd.Series(plus_dm, index=high.index)
    minus_dm = pd.Series(minus_dm, index=high.index)

    tr = _true_range(high, low, close)
    tr_sm = _wilder_rma(tr, period)
    plus_dm_sm = _wilder_rma(plus_dm, period)
    minus_dm_sm = _wilder_rma(minus_dm, period)

    plus_di = 100.0 * (plus_dm_sm / tr_sm.replace(0.0, np.nan))
    minus_di = 100.0 * (minus_dm_sm / tr_sm.replace(0.0, np.nan))
    dx = (100.0 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0.0, np.nan)).replace([np.inf, -np.inf], np.nan)
    adx = _wilder_rma(dx, period)
    return plus_di, minus_di, adx


def m1_indicator_row(df: pd.DataFrame) -> dict[str, float]:
    """Latest indicator values for M1 feature packet keys."""
    c = df["close"].astype(float)
    h = df["high"].astype(float)
    l = df["low"].astype(float)
    pdi, mdi, adx = _adx_di(h, l, c, period=14)
    atr = atr_wilder(h, l, c, period=14)
    rsi = rsi_wilder(c, period=14)
    e9 = ema(c, 9)
    e21 = ema(c, 21)
    e50 = ema(c, 50)
    return {
        "m1_ema9": last_or_nan(e9),
        "m1_ema21": last_or_nan(e21),
        "m1_ema50": last_or_nan(e50),
        "m1_rsi14": last_or_nan(rsi),
        "m1_atr14": last_or_nan(atr),
        "m1_adx14": last_or_nan(adx),
        "m1_plusdi": last_or_nan(pdi),
        "m1_minusdi": last_or_nan(mdi),
    }


def m5_indicator_row(df: pd.DataFrame) -> dict[str, float]:
    """Latest indicator values for M5 feature packet keys."""
    c = df["close"].astype(float)
    h = df["high"].astype(float)
    l = df["low"].astype(float)
    pdi, mdi, adx = _adx_di(h, l, c, period=14)
    atr = atr_wilder(h, l, c, period=14)
    rsi = rsi_wilder(c, period=14)
    e20 = ema(c, 20)
    e50 = ema(c, 50)
    return {
        "m5_ema20": last_or_nan(e20),
        "m5_ema50": last_or_nan(e50),
        "m5_rsi14": last_or_nan(rsi),
        "m5_atr14": last_or_nan(atr),
        "m5_adx14": last_or_nan(adx),
        "m5_plusdi": last_or_nan(pdi),
        "m5_minusdi": last_or_nan(mdi),
    }


def last_or_nan(s: pd.Series) -> float:
    if s is None or len(s) == 0:
        return float("nan")
    v = float(s.iloc[-1])
    return v


def ohlcv_rows_tail(df: pd.DataFrame, n: int = 20) -> list[list[float]]:
    """Oldest->newest OHLCV lists for `features.m1_ohlcv` (matches EA bridge)."""
    tail = df.tail(n)
    out: list[list[float]] = []
    for _, row in tail.iterrows():
        out.append(
            [
                float(row["open"]),
                float(row["high"]),
                float(row["low"]),
                float(row["close"]),
                float(row.get("tick_volume", row.get("real_volume", 0)) or 0),
            ]
        )
    return out
