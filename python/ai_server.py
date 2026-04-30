from __future__ import annotations

import argparse
import json
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import joblib
import numpy as np
import zmq

from features import flatten_feature_packet, packet_to_dataframe_row, select_model_features
from trade_logger import LogPaths, log_feature_packet, log_signal


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

    def predict(self, packet: Dict[str, Any]) -> Optional[Tuple[str, float]]:
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

        X = X.fillna(method="ffill", axis=1).fillna(0.0)

        if hasattr(self.model, "predict_proba"):
            proba = self.model.predict_proba(X)[0]
            classes = list(getattr(self.model, "classes_", []))
            if not classes:
                pred = self.model.predict(X)[0]
                return str(pred), 0.55
            best_idx = int(np.argmax(proba))
            pred = str(classes[best_idx])
            conf = float(proba[best_idx])
            return pred, conf

        pred = self.model.predict(X)[0]
        return str(pred), 0.55


def dummy_rule_ai(packet: Dict[str, Any]) -> Dict[str, Any]:
    f = packet.get("features", {}) or {}

    m1_ema9 = _safe_float(f, "m1_ema9")
    m1_ema21 = _safe_float(f, "m1_ema21")
    m5_ema20 = _safe_float(f, "m5_ema20")
    m5_ema50 = _safe_float(f, "m5_ema50")
    rsi = _safe_float(f, "m1_rsi14")
    adx = _safe_float(f, "m1_adx14")
    spread_pts = float(_safe_int(f, "spread_points"))

    is_buy = (m1_ema9 > m1_ema21) and (m5_ema20 > m5_ema50) and (45.0 <= rsi <= 68.0) and (adx > 12.0)
    is_sell = (m1_ema9 < m1_ema21) and (m5_ema20 < m5_ema50) and (32.0 <= rsi <= 55.0) and (adx > 12.0)

    signal = "HOLD"
    if is_buy and not is_sell:
        signal = "BUY"
    elif is_sell and not is_buy:
        signal = "SELL"

    # Confidence decomposition (0..1)
    trend_align = 0.0
    if signal == "BUY":
        trend_align = float((m1_ema9 - m1_ema21) > 0) * 0.5 + float((m5_ema20 - m5_ema50) > 0) * 0.5
    elif signal == "SELL":
        trend_align = float((m1_ema9 - m1_ema21) < 0) * 0.5 + float((m5_ema20 - m5_ema50) < 0) * 0.5

    adx_strength = _clamp((adx - 12.0) / 25.0, 0.0, 1.0)  # stronger above 12

    if signal == "BUY":
        rsi_quality = 1.0 - _clamp(abs(rsi - 56.0) / 14.0, 0.0, 1.0)
    elif signal == "SELL":
        rsi_quality = 1.0 - _clamp(abs(rsi - 44.0) / 14.0, 0.0, 1.0)
    else:
        rsi_quality = 0.3

    # Spread penalty: ideal <= 25 pts; degrade after.
    spread_quality = 1.0 - _clamp((spread_pts - 25.0) / 60.0, 0.0, 1.0)

    base = 0.15
    conf = base + 0.35 * trend_align + 0.25 * adx_strength + 0.20 * rsi_quality + 0.05 * spread_quality
    if signal == "HOLD":
        conf = min(conf, 0.55)
    conf = float(_clamp(conf, 0.0, 1.0))

    # SL/TP points: conservative defaults for XAU scalping; EA will still validate stops/levels.
    # Use ATR if present to scale slightly.
    atr = _safe_float(f, "m1_atr14")
    point = 0.01  # unknown on python side; treat as points already from EA-indicator context
    atr_points_hint = 0.0
    if np.isfinite(atr) and atr > 0:
        atr_points_hint = atr / point

    sl_points = int(_clamp(120.0 + 0.10 * atr_points_hint, 80.0, 350.0))
    tp_points = int(_clamp(sl_points * 1.4, 100.0, 600.0))

    reason = f"dummy_rule_ai: {signal} (trend={trend_align:.2f}, adx={adx:.1f}, rsi={rsi:.1f}, spread={spread_pts:.0f})"
    return {
        "signal": signal,
        "confidence": conf,
        "sl_points": sl_points,
        "tp_points": tp_points,
        "reason": reason,
    }


def decide(packet: Dict[str, Any], model: AiModel) -> Dict[str, Any]:
    # Try model first (if loaded), else dummy rule AI.
    mp = model.predict(packet)
    if mp is None:
        return dummy_rule_ai(packet)

    pred, conf = mp
    pred = pred.upper().strip()
    if pred not in {"BUY", "SELL", "HOLD"}:
        pred = "HOLD"

    # Keep SL/TP from rule logic (safe defaults) while model provides direction/confidence.
    rule = dummy_rule_ai(packet)
    rule["signal"] = pred
    rule["confidence"] = float(_clamp(conf, 0.0, 1.0))
    rule["reason"] = f"model: {pred} (conf={rule['confidence']:.2f}) | {rule.get('reason','')}"
    if pred == "HOLD":
        rule["confidence"] = min(rule["confidence"], 0.55)
    return rule


