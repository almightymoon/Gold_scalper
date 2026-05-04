from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, precision_recall_fscore_support
from sklearn.model_selection import TimeSeriesSplit

from features import packet_to_dataframe_row, select_model_features


@dataclass
class Paths:
    data_dir: Path
    models_dir: Path

    @property
    def features_csv(self) -> Path:
        return self.data_dir / "live_features.csv"

    @property
    def signals_csv(self) -> Path:
        return self.data_dir / "signals.csv"


def _parse_time(s: str) -> pd.Timestamp:
    # Expect ISO-like gmtime from EA/Python; tolerate errors.
    return pd.to_datetime(s, errors="coerce", utc=True)


def _mid_from_row(row: pd.Series) -> float:
    bid = row.get("bid", np.nan)
    ask = row.get("ask", np.nan)
    if np.isfinite(bid) and np.isfinite(ask) and ask >= bid:
        return float((bid + ask) / 2.0)
    c = row.get("m1_c20_c", np.nan)  # newest candle close (if present)
    return float(c) if np.isfinite(c) else np.nan


def _label_trade(
    future_mids: np.ndarray,
    entry_mid: float,
    signal: str,
    sl_points: int,
    tp_points: int,
    point_value: float,
) -> Optional[int]:
    """
    Label as 1 if TP is reached before SL, else 0.
    Returns None if insufficient data.
    """
    if not np.isfinite(entry_mid) or len(future_mids) == 0:
        return None
    if sl_points <= 0 or tp_points <= 0 or point_value <= 0:
        return None

    sl = sl_points * point_value
    tp = tp_points * point_value

    if signal == "BUY":
        tp_level = entry_mid + tp
        sl_level = entry_mid - sl
        for m in future_mids:
            if not np.isfinite(m):
                continue
            if m >= tp_level:
                return 1
            if m <= sl_level:
                return 0
        return 0

    if signal == "SELL":
        tp_level = entry_mid - tp
        sl_level = entry_mid + sl
        for m in future_mids:
            if not np.isfinite(m):
                continue
            if m <= tp_level:
                return 1
            if m >= sl_level:
                return 0
        return 0

    return None


def build_training_set(
    features_df: pd.DataFrame,
    signals_df: pd.DataFrame,
    *,
    horizon_rows: int = 30,
    default_point_value: float = 0.01,
) -> Tuple[pd.DataFrame, pd.Series]:
    """
    Uses `signals.csv` rows as "entries", merges with nearest feature row by time,
    and labels success by scanning forward `horizon_rows` feature rows.

    This is a pragmatic first-pass trainer intended for demo research.
    """
    fdf = features_df.copy()
    sdf = signals_df.copy()

    fdf["time_ts"] = fdf["time"].astype(str).map(_parse_time)
    sdf["time_ts"] = sdf["time"].astype(str).map(_parse_time)
    fdf = fdf.dropna(subset=["time_ts"]).sort_values(["symbol", "time_ts"]).reset_index(drop=True)
    sdf = sdf.dropna(subset=["time_ts"]).sort_values(["symbol", "time_ts"]).reset_index(drop=True)

    # Keep only actionable signals
    sdf["signal"] = sdf["signal"].astype(str).str.upper()
    sdf = sdf[sdf["signal"].isin(["BUY", "SELL"])].copy()
    if sdf.empty:
        raise RuntimeError("No BUY/SELL rows found in signals.csv. Need more collected data.")

    # Merge-asof per symbol: nearest feature row at or before the signal time.
    rows: list[dict[str, Any]] = []
    labels: list[int] = []
    for sym, sym_signals in sdf.groupby("symbol", sort=False):
        sym_feats = fdf[fdf["symbol"] == sym].copy()
        if sym_feats.empty:
            continue
        merged = pd.merge_asof(
            sym_signals.sort_values("time_ts"),
            sym_feats.sort_values("time_ts"),
            on="time_ts",
            direction="backward",
            suffixes=("_sig", "_feat"),
        )
        merged = merged.dropna(subset=["bid", "ask"], how="all")
        if merged.empty:
            continue

        # Build label by scanning forward horizon in feature time series
        sym_feats = sym_feats.reset_index(drop=True)
        for _, r in merged.iterrows():
            # find index of the matched feature row
            t = r["time_ts"]
            idx = int(sym_feats["time_ts"].searchsorted(t, side="right") - 1)
            if idx < 0:
                continue
            future = sym_feats.iloc[idx + 1 : idx + 1 + horizon_rows]
            entry_mid = _mid_from_row(sym_feats.iloc[idx])
            y = _label_trade(
                future_mids=np.array([_mid_from_row(rr) for _, rr in future.iterrows()], dtype=float),
                entry_mid=entry_mid,
                signal=str(r["signal"]),
                sl_points=int(r.get("sl_points", 0) or 0),
                tp_points=int(r.get("tp_points", 0) or 0),
                point_value=default_point_value,
            )
            if y is None:
                continue

            d = sym_feats.iloc[idx].to_dict()
            d["time_ts"] = sym_feats.iloc[idx]["time_ts"]
            d["signal_dir"] = str(r["signal"])
            labels.append(int(y))
            rows.append(d)

    if not rows:
        raise RuntimeError("Could not build any labeled samples. Collect more data or increase horizon.")

    Xdf = pd.DataFrame(rows)
    # Keep chronological order to support time-based splitting.
    if "time_ts" in Xdf.columns:
        Xdf = Xdf.sort_values("time_ts").reset_index(drop=True)
    yser = pd.Series(labels, name="label")
    return Xdf, yser


