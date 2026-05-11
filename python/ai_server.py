from __future__ import annotations

import argparse
import json
import logging
import signal
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import joblib
import numpy as np
import zmq

from features import (
    AGGRESSIVE_FEATURE_COLUMNS,
    aggressive_feature_dataframe,
    flatten_feature_packet,
    packet_to_dataframe_row,
    select_model_features,
)
from trade_logger import LogPaths, log_feature_packet, log_signal, log_trade_event


@dataclass
class ServerConfig:
    host: str = "127.0.0.1"
    zmq_port: int = 5555
    tcp_port: int = 5556  # MT5 socket fallback (JSON line protocol)
    data_dir: Path = Path(__file__).resolve().parents[1] / "data"
    models_dir: Path = Path(__file__).resolve().parent / "models"
    enable_tcp_fallback: bool = True
    enable_file_bridge: bool = False
    file_bridge_dir: Optional[Path] = None
    file_poll_interval_s: float = 0.15
    # If > 0: when aggressive model supplies p_win, force HOLD if p_win is below this (before MIN_CONF gate).
    min_agg_pwin: float = 0.0


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())


def _clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def _safe_float(d: Dict[str, Any], k: str, default: float = float("nan")) -> float:
    try:
        v = d.get(k, None)
        if v is None:
            return default
        return float(v)
    except Exception:
        return default


def _safe_int(d: Dict[str, Any], k: str, default: int = 0) -> int:
    try:
        v = d.get(k, None)
        if v is None:
            return default
        return int(v)
    except Exception:
        return default


class AiModel:
    def __init__(self, models_dir: Path):
        self.models_dir = models_dir
        self.model_path = models_dir / "model.pkl"
        self.model: Any = None
        self.feature_columns: Optional[list[str]] = None

    def load_if_available(self) -> bool:
        if not self.model_path.exists():
            return False
        payload = joblib.load(self.model_path)
        if isinstance(payload, dict) and "model" in payload:
            self.model = payload["model"]
            self.feature_columns = payload.get("feature_columns")
        else:
            self.model = payload
            self.feature_columns = None
        return True

    def predict_win_probability(self, packet: Dict[str, Any]) -> Optional[float]:
        if self.model is None:
            return None

        df = packet_to_dataframe_row(packet)
        X, cols = select_model_features(df)
        if self.feature_columns:
            # Align to training columns
            for c in self.feature_columns:
                if c not in X.columns:
                    X[c] = np.nan
            X = X[self.feature_columns]
            cols = self.feature_columns

        X = X.ffill(axis=1).fillna(0.0)

        if hasattr(self.model, "predict_proba"):
            proba = self.model.predict_proba(X)[0]
            classes = list(getattr(self.model, "classes_", []))
            # Expect binary {0,1}.
            # If not, fall back to max probability.
            if 1 in classes:
                return float(proba[classes.index(1)])
            if "1" in [str(c) for c in classes]:
                return float(proba[[str(c) for c in classes].index("1")])
            return float(np.max(proba))

        # No proba available: treat prediction as weak confidence.
        try:
            pred = int(self.model.predict(X)[0])
            return 0.60 if pred == 1 else 0.40
        except Exception:
            return None


class AggressiveAiModel:
    """
    Classifier trained on aggressive_scalping trades_ml.csv (P(closed_profit > 0)).
    Feature vector matches `AGGRESSIVE_FEATURE_COLUMNS` / model_train_aggressive.py.
    """

    def __init__(self, model_path: Path):
        self.model_path = model_path
        self.model: Any = None
        self.feature_columns: Optional[list[str]] = None

    def load_if_available(self) -> bool:
        if not self.model_path.exists():
            return False
        payload = joblib.load(self.model_path)
        if isinstance(payload, dict) and "model" in payload:
            self.model = payload["model"]
            self.feature_columns = payload.get("feature_columns") or list(AGGRESSIVE_FEATURE_COLUMNS)
        else:
            self.model = payload
            self.feature_columns = list(AGGRESSIVE_FEATURE_COLUMNS)
        return True

    def predict_profit_probability(self, packet: Dict[str, Any], rule: Dict[str, Any]) -> Optional[float]:
        """
        Uses rule signal + SL/TP points and live bid/ask to build the same features as at trade open.
        """
        if self.model is None:
            return None
        sig = str(rule.get("signal") or "HOLD").upper()
        if sig not in {"BUY", "SELL"}:
            return None
        sl_pts = int(rule.get("sl_points") or 0)
        tp_pts = int(rule.get("tp_points") or 0)
        if sl_pts <= 0 or tp_pts <= 0:
            return None

        f = packet.get("features", {}) or {}
        bid = _safe_float(f, "bid")
        ask = _safe_float(f, "ask")
        spread_pts = float(_safe_int(f, "spread_points"))
        ema9 = _safe_float(f, "m1_ema9")
        ema21 = _safe_float(f, "m1_ema21")
        rsi = _safe_float(f, "m1_rsi14")

        point = 0.01
        if np.isfinite(bid) and np.isfinite(ask) and spread_pts > 0:
            inferred = (ask - bid) / spread_pts
            if np.isfinite(inferred) and inferred > 0:
                point = float(inferred)

        if sig == "BUY":
            price = ask
            sl = price - sl_pts * point
            tp = price + tp_pts * point
        else:
            price = bid
            sl = price + sl_pts * point
            tp = price - tp_pts * point

        vol = _safe_float(f, "volume_lots")
        if not np.isfinite(vol) or vol <= 0:
            vol = 0.01

        X = aggressive_feature_dataframe(ema9, ema21, rsi, spread_pts, price, sl, tp, sig, vol)
        cols = self.feature_columns or list(AGGRESSIVE_FEATURE_COLUMNS)
        for c in cols:
            if c not in X.columns:
                X[c] = 0.0
        X = X[cols].astype(float)
        X = X.fillna(0.0)

        if hasattr(self.model, "predict_proba"):
            proba = self.model.predict_proba(X)[0]
            classes = list(getattr(self.model, "classes_", []))
            if 1 in classes:
                return float(_clamp(float(proba[classes.index(1)]), 0.0, 1.0))
            if "1" in [str(c) for c in classes]:
                return float(_clamp(float(proba[[str(c) for c in classes].index("1")]), 0.0, 1.0))
            return float(_clamp(float(np.max(proba)), 0.0, 1.0))

        try:
            pred = int(self.model.predict(X)[0])
            return 0.60 if pred == 1 else 0.40
        except Exception:
            return None


