# GoldScalper_AI_Bridge (MT5 + Python ZeroMQ AI bridge)

This project connects a **MetaTrader 5 Expert Advisor (MQL5)** to a **local Python AI server**.

- The MT5 EA collects live features on each **new M1 candle** and requests a signal.
- The Python server responds with **BUY / SELL / HOLD**, **confidence**, **SL points**, **TP points**, and a **reason**.
- **All risk protection and order sizing are enforced on the MT5 side**. Python never decides lot size.

## What you get

- **MT5 EA**: `mt5/GoldScalper_AI_Bridge.mq5`
  - Feature collection (M1 + M5 indicators + last 20 M1 candles)
  - ZeroMQ-first design with **safe fallbacks**:
    - **TCP JSON** fallback (recommended if you don’t want DLLs)
    - **File bridge** fallback (works even without sockets)
  - Strict risk filters: daily loss cap, spread cap, max trades/day, max open trades, margin checks
  - Trade management: break-even @ 0.7R, trailing after 1R, stale close after 20 minutes if not profitable
  - CSV logging + on-chart dashboard
- **Python server**: `python/ai_server.py`
  - ZeroMQ REP server on `127.0.0.1:5555`
  - Optional TCP JSON line server on `127.0.0.1:5556` (for MT5 socket fallback)
  - Optional file bridge responder (polls request file, writes response file)
  - Dummy rule-based AI logic included (works immediately)
  - Optional model loading from `python/models/model.pkl`

## Safety / important notes

- This is for **demo/backtesting first**. There are **no profit guarantees**.
- **Enable live trading only after you validate behavior in Strategy Tester + demo**.
- No martingale, no grid, no stacking beyond configured limits.
- If the Python side is unreachable or times out, the EA defaults to **HOLD** and continues safely.

## Quick start

### 1) Python

```bash
cd GoldScalper_AI_Bridge/python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 ai_server.py
```

By default this starts:
- ZeroMQ REP: `127.0.0.1:5555`
- TCP fallback: `127.0.0.1:5556`
- Logs to `../data/*.csv`

### 2) MT5 EA

1. Open MetaEditor (MT5) → **File → Open Data Folder**.
2. Copy `mt5/GoldScalper_AI_Bridge.mq5` into:
   - `MQL5/Experts/`
3. Compile in MetaEditor.
4. Attach to **XAUUSD** (or broker variants like **GOLD**, **XAUUSDm**) on **M1**.
5. Keep `InpAllowLiveTrading = false` for testing.

### Connection modes

- **Recommended (no DLLs)**: keep `InpUseFileFallback = false` (use sockets) and run python TCP fallback on port **5556**.
  - The EA will connect to `InpPythonHost` at `InpPythonPort + 1` for TCP fallback.
- **Most compatible**: set `InpUseFileFallback = true` (default).
  - The EA writes feature requests and reads responses using MT5 **Common Files**.
  - In MT5, the EA prints the resolved bridge folder in the Experts log.
  - Run Python with `--file-bridge-dir` pointing to that folder (see `python/README.md`).

## Training a simple model (optional)

```bash
cd GoldScalper_AI_Bridge/python
source .venv/bin/activate
python3 model_train.py
```

If a model is saved to `python/models/model.pkl`, the server will load it on startup and use it when available.

## Smoke test commands

```bash
pip install -r python/requirements.txt
python -m py_compile python/*.py
python python/ai_server.py --file-bridge --file-bridge-dir "<MT5_COMMON_FILES_BRIDGE_DIR>"
```

## Verification (repo health)

From the repository root (`GoldScalper_AI_Bridge/`):

```bash
wc -l mt5/GoldScalper_Aggressive_v3.mq5
wc -l mt5/GoldScalper_AI_Bridge.mq5
python3 -m py_compile python/*.py
pip install -r python/requirements.txt
```

Expect many lines per MQL5 file (not a single minified line). `py_compile` must exit with status 0.

  