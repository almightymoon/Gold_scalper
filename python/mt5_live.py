"""
Live XAUUSD scalping via MetaTrader5 Python API (no CSV bridge for signals/execution).

Imports `decide()` / models from `ai_server` so strategy logic stays centralized.

MetaTrader5 is imported lazily so `import ai_server` works without the wheel installed.
"""

from __future__ import annotations

import importlib
import logging
import os
import time
from argparse import Namespace
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np

from ai_server import AggressiveAiModel, AiModel, ServerConfig, decide
from mt5_indicators import m1_indicator_row, m5_indicator_row, ohlcv_rows_tail


log = logging.getLogger("gold_scalper.mt5_live")

_MT5: Any = None


def _mt5():
    """Late-bind MetaTrader5 so bridge-only installs skip this dependency."""
    global _MT5
    if _MT5 is None:
        try:
            _MT5 = importlib.import_module("MetaTrader5")
        except ImportError as e:
            raise ImportError(
                "The 'MetaTrader5' package is required for --mt5-live. "
                "Install with: pip install MetaTrader5"
            ) from e
    return _MT5


@dataclass
class Mt5LiveSettings:
    symbol: str
    poll_interval_s: float
    volume: float
    magic: int
    deviation: int
    max_positions: int
    login: Optional[int]
    password: Optional[str]
    server: Optional[str]
    terminal_path: Optional[str]


def init_mt5_with_retry(
    *,
    login: Optional[int],
    password: Optional[str],
    server: Optional[str],
    terminal_path: Optional[str],
    attempts: int = 12,
    delay_s: float = 5.0,
) -> bool:
    """Initialize terminal connection with retries (handles slow MT5 startup)."""
    mt5 = _mt5()
    for i in range(attempts):
        kwargs: dict[str, Any] = {}
        if terminal_path:
            kwargs["path"] = terminal_path
        ok = mt5.initialize(**kwargs)
        if not ok:
            err = mt5.last_error()
            log.warning("MT5 initialize failed (attempt %d/%d): %s", i + 1, attempts, err)
            time.sleep(delay_s)
            continue
        if login is not None and password and server:
            authorized = mt5.login(login, password=password, server=server)
            if not authorized:
                log.error("MT5 login failed: %s", mt5.last_error())
                mt5.shutdown()
                time.sleep(delay_s)
                continue
        elif any(x is not None for x in (login, password, server)):
            log.warning("Incomplete login triplet; continuing with already-logged-in terminal session.")
        ti = mt5.terminal_info()
        ai = mt5.account_info()
        log.info(
            "MT5 connected: terminal=%s account=%s balance=%s",
            getattr(ti, "company", "?") if ti else "?",
            getattr(ai, "login", "?") if ai else "?",
            getattr(ai, "balance", "?") if ai else "?",
        )
        return True
    return False


def shutdown_mt5() -> None:
    _mt5().shutdown()


def rates_to_dataframe(rates: Optional[np.ndarray]) -> Any:
    import pandas as pd

    if rates is None or len(rates) == 0:
        return pd.DataFrame()
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    return df


def fetch_market_ohlc(symbol: str, bars_m1: int = 600, bars_m5: int = 400) -> tuple[Any, Any]:
    """Pull recent closed bars from MT5 (M1/M5)."""
    mt5 = _mt5()
    r1 = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M1, 0, bars_m1)
    r5 = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M5, 0, bars_m5)
    return rates_to_dataframe(r1), rates_to_dataframe(r5)


def _spread_points(symbol: str, bid: float, ask: float) -> int:
    mt5 = _mt5()
    si = mt5.symbol_info(symbol)
    if si is None:
        return 0
    pt = float(si.point or 0.0)
    if pt <= 0 or not np.isfinite(bid) or not np.isfinite(ask):
        return int(si.spread) if si.spread else 0
    return int(max(0, round((ask - bid) / pt)))


def count_positions_for_magic(symbol: str, magic: int) -> int:
    mt5 = _mt5()
    pos = mt5.positions_get(symbol=symbol)
    if pos is None:
        return 0
    return sum(1 for p in pos if p.magic == magic)


def normalize_volume(symbol: str, volume: float) -> float:
    mt5 = _mt5()
    si = mt5.symbol_info(symbol)
    if si is None:
        return volume
    vol = float(volume)
    vol = max(float(si.volume_min), min(vol, float(si.volume_max)))
    step = float(si.volume_step)
    if step > 0:
        steps = round(vol / step)
        vol = steps * step
    return float(vol)


def resolve_order_filling(symbol: str) -> int:
    mt5 = _mt5()
    si = mt5.symbol_info(symbol)
    if si is None:
        return mt5.ORDER_FILLING_IOC
    fm = int(si.filling_mode)
    if fm & mt5.SYMBOL_FILLING_IOC:
        return mt5.ORDER_FILLING_IOC
    if fm & mt5.SYMBOL_FILLING_FOK:
        return mt5.ORDER_FILLING_FOK
    return mt5.ORDER_FILLING_RETURN


def build_live_feature_packet(
    symbol: str,
    df_m1: Any,
    df_m5: Any,
    *,
    magic: int,
    volume_lots: float,
) -> Dict[str, Any]:
    """Assemble the same nested `features` shape the EA used for `decide()`."""
    mt5 = _mt5()
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        raise RuntimeError(f"No tick for {symbol}: {mt5.last_error()}")

    ai = mt5.account_info()
    hour_gmt = time.gmtime().tm_hour

    bid = float(tick.bid)
    ask = float(tick.ask)
    spread_pts = _spread_points(symbol, bid, ask)

    if len(df_m1) < 80 or len(df_m5) < 80:
        raise RuntimeError(f"Insufficient bars (m1={len(df_m1)} m5={len(df_m5)}); wait for history sync.")

    m1_ind = m1_indicator_row(df_m1)
    m5_ind = m5_indicator_row(df_m5)
    ohlcv20 = ohlcv_rows_tail(df_m1, 20)

    feats: Dict[str, Any] = {
        "bid": bid,
        "ask": ask,
        "spread_points": spread_pts,
        "balance": float(ai.balance) if ai else float("nan"),
        "equity": float(ai.equity) if ai else float("nan"),
        "free_margin": float(ai.margin_free) if ai else float("nan"),
        "hour_gmt": hour_gmt,
        "open_ea_trades": count_positions_for_magic(symbol, magic),
        "trades_today": 0,
        "volume_lots": volume_lots,
        **m1_ind,
        **m5_ind,
        "m1_ohlcv": ohlcv20,
    }

    return {
        "type": "features",
        "symbol": symbol,
        "time": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()),
        "features": feats,
    }


def calculate_signals(
    packet: Dict[str, Any],
    model: AiModel,
    aggressive: Optional[AggressiveAiModel],
    *,
    min_agg_pwin: float,
) -> Dict[str, Any]:
    """Run centralized strategy + optional ML overlays (same path as the bridge server)."""
    return decide(packet, model, aggressive=aggressive, min_agg_pwin=min_agg_pwin)


def execute_trade(
    symbol: str,
    signal: str,
    sl_points: int,
    tp_points: int,
    *,
    volume: float,
    magic: int,
    deviation: int,
    comment: str = "py_scalper",
) -> bool:
    """
    Send market order with SL/TP in price space derived from point size.
    Returns True if order_send reports DONE.
    """
    mt5 = _mt5()
    signal_u = signal.upper()
    if signal_u not in {"BUY", "SELL"}:
        log.debug("execute_trade skipped non-actionable signal=%s", signal)
        return False

    if sl_points <= 0 or tp_points <= 0:
        log.warning("Refusing order: invalid SL/TP points sl=%s tp=%s", sl_points, tp_points)
        return False

    si = mt5.symbol_info(symbol)
    if si is None:
        log.error("symbol_info failed for %s: %s", symbol, mt5.last_error())
        return False
    if not si.visible:
        mt5.symbol_select(symbol, True)

    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        log.error("symbol_info_tick failed for %s: %s", symbol, mt5.last_error())
        return False

    point = float(si.point or 0.0)
    if point <= 0:
        log.error("Invalid point size for %s", symbol)
        return False

    digits = int(si.digits)
    vol = normalize_volume(symbol, volume)

    order_type = mt5.ORDER_TYPE_BUY if signal_u == "BUY" else mt5.ORDER_TYPE_SELL
    price = float(tick.ask) if signal_u == "BUY" else float(tick.bid)

    sl_dist = sl_points * point
    tp_dist = tp_points * point
    if signal_u == "BUY":
        sl = price - sl_dist
        tp = price + tp_dist
    else:
        sl = price + sl_dist
        tp = price - tp_dist

    sl = round(sl, digits)
    tp = round(tp, digits)

    filling = resolve_order_filling(symbol)

    req = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": vol,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": deviation,
        "magic": magic,
        "comment": comment[:31],
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": filling,
    }

    result = mt5.order_send(req)
    if result is None:
        log.error("order_send returned None: %s", mt5.last_error())
        return False

    if result.retcode != mt5.TRADE_RETCODE_DONE:
        comment_txt = getattr(result, "comment", "") or ""
        log.warning(
            "Order rejected: retcode=%s comment=%s filling=%s request=%s",
            result.retcode,
            comment_txt,
            filling,
            {k: v for k, v in req.items() if k != "comment"},
        )
        return False

    log.info(
        "Order OK: %s vol=%s price=%s sl=%s tp=%s deal=%s filling=%s",
        signal_u,
        vol,
        result.price,
        sl,
        tp,
        getattr(result, "deal", None),
        filling,
    )
    return True


