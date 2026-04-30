from __future__ import annotations

import csv
import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, Optional


@dataclass(frozen=True)
class LogPaths:
    data_dir: Path

    @property
    def live_features_csv(self) -> Path:
        return self.data_dir / "live_features.csv"

    @property
    def signals_csv(self) -> Path:
        return self.data_dir / "signals.csv"

    @property
    def trades_csv(self) -> Path:
        return self.data_dir / "trades.csv"


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _rotate_if_header_mismatch(path: Path, fieldnames: list[str]) -> None:
    """
    If an existing CSV was created with a different header (common during iteration),
    rotate it to a timestamped backup so future reads are consistent.
    """
    if not path.exists() or path.stat().st_size <= 0:
        return
    try:
        with path.open("r", encoding="utf-8", errors="replace", newline="") as f:
            first = f.readline().strip("\n\r")
    except Exception:
        return

    expected = ",".join(fieldnames)
    if first.strip() == expected.strip():
        return

    ts = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
    backup = path.with_name(f"{path.stem}.bak_{ts}{path.suffix}")
    try:
        path.rename(backup)
    except Exception:
        # If rename fails, don't block logging.
        return


def _append_row(path: Path, fieldnames: Iterable[str], row: Dict[str, Any]) -> None:
    _ensure_parent(path)
    fns = list(fieldnames)
    _rotate_if_header_mismatch(path, fns)
    file_exists = path.exists() and path.stat().st_size > 0
    with path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fns)
        if not file_exists:
            writer.writeheader()
        writer.writerow({k: row.get(k, "") for k in writer.fieldnames})


def log_feature_packet(paths: LogPaths, packet: Dict[str, Any], flattened: Dict[str, Any]) -> None:
    row = {
        "time": packet.get("time", ""),
        "symbol": packet.get("symbol", ""),
        "type": packet.get("type", ""),
        "raw_json": json.dumps(packet, ensure_ascii=False),
        **flattened,
    }
    fieldnames = [
        "time",
        "symbol",
        "type",
        "raw_json",
        *sorted(k for k in flattened.keys()),
    ]
    _append_row(paths.live_features_csv, fieldnames, row)


def log_signal(
    paths: LogPaths,
    packet: Dict[str, Any],
    response: Dict[str, Any],
    *,
    transport: str,
) -> None:
    row = {
        "time": packet.get("time", ""),
        "symbol": packet.get("symbol", ""),
        "transport": transport,
        "signal": response.get("signal", "HOLD"),
        "confidence": float(response.get("confidence", 0.0) or 0.0),
        "sl_points": int(response.get("sl_points", 0) or 0),
        "tp_points": int(response.get("tp_points", 0) or 0),
        "reason": response.get("reason", ""),
        "raw_features_json": json.dumps(packet, ensure_ascii=False),
        "raw_response_json": json.dumps(response, ensure_ascii=False),
    }
    fieldnames = [
        "time",
        "symbol",
        "transport",
        "signal",
        "confidence",
        "sl_points",
        "tp_points",
        "reason",
        "raw_features_json",
        "raw_response_json",
    ]
    _append_row(paths.signals_csv, fieldnames, row)


def log_trade_event(
    paths: LogPaths,
    *,
    time: str,
    symbol: str,
    event: str,
    magic: Optional[int] = None,
    ticket: Optional[int] = None,
    side: Optional[str] = None,
    volume: Optional[float] = None,
    price: Optional[float] = None,
    sl: Optional[float] = None,
    tp: Optional[float] = None,
    profit: Optional[float] = None,
    reason: str = "",
    extra: Optional[Dict[str, Any]] = None,
) -> None:
    row: Dict[str, Any] = {
        "time": time,
        "symbol": symbol,
        "event": event,
        "magic": "" if magic is None else int(magic),
        "ticket": "" if ticket is None else int(ticket),
        "side": side or "",
        "volume": "" if volume is None else float(volume),
        "price": "" if price is None else float(price),
        "sl": "" if sl is None else float(sl),
        "tp": "" if tp is None else float(tp),
        "profit": "" if profit is None else float(profit),
        "reason": reason,
        "extra_json": json.dumps(extra or {}, ensure_ascii=False),
    }
    fieldnames = [
        "time",
        "symbol",
        "event",
        "magic",
        "ticket",
        "side",
        "volume",
        "price",
        "sl",
        "tp",
        "profit",
        "reason",
        "extra_json",
    ]
    _append_row(paths.trades_csv, fieldnames, row)

