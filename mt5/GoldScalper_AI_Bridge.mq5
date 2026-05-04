//+------------------------------------------------------------------+
//| GoldScalper_AI_Bridge.mq5                                        |
//| MT5 <-> Python AI bridge (ZeroMQ design; TCP/file fallbacks)     |
//| Demo/backtest-first; MT5 enforces all risk protection            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.06"
#property description "GoldScalper AI Bridge: MT5 EA sends features to Python, receives BUY/SELL/HOLD with confidence/SL/TP."

#include <Trade\Trade.mqh>

// -------------------- Inputs --------------------
input long   InpMagicNumber            = 24043001;
input double InpRiskPercent            = 0.25;    // % of balance risked per trade (SL-based)
input double InpMaxDailyLossPercent    = 3.0;     // stop trading after hitting daily loss
input int    InpMaxOpenTrades          = 2;
input int    InpMaxTradesPerDay        = 10;
input double InpMinConfidence          = 0.70;
input int    InpMaxSpreadPoints        = 55;
input double InpMinBalanceUSD          = 10.0;
input bool   InpAllowLiveTrading       = false;
input string InpPythonHost             = "127.0.0.1";
input int    InpPythonPort             = 5555;    // ZMQ port on python (TCP fallback uses +1)
input bool   InpUseFileFallback        = true;    // safer default
input bool   InpAllowMinLotOverride    = true;    // allow min lot ONLY if risk at min lot is safe
input double InpMaxRiskAtMinLotPercent = 2.0;     // max % risk allowed if using SYMBOL_VOLUME_MIN

// -------------------- Globals --------------------
CTrade g_trade;
datetime g_last_m1_bar_time = 0;
string g_last_signal = "HOLD";
double g_last_confidence = 0.0;
string g_last_reason = "";
string g_conn_status = "DISCONNECTED";
datetime g_last_ai_time = 0;
bool g_kill_switch = false;
string g_last_request_id = "";
string g_last_ping = "N/A";
string g_last_day_key = "";
ulong  g_req_seq = 0;

// Indicator handles
int h_m1_ema9 = INVALID_HANDLE, h_m1_ema21 = INVALID_HANDLE, h_m1_ema50 = INVALID_HANDLE;
int h_m1_rsi14 = INVALID_HANDLE, h_m1_atr14 = INVALID_HANDLE, h_m1_adx14 = INVALID_HANDLE;
int h_m5_ema20 = INVALID_HANDLE, h_m5_ema50 = INVALID_HANDLE;
int h_m5_rsi14 = INVALID_HANDLE, h_m5_atr14 = INVALID_HANDLE, h_m5_adx14 = INVALID_HANDLE;

// File bridge locations (COMMON files)
string g_bridge_dir_common = "";
string g_req_file = "request.json";
string g_resp_file = "response.json";
string g_stamp_file = "response.stamp";
string g_trade_event_file = "trade_event.json";
bool   g_common_subdir_ok = false;

// CSV log files (COMMON)
string g_log_features_csv = "live_features_mt5.csv";
string g_log_signals_csv  = "signals_mt5.csv";
string g_log_trades_csv   = "trades_mt5.csv";

// -------------------- Utility --------------------
string TimeToISO(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d",
                       dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
}

string NewRequestId()
{
   // Unique enough for local bridge: GMT timestamp + seq
   g_req_seq++;
   return StringFormat("%s_%I64u", TimeToISO(TimeGMT()), (ulong)g_req_seq);
}

int HourGMT(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   return dt.hour;
}

string JsonEscape(const string s)
{
   string out = s;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   StringReplace(out, "\r", "\\r");
   StringReplace(out, "\n", "\\n");
   StringReplace(out, "\t", "\\t");
   return out;
}

bool SymbolLooksLikeGold(const string sym)
{
   string u = sym;
   StringToUpper(u);
   if(StringFind(u, "XAUUSD") >= 0) return true;
   if(StringFind(u, "GOLD") >= 0) return true;
   if(StringFind(u, "XAU") >= 0) return true;
   return false;
}

int VolumeDigitsFromStep(double step)
{
   if(step <= 0.0) return 2;
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
   {
      s *= 10.0;
      digits++;
   }
   return digits;
}

double NormalizeVolume(const string sym, double vol)
{
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(vol < vmin || vol > vmax) return vol;
   if(vstep <= 0) return vol;
   double steps = MathFloor((vol - vmin) / vstep + 1e-9);
   double out = vmin + steps * vstep;
   out = MathMax(vmin, MathMin(vmax, out));
   out = NormalizeDouble(out, VolumeDigitsFromStep(vstep));
   return out;
}

bool EnsureTradeFillingMode(const string sym)
{
   long fill = (long)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   return true;
}

// -------------------- Daily controls --------------------
string DayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

string GVName(const string suffix)
{
   return StringFormat("GSAB.%I64d.%s.%s", InpMagicNumber, _Symbol, suffix, DayKey());
}

double GetDayStartBalance()
{
   string name = GVName("day_start_balance");
   if(!GlobalVariableCheck(name))
   {
      GlobalVariableSet(name, AccountInfoDouble(ACCOUNT_BALANCE));
   }
   return GlobalVariableGet(name);
}

void ResetDayStartBalance()
{
   string name = GVName("day_start_balance");
   GlobalVariableSet(name, AccountInfoDouble(ACCOUNT_BALANCE));
}

void CheckDailyReset()
{
   string dk = DayKey();
   if(g_last_day_key == "")
      g_last_day_key = dk;
   if(dk != g_last_day_key)
   {
      g_last_day_key = dk;
      g_kill_switch = false;
      ResetDayStartBalance();
      Print("Daily reset: kill_switch cleared, day_start_balance reset.");
   }
}

int GetTradesToday()
{
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime day_start = StructToTime(dt);

   if(!HistorySelect(day_start, now))
      return 0;

   int count = 0;
   uint deals = (uint)HistoryDealsTotal();
   for(uint i=0;i<deals;i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0) continue;
      long magic = (long)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
      if(magic != InpMagicNumber) continue;
      string sym = (string)HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
      if(sym != _Symbol) continue;
      long entry = (long)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN) count++;
   }
   return count;
}

int GetOpenEATrades()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;
      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber) continue;
      count++;
   }
   return count;
}

double GetDailyPL()
{
   // Approximate: equity - day start balance
   double start = GetDayStartBalance();
   return AccountInfoDouble(ACCOUNT_EQUITY) - start;
}

bool DailyLossHit(string &why)
{
   double start = GetDayStartBalance();
   if(start <= 0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (start - eq) / start * 100.0;
   if(dd >= InpMaxDailyLossPercent)
   {
      why = StringFormat("daily_loss_hit: drawdown=%.2f%% >= %.2f%%", dd, InpMaxDailyLossPercent);
      return true;
   }
   return false;
}

// -------------------- CSV logging --------------------
string CommonSubPath()
{
   return "GoldScalper_AI_Bridge\\";
}

string CommonRelPath(const string filename)
{
   if(g_common_subdir_ok)
      return CommonSubPath() + filename;
   return filename;
}

bool WriteCSVHeaderIfNeeded(const string common_file, const string header_line)
{
   int h = FileOpen(common_file, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
   {
      // try create
      h = FileOpen(common_file, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
      if(h == INVALID_HANDLE) return false;
      FileWriteString(h, header_line);
      FileClose(h);
      return true;
   }
   ulong size = (ulong)FileSize(h);
   if(size <= 0)
   {
      FileSeek(h, 0, SEEK_SET);
      FileWriteString(h, header_line);
   }
   FileClose(h);
   return true;
}

void LogFeaturePacket(const string iso_time, const string sym, const string json)
{
   string file = CommonRelPath(g_log_features_csv);
   WriteCSVHeaderIfNeeded(file, "time,symbol,raw_json\n");
   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat("%s,%s,\"%s\"\n", iso_time, sym, JsonEscape(json));
   FileWriteString(h, line);
   FileClose(h);
}

void LogSignal(const string iso_time, const string sym, const string transport, const string signal, double conf, int sl_pts, int tp_pts, const string reason, const string req_json, const string resp_json)
{
   string file = CommonRelPath(g_log_signals_csv);
   WriteCSVHeaderIfNeeded(file, "time,symbol,transport,signal,confidence,sl_points,tp_points,reason,raw_req_json,raw_resp_json\n");
   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat("%s,%s,%s,%s,%.4f,%d,%d,\"%s\",\"%s\",\"%s\"\n",
                              iso_time, sym, transport, signal, conf, sl_pts, tp_pts,
                              JsonEscape(reason), JsonEscape(req_json), JsonEscape(resp_json));
   FileWriteString(h, line);
   FileClose(h);
}

void LogTradeEvent(const string iso_time, const string sym, const string event, const string side, double volume, double price, double sl, double tp, double profit, const string reason)
{
   string file = CommonRelPath(g_log_trades_csv);
   WriteCSVHeaderIfNeeded(file, "time,symbol,event,side,volume,price,sl,tp,profit,reason\n");
   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat("%s,%s,%s,%s,%.2f,%.5f,%.5f,%.5f,%.2f,\"%s\"\n",
                              iso_time, sym, event, side, volume, price, sl, tp, profit, JsonEscape(reason));
   FileWriteString(h, line);
   FileClose(h);
}

// -------------------- Transport: TCP --------------------
bool TcpRequest(const string host, int port, const string req, string &resp, int timeout_ms, string &err)
{
   resp = "";
   err = "";

   int sock = SocketCreate();
   if(sock == INVALID_HANDLE)
   {
      err = "SocketCreate failed";
      return false;
   }
   if(!SocketConnect(sock, host, (ushort)port, timeout_ms))
   {
      err = StringFormat("SocketConnect failed (%d)", GetLastError());
      SocketClose(sock);
      return false;
   }

   string line = req + "\n";
   uchar data[];
   StringToCharArray(line, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(SocketSend(sock, data, ArraySize(data)-1) <= 0)
   {
      err = StringFormat("SocketSend failed (%d)", GetLastError());
      SocketClose(sock);
      return false;
   }

   // Read until newline or timeout
   datetime start = TimeLocal();
   string acc = "";
   while(true)
   {
      uchar buf[4096];
      int n = SocketRead(sock, buf, 4096, timeout_ms);
      if(n > 0)
      {
         string chunk = CharArrayToString(buf, 0, n, CP_UTF8);
         acc += chunk;
         int pos = StringFind(acc, "\n");
         if(pos >= 0)
         {
            resp = StringSubstr(acc, 0, pos);
            break;
         }
      }
      else
      {
         if((TimeLocal() - start) * 1000 >= timeout_ms)
         {
            err = "SocketRead timeout";
            SocketClose(sock);
            return false;
         }
         Sleep(20);
      }
   }
   SocketClose(sock);
   return true;
}

bool TcpRequestExpectId(const string host, int port, const string req_json, const string request_id, string &resp_json, int timeout_ms, string &err)
{
   resp_json = "";
   if(!TcpRequest(host, port, req_json, resp_json, timeout_ms, err))
      return false;
   string rid = "";
   if(!ExtractJsonStringField(resp_json, "request_id", rid))
   {
      err = "missing_request_id_in_response";
      return false;
   }
   if(rid != request_id)
   {
      err = StringFormat("request_id_mismatch: got=%s expected=%s", rid, request_id);
      return false;
   }
   return true;
}

// -------------------- Transport: File bridge --------------------
bool FileBridgeRequest(const string req_json, const string request_id, string &resp_json, string &err)
{
   resp_json = "";
   err = "";

   // Ensure bridge dir exists by opening a file within it.
   string req_path = CommonRelPath(g_req_file);
   int h = FileOpen(req_path, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      err = StringFormat("FileOpen request failed (%d) path=%s", GetLastError(), req_path);
      return false;
   }
   FileWriteString(h, req_json);
   FileClose(h);

   // Wait for response.json to appear and be newer than request.
   string resp_path = CommonRelPath(g_resp_file);
   string stamp_path = CommonRelPath(g_stamp_file);
   datetime start = TimeLocal();
   while((TimeLocal() - start) < 3) // up to ~3 seconds
   {
      if(FileIsExist(resp_path, FILE_COMMON))
      {
         string tmp = "";
         if(ReadAllFileCommonUtf8(resp_path, tmp))
         {
            resp_json = tmp;
            if(StringLen(resp_json) > 0)
            {
               string rid = "";
               if(ExtractJsonStringField(resp_json, "request_id", rid))
               {
                  if(rid == request_id)
                     return true;
               }
            }
         }
      }
      Sleep(120);
   }
   err = "file_bridge timeout waiting for matching response.json";
   return false;
}

bool InitCommonSubdir()
{
   // Some terminals/brokers disallow creating subfolders automatically.
   // We test once and fall back to flat filenames if subfolder access fails.
   g_common_subdir_ok = false;
   string test_rel = CommonSubPath() + "._subdir_test.tmp";
   int h = FileOpen(test_rel, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, "ok");
      FileClose(h);
      FileDelete(test_rel, FILE_COMMON);
      g_common_subdir_ok = true;
      return true;
   }
   // Flat fallback (no subfolder)
   return false;
}

bool ReadAllTextFileCommon(const string rel_path, string &out)
{
   out = "";
   if(!FileIsExist(rel_path, FILE_COMMON))
      return false;
   int h = FileOpen(rel_path, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   int sz = (int)FileSize(h);
   if(sz <= 0)
   {
      FileClose(h);
      return false;
   }
   // Read the entire file; FileReadString() without length tokenizes by whitespace.
   out = FileReadString(h, sz);
   FileClose(h);
   return (StringLen(out) > 0);
}

bool ReadAllFileCommonUtf8(const string rel_path, string &out)
{
   out = "";
   if(!FileIsExist(rel_path, FILE_COMMON))
      return false;
   int h = FileOpen(rel_path, FILE_READ|FILE_BIN|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   int sz = (int)FileSize(h);
   if(sz <= 0)
   {
      FileClose(h);
      return false;
   }
   uchar buf[];
   ArrayResize(buf, sz);
   int n = FileReadArray(h, buf, 0, sz);
   FileClose(h);
   if(n <= 0)
      return false;
   out = CharArrayToString(buf, 0, n, CP_UTF8);
   return (StringLen(out) > 0);
}

bool TryReadResponseStampEpoch(double &out_epoch)
{
   out_epoch = 0.0;
   string stamp_path = CommonRelPath(g_stamp_file);
   string s = "";
   if(!ReadAllFileCommonUtf8(stamp_path, s))
      return false;
   if(StringLen(s) <= 0)
      return false;
   out_epoch = StringToDouble(s);
   if(out_epoch <= 0.0)
      return false;
   return true;
}

// -------------------- JSON response parsing --------------------
bool ExtractJsonStringField(const string json, const string key, string &out)
{
   out = "";
   string k = "\"" + key + "\"";
   int p = StringFind(json, k);
   if(p < 0) return false;
   p = StringFind(json, ":", p);
   if(p < 0) return false;
   p++;
   while(p < StringLen(json) && (StringGetCharacter(json,p)==' ')) p++;
   if(p >= StringLen(json) || StringGetCharacter(json,p) != '\"') return false;
   p++;
   int e = StringFind(json, "\"", p);
   if(e < 0) return false;
   out = StringSubstr(json, p, e - p);
   return true;
}

bool ExtractJsonNumberField(const string json, const string key, double &out)
{
   out = 0.0;
   string k = "\"" + key + "\"";
   int p = StringFind(json, k);
   if(p < 0) return false;
   p = StringFind(json, ":", p);
   if(p < 0) return false;
   p++;
   while(p < StringLen(json) && (StringGetCharacter(json,p)==' ')) p++;
   int e = p;
   while(e < StringLen(json))
   {
      ushort c = (ushort)StringGetCharacter(json,e);
      if((c>='0' && c<='9') || c=='-' || c=='+' || c=='.' || c=='e' || c=='E')
         e++;
      else
         break;
   }
   if(e <= p) return false;
   string s = StringSubstr(json, p, e - p);
   out = StringToDouble(s);
   return true;
}

bool ParseAiResponse(const string resp_json, string &signal, double &conf, int &sl_pts, int &tp_pts, string &reason)
{
   signal = "HOLD"; conf = 0.0; sl_pts = 0; tp_pts = 0; reason = "";
   string sig;
   if(ExtractJsonStringField(resp_json, "signal", sig))
   {
      StringToUpper(sig);
      signal = sig;
   }
   double c;
   if(ExtractJsonNumberField(resp_json, "confidence", c)) conf = c;
   double sln, tpn;
   if(ExtractJsonNumberField(resp_json, "sl_points", sln)) sl_pts = (int)MathRound(sln);
   if(ExtractJsonNumberField(resp_json, "tp_points", tpn)) tp_pts = (int)MathRound(tpn);
   string rsn;
   if(ExtractJsonStringField(resp_json, "reason", rsn)) reason = rsn;
   if(signal!="BUY" && signal!="SELL" && signal!="HOLD") signal="HOLD";
   if(conf < 0) conf = 0; if(conf>1) conf = 1;
   if(sl_pts < 0) sl_pts = 0;
   if(tp_pts < 0) tp_pts = 0;
   return true;
}

bool ExtractJsonStatusOk(const string json, bool &ok)
{
   ok = false;
   string status = "";
   if(!ExtractJsonStringField(json, "status", status)) return false;
   if(status == "ok") ok = true;
   return true;
}

// -------------------- Feature collection --------------------
bool CopySingleValueShift(int handle, int buffer, int shift, double &out)
{
   out = 0.0;
   if(handle == INVALID_HANDLE) return false;
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) != 1) return false;
   out = arr[0];
   return true;
}

bool BuildFeaturesJson(string &out_json)
{
   string sym = _Symbol;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int spread_points = (point > 0.0 ? (int)MathRound((ask - bid)/point) : 0);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   // last 20 M1 candles
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(sym, PERIOD_M1, 0, 21, rates) < 21) // include current forming bar + 20 closed
      return false;

   // Build OHLCV for last 20 CLOSED candles (index 1..20), oldest->newest
   string ohlcv = "[";
   for(int i=20;i>=1;i--)
   {
      string item = StringFormat("[%.5f,%.5f,%.5f,%.5f,%.0f]",
                                 rates[i].open, rates[i].high, rates[i].low, rates[i].close, (double)rates[i].tick_volume);
      ohlcv += item;
      if(i != 1) ohlcv += ",";
   }
   ohlcv += "]";

   // Indicators (M1)
   double m1_ema9, m1_ema21, m1_ema50, m1_rsi14, m1_atr14, m1_adx14, m1_plusdi, m1_minusdi;
   if(!CopySingleValueShift(h_m1_ema9, 0, 1, m1_ema9)) return false;
   if(!CopySingleValueShift(h_m1_ema21, 0, 1, m1_ema21)) return false;
   if(!CopySingleValueShift(h_m1_ema50, 0, 1, m1_ema50)) return false;
   if(!CopySingleValueShift(h_m1_rsi14, 0, 1, m1_rsi14)) return false;
   if(!CopySingleValueShift(h_m1_atr14, 0, 1, m1_atr14)) return false;
   if(!CopySingleValueShift(h_m1_adx14, 0, 1, m1_adx14)) return false;
   if(!CopySingleValueShift(h_m1_adx14, 1, 1, m1_plusdi)) return false;
   if(!CopySingleValueShift(h_m1_adx14, 2, 1, m1_minusdi)) return false;

   // Indicators (M5)
   double m5_ema20, m5_ema50, m5_rsi14, m5_atr14, m5_adx14, m5_plusdi, m5_minusdi;
   if(!CopySingleValueShift(h_m5_ema20, 0, 1, m5_ema20)) return false;
   if(!CopySingleValueShift(h_m5_ema50, 0, 1, m5_ema50)) return false;
   if(!CopySingleValueShift(h_m5_rsi14, 0, 1, m5_rsi14)) return false;
   if(!CopySingleValueShift(h_m5_atr14, 0, 1, m5_atr14)) return false;
   if(!CopySingleValueShift(h_m5_adx14, 0, 1, m5_adx14)) return false;
   if(!CopySingleValueShift(h_m5_adx14, 1, 1, m5_plusdi)) return false;
   if(!CopySingleValueShift(h_m5_adx14, 2, 1, m5_minusdi)) return false;

   int open_ea_trades = GetOpenEATrades();
   int trades_today = GetTradesToday();
   int hour_gmt = HourGMT(TimeGMT());

   // Estimated SL points from ATR (aligned with python dummy_rule_ai) for volume_lots → aggressive ML feature parity
   double base_atr = (m5_atr14 > 0.0 ? m5_atr14 : m1_atr14);
   int sl_est = 150;
   int tp_est = 270;
   if(base_atr > 0.0 && point > 0.0)
   {
      int atr_pts = (int)MathMax(1, (int)MathRound(base_atr / point));
      sl_est = (int)MathMin(320.0, MathMax(80.0, (double)MathRound(atr_pts * 1.2)));
      tp_est = (int)MathMin(650.0, MathMax(150.0, (double)MathRound(atr_pts * 2.0)));
   }
   double volume_lots = 0.01;
   double vb = 0.0, vs = 0.0;
   string wb = "", ws = "";
   bool okb = CalcVolumeForRisk(sym, ORDER_TYPE_BUY, ask, sl_est, vb, wb);
   bool oks = CalcVolumeForRisk(sym, ORDER_TYPE_SELL, bid, sl_est, vs, ws);
   if(okb && oks)
      volume_lots = (vb + vs) / 2.0;
   else if(okb)
      volume_lots = vb;
   else if(oks)
      volume_lots = vs;

   string iso_time = TimeToISO(TimeGMT());
   string request_id = NewRequestId();
   g_last_request_id = request_id;

   // Build JSON packet
   string features =
      "{"
      "\"symbol\":\"" + JsonEscape(sym) + "\","
      "\"bid\":" + DoubleToString(bid, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) + ","
      "\"ask\":" + DoubleToString(ask, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) + ","
      "\"spread_points\":" + (string)spread_points + ","
      "\"balance\":" + DoubleToString(balance, 2) + ","
      "\"equity\":" + DoubleToString(equity, 2) + ","
      "\"free_margin\":" + DoubleToString(free_margin, 2) + ","
      "\"m1_ohlcv\":" + ohlcv + ","
      "\"m1_ema9\":" + DoubleToString(m1_ema9, 6) + ","
      "\"m1_ema21\":" + DoubleToString(m1_ema21, 6) + ","
      "\"m1_ema50\":" + DoubleToString(m1_ema50, 6) + ","
      "\"m1_rsi14\":" + DoubleToString(m1_rsi14, 2) + ","
      "\"m1_atr14\":" + DoubleToString(m1_atr14, 6) + ","
      "\"m1_adx14\":" + DoubleToString(m1_adx14, 2) + ","
      "\"m1_plusdi\":" + DoubleToString(m1_plusdi, 2) + ","
      "\"m1_minusdi\":" + DoubleToString(m1_minusdi, 2) + ","
      "\"m5_ema20\":" + DoubleToString(m5_ema20, 6) + ","
      "\"m5_ema50\":" + DoubleToString(m5_ema50, 6) + ","
      "\"m5_rsi14\":" + DoubleToString(m5_rsi14, 2) + ","
      "\"m5_atr14\":" + DoubleToString(m5_atr14, 6) + ","
      "\"m5_adx14\":" + DoubleToString(m5_adx14, 2) + ","
      "\"m5_plusdi\":" + DoubleToString(m5_plusdi, 2) + ","
      "\"m5_minusdi\":" + DoubleToString(m5_minusdi, 2) + ","
      "\"hour_gmt\":" + (string)hour_gmt + ","
      "\"open_ea_trades\":" + (string)open_ea_trades + ","
      "\"trades_today\":" + (string)trades_today + ","
      "\"volume_lots\":" + DoubleToString(volume_lots, 4) +
      "}";

   out_json =
      "{"
      "\"request_id\":\"" + JsonEscape(request_id) + "\","
      "\"type\":\"features\","
      "\"symbol\":\"" + JsonEscape(sym) + "\","
      "\"time\":\"" + iso_time + "\","
      "\"features\":" + features +
      "}";

   LogFeaturePacket(iso_time, sym, out_json);
   return true;
}

// -------------------- Risk & execution --------------------
bool SpreadOk(int spread_points, string &why)
{
   if(spread_points > InpMaxSpreadPoints)
   {
      why = StringFormat("spread_too_high: %d > %d", spread_points, InpMaxSpreadPoints);
      return false;
   }
   return true;
}

bool BalanceOk(string &why)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < InpMinBalanceUSD)
   {
      why = StringFormat("balance_too_low: %.2f < %.2f", bal, InpMinBalanceUSD);
      return false;
   }
   return true;
}