def dummy_rule_ai(packet: Dict[str, Any]) -> Dict[str, Any]:
    f = packet.get("features", {}) or {}

    def _hold(reason: str) -> Dict[str, Any]:
        return {"signal": "HOLD", "confidence": 0.0, "sl_points": 0, "tp_points": 0, "reason": reason}

    # Basic fields
    bid = _safe_float(f, "bid")
    ask = _safe_float(f, "ask")
    spread_pts = float(_safe_int(f, "spread_points"))
    hour = _safe_int(f, "hour_gmt")

    # Session filter: avoid dead zone (late NY -> Asia)
    in_dead_zone = (hour >= 21) or (hour < 6)
    if in_dead_zone:
        return _hold(f"dead_zone: hour_gmt={hour}")

    # Hard spread gate for scalping (server-side prefilter; EA still enforces its own spread cap)
    if spread_pts > 40:
        return _hold(f"spread_too_wide: {spread_pts:.0f}")

    # Volatility regime: use derived features if provided by features.py
    ret_std = _safe_float(f, "m1_ret_std_20")
    if np.isfinite(ret_std):
        # Reject extremely flat or extreme spikes (heuristic)
        if ret_std < 0.00005:
            return _hold(f"volatility_too_low: ret_std_20={ret_std:.6f}")
        if ret_std > 0.00150:
            return _hold(f"volatility_too_high: ret_std_20={ret_std:.6f}")

    # Trend/momentum inputs
    m1_ema9 = _safe_float(f, "m1_ema9")
    m1_ema21 = _safe_float(f, "m1_ema21")
    m1_ema50 = _safe_float(f, "m1_ema50")
    m5_ema20 = _safe_float(f, "m5_ema20")
    m5_ema50 = _safe_float(f, "m5_ema50")
    rsi1 = _safe_float(f, "m1_rsi14")
    rsi5 = _safe_float(f, "m5_rsi14")
    adx = _safe_float(f, "m1_adx14")
    plusdi = _safe_float(f, "m1_plusdi")
    minusdi = _safe_float(f, "m1_minusdi")

    # Last candle confirmation (use newest close: m1_c20_*)
    o = _safe_float(f, "m1_c20_o")
    h = _safe_float(f, "m1_c20_h")
    l = _safe_float(f, "m1_c20_l")
    c = _safe_float(f, "m1_c20_c")
    rng = (h - l) if (np.isfinite(h) and np.isfinite(l) and (h - l) > 0) else np.nan
    body_ratio = (abs(c - o) / rng) if np.isfinite(rng) else np.nan

    def _score_buy() -> float:
        score = 0.0
        if m1_ema9 > m1_ema21:
            score += 1.0
        if m1_ema21 > m1_ema50:
            score += 0.5
        if m5_ema20 > m5_ema50:
            score += 1.0
        if 50.0 <= rsi1 <= 65.0:
            score += 1.0
        elif 45.0 <= rsi1 < 50.0:
            score += 0.5
        if adx > 25.0:
            score += 1.5
        elif adx > 15.0:
            score += 0.75
        if plusdi > minusdi:
            score += 1.0
        if rsi5 > 50.0:
            score += 0.5
        return score  # max ~6.5

    def _score_sell() -> float:
        score = 0.0
        if m1_ema9 < m1_ema21:
            score += 1.0
        if m1_ema21 < m1_ema50:
            score += 0.5
        if m5_ema20 < m5_ema50:
            score += 1.0
        if 35.0 <= rsi1 <= 50.0:
            score += 1.0
        elif 50.0 < rsi1 <= 55.0:
            score += 0.5
        if adx > 25.0:
            score += 1.5
        elif adx > 15.0:
            score += 0.75
        if minusdi > plusdi:
            score += 1.0
        if rsi5 < 50.0:
            score += 0.5
        return score

    buy_score = _score_buy()
    sell_score = _score_sell()
    MIN_SCORE = 4.5

    signal = "HOLD"
    score = 0.0
    if buy_score >= MIN_SCORE and buy_score > sell_score + 0.5:
        # Candle confirmation: bullish + decisive body
        if np.isfinite(body_ratio) and (c > o) and (body_ratio >= 0.45):
            signal = "BUY"
            score = buy_score
        else:
            return _hold(f"candle_filter_buy: body_ratio={body_ratio:.2f}")
    elif sell_score >= MIN_SCORE and sell_score > buy_score + 0.5:
        if np.isfinite(body_ratio) and (c < o) and (body_ratio >= 0.45):
            signal = "SELL"
            score = sell_score
        else:
            return _hold(f"candle_filter_sell: body_ratio={body_ratio:.2f}")

    if signal == "HOLD":
        return _hold(f"confluence_low: buy={buy_score:.2f} sell={sell_score:.2f} adx={adx:.1f} rsi={rsi1:.1f}")

    # Confidence: normalize score + add spread and session quality
    spread_quality = 1.0 - _clamp((spread_pts - 18.0) / 40.0, 0.0, 1.0)
    session_quality = 1.0
    # Prefer London + overlap
    if 7 <= hour < 12:
        session_quality = 1.0
    elif 12 <= hour < 16:
        session_quality = 0.95
    else:
        session_quality = 0.80

    score_quality = _clamp((score - MIN_SCORE) / (6.5 - MIN_SCORE), 0.0, 1.0)
    conf = float(_clamp(0.55 + 0.30 * score_quality + 0.10 * spread_quality + 0.05 * session_quality, 0.0, 1.0))

    # ATR-based SL/TP (in points)
    atr1 = _safe_float(f, "m1_atr14")
    atr5 = _safe_float(f, "m5_atr14")
    base_atr = atr5 if (np.isfinite(atr5) and atr5 > 0) else atr1

    # Infer point size from bid/ask and spread_points (more robust on non-0.01 brokers)
    point = 0.01
    if np.isfinite(bid) and np.isfinite(ask) and spread_pts > 0:
        inferred = (ask - bid) / spread_pts
        if np.isfinite(inferred) and inferred > 0:
            point = float(inferred)

    if np.isfinite(base_atr) and base_atr > 0 and point > 0:
        atr_pts = int(max(1, round(base_atr / point)))
        sl_points = int(_clamp(atr_pts * 1.2, 80.0, 320.0))
        tp_points = int(_clamp(atr_pts * 2.0, 150.0, 650.0))
    else:
        sl_points = 150
        tp_points = 270

    reason = (
        f"confluence: {signal} score={score:.2f} buy={buy_score:.2f} sell={sell_score:.2f} "
        f"adx={adx:.1f} rsi1={rsi1:.1f} body={body_ratio:.2f} spread={spread_pts:.0f} hour={hour}"
    )
    return {"signal": signal, "confidence": conf, "sl_points": sl_points, "tp_points": tp_points, "reason": reason}


