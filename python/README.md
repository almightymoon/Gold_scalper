# Python AI server (GoldScalper_AI_Bridge)

This folder contains the Python side of the bridge:

- `ai_server.py`: ZeroMQ REP server (main) + optional TCP/file fallbacks
- `features.py`: helpers to flatten incoming JSON packets into a DataFrame row
- `trade_logger.py`: CSV appenders for features/signals/trades
- `model_train.py`: offline trainer that can create `models/model.pkl`

## Install

```bash
cd GoldScalper_AI_Bridge/python
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run the server (recommended)

```bash
source .venv/bin/activate
python3 ai_server.py
```

Defaults:
- ZeroMQ REP: `tcp://127.0.0.1:5555`
- TCP JSON line fallback: `127.0.0.1:5556`
- CSV logs: `../data/live_features.csv`, `../data/signals.csv`, `../data/trades.csv`

## File-bridge mode (works without sockets)

The MT5 EA can write a request JSON file and read a response JSON file from **MT5 Common Files**.

1) In MT5, attach the EA with:
- `InpUseFileFallback = true`

2) Watch the MT5 Experts log for a line like:
- `Bridge dir (COMMON): .../GoldScalper_AI_Bridge`

3) Start python with that directory:

```bash
python3 ai_server.py --file-bridge --file-bridge-dir "/Users/moon/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files/GoldScalper_AI_Bridge"


 python3 ai_server.py --import-aggressive-trade-csv "/Users/moon/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files/GoldScalper_AI_Bridge"

```

Files used:
- Request: `request.json`
- Response: `response.json`

If the response is missing or stale, the EA defaults to **HOLD**.

## Notes

- Python returns **signal, confidence, SL points, TP points, reason** only.
- **Lot sizing and risk constraints stay in MT5**.
- This is intended for **demo/backtesting first**.