bool TradesTodayOk(string &why)
{
   int n = GetTradesToday();
   if(n >= InpMaxTradesPerDay)
   {
      why = StringFormat("trades_today_limit: %d >= %d", n, InpMaxTradesPerDay);
      return false;
   }
   return true;
}

bool OpenTradesOk(string &why)
{
   int n = GetOpenEATrades();
   if(n >= InpMaxOpenTrades)
   {
      why = StringFormat("open_trades_limit: %d >= %d", n, InpMaxOpenTrades);
      return false;
   }
   return true;
}

bool ConfidenceOk(double conf, string &why)
{
   if(conf < InpMinConfidence)
   {
      why = StringFormat("confidence_low: %.2f < %.2f", conf, InpMinConfidence);
      return false;
   }
   return true;
}

bool StopsOk(const string sym, int sl_points, int tp_points, string &why)
{
   if(sl_points <= 0 || tp_points <= 0)
   {
      why = "invalid_sl_tp_points";
      return false;
   }
   int stops_level = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze_level = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   int min_level = MathMax(stops_level, freeze_level);
   if(sl_points < min_level || tp_points < min_level)
   {
      why = StringFormat("stops_too_close: sl=%d tp=%d min=%d (stops=%d freeze=%d)", sl_points, tp_points, min_level, stops_level, freeze_level);
      return false;
   }
   return true;
}