def decide(
    packet: Dict[str, Any],
    model: AiModel,
    aggressive: Optional[AggressiveAiModel] = None,
    *,
    min_agg_pwin: float = 0.0,
) -> Dict[str, Any]:
    # Architecture note:
    # - Direction comes from the rule engine (BUY/SELL/HOLD)
    # - ML models are win-probability overlays (not direction), never for lot sizing or risk overrides.
    rule = dummy_rule_ai(packet)
    p_win: Optional[float] = None
    p_source = ""

    if aggressive is not None and aggressive.model is not None:
        p_win = aggressive.predict_profit_probability(packet, rule)
        if p_win is not None:
            p_source = "agg"

    if p_win is None:
        p_win = model.predict_win_probability(packet)
        if p_win is not None:
            p_source = "bridge"

    if p_win is None:
        resp = rule
    else:
        p_win = float(_clamp(p_win, 0.0, 1.0))
        base_conf = float(rule.get("confidence", 0.0) or 0.0)
        # Combine: keep rule as baseline, then nudge by model probability.
        combined = 0.55 * base_conf + 0.45 * p_win
        rule["confidence"] = float(_clamp(combined, 0.0, 1.0))
        tag = f"{p_source}_pwin" if p_source else "pwin"
        rule["reason"] = f"{tag}={p_win:.2f} combined_conf={rule['confidence']:.2f} | {rule.get('reason','')}"
        if rule.get("signal") == "HOLD":
            rule["confidence"] = min(rule["confidence"], 0.55)
        resp = rule

    # Optional hard gate on aggressive P(profit>0) only (bridge model unaffected).
    if (
        min_agg_pwin > 0.0
        and p_source == "agg"
        and p_win is not None
        and resp.get("signal") in {"BUY", "SELL"}
        and float(p_win) < float(min_agg_pwin)
    ):
        resp["reason"] = (
            f"filtered: agg_pwin={float(p_win):.3f} < {float(min_agg_pwin):.3f} | {resp.get('reason', '')}"
        )
        resp["signal"] = "HOLD"
        resp["confidence"] = min(float(resp.get("confidence", 0.0) or 0.0), 0.55)

    # Server-side confidence filter (keeps MT5 risk controls intact)
    MIN_CONF = 0.58
    if resp.get("signal") in {"BUY", "SELL"} and float(resp.get("confidence", 0.0) or 0.0) < MIN_CONF:
        resp["reason"] = f"filtered: conf={float(resp.get('confidence',0.0)):.2f} < {MIN_CONF:.2f} | {resp.get('reason','')}"
        resp["signal"] = "HOLD"
        resp["confidence"] = min(float(resp.get("confidence", 0.0) or 0.0), 0.55)
    return resp