def train(paths: Paths, *, horizon_rows: int, point_value: float) -> None:
    if not paths.features_csv.exists() or not paths.signals_csv.exists():
        raise FileNotFoundError("Missing live_features.csv or signals.csv. Run the bridge first to collect data.")

    # Robust load for features:
    # During iteration, live_features.csv may contain extra flattened columns beyond the original header.
    # We rely on the first 4 columns (time,symbol,type,raw_json) and re-parse raw_json into a clean DataFrame.
    feature_rows = []
    with paths.features_csv.open("r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if header is None:
            raise RuntimeError("live_features.csv is empty.")
        for row in reader:
            if not row:
                continue
            if len(row) < 4:
                continue
            time_s, symbol, typ, raw_json = row[0], row[1], row[2], row[3]
            if not raw_json:
                continue
            try:
                packet = json.loads(raw_json)
            except Exception:
                # Some files may have double-quoted JSON from earlier runs; try a light fix.
                try:
                    packet = json.loads(raw_json.replace('""', '"'))
                except Exception:
                    continue
            df1 = packet_to_dataframe_row(packet)
            feature_rows.append(df1)
    if not feature_rows:
        raise RuntimeError("Could not parse any feature packets from live_features.csv.")
    features_df = pd.concat(feature_rows, ignore_index=True)
    signals_df = pd.read_csv(paths.signals_csv)

    Xraw, y = build_training_set(features_df, signals_df, horizon_rows=horizon_rows, default_point_value=point_value)
    # Time-based split to avoid look-ahead bias.
    if "time_ts" in Xraw.columns:
        order = np.argsort(pd.to_datetime(Xraw["time_ts"], utc=True, errors="coerce").astype("int64").fillna(0).values)
        Xraw = Xraw.iloc[order].reset_index(drop=True)
        y = y.iloc[order].reset_index(drop=True)

    # Drop non-feature columns
    for c in ["time", "symbol", "type", "time_ts", "signal_dir"]:
        if c in Xraw.columns:
            Xraw = Xraw.drop(columns=[c])
    X, feature_cols = select_model_features(Xraw)
    X = X.fillna(0.0)

    # Prefer a time-based split, but don't hard-fail on small datasets.
    # When data is scarce, train on all labeled samples and still write model.pkl so the
    # live server can run (confidence overlay will be weak until more data is collected).
    split = int(len(X) * 0.75)
    min_train = 15
    min_test = 6
    use_holdout = (split >= min_train) and ((len(X) - split) >= min_test)
    if use_holdout:
        X_train, X_test = X.iloc[:split], X.iloc[split:]
        y_train, y_test = y.iloc[:split], y.iloc[split:]
    else:
        X_train, y_train = X, y
        X_test, y_test = None, None
        print(
            "WARNING: Not enough labeled samples for a time-based split "
            f"(samples={len(X)} train={split} test={len(X)-split}). "
            "Training on ALL data; collect more data for proper validation."
        )

    clf = RandomForestClassifier(
        n_estimators=450,
        max_depth=10,
        min_samples_leaf=10,
        random_state=42,
        class_weight="balanced_subsample",
        n_jobs=-1,
    )
    clf.fit(X_train, y_train)

    if X_test is not None and y_test is not None:
        y_pred = clf.predict(X_test)
        acc = accuracy_score(y_test, y_pred)
        prec, rec, f1, _ = precision_recall_fscore_support(y_test, y_pred, average="binary", zero_division=0)

        print("=== Model metrics (binary: TP-before-SL) ===")
        print(f"Samples: {len(y)} (train={len(y_train)}, test={len(y_test)})")
        print(f"Accuracy : {acc:.4f}")
        print(f"Precision: {prec:.4f}")
        print(f"Recall   : {rec:.4f}")
        print(f"F1       : {f1:.4f}")
    else:
        print("=== Model metrics ===")
        print(f"Samples: {len(y)} (trained on all; no holdout metrics)")

    # Walk-forward validation (optional but recommended signal)
    if X_test is not None and len(X) >= 40:
        n_splits = 5
        tscv = TimeSeriesSplit(n_splits=n_splits)
        wf_scores = []
        for tr_idx, te_idx in tscv.split(X):
            m = RandomForestClassifier(
                n_estimators=450,
                max_depth=10,
                min_samples_leaf=10,
                random_state=42,
                class_weight="balanced_subsample",
                n_jobs=-1,
            )
            m.fit(X.iloc[tr_idx], y.iloc[tr_idx])
            wf_scores.append(accuracy_score(y.iloc[te_idx], m.predict(X.iloc[te_idx])))
        print(f"Walk-forward accuracy: {float(np.mean(wf_scores)):.4f} ± {float(np.std(wf_scores)):.4f} (n_splits={n_splits})")

    paths.models_dir.mkdir(parents=True, exist_ok=True)
    out = {
        "model": clf,
        "feature_columns": feature_cols,
        "meta": {
            "horizon_rows": horizon_rows,
            "point_value": point_value,
            "note": "Model predicts success probability; server still enforces safe SL/TP defaults.",
            "trained_with_holdout": bool(X_test is not None),
            "n_samples": int(len(y)),
        },
    }
    joblib.dump(out, paths.models_dir / "model.pkl")
    print(f"Saved model to {str(paths.models_dir / 'model.pkl')}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train a simple model for GoldScalper_AI_Bridge")
    p.add_argument("--data-dir", default=str(Path(__file__).resolve().parents[1] / "data"))
    p.add_argument("--models-dir", default=str(Path(__file__).resolve().parent / "models"))
    p.add_argument("--horizon-rows", type=int, default=30, help="How many future feature rows to scan for TP/SL")
    p.add_argument("--point-value", type=float, default=0.01, help="Approximate point value for XAUUSD (demo)")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    paths = Paths(
        data_dir=Path(args.data_dir).expanduser().resolve(),
        models_dir=Path(args.models_dir).expanduser().resolve(),
    )
    train(paths, horizon_rows=int(args.horizon_rows), point_value=float(args.point_value))


if __name__ == "__main__":
    main()

