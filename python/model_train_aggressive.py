from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, precision_recall_fscore_support


@dataclass
class Paths:
    data_dir: Path
    models_dir: Path

    @property
    def ml_csv(self) -> Path:
        return self.data_dir / "trades_ml.csv"


def _parse_time(s: str) -> pd.Timestamp:
    return pd.to_datetime(s, errors="coerce", utc=True)


def build_dataset(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.Series]:
    """
    Build samples from OPEN rows, labeled by CLOSE profit of same position_id.
    Requires: position_id, event, profit, ema9, ema21, rsi, spread_pts, price, sl, tp, side.
    """
    d = df.copy()
    d["time_ts"] = d["time"].astype(str).map(_parse_time)
    d = d.dropna(subset=["time_ts"]).sort_values("time_ts").reset_index(drop=True)

    # Keep only rows with position_id
    d["position_id"] = pd.to_numeric(d.get("position_id"), errors="coerce")
    d = d.dropna(subset=["position_id"])
    d["position_id"] = d["position_id"].astype("int64")

    opens = d[d["event"].astype(str).str.upper().eq("OPEN")].copy()
    closes = d[d["event"].astype(str).str.upper().eq("CLOSE")].copy()
    if opens.empty or closes.empty:
        raise RuntimeError("Need both OPEN and CLOSE rows in trades_ml.csv to train.")

    closes_agg = (
        closes.groupby("position_id", as_index=False)
        .agg(closed_profit=("profit", "sum"), close_time=("time_ts", "max"))
        .sort_values("close_time")
    )

    merged = opens.merge(closes_agg[["position_id", "closed_profit"]], on="position_id", how="inner")
    if merged.empty:
        raise RuntimeError("Could not match OPEN rows to CLOSE rows by position_id. Collect more data.")

    merged = merged.sort_values("time_ts").reset_index(drop=True)

    # Label: closed trade profit > 0 (OPEN rows carry profit=0, avoid column clash with agg)
    y = (pd.to_numeric(merged["closed_profit"], errors="coerce").fillna(0.0) > 0.0).astype(int)

    # Features
    def _num(col: str) -> pd.Series:
        return pd.to_numeric(merged.get(col), errors="coerce")

    X = pd.DataFrame(
        {
            "ema_gap": (_num("ema9") - _num("ema21")).fillna(0.0),
            "rsi": _num("rsi").fillna(0.0),
            "spread_pts": _num("spread_pts").fillna(0.0),
            "sl_dist": (_num("price") - _num("sl")).abs().fillna(0.0),
            "tp_dist": (_num("tp") - _num("price")).abs().fillna(0.0),
            "volume": _num("volume").fillna(0.0),
            "side_is_buy": (merged.get("side").astype(str).str.upper() == "BUY").astype(int),
        }
    )

    return X.reset_index(drop=True), y.reset_index(drop=True)


def train(paths: Paths) -> None:
    if not paths.ml_csv.exists():
        raise FileNotFoundError(
            f"Missing {paths.ml_csv}. Recompile/reload EA with EnableMlLog=true, then import it via ai_server.py."
        )

    df = pd.read_csv(paths.ml_csv)
    X, y = build_dataset(df)

    # Time-based holdout
    split = int(len(X) * 0.75)
    min_train, min_test = 20, 8
    use_holdout = split >= min_train and (len(X) - split) >= min_test
    if use_holdout:
        X_train, X_test = X.iloc[:split], X.iloc[split:]
        y_train, y_test = y.iloc[:split], y.iloc[split:]
    else:
        X_train, y_train = X, y
        X_test, y_test = None, None
        print(
            "WARNING: Not enough samples for time holdout "
            f"(samples={len(X)} train={split} test={len(X)-split}). Training on ALL data."
        )

    clf = RandomForestClassifier(
        n_estimators=600,
        max_depth=10,
        min_samples_leaf=8,
        random_state=42,
        class_weight="balanced_subsample",
        n_jobs=-1,
    )
    clf.fit(X_train, y_train)

    if X_test is not None and y_test is not None:
        pred = clf.predict(X_test)
        acc = accuracy_score(y_test, pred)
        prec, rec, f1, _ = precision_recall_fscore_support(y_test, pred, average="binary", zero_division=0)
        print("=== Aggressive model metrics (profit>0) ===")
        print(f"Samples: {len(y)} (train={len(y_train)}, test={len(y_test)})")
        print(f"Accuracy : {acc:.4f}")
        print(f"Precision: {prec:.4f}")
        print(f"Recall   : {rec:.4f}")
        print(f"F1       : {f1:.4f}")
    else:
        print("=== Aggressive model metrics ===")
        print(f"Samples: {len(y)} (trained on all; no holdout metrics)")

    paths.models_dir.mkdir(parents=True, exist_ok=True)
    out: dict[str, Any] = {
        "model": clf,
        "feature_columns": list(X.columns),
        "meta": {"kind": "aggressive_scalping", "label": "profit>0", "n_samples": int(len(y))},
    }
    joblib.dump(out, paths.models_dir / "model_aggressive.pkl")
    print(f"Saved model to {paths.models_dir / 'model_aggressive.pkl'}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train ML model for aggressive scalping (from trades_ml.csv)")
    p.add_argument("--data-dir", default=str(Path(__file__).resolve().parents[1] / "data" / "aggressive_scalping"))
    p.add_argument("--models-dir", default=str(Path(__file__).resolve().parent / "models"))
    return p.parse_args()


def main() -> None:
    args = parse_args()
    paths = Paths(
        data_dir=Path(args.data_dir).expanduser().resolve(),
        models_dir=Path(args.models_dir).expanduser().resolve(),
    )
    train(paths)


if __name__ == "__main__":
    main()