def _handle_packet(
    packet: Dict[str, Any],
    *,
    cfg: ServerConfig,
    model: AiModel,
    aggressive: Optional[AggressiveAiModel],
    logs: LogPaths,
    transport: str,
) -> Dict[str, Any]:
    flattened = flatten_feature_packet(packet)
    log_feature_packet(logs, packet, flattened)

    ptype = packet.get("type")
    request_id = packet.get("request_id")
    if ptype == "ping":
        resp = {"status": "ok", "time": _now_iso()}
        if request_id is not None:
            resp["request_id"] = request_id
        return resp

    if ptype != "features":
        resp = {"signal": "HOLD", "confidence": 0.0, "sl_points": 0, "tp_points": 0, "reason": "invalid_packet_type"}
        if request_id is not None:
            resp["request_id"] = request_id
        log_signal(logs, packet, resp, transport=transport)
        return resp

    resp = decide(packet, model, aggressive=aggressive, min_agg_pwin=cfg.min_agg_pwin)
    # Safety: clamp and sanitize output
    resp = {
        "signal": (resp.get("signal", "HOLD") or "HOLD").upper(),
        "confidence": float(_clamp(float(resp.get("confidence", 0.0) or 0.0), 0.0, 1.0)),
        "sl_points": int(max(0, int(resp.get("sl_points", 0) or 0))),
        "tp_points": int(max(0, int(resp.get("tp_points", 0) or 0))),
        "reason": str(resp.get("reason", "") or ""),
    }
    if request_id is not None:
        resp["request_id"] = request_id
    if resp["signal"] not in {"BUY", "SELL", "HOLD"}:
        resp["signal"] = "HOLD"
    log_signal(logs, packet, resp, transport=transport)
    return resp


def run_zmq_rep(
    cfg: ServerConfig,
    model: AiModel,
    aggressive: Optional[AggressiveAiModel],
    logs: LogPaths,
) -> None:
    ctx = zmq.Context.instance()
    sock = ctx.socket(zmq.REP)
    sock.setsockopt(zmq.LINGER, 0)
    endpoint = f"tcp://{cfg.host}:{cfg.zmq_port}"
    sock.bind(endpoint)
    log = logging.getLogger("gold_scalper")
    log.info("ZeroMQ REP listening on %s", endpoint)

    while True:
        raw = sock.recv()
        try:
            packet = json.loads(raw.decode("utf-8", errors="replace"))
        except Exception:
            resp = {"signal": "HOLD", "confidence": 0.0, "sl_points": 0, "tp_points": 0, "reason": "json_decode_error"}
            sock.send_string(json.dumps(resp))
            continue

        resp = _handle_packet(packet, cfg=cfg, model=model, aggressive=aggressive, logs=logs, transport="zmq")
        sock.send_string(json.dumps(resp, ensure_ascii=False))


def _tcp_client_handler(
    conn: socket.socket,
    addr: Tuple[str, int],
    cfg: ServerConfig,
    model: AiModel,
    aggressive: Optional[AggressiveAiModel],
    logs: LogPaths,
) -> None:
    try:
        conn.settimeout(8.0)
        buf = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    packet = json.loads(line.decode("utf-8", errors="replace"))
                except Exception:
                    resp = {"signal": "HOLD", "confidence": 0.0, "sl_points": 0, "tp_points": 0, "reason": "json_decode_error"}
                    conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
                    continue

                resp = _handle_packet(packet, cfg=cfg, model=model, aggressive=aggressive, logs=logs, transport="tcp")
                conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
    except Exception:
        return
    finally:
        try:
            conn.close()
        except Exception:
            pass


def run_tcp_fallback(
    cfg: ServerConfig,
    model: AiModel,
    aggressive: Optional[AggressiveAiModel],
    logs: LogPaths,
) -> None:
    log = logging.getLogger("gold_scalper")
    while True:
        try:
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((cfg.host, cfg.tcp_port))
            srv.listen(32)
            log.info("TCP fallback listening on %s:%s (JSON line protocol)", cfg.host, cfg.tcp_port)

            while True:
                conn, addr = srv.accept()
                th = threading.Thread(
                    target=_tcp_client_handler,
                    args=(conn, addr, cfg, model, aggressive, logs),
                    daemon=True,
                )
                th.start()
        except Exception as e:
            log.exception("TCP fallback crashed: %s. Restarting in 5s...", e)
            time.sleep(5.0)