bool MarginOk(const string sym, ENUM_ORDER_TYPE order_type, double volume, double price, string &why)
{
   double margin = 0.0;
   if(!OrderCalcMargin(order_type, sym, volume, price, margin))
   {
      why = StringFormat("OrderCalcMargin failed (%d)", GetLastError());
      return false;
   }
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > free)
   {
      why = StringFormat("insufficient_margin: need=%.2f free=%.2f", margin, free);
      return false;
   }
   return true;
}

bool CalcVolumeForRisk(const string sym, ENUM_ORDER_TYPE order_type, double entry_price, int sl_points, double &out_volume, string &why)
{
   out_volume = 0.0;
   why = "";

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * (InpRiskPercent / 100.0);
   if(risk_money <= 0.0)
   {
      why = "risk_money<=0";
      return false;
   }

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0)
   {
      why = "invalid_point";
      return false;
   }

   double sl_price = entry_price;
   if(order_type == ORDER_TYPE_BUY) sl_price = entry_price - sl_points * point;
   if(order_type == ORDER_TYPE_SELL) sl_price = entry_price + sl_points * point;

   double profit = 0.0;
   if(!OrderCalcProfit(order_type, sym, 1.0, entry_price, sl_price, profit))
   {
      why = StringFormat("OrderCalcProfit failed (%d)", GetLastError());
      return false;
   }

   double risk_per_lot = -profit;
   if(risk_per_lot <= 0.0)
   {
      why = StringFormat("risk_per_lot<=0 (profit=%.5f)", profit);
      return false;
   }

   double vol = risk_money / risk_per_lot;
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(vol < vmin)
   {
      // Optional: controlled min-lot override if min-lot risk is still within safe bounds.
      if(!InpAllowMinLotOverride)
      {
         why = StringFormat("risk_unsafe: computed_volume=%.4f < min=%.4f", vol, vmin);
         return false;
      }
      double sl_profit_min = 0.0;
      if(!OrderCalcProfit(order_type, sym, vmin, entry_price, sl_price, sl_profit_min))
      {
         why = StringFormat("OrderCalcProfit(minlot) failed (%d)", GetLastError());
         return false;
      }
      double minlot_risk = -sl_profit_min;
      double risk_pct = (balance > 0.0 ? (minlot_risk / balance * 100.0) : 100.0);
      if(risk_pct <= InpMaxRiskAtMinLotPercent)
      {
         out_volume = NormalizeVolume(sym, vmin);
         why = StringFormat("min_lot_override: computed=%.4f using=%.4f risk=%.2f%%", vol, out_volume, risk_pct);
         return true;
      }
      why = StringFormat("min_lot_risk_too_high: computed=%.4f min=%.4f risk=%.2f%% > %.2f%%", vol, vmin, risk_pct, InpMaxRiskAtMinLotPercent);
      return false;
   }
   if(vol > vmax) vol = vmax;
   vol = NormalizeVolume(sym, vol);
   if(vol < vmin || vol > vmax)
   {
      why = StringFormat("volume_out_of_bounds: %.4f (min=%.4f max=%.4f)", vol, vmin, vmax);
      return false;
   }

   out_volume = vol;
   return true;
}

