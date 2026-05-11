"""Unit tests for pandas indicators used by MT5 live mode."""

from __future__ import annotations

from pathlib import Path
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mt5_indicators import m1_indicator_row, ohlcv_rows_tail, rsi_wilder  # noqa: E402


def _synthetic_m1(n: int = 200) -> pd.DataFrame:
    t = pd.date_range("2026-01-01", periods=n, freq="min", tz="UTC")
    close = 2650 + np.cumsum(np.random.default_rng(42).normal(0, 0.05, size=n))
    high = close + 0.4
    low = close - 0.4
    open_ = np.roll(close, 1)
    open_[0] = close[0]
    vol = np.full(n, 100.0)
    return pd.DataFrame({"time": t, "open": open_, "high": high, "low": low, "close": close, "tick_volume": vol})


def test_rsi_bounds() -> None:
    df = _synthetic_m1(120)
    r = rsi_wilder(df["close"], 14)
    tail = r.iloc[50:].dropna()
    assert (tail >= 0).all() and (tail <= 100).all()


def test_m1_indicator_row_finite() -> None:
    df = _synthetic_m1(200)
    row = m1_indicator_row(df)
    assert np.isfinite(row["m1_ema9"])
    assert np.isfinite(row["m1_rsi14"])
    assert np.isfinite(row["m1_adx14"])


def test_ohlcv_tail_shape() -> None:
    df = _synthetic_m1(30)
    rows = ohlcv_rows_tail(df, 20)
    assert len(rows) == 20
    assert len(rows[0]) == 5