def run_file_bridge(
    cfg: ServerConfig,
    model: AiModel,
    aggressive: Optional[AggressiveAiModel],
    logs: LogPaths,
) -> None:
    assert cfg.file_bridge_dir is not None
    d = cfg.file_bridge_dir
    d.mkdir(parents=True, exist_ok=True)
    req_path = d / "request.json"
    resp_path = d / "response.json"
    stamp_path = d / "response.stamp"
    trade_event_path = d / "trade_event.json"
    log = logging.getLogger("gold_scalper")
    log.info("File bridge enabled at %s", str(d))
    log.info("Waiting for %s", str(req_path))

    last_seen_mtime = 0.0
    last_trade_mtime = 0.0
    while True:
        try:
            if req_path.exists():
                mtime = req_path.stat().st_mtime
                if mtime > last_seen_mtime:
                    last_seen_mtime = mtime
                    raw_bytes = req_path.read_bytes()
                    text: Optional[str] = None
                    # MT5/Wine often writes UTF-16 for FILE_TXT; try common encodings.
                    for enc in ("utf-8-sig", "utf-16", "utf-16le", "utf-16be", "cp1252"):
                        try:
                            text = raw_bytes.decode(enc)
                            # Heuristic: JSON should start with "{" or "[" after whitespace.
                            if text.lstrip().startswith(("{", "[")):
                                break
                        except Exception:
                            text = None
                    if text is None:
                        resp = {
                            "signal": "HOLD",
                            "confidence": 0.0,
                            "sl_points": 0,
                            "tp_points": 0,
                            "reason": "decode_error",
                        }
                    else:
                        try:
                            packet = json.loads(text)
                        except Exception:
                            resp = {
                                "signal": "HOLD",
                                "confidence": 0.0,
                                "sl_points": 0,
                                "tp_points": 0,
                                "reason": "json_decode_error",
                            }
                        else:
                            resp = _handle_packet(
                                packet, cfg=cfg, model=model, aggressive=aggressive, logs=logs, transport="file"
                            )
                    resp_path.write_text(json.dumps(resp, ensure_ascii=False), encoding="utf-8")
                    stamp_path.write_text(str(time.time()), encoding="utf-8")

            # Optional: MT5 closed-trade event ingestion (one-shot file)
            if trade_event_path.exists():
                tm = trade_event_path.stat().st_mtime
                if tm > last_trade_mtime:
                    last_trade_mtime = tm
                    raw_bytes = trade_event_path.read_bytes()
                    text: Optional[str] = None
                    for enc in ("utf-8-sig", "utf-16", "utf-16le", "utf-16be", "cp1252"):
                        try:
                            text = raw_bytes.decode(enc)
                            if text.lstrip().startswith(("{", "[")):
                                break
                        except Exception:
                            text = None
                    if text is not None:
                        try:
                            ev = json.loads(text)
                        except Exception:
                            ev = None
                        if isinstance(ev, dict):
                            log_trade_event(
                                logs,
                                time=str(ev.get("time", "")),
                                symbol=str(ev.get("symbol", "")),
                                event=str(ev.get("event", "CLOSE")),
                                magic=int(ev.get("magic")) if ev.get("magic") is not None else None,
                                ticket=int(ev.get("ticket")) if ev.get("ticket") is not None else None,
                                side=str(ev.get("side", "")) if ev.get("side") is not None else None,
                                volume=float(ev.get("volume")) if ev.get("volume") is not None else None,
                                price=float(ev.get("price")) if ev.get("price") is not None else None,
                                sl=float(ev.get("sl")) if ev.get("sl") is not None else None,
                                tp=float(ev.get("tp")) if ev.get("tp") is not None else None,
                                profit=float(ev.get("profit")) if ev.get("profit") is not None else None,
                                reason=str(ev.get("reason", "")),
                                extra=ev.get("extra", {}) if isinstance(ev.get("extra"), dict) else {},
                            )
                    # Rename so it won't be re-processed (best effort).
                    try:
                        suffix = str(int(time.time()))
                        trade_event_path.rename(d / f"trade_event.processed_{suffix}.json")
                    except Exception:
                        pass
        except Exception:
            # Keep running even on filesystem errors.
            pass

        time.sleep(cfg.file_poll_interval_s)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="GoldScalper AI Bridge server (ZeroMQ REP + fallbacks)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5555, help="ZeroMQ port (REP)")
    p.add_argument("--tcp-port", type=int, default=5556, help="TCP fallback port (JSON line protocol)")
    p.add_argument("--no-tcp", action="store_true", help="Disable TCP fallback server")
    p.add_argument("--data-dir", default=None, help="Directory for CSV logs (default: ../data)")
    p.add_argument("--models-dir", default=None, help="Directory containing model.pkl (default: ./models)")
    p.add_argument(
        "--no-aggressive-model",
        action="store_true",
        help="Do not load models/model_aggressive.pkl even if present (aggressive P(profit>0) overlay).",
    )
    p.add_argument(
        "--min-agg-pwin",
        type=float,
        default=0.0,
        help=(
            "If >0 and the aggressive model supplied agg_pwin for a BUY/SELL, force HOLD when "
            "agg_pwin is below this threshold (applied before the general confidence filter)."
        ),
    )
    p.add_argument("--file-bridge", action="store_true", help="Enable file-bridge responder")
    p.add_argument("--file-bridge-dir", default=None, help="Directory containing request.json/response.json")
    p.add_argument(
        "--import-aggressive-trade-csv",
        default=None,
        help=(
            "Optional: absolute path to MT5 trades_aggressive_v3.csv to ingest into data/trades.csv. "
            "Tip: copy the path printed by the EA in MT5 Experts."
        ),
    )
    p.add_argument(
        "--mt5-live",
        action="store_true",
        help="Python-driven MT5 execution loop (technical analysis + order_send); terminal is gateway only.",
    )
    p.add_argument("--mt5-symbol", default="XAUUSD", help="Symbol exactly as in Market Watch")
    p.add_argument("--mt5-poll-interval", type=float, default=5.0, help="Seconds between polling iterations")
    p.add_argument("--mt5-volume", type=float, default=0.01, help="Lots per executed signal")
    p.add_argument("--mt5-magic", type=int, default=770050, help="Magic number on bot orders")
    p.add_argument("--mt5-deviation", type=int, default=40, help="Max price slippage/deviation (points)")
    p.add_argument("--mt5-max-positions", type=int, default=1, help="Max concurrent positions (this magic + symbol)")
    p.add_argument("--mt5-login", default=None, help="Account login (optional if terminal already logged in)")
    p.add_argument("--mt5-password", default=None, help="Password (prefer env MT5_PASSWORD)")
    p.add_argument("--mt5-server", default=None, help="Broker server (env MT5_SERVER)")
    p.add_argument(
        "--mt5-path",
        default=None,
        help="Path to MetaTrader 5 terminal executable (optional)",
    )
    return p.parse_args()