def run_mt5_live_loop(cfg: ServerConfig, settings: Mt5LiveSettings, model: AiModel, aggressive: Optional[AggressiveAiModel]) -> None:
    _mt5()  # fail fast with clear ImportError
    login = settings.login
    password = settings.password or os.environ.get("MT5_PASSWORD")
    server = settings.server or os.environ.get("MT5_SERVER")
    env_login = os.environ.get("MT5_LOGIN")
    if login is None and env_login:
        try:
            login = int(env_login)
        except ValueError:
            pass

    if not init_mt5_with_retry(
        login=login,
        password=password,
        server=server,
        terminal_path=settings.terminal_path,
    ):
        log.error("Could not connect to MT5 after retries; exiting.")
        return

    mt5 = _mt5()
    symbol = settings.symbol
    if not mt5.symbol_select(symbol, True):
        log.error("symbol_select failed for %s", symbol)
        shutdown_mt5()
        return

    try:
        while True:
            try:
                if not mt5.terminal_info():
                    log.warning("Terminal closed or unreachable; reconnecting...")
                    shutdown_mt5()
                    time.sleep(2.0)
                    if not init_mt5_with_retry(
                        login=login,
                        password=password,
                        server=server,
                        terminal_path=settings.terminal_path,
                    ):
                        time.sleep(settings.poll_interval_s)
                        continue
                    mt5.symbol_select(symbol, True)

                df1, df5 = fetch_market_ohlc(symbol)
                packet = build_live_feature_packet(
                    symbol,
                    df1,
                    df5,
                    magic=settings.magic,
                    volume_lots=settings.volume,
                )
                sig = calculate_signals(packet, model, aggressive, min_agg_pwin=cfg.min_agg_pwin)

                direction = str(sig.get("signal", "HOLD")).upper()
                if direction in {"BUY", "SELL"}:
                    open_n = count_positions_for_magic(symbol, settings.magic)
                    if open_n >= settings.max_positions:
                        log.debug("Max positions reached (%d); skipping %s", settings.max_positions, direction)
                    else:
                        execute_trade(
                            symbol,
                            direction,
                            int(sig.get("sl_points") or 0),
                            int(sig.get("tp_points") or 0),
                            volume=settings.volume,
                            magic=settings.magic,
                            deviation=settings.deviation,
                            comment="py_scalper",
                        )

            except Exception as e:
                log.exception("Live loop iteration error: %s", e)

            time.sleep(settings.poll_interval_s)
    finally:
        shutdown_mt5()


def run_mt5_live_main(args: Namespace, cfg: ServerConfig, model: AiModel, aggressive: Optional[AggressiveAiModel]) -> None:
    login_i: Optional[int] = None
    if getattr(args, "mt5_login", None) is not None:
        try:
            login_i = int(args.mt5_login)
        except (TypeError, ValueError):
            log.warning("Ignoring invalid --mt5-login")

    tp = getattr(args, "mt5_path", None)
    term_path: Optional[str] = None
    if tp:
        term_path = str(Path(tp).expanduser().resolve()).strip() or None

    settings = Mt5LiveSettings(
        symbol=str(args.mt5_symbol),
        poll_interval_s=float(args.mt5_poll_interval),
        volume=float(args.mt5_volume),
        magic=int(args.mt5_magic),
        deviation=int(args.mt5_deviation),
        max_positions=int(args.mt5_max_positions),
        login=login_i,
        password=getattr(args, "mt5_password", None),
        server=getattr(args, "mt5_server", None),
        terminal_path=term_path,
    )

    log.info(
        "MT5 live executor: symbol=%s poll=%ss volume=%s magic=%s max_pos=%s",
        settings.symbol,
        settings.poll_interval_s,
        settings.volume,
        settings.magic,
        settings.max_positions,
    )
    run_mt5_live_loop(cfg, settings, model, aggressive)