def _handle_packet(
    packet: Dict[str, Any],
    *,
    model: AiModel,
    logs: LogPaths,
    transport: str,
) -> Dict[str, Any]:
    flattened = flatten_feature_packet(packet)
    log_feature_packet(logs, packet, flattened)

    if packet.get("type") != "features":
        resp = {"signal": "HOLD", "confidence": 0.0, "sl_points": 0, "tp_points": 0, "reason": "invalid_packet_type"}
        log_signal(logs, packet, resp, transport=transport)
        return resp

    resp = decide(packet, model)
    # Safety: clamp and sanitize output
    resp = {
        "signal": (resp.get("signal", "HOLD") or "HOLD").upper(),
        "confidence": float(_clamp(float(resp.get("confidence", 0.0) or 0.0), 0.0, 1.0)),
        "sl_points": int(max(0, int(resp.get("sl_points", 0) or 0))),
        "tp_points": int(max(0, int(resp.get("tp_points", 0) or 0))),
        "reason": str(resp.get("reason", "") or ""),
    }
    if resp["signal"] not in {"BUY", "SELL", "HOLD"}:
        resp["signal"] = "HOLD"
    log_signal(logs, packet, resp, transport=transport)
    return resp


def run_zmq_rep(cfg: ServerConfig, model: AiModel, logs: LogPaths) -> None:
    ctx = zmq.Context.instance()
    sock = ctx.socket(zmq.REP)
    sock.setsockopt(zmq.LINGER, 0)
    endpoint = f"tcp://{cfg.host}:{cfg.zmq_port}"
    sock.bind(endpoint)
    print(f"[{_now_iso()}] ZeroMQ REP listening on {endpoint}")

    while True:
        raw = sock.recv()
        try:
            packet = json.loads(raw.decode("utf-8", errors="replace"))
        except Exception:
            resp = {"signal": "HOLD", "confidence": 0.0, "sl_points": 0, "tp_points": 0, "reason": "json_decode_error"}
            sock.send_string(json.dumps(resp))
            continue

        resp = _handle_packet(packet, model=model, logs=logs, transport="zmq")
        sock.send_string(json.dumps(resp, ensure_ascii=False))


def _tcp_client_handler(conn: socket.socket, addr: Tuple[str, int], cfg: ServerConfig, model: AiModel, logs: LogPaths) -> None:
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

                resp = _handle_packet(packet, model=model, logs=logs, transport="tcp")
                conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
    except Exception:
        return
    finally:
        try:
            conn.close()
        except Exception:
            pass


def run_tcp_fallback(cfg: ServerConfig, model: AiModel, logs: LogPaths) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((cfg.host, cfg.tcp_port))
    srv.listen(32)
    print(f"[{_now_iso()}] TCP fallback listening on {cfg.host}:{cfg.tcp_port} (JSON line protocol)")

    while True:
        conn, addr = srv.accept()
        th = threading.Thread(target=_tcp_client_handler, args=(conn, addr, cfg, model, logs), daemon=True)
        th.start()


def run_file_bridge(cfg: ServerConfig, model: AiModel, logs: LogPaths) -> None:
    assert cfg.file_bridge_dir is not None
    d = cfg.file_bridge_dir
    d.mkdir(parents=True, exist_ok=True)
    req_path = d / "request.json"
    resp_path = d / "response.json"
    stamp_path = d / "response.stamp"
    print(f"[{_now_iso()}] File bridge enabled at {str(d)}")
    print(f"[{_now_iso()}] Waiting for {str(req_path)}")

    last_seen_mtime = 0.0
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
                            resp = _handle_packet(packet, model=model, logs=logs, transport="file")
                    resp_path.write_text(json.dumps(resp, ensure_ascii=False), encoding="utf-8")
                    stamp_path.write_text(str(time.time()), encoding="utf-8")
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
    p.add_argument("--file-bridge", action="store_true", help="Enable file-bridge responder")
    p.add_argument("--file-bridge-dir", default=None, help="Directory containing request.json/response.json")
    return p.parse_args()


def main() -> None:
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

    logs = LogPaths(cfg.data_dir)
    model = AiModel(cfg.models_dir)
    loaded = model.load_if_available()
    if loaded:
        print(f"[{_now_iso()}] Loaded model from {str(model.model_path)}")
    else:
        print(f"[{_now_iso()}] No model found at {str(model.model_path)} (using dummy rule logic)")

    print(f"[{_now_iso()}] Logging CSVs to: {str(cfg.data_dir)}")
    print(f"[{_now_iso()}]  - {str(logs.live_features_csv)}")
    print(f"[{_now_iso()}]  - {str(logs.signals_csv)}")
    print(f"[{_now_iso()}]  - {str(logs.trades_csv)}")

    threads: list[threading.Thread] = []
    if cfg.enable_tcp_fallback:
        t = threading.Thread(target=run_tcp_fallback, args=(cfg, model, logs), daemon=True)
        t.start()
        threads.append(t)

    if cfg.enable_file_bridge:
        t = threading.Thread(target=run_file_bridge, args=(cfg, model, logs), daemon=True)
        t.start()
        threads.append(t)

    # Run ZMQ on main thread.
    run_zmq_rep(cfg, model, logs)


if __name__ == "__main__":
    main()