def _tail_csv_rows_incremental(
    path: Path,
    *,
    state: Dict[str, Any],
    logger: logging.Logger,
) -> list[dict[str, str]]:
    """
    Incrementally reads new CSV rows as the file grows.
    Keeps state in `state` dict: {inode, offset}.
    If the file is rotated/truncated, resets.
    """
    if not path.exists() or path.stat().st_size <= 0:
        return []

    try:
        st = path.stat()
        inode = getattr(st, "st_ino", None)
        size = st.st_size
    except Exception as e:
        logger.debug("importer: stat failed for %s (%s)", str(path), e)
        return []

    prev_inode = state.get("inode")
    prev_offset = int(state.get("offset", 0) or 0)
    if prev_inode is None:
        prev_inode = inode
    # reset on rotate or truncate
    if inode != prev_inode or prev_offset > size:
        prev_offset = 0

    rows: list[dict[str, str]] = []

    def _detect_encoding(sample: bytes) -> str:
        # BOM-based detection first
        if sample.startswith(b"\xff\xfe"):
            return "utf-16-le"
        if sample.startswith(b"\xfe\xff"):
            return "utf-16-be"
        if sample.startswith(b"\xef\xbb\xbf"):
            return "utf-8-sig"
        # Heuristic: MT5 on Windows/Wine often writes UTF-16LE without BOM.
        if sample.count(b"\x00") > max(8, len(sample) // 10):
            return "utf-16-le"
        return "utf-8"

    try:
        # Read as bytes so we can handle UTF-16 (null bytes) reliably.
        with path.open("rb") as f:
            if prev_offset > 0:
                f.seek(prev_offset)
            else:
                # Establish encoding on first read.
                sample = f.read(4096)
                enc = _detect_encoding(sample)
                state["encoding"] = enc
                # Reset to start for full parse.
                f.seek(0)

            enc = str(state.get("encoding") or "utf-8")
            carry: bytes = state.get("carry", b"") or b""
            data = carry + f.read()
            state["offset"] = f.tell()
            state["inode"] = inode

        # For UTF-16, ensure we don't cut a code unit in half.
        if enc.startswith("utf-16") and (len(data) % 2 == 1):
            state["carry"] = data[-1:]
            data = data[:-1]
        else:
            state["carry"] = b""

        text = data.decode(enc, errors="replace")
        lines = [ln.strip("\r\n") for ln in text.splitlines() if ln.strip("\r\n")]

        # If starting from 0, skip header only if it looks like one.
        if prev_offset == 0 and lines:
            if lines[0].lower().startswith("time,"):
                lines = lines[1:]

        import csv as _csv  # local import to avoid polluting module namespace

        for line in lines:
            try:
                parts = next(_csv.reader([line]))
            except Exception:
                continue
            if len(parts) < 10:
                continue
            rows.append(
                {
                    "time": parts[0],
                    "symbol": parts[1],
                    "event": parts[2],
                    "side": parts[3],
                    "volume": parts[4],
                    "price": parts[5],
                    "sl": parts[6],
                    "tp": parts[7],
                    "profit": parts[8],
                    "reason": parts[9],
                }
            )
    except Exception as e:
        logger.warning("importer: failed reading %s (%s)", str(path), e)
        return []

    return rows


def _resolve_aggressive_csv_source(src: Path) -> Path:
    """
    Accept either a directory, a correct file path, or the common mistake:
    passing Common/Files/GoldScalper_AI_Bridge/trades_aggressive_v3.csv when
    the file actually lives at Common/Files/trades_aggressive_v3.csv.
    """
    if src.exists() and src.is_dir():
        return src / "trades_aggressive_v3.csv"

    # If it doesn't exist, try to recover from the common mistake.
    if not src.exists() and src.name == "trades_aggressive_v3.csv" and src.parent.name == "GoldScalper_AI_Bridge":
        candidate = src.parent.parent / src.name
        return candidate

    return src


def _read_csv_rows_all(path: Path, *, state: Dict[str, Any], logger: logging.Logger) -> list[dict[str, str]]:
    """
    Full-file read (robust). Used for MT5/Wine logs that may be UTF-16 and/or
    tricky to tail reliably.
    """
    if not path.exists() or path.stat().st_size <= 0:
        return []

    def _detect_encoding(sample: bytes) -> str:
        if sample.startswith(b"\xff\xfe"):
            return "utf-16-le"
        if sample.startswith(b"\xfe\xff"):
            return "utf-16-be"
        if sample.startswith(b"\xef\xbb\xbf"):
            return "utf-8-sig"
        if sample.count(b"\x00") > max(8, len(sample) // 10):
            return "utf-16-le"
        return "utf-8"

    try:
        data = path.read_bytes()
    except Exception as e:
        logger.warning("importer: failed reading %s (%s)", str(path), e)
        return []

    enc = state.get("encoding")
    if not enc:
        enc = _detect_encoding(data[:4096])
        state["encoding"] = enc

    # For UTF-16, ensure even length.
    if str(enc).startswith("utf-16") and (len(data) % 2 == 1):
        data = data[:-1]

    text = data.decode(str(enc), errors="replace")
    lines = [ln.strip("\r\n") for ln in text.splitlines() if ln.strip("\r\n")]

    # Skip header only if it looks like one.
    if lines and lines[0].lower().startswith("time,"):
        lines = lines[1:]

    import csv as _csv

    out: list[dict[str, str]] = []
    for line in lines:
        try:
            parts = next(_csv.reader([line]))
        except Exception:
            continue
        if len(parts) < 10:
            continue
        out.append(
            {
                "time": parts[0].lstrip("\ufeff"),
                "symbol": parts[1],
                "event": parts[2],
                "side": parts[3],
                "volume": parts[4],
                "price": parts[5],
                "sl": parts[6],
                "tp": parts[7],
                "profit": parts[8],
                "reason": parts[9],
            }
        )
    return out


def run_aggressive_trade_importer(csv_path: Path, out_logs: LogPaths) -> None:
    log = logging.getLogger("gold_scalper.importer")
    state: Dict[str, Any] = {}
    # Force-create the destination CSV so it appears immediately.
    log_trade_event(
        out_logs,
        time=_now_iso(),
        symbol="",
        event="INIT",
        magic=20260501,
        ticket=None,
        side="",
        volume=None,
        price=None,
        sl=None,
        tp=None,
        profit=None,
        reason="aggressive_importer_started",
        extra={"source": "aggressive_v3"},
    )

    log.info("Aggressive trade importer enabled (source): %s", str(csv_path))
    seen: set[str] = set()
    while True:
        try:
            # Robust mode: read whole file and append only unseen events.
            rows = _read_csv_rows_all(csv_path, state=state, logger=log)
            appended = 0
            for r in rows:
                key = "|".join(
                    [
                        (r.get("time") or "").strip(),
                        (r.get("symbol") or "").strip(),
                        (r.get("event") or "").strip(),
                        (r.get("side") or "").strip(),
                        (r.get("volume") or "").strip(),
                        (r.get("price") or "").strip(),
                    ]
                )
                if not key or key in seen:
                    continue
                seen.add(key)
                log_trade_event(
                    out_logs,
                    time=r.get("time", ""),
                    symbol=r.get("symbol", ""),
                    event=r.get("event", ""),
                    magic=20260501,
                    ticket=None,
                    side=r.get("side", ""),
                    volume=float(r["volume"]) if r.get("volume") not in (None, "", "nan") else None,
                    price=float(r["price"]) if r.get("price") not in (None, "", "nan") else None,
                    sl=float(r["sl"]) if r.get("sl") not in (None, "", "nan") else None,
                    tp=float(r["tp"]) if r.get("tp") not in (None, "", "nan") else None,
                    profit=float(r["profit"]) if r.get("profit") not in (None, "", "nan") else None,
                    reason=(r.get("reason") or "").strip(),
                    extra={"source": "aggressive_v3", "raw_event": r.get("event", "")},
                )
                appended += 1
            if appended:
                log.info("Aggressive importer appended %d new rows", appended)
        except Exception as e:
            log.warning("Aggressive importer loop error: %s", e)
        time.sleep(1.0)


def run_aggressive_ml_importer(src: Path, dst_csv: Path) -> None:
    """
    Copy/append ML-ready rows produced by the EA (trades_aggressive_v3_ml.csv) into repo data folder.
    This is a simple, deduped sync for training.
    """
    log = logging.getLogger("gold_scalper.importer_ml")
    state: dict[str, Any] = {}
    seen: set[str] = set()
    log.info("Aggressive ML importer enabled (source): %s", str(src))
    dst_csv.parent.mkdir(parents=True, exist_ok=True)

    header = "time,symbol,event,position_id,deal_id,side,volume,price,sl,tp,ema9,ema21,rsi,spread_pts,profit,reason\n"
    if not dst_csv.exists() or dst_csv.stat().st_size <= 0:
        dst_csv.write_text(header, encoding="utf-8")

    while True:
        try:
            rows = _read_csv_rows_all(src, state=state, logger=log)
            appended = 0
            with dst_csv.open("a", encoding="utf-8", newline="") as f:
                for r in rows:
                    # this reader expects the old 10-col format; if it doesn't match, skip.
                    # We'll parse ML file separately as raw lines below if needed.
                    pass
            # If we got here, it means src is not in the old format; fall back to raw text copy with dedupe.
            raw = src.read_bytes()
            enc = state.get("encoding") or ("utf-16-le" if raw.count(b"\x00") > max(8, len(raw) // 10) else "utf-8")
            state["encoding"] = enc
            if str(enc).startswith("utf-16") and (len(raw) % 2 == 1):
                raw = raw[:-1]
            text = raw.decode(str(enc), errors="replace")
            lines = [ln.strip("\r\n") for ln in text.splitlines() if ln.strip("\r\n")]
            if lines and lines[0].lower().startswith("time,"):
                lines = lines[1:]
            with dst_csv.open("a", encoding="utf-8", newline="") as f:
                for line in lines:
                    line = line.lstrip("\ufeff")
                    key = line
                    if not key or key in seen:
                        continue
                    seen.add(key)
                    f.write(line + "\n")
                    appended += 1
            if appended:
                log.info("Aggressive ML importer appended %d new rows", appended)
        except Exception as e:
            log.warning("Aggressive ML importer loop error: %s", e)
        time.sleep(1.0)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    log = logging.getLogger("gold_scalper")

    def _shutdown(sig, frame):
        log.info("Shutting down (signal=%s)...", sig)
        raise SystemExit(0)

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    args = parse_args()
    cfg = ServerConfig(
        host=args.host,
        zmq_port=args.port,
        tcp_port=args.tcp_port,
        enable_tcp_fallback=not args.no_tcp,
        enable_file_bridge=bool(args.file_bridge),
    )
    if args.data_dir:
        cfg.data_dir = Path(args.data_dir).expanduser().resolve()
    if args.models_dir:
        cfg.models_dir = Path(args.models_dir).expanduser().resolve()
    if cfg.enable_file_bridge:
        cfg.file_bridge_dir = Path(args.file_bridge_dir).expanduser().resolve() if args.file_bridge_dir else None
        if cfg.file_bridge_dir is None:
            # Default to project-local bridge directory for convenience.
            cfg.file_bridge_dir = cfg.data_dir / "bridge"

    cfg.min_agg_pwin = max(0.0, min(1.0, float(args.min_agg_pwin or 0.0)))
    if cfg.min_agg_pwin > 0.0:
        log.info("Aggressive hard filter enabled: min_agg_pwin=%.4f", cfg.min_agg_pwin)

    logs = LogPaths(cfg.data_dir)
    aggressive_logs = LogPaths(cfg.data_dir / "aggressive_scalping")
    model = AiModel(cfg.models_dir)
    loaded = model.load_if_available()
    if loaded:
        log.info("Loaded model from %s", str(model.model_path))
    else:
        log.info("No model found at %s (using dummy rule logic)", str(model.model_path))

    aggressive_model: Optional[AggressiveAiModel] = None
    aggressive_path = cfg.models_dir / "model_aggressive.pkl"
    if not args.no_aggressive_model:
        am = AggressiveAiModel(aggressive_path)
        if am.load_if_available():
            aggressive_model = am
            log.info("Loaded aggressive scalping model from %s", str(aggressive_path))
        else:
            log.info("No aggressive model at %s (skip agg overlay)", str(aggressive_path))

    log.info("Logging CSVs to: %s", str(cfg.data_dir))
    log.info(" - %s", str(logs.live_features_csv))
    log.info(" - %s", str(logs.signals_csv))
    log.info(" - %s", str(logs.trades_csv))

    if args.mt5_live:
        from mt5_live import run_mt5_live_main

        log.info("Starting MT5 live mode (--mt5-live); ZMQ/TCP bridge servers are disabled.")
        run_mt5_live_main(args, cfg, model, aggressive_model)
        return

    threads: list[threading.Thread] = []
    if cfg.enable_tcp_fallback:
        t = threading.Thread(target=run_tcp_fallback, args=(cfg, model, aggressive_model, logs), daemon=True)
        t.start()
        threads.append(t)

    if cfg.enable_file_bridge:
        t = threading.Thread(target=run_file_bridge, args=(cfg, model, aggressive_model, logs), daemon=True)
        t.start()
        threads.append(t)

    if args.import_aggressive_trade_csv:
        src = _resolve_aggressive_csv_source(Path(args.import_aggressive_trade_csv).expanduser().resolve())
        log.info("Aggressive scalping CSVs will be written to: %s", str(aggressive_logs.data_dir))
        log.info(" - %s", str(aggressive_logs.trades_csv))
        if not src.exists():
            log.warning("Aggressive trade CSV source not found: %s", str(src))
        t = threading.Thread(target=run_aggressive_trade_importer, args=(src, aggressive_logs), daemon=True)
        t.start()
        threads.append(t)

        # Also import ML-ready file if it exists (or if the user passed the Common Files directory).
        ml_src = src.parent / "trades_aggressive_v3_ml.csv"
        ml_dst = aggressive_logs.data_dir / "trades_ml.csv"
        t = threading.Thread(target=run_aggressive_ml_importer, args=(ml_src, ml_dst), daemon=True)
        t.start()
        threads.append(t)

    # Run ZMQ on main thread.
    run_zmq_rep(cfg, model, aggressive_model, logs)


if __name__ == "__main__":
    main()