bool ExecuteSignal(const string signal, double confidence, int sl_points, int tp_points, const string reason, int spread_points)
{
   string sym = _Symbol;
   string iso_time = TimeToISO(TimeGMT());

   // Hard kill switch: daily loss, etc.
   string why = "";
   if(g_kill_switch)
   {
      why = "kill_switch";
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(!InpAllowLiveTrading)
   {
      why = "InpAllowLiveTrading=false";
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(signal != "BUY" && signal != "SELL")
   {
      why = "signal_not_trade";
      Print("Skip: signal=", signal);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(!ConfidenceOk(confidence, why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(!SpreadOk(spread_points, why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(!BalanceOk(why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(DailyLossHit(why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "KILL_SWITCH_ON", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      g_kill_switch = true;
      return false;
   }
   if(!TradesTodayOk(why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(!OpenTradesOk(why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }
   if(!StopsOk(sym, sl_points, tp_points, why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, 0.0, 0.0, 0.0, 0.0, why);
      return false;
   }

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   ENUM_ORDER_TYPE order_type = (signal == "BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double entry = (signal == "BUY" ? ask : bid);
   double sl = (signal == "BUY" ? entry - sl_points * point : entry + sl_points * point);
   double tp = (signal == "BUY" ? entry + tp_points * point : entry - tp_points * point);

   // Normalize prices
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double volume = 0.0;
   if(!CalcVolumeForRisk(sym, order_type, entry, sl_points, volume, why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, 0.0, entry, sl, tp, 0.0, why);
      return false;
   }
   // If min-lot override happened, record it in the comment logs
   if(StringFind(why, "min_lot_override") >= 0)
      Print("Info: ", why);
   if(!MarginOk(sym, order_type, volume, entry, why))
   {
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, volume, entry, sl, tp, 0.0, why);
      return false;
   }

   // OrderCheck preflight
   MqlTradeRequest rq;
   MqlTradeCheckResult ck;
   ZeroMemory(rq);
   ZeroMemory(ck);
   rq.action   = TRADE_ACTION_DEAL;
   rq.symbol   = sym;
   rq.magic    = (ulong)InpMagicNumber;
   rq.volume   = volume;
   rq.price    = entry;
   rq.sl       = sl;
   rq.tp       = tp;
   rq.deviation= 20;
   rq.type     = (signal == "BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   // Some MT5 builds do not expose CTrade::GetTypeFilling(); compute from symbol filling flags.
   long fill_flags = (long)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fill_flags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) rq.type_filling = ORDER_FILLING_FOK;
   else if((fill_flags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) rq.type_filling = ORDER_FILLING_IOC;
   else rq.type_filling = ORDER_FILLING_RETURN;
   rq.type_time = ORDER_TIME_GTC;

   if(!OrderCheck(rq, ck))
   {
      why = StringFormat("OrderCheck failed (%d)", GetLastError());
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, volume, entry, sl, tp, 0.0, why);
      return false;
   }
   // Accept only OK retcodes (tolerate some builds returning retcode=0 with "done")
   string cmt = ck.comment;
   StringToLower(cmt);
   bool check_ok =
      (ck.retcode == 0 && StringFind(cmt, "done") >= 0) ||
      ck.retcode == TRADE_RETCODE_DONE ||
      ck.retcode == TRADE_RETCODE_PLACED ||
      ck.retcode == TRADE_RETCODE_DONE_PARTIAL;

   if(!check_ok)
   {
      why = StringFormat("OrderCheck reject: retcode=%d comment=%s margin=%.2f free=%.2f",
                         ck.retcode, ck.comment, ck.margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      Print("Skip: ", why);
      LogTradeEvent(iso_time, sym, "SKIP", signal, volume, entry, sl, tp, 0.0, why);
      return false;
   }

   EnsureTradeFillingMode(sym);
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);

   bool ok=false;
   ResetLastError();
   if(signal == "BUY")
      ok = g_trade.Buy(volume, sym, entry, sl, tp, reason);
   else
      ok = g_trade.Sell(volume, sym, entry, sl, tp, reason);

   if(!ok)
   {
      int ec = (int)g_trade.ResultRetcode();
      string d = g_trade.ResultRetcodeDescription();
      Print("Order failed: retcode=", ec, " desc=", d);
      LogTradeEvent(iso_time, sym, "ORDER_FAIL", signal, volume, entry, sl, tp, 0.0, d);
      return false;
   }

   ulong ticket = g_trade.ResultOrder();
   Print("Order placed: ", signal, " vol=", DoubleToString(volume,2), " SLpts=", sl_points, " TPpts=", tp_points, " conf=", DoubleToString(confidence,2), " ticket=", (string)ticket);
   LogTradeEvent(iso_time, sym, "ORDER_OK", signal, volume, entry, sl, tp, 0.0, reason);
   return true;
}

// -------------------- Trade management --------------------
void ManagePositions()
{
   string sym = _Symbol;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string psym = PositionGetString(POSITION_SYMBOL);
      if(psym != sym) continue;
      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double profit = PositionGetDouble(POSITION_PROFIT);
      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);

      // Close stale after 20 minutes if not profitable
      if((TimeCurrent() - open_time) > 20*60 && profit <= 0.0)
      {
         string iso_time = TimeToISO(TimeGMT());
         bool ok = g_trade.PositionClose(ticket);
         string msg = ok ? "STALE_CLOSE_OK" : "STALE_CLOSE_FAIL";
         Print(msg, " ticket=", (string)ticket, " profit=", DoubleToString(profit,2));
         LogTradeEvent(iso_time, sym, msg, (type==POSITION_TYPE_BUY?"BUY":"SELL"), PositionGetDouble(POSITION_VOLUME), open_price, sl, tp, profit, "stale>20m and not profitable");
         continue;
      }

      // R in points computed from open->SL
      if(sl <= 0.0) continue;
      double r_points = 0.0;
      if(type == POSITION_TYPE_BUY) r_points = (open_price - sl)/point;
      else r_points = (sl - open_price)/point;
      if(r_points <= 1) continue;

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double cur = (type==POSITION_TYPE_BUY ? bid : ask);
      double move_points = (type==POSITION_TYPE_BUY ? (cur - open_price)/point : (open_price - cur)/point);
      if(move_points <= 0) continue;

      // Break-even at 0.7R: set SL to open (plus small buffer)
      if(move_points >= 0.7 * r_points)
      {
         double be = open_price;
         double buffer = 2 * point;
         if(type==POSITION_TYPE_BUY) be = open_price + buffer;
         else be = open_price - buffer;
         be = NormalizeDouble(be, digits);

         bool needs_be = false;
         if(type==POSITION_TYPE_BUY && (sl < be)) needs_be = true;
         if(type==POSITION_TYPE_SELL && (sl > be)) needs_be = true;
         if(needs_be)
         {
            g_trade.PositionModify(ticket, be, tp);
         }
      }

      // Trailing after 1.0R: keep SL at least at BE, trail at 0.5R distance
      if(move_points >= 1.0 * r_points)
      {
         double trail_dist = 0.5 * r_points * point;
         double new_sl = sl;
         if(type==POSITION_TYPE_BUY)
            new_sl = NormalizeDouble(bid - trail_dist, digits);
         else
            new_sl = NormalizeDouble(ask + trail_dist, digits);

         // Do not loosen stop
         bool tighten = false;
         if(type==POSITION_TYPE_BUY && new_sl > sl) tighten = true;
         if(type==POSITION_TYPE_SELL && new_sl < sl) tighten = true;
         if(tighten)
         {
            g_trade.PositionModify(ticket, new_sl, tp);
         }
      }
   }
}

// -------------------- Dashboard --------------------
void UpdateDashboard()
{
   string sym = _Symbol;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int spread = (point > 0.0 ? (int)MathRound((ask - bid)/point) : 0);
   int open_trades = GetOpenEATrades();
   int trades_today = GetTradesToday();
   double daily_pl = GetDailyPL();
   string loss_msg="";
   bool loss_hit = DailyLossHit(loss_msg);

   // Connection status UX:
   // The one-time OnInit() ping can fail if Python wasn't running yet.
   // Use last successful AI reply (or file response stamp) to reflect actual connectivity.
   if(g_conn_status != "FEATURES_ERROR")
   {
      bool connected = false;
      if(g_last_ai_time > 0 && (TimeCurrent() - g_last_ai_time) <= 90)
         connected = true;
      // File-bridge: if Python writes response.stamp recently, consider it connected even if
      // this chart hasn't processed a new-bar cycle yet.
      if(!connected && InpUseFileFallback)
      {
         double stamp_epoch = 0.0;
         if(TryReadResponseStampEpoch(stamp_epoch))
         {
            // response.stamp is written as a Unix epoch (UTC seconds).
            // Use TimeGMT() so we compare in the same time base.
            datetime now_utc = TimeGMT();
            datetime stamp_dt = (datetime)MathRound(stamp_epoch);
            if(stamp_dt > 0 && (now_utc - stamp_dt) <= 180)
               connected = true;
         }
      }
      g_conn_status = (connected ? "CONNECTED" : "DISCONNECTED");
   }

   string txt =
      "GoldScalper_AI_Bridge\n"
      "Symbol: " + sym + (SymbolLooksLikeGold(sym) ? "" : " (not XAU?)") + "\n"
      "Conn: " + g_conn_status + "\n"
      "Last ping: " + g_last_ping + "\n"
      "Last signal: " + g_last_signal + "  conf=" + DoubleToString(g_last_confidence,2) + "\n"
      "Reason: " + g_last_reason + "\n"
      "Spread(points): " + (string)spread + " / max " + (string)InpMaxSpreadPoints + "\n"
      "Trades today: " + (string)trades_today + " / " + (string)InpMaxTradesPerDay + "\n"
      "Open EA trades: " + (string)open_trades + " / " + (string)InpMaxOpenTrades + "\n"
      "Daily P/L (approx): " + DoubleToString(daily_pl,2) + "\n"
      "Kill switch: " + (g_kill_switch ? "ON" : "OFF") + (loss_hit ? " (daily loss hit)" : "") + "\n"
      "Live trading: " + (InpAllowLiveTrading ? "ENABLED" : "DISABLED") + "\n"
      "Mode: " + (InpUseFileFallback ? "FILE" : "TCP") + "\n";

   Comment(txt);
}

bool SendPing()
{
   string request_id = NewRequestId();
   string req = "{"
                "\"request_id\":\"" + JsonEscape(request_id) + "\","
                "\"type\":\"ping\""
                "}";
   string resp = "";
   string err = "";
   bool ok = false;
   if(InpUseFileFallback)
      ok = FileBridgeRequest(req, request_id, resp, err);
   else
      ok = TcpRequestExpectId(InpPythonHost, InpPythonPort + 1, req, request_id, resp, 1200, err);

   if(!ok)
   {
      g_last_ping = "FAIL: " + err;
      g_conn_status = "DISCONNECTED";
      return false;
   }
   bool status_ok=false;
   if(ExtractJsonStatusOk(resp, status_ok) && status_ok)
   {
      g_last_ping = "OK";
      g_conn_status = "CONNECTED";
      return true;
   }
   g_last_ping = "FAIL: bad_status";
   g_conn_status = "DISCONNECTED";
   return false;
}

// -------------------- New-bar detection --------------------
bool IsNewM1Bar()
{
   datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 == 0) return false;
   if(g_last_m1_bar_time == 0)
   {
      g_last_m1_bar_time = t0;
      return false;
   }
   if(t0 != g_last_m1_bar_time)
   {
      g_last_m1_bar_time = t0;
      return true;
   }
   return false;
}

// -------------------- Lifecycle --------------------
int OnInit()
{
   Print("GoldScalper_AI_Bridge init (v1.05) conn-status fix active.");
   if(!SymbolLooksLikeGold(_Symbol))
      Print("Warning: attached to symbol=", _Symbol, " (expected XAUUSD/GOLD variants). EA will still run.");

   // Indicator handles
   h_m1_ema9  = iMA(_Symbol, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
   h_m1_ema21 = iMA(_Symbol, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
   h_m1_ema50 = iMA(_Symbol, PERIOD_M1, 50, 0, MODE_EMA, PRICE_CLOSE);
   h_m1_rsi14 = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);
   h_m1_atr14 = iATR(_Symbol, PERIOD_M1, 14);
   h_m1_adx14 = iADX(_Symbol, PERIOD_M1, 14);

   h_m5_ema20 = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   h_m5_ema50 = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   h_m5_rsi14 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   h_m5_atr14 = iATR(_Symbol, PERIOD_M5, 14);
   h_m5_adx14 = iADX(_Symbol, PERIOD_M5, 14);

   if(h_m1_ema9==INVALID_HANDLE || h_m1_adx14==INVALID_HANDLE || h_m5_ema20==INVALID_HANDLE)
   {
      Print("Indicator init failed. err=", GetLastError());
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   EnsureTradeFillingMode(_Symbol);

   // COMMON files: attempt to use a dedicated subfolder, else fall back to flat files.
   InitCommonSubdir();
   if(g_common_subdir_ok)
      Print("Bridge dir (COMMON): ", TerminalInfoString(TERMINAL_COMMONDATA_PATH), "\\Files\\", CommonSubPath());
   else
      Print("Bridge dir (COMMON): subfolder unavailable; using flat COMMON files directory.");

   // Initialize daily start balance GV
   GetDayStartBalance();
   g_last_day_key = DayKey();

   // Connection self-test (non-fatal)
   SendPing();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   if(h_m1_ema9!=INVALID_HANDLE) IndicatorRelease(h_m1_ema9);
   if(h_m1_ema21!=INVALID_HANDLE) IndicatorRelease(h_m1_ema21);
   if(h_m1_ema50!=INVALID_HANDLE) IndicatorRelease(h_m1_ema50);
   if(h_m1_rsi14!=INVALID_HANDLE) IndicatorRelease(h_m1_rsi14);
   if(h_m1_atr14!=INVALID_HANDLE) IndicatorRelease(h_m1_atr14);
   if(h_m1_adx14!=INVALID_HANDLE) IndicatorRelease(h_m1_adx14);
   if(h_m5_ema20!=INVALID_HANDLE) IndicatorRelease(h_m5_ema20);
   if(h_m5_ema50!=INVALID_HANDLE) IndicatorRelease(h_m5_ema50);
   if(h_m5_rsi14!=INVALID_HANDLE) IndicatorRelease(h_m5_rsi14);
   if(h_m5_atr14!=INVALID_HANDLE) IndicatorRelease(h_m5_atr14);
   if(h_m5_adx14!=INVALID_HANDLE) IndicatorRelease(h_m5_adx14);
}

void OnTick()
{
   CheckDailyReset();
   ManagePositions();

   if(IsNewM1Bar())
   {
      string req_json;
      if(!BuildFeaturesJson(req_json))
      {
         g_conn_status = "FEATURES_ERROR";
         g_last_ping = "FAIL: features_build";
         UpdateDashboard();
         return;
      }

      string resp_json = "";
      string err = "";
      bool ok = false;
      string transport = "";

      if(InpUseFileFallback)
      {
         transport = "file";
         ok = FileBridgeRequest(req_json, g_last_request_id, resp_json, err);
      }
      else
      {
         transport = "tcp";
         int tcp_port = InpPythonPort + 1; // python TCP fallback listens on port+1 by default
         ok = TcpRequestExpectId(InpPythonHost, tcp_port, req_json, g_last_request_id, resp_json, 1200, err);
      }

      if(!ok)
      {
         g_conn_status = "DISCONNECTED";
         g_last_ping = "FAIL: " + err;
         g_last_signal = "HOLD";
         g_last_confidence = 0.0;
         g_last_reason = "no_ai_response: " + err;

         // Log signal attempt (HOLD)
         string iso_time = TimeToISO(TimeGMT());
         LogSignal(iso_time, _Symbol, transport, g_last_signal, g_last_confidence, 0, 0, g_last_reason, req_json, resp_json);
         UpdateDashboard();
         return;
      }

      g_conn_status = "CONNECTED";
      g_last_ping = "OK";
      string sig, rsn;
      double conf;
      int sl_pts, tp_pts;
      ParseAiResponse(resp_json, sig, conf, sl_pts, tp_pts, rsn);

      g_last_signal = sig;
      g_last_confidence = conf;
      g_last_reason = rsn;
      g_last_ai_time = TimeCurrent();

      // Spread points (recompute from current tick)
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int spread_points = (point > 0.0 ? (int)MathRound((ask - bid)/point) : 0);

      // Log AI response
      string iso_time = TimeToISO(TimeGMT());
      LogSignal(iso_time, _Symbol, transport, sig, conf, sl_pts, tp_pts, rsn, req_json, resp_json);

      // Trade if allowed and filters pass
      ExecuteSignal(sig, conf, sl_pts, tp_pts, rsn, spread_points);
   }

   UpdateDashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   // Log closed trades for this EA (magic + symbol).
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   ulong deal = trans.deal;
   if(deal == 0)
      return;
   if(!HistoryDealSelect(deal))
      return;

   long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
   if(magic != InpMagicNumber)
      return;
   string sym = (string)HistoryDealGetString(deal, DEAL_SYMBOL);
   if(sym != _Symbol)
      return;

   long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT)
      return;

   long dtype = (long)HistoryDealGetInteger(deal, DEAL_TYPE);
   string side = (dtype == DEAL_TYPE_SELL ? "SELL" : "BUY");
   double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double price  = HistoryDealGetDouble(deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(deal, DEAL_SWAP);

   string iso_time = TimeToISO(TimeGMT());
   string reason = "deal_close";
   LogTradeEvent(iso_time, sym, "CLOSE", side, volume, price, 0.0, 0.0, profit, reason);

   // Emit a trade_event.json for python ingestion (file-bridge).
   string ev_json =
      "{"
      "\"time\":\"" + JsonEscape(iso_time) + "\","
      "\"symbol\":\"" + JsonEscape(sym) + "\","
      "\"event\":\"CLOSE\","
      "\"magic\":" + (string)magic + ","
      "\"ticket\":" + (string)deal + ","
      "\"side\":\"" + side + "\","
      "\"volume\":" + DoubleToString(volume, 2) + ","
      "\"price\":" + DoubleToString(price, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) + ","
      "\"profit\":" + DoubleToString(profit, 2) + ","
      "\"reason\":\"" + JsonEscape(reason) + "\","
      "\"extra\":{"
         "\"commission\":" + DoubleToString(commission, 2) + ","
         "\"swap\":" + DoubleToString(swap, 2) +
      "}"
      "}";

   string path = CommonRelPath(g_trade_event_file);
   int h = FileOpen(path, FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, ev_json);
      FileClose(h);
   }
}


