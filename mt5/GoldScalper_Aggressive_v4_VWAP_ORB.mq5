//+------------------------------------------------------------------+
//| GoldScalper_Aggressive_v4_VWAP_ORB.mq5                           |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

// -----------------------------------
// INPUTS
// -----------------------------------
input int    MagicNumber                = 20260504;
input double FixedLot                   = 0.01;
input bool   ForceMinLot                = true;

input int    TP_Points                  = 35;
input int    TP2_Points                 = 55;
input int    SL_Points                  = 55;
input bool   EnableTP2                  = true;

input int    BreakEvenAfterPts          = 18;
input int    BreakEvenPlusPts           = 2;
input int    TrailStartPts              = 28;
input int    TrailDistancePts           = 16;
input int    MaxHoldSeconds             = 35;
input int    MaxHoldMinProfitPts        = 3;

input double MaxDailyLossPercent        = 5.0;
input int    MaxConsecutiveLosses       = 3;
input int    CooldownSeconds            = 10;
input int    SpreadLimit                = 45;
input int    MaxTrades                  = 1;
input int    MaxTradesPerDay            = 20;

input bool   UseMoneyRiskGate           = true;
input double MaxMoneyRiskPerTrade       = 0.75;

input int    MinSecondsAfterBarOpen     = 8;

// VWAP trend mode
input bool   UseVWAPTrend               = true;
input int    VWAPSessionStartHourGMT    = 0;
input int    MaxDistanceFromVWAPPoints  = 250;

// M5 trend filter
input bool   UseM5TrendFilter           = true;
input double MinM5ADX                   = 14.0;

// ORB mode
input bool   UseORB                     = true;
input int    ORBStartHourGMT            = 7;
input int    ORBRangeMinutes            = 30;
input int    ORBEndHourGMT              = 11;
input int    ORBBufferPoints            = 25;
input int    MaxORBTradesPerDay         = 2;
input int    MinORBRangePoints          = 80;
input int    MaxORBRangePoints          = 500;

// Range fade mode (optional)
input bool   UseRangeFade               = false;
input double RangeFadeMaxM5ADX          = 12.0;
input int    RangeVWAPBandPoints        = 120;
input int    RangeTP_Points             = 22;
input int    RangeSL_Points             = 42;
input int    RangeBEAfterPts            = 12;
input int    RangeTrailStartPts         = 18;
input int    RangeTrailDistPts          = 12;
input double MinBodyRatio               = 0.45;
input double MinWickRatio               = 0.55;

// Smart stacking (off by default)
input bool   UseSmartStacking           = false;
input int    MaxSameDirectionTrades     = 2;
input int    MinProfitBeforeStackPoints = 30;

// Time filters
input bool   EnableSessionFilter        = true;
input bool   EnableBuyBlockWindow       = true;
input int    BlockBuyStartHourGMT       = 17;
input int    BlockBuyEndHourGMT         = 20;

// Logging
input bool   EnableTradeLog             = true;
input bool   TradeLogToCommonFolder     = true;
input string TradeLogCsv                = "trades_aggressive_v4.csv";
input bool   EnableMlLog                = true;
input string MlLogCsv                   = "trades_aggressive_v4_ml.csv";
input bool   EnableDebugPrint           = false; // prints detailed decision reasons to Experts

// -----------------------------------
// GLOBALS
// -----------------------------------
CTrade   g_trade;
int      g_loss_streak = 0;
datetime g_last_trade_time = 0;
double   g_day_start_balance = 0.0;
string   g_day_key = "";
string   g_last_mode = "NONE";
string   g_last_signal = "HOLD";
string   g_last_skip = "";

int h_m1_ema9 = INVALID_HANDLE;
int h_m1_ema21 = INVALID_HANDLE;
int h_m1_rsi14 = INVALID_HANDLE;

int h_m5_ema20 = INVALID_HANDLE;
int h_m5_ema50 = INVALID_HANDLE;
int h_m5_rsi14 = INVALID_HANDLE;
int h_m5_adx14 = INVALID_HANDLE;

double   g_vwap = 0.0;
datetime g_vwap_session_start = 0;

bool     g_orb_ready = false;
datetime g_orb_session_day = 0;
datetime g_orb_window_start = 0;
datetime g_orb_window_end = 0;
double   g_orb_high = 0.0;
double   g_orb_low = 0.0;
int      g_orb_trades_today = 0;

// Per-bar evaluation control (prevents missing the whole bar when skipping first seconds)
datetime g_active_bar_time = 0;
bool     g_bar_evaluated = false;

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
string ToISO(datetime t)
{
   string s = TimeToString(t, TIME_DATE | TIME_SECONDS);
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return s + "Z";
}

string DayKeyGMT()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

datetime DayStartGMT()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

datetime SessionStartGMT(const int start_hour_gmt)
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   dt.hour = start_hour_gmt;
   dt.min = 0;
   dt.sec = 0;
   datetime t = StructToTime(dt);
   datetime now = TimeGMT();
   if(t > now)
      t -= 24 * 60 * 60;
   return t;
}

int DiskFlags()
{
   return TradeLogToCommonFolder ? FILE_COMMON : 0;
}

string CsvEscape(const string s)
{
   string out = s;
   StringReplace(out, "\"", "\"\"");
   return "\"" + out + "\"";
}

bool WriteHeaderIfNeeded(const string csv_file, const string header_line)
{
   int h = FileOpen(csv_file, FILE_READ | FILE_WRITE | FILE_CSV | DiskFlags(), ',');
   if(h == INVALID_HANDLE)
   {
      h = FileOpen(csv_file, FILE_WRITE | FILE_CSV | DiskFlags(), ',');
      if(h == INVALID_HANDLE)
         return false;
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

void LogTradeCSV(
   const string iso_time,
   const string event,
   const string side,
   const double volume,
   const double price,
   const double sl,
   const double tp,
   const double profit,
   const string reason
)
{
   if(!EnableTradeLog)
      return;
   if(!WriteHeaderIfNeeded(TradeLogCsv, "time,symbol,event,side,volume,price,sl,tp,profit,reason\n"))
      return;
   int h = FileOpen(TradeLogCsv, FILE_READ | FILE_WRITE | FILE_TXT | DiskFlags());
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat(
      "%s,%s,%s,%s,%.2f,%.5f,%.5f,%.5f,%.2f,%s\n",
      iso_time, _Symbol, event, side, volume, price, sl, tp, profit, CsvEscape(reason)
   );
   FileWriteString(h, line);
   FileClose(h);
}

bool EnsureMlHeader()
{
   if(!EnableMlLog)
      return false;
   return WriteHeaderIfNeeded(
      MlLogCsv,
      "time,event,position_id,side,profit,ema9,ema21,rsi,spread_pts,"
      "vwap,distance_to_vwap_points,m5_ema20,m5_ema50,m5_rsi,m5_adx,"
      "mode,orb_high,orb_low,reason\n"
   );
}

void LogMlCSV(
   const string iso_time,
   const string event,
   const long position_id,
   const string side,
   const double profit,
   const double ema9,
   const double ema21,
   const double rsi,
   const int spread_pts,
   const double vwap,
   const int dist_vwap_pts,
   const double m5_ema20,
   const double m5_ema50,
   const double m5_rsi,
   const double m5_adx,
   const string mode,
   const double orb_high,
   const double orb_low,
   const string reason
)
{
   if(!EnableMlLog)
      return;
   if(!EnsureMlHeader())
      return;
   int h = FileOpen(MlLogCsv, FILE_READ | FILE_WRITE | FILE_TXT | DiskFlags());
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat(
      "%s,%s,%I64d,%s,%.2f,%.5f,%.5f,%.2f,%d,%.5f,%d,%.5f,%.5f,%.2f,%.2f,%s,%.5f,%.5f,%s\n",
      iso_time, event, position_id, side, profit,
      ema9, ema21, rsi, spread_pts,
      vwap, dist_vwap_pts,
      m5_ema20, m5_ema50, m5_rsi, m5_adx,
      CsvEscape(mode), orb_high, orb_low, CsvEscape(reason)
   );
   FileWriteString(h, line);
   FileClose(h);
}

bool CopyValue(const int handle, const int buffer, const int shift, double &out)
{
   out = 0.0;
   if(handle == INVALID_HANDLE)
      return false;
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) != 1)
      return false;
   out = arr[0];
   return true;
}

bool CopyClose(const ENUM_TIMEFRAMES tf, const int shift, double &out_close)
{
   out_close = 0.0;
   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   if(CopyRates(_Symbol, tf, shift, 1, rr) < 1)
      return false;
   out_close = rr[0].close;
   return true;
}

int SpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(_Point <= 0.0)
      return 0;
   return (int)MathRound((ask - bid) / _Point);
}

double NormalizeVolume(const double vol)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = 0.01;
   double v = MathMax(vmin, MathMin(vmax, vol));
   double steps = MathFloor((v - vmin) / vstep + 1e-9);
   double out = vmin + steps * vstep;
   out = MathMax(vmin, MathMin(vmax, out));
   int digits = 0;
   double s = vstep;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
   {
      s *= 10.0;
      digits++;
   }
   return NormalizeDouble(out, digits);
}

double ChooseVolume()
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double v = FixedLot;
   if(ForceMinLot)
      v = vmin;
   return NormalizeVolume(v);
}

int StopsLevelPoints()
{
   int lvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(lvl < 0)
      lvl = 0;
   return lvl;
}

int FreezeLevelPoints()
{
   int lvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(lvl < 0)
      lvl = 0;
   return lvl;
}

bool StopsOk(const int sl_pts, const int tp_pts, string &why)
{
   why = "";
   int min_pts = StopsLevelPoints() + FreezeLevelPoints();
   if(sl_pts < min_pts)
   {
      why = StringFormat("invalid stops: SL %d < min %d", sl_pts, min_pts);
      return false;
   }
   if(tp_pts < min_pts)
   {
      why = StringFormat("invalid stops: TP %d < min %d", tp_pts, min_pts);
      return false;
   }
   return true;
}

bool MoneyRiskOkOrAdjust(
   const ENUM_ORDER_TYPE type,
   const double volume,
   const double entry,
   int &sl_points_inout,
   string &why
)
{
   why = "";
   if(!UseMoneyRiskGate || MaxMoneyRiskPerTrade <= 0.0)
      return true;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;
   int min_pts = StopsLevelPoints() + FreezeLevelPoints();
   int sl_pts = sl_points_inout;
   sl_pts = (int)MathMax((double)sl_pts, (double)min_pts);

   for(int iter = 0; iter < 3; iter++)
   {
      double sl_price = (type == ORDER_TYPE_BUY ? entry - sl_pts * point : entry + sl_pts * point);
      double profit = 0.0;
      if(!OrderCalcProfit(type, _Symbol, volume, entry, sl_price, profit))
      {
         why = "OrderCalcProfit failed";
         return false;
      }
      double loss_money = MathAbs(profit);
      if(loss_money <= MaxMoneyRiskPerTrade + 1e-9)
      {
         sl_points_inout = sl_pts;
         return true;
      }
      double scale = MaxMoneyRiskPerTrade / loss_money;
      int new_sl = (int)MathFloor((double)sl_pts * scale);
      new_sl = (int)MathMax((double)new_sl, (double)min_pts);
      if(new_sl >= sl_pts)
         break;
      sl_pts = new_sl;
   }
   why = "money_risk_too_high";
   return false;
}

bool MarginOk(const ENUM_ORDER_TYPE type, const double volume, const double price, string &why)
{
   why = "";
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
   {
      why = "OrderCalcMargin failed";
      return false;
   }
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin <= 0.0 || freeM < margin)
   {
      why = StringFormat("not_enough_margin: need=%.2f free=%.2f", margin, freeM);
      return false;
   }
   return true;
}

bool OrderCheckDeal(const ENUM_ORDER_TYPE otype, const double volume, const double price, const double sl, const double tp, string &why)
{
   why = "";
   MqlTradeRequest rq;
   MqlTradeCheckResult ck;
   ZeroMemory(rq);
   ZeroMemory(ck);
   rq.action = TRADE_ACTION_DEAL;
   rq.symbol = _Symbol;
   rq.magic = (ulong)MagicNumber;
   rq.volume = volume;
   rq.price = price;
   rq.sl = sl;
   rq.tp = tp;
   rq.deviation = 20;
   rq.type = otype;
   long fill_flags = (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fill_flags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      rq.type_filling = ORDER_FILLING_FOK;
   else if((fill_flags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      rq.type_filling = ORDER_FILLING_IOC;
   else
      rq.type_filling = ORDER_FILLING_RETURN;
   rq.type_time = ORDER_TIME_GTC;
   if(!OrderCheck(rq, ck))
   {
      int ec = GetLastError();
      why = StringFormat("OrderCheck false err=%d ck.retcode=%d ck.comment=%s", ec, (int)ck.retcode, ck.comment);
      return false;
   }
   return true;
}

void CheckDailyReset()
{
   string dk = DayKeyGMT();
   if(dk == g_day_key)
      return;
   g_day_key = dk;
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_loss_streak = 0;
   g_orb_trades_today = 0;
   g_orb_ready = false;
   g_orb_high = 0.0;
   g_orb_low = 0.0;
   g_vwap = 0.0;
   g_vwap_session_start = 0;
}

void DebugPrintDecision(
   const string tag,
   const int spread_pts,
   const bool bull,
   const bool bear,
   const double m5_adx,
   const int m1_sig,
   const double ema9,
   const double ema21,
   const double rsi,
   const double body_ratio,
   const double mid
)
{
   if(!EnableDebugPrint)
      return;
   Print(
      tag,
      " sym=", _Symbol,
      " spread=", (string)spread_pts,
      " vwap=", DoubleToString(g_vwap, 2),
      " dist_vwap_pts=", (string)DistanceFromVWAPPoints(mid),
      " m5=", (bull ? "BULL" : (bear ? "BEAR" : "NEUTRAL")),
      " m5_adx=", DoubleToString(m5_adx, 1),
      " m1_sig=", (string)m1_sig,
      " ema9=", DoubleToString(ema9, 2),
      " ema21=", DoubleToString(ema21, 2),
      " rsi=", DoubleToString(rsi, 1),
      " body=", DoubleToString(body_ratio, 2),
      " orb_ready=", (g_orb_ready ? "1" : "0"),
      " orbH=", DoubleToString(g_orb_high, 2),
      " orbL=", DoubleToString(g_orb_low, 2)
   );
}

double DailyDrawdownPct()
{
   if(g_day_start_balance <= 0.0)
      return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (g_day_start_balance - eq) / g_day_start_balance * 100.0;
}

bool DailyLossOk()
{
   return (DailyDrawdownPct() < MaxDailyLossPercent);
}

bool BuyBlockedNowGMT()
{
   if(!EnableBuyBlockWindow)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   if(BlockBuyEndHourGMT > BlockBuyStartHourGMT && h >= BlockBuyStartHourGMT && h < BlockBuyEndHourGMT)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| VWAP                                                             |
//+------------------------------------------------------------------+
void ResetVWAPIfNeeded()
{
   datetime start = SessionStartGMT(VWAPSessionStartHourGMT);
   if(g_vwap_session_start != start)
   {
      g_vwap_session_start = start;
      g_vwap = 0.0;
   }
}

void UpdateVWAP()
{
   if(!UseVWAPTrend)
      return;
   ResetVWAPIfNeeded();
   if(g_vwap_session_start <= 0)
      return;
   MqlRates rr[];
   ArraySetAsSeries(rr, false);
   int got = CopyRates(_Symbol, PERIOD_M1, g_vwap_session_start, TimeGMT(), rr);
   if(got <= 0)
      return;
   double pv = 0.0;
   double vv = 0.0;
   for(int i = 0; i < got; i++)
   {
      double tp = (rr[i].high + rr[i].low + rr[i].close) / 3.0;
      double v = (double)rr[i].tick_volume;
      pv += tp * v;
      vv += v;
   }
   g_vwap = (vv > 0.0 ? pv / vv : 0.0);
}

int DistanceFromVWAPPoints(const double price)
{
   if(_Point <= 0.0 || g_vwap <= 0.0)
      return 0;
   return (int)MathRound(MathAbs(price - g_vwap) / _Point);
}

//+------------------------------------------------------------------+
//| ORB                                                              |
//+------------------------------------------------------------------+
void ResetORBForDay()
{
   datetime day = DayStartGMT();
   g_orb_session_day = day;
   g_orb_ready = false;
   g_orb_high = 0.0;
   g_orb_low = 0.0;
   g_orb_window_start = SessionStartGMT(ORBStartHourGMT);
   g_orb_window_end = g_orb_window_start + ORBRangeMinutes * 60;
}

bool BuildORBFromHistory(string &why)
{
   why = "";
   if(g_orb_window_start <= 0 || g_orb_window_end <= 0 || g_orb_window_end <= g_orb_window_start)
   {
      why = "orb_bad_window";
      return false;
   }
   // Prefer index-based CopyRates for better reliability on some terminals (history may not load by time range).
   int start_shift = iBarShift(_Symbol, PERIOD_M1, g_orb_window_start, false);
   int end_shift   = iBarShift(_Symbol, PERIOD_M1, g_orb_window_end, false);
   if(start_shift < 0 || end_shift < 0)
   {
      why = "orb_no_history_shifts";
      return false;
   }
   int older = MathMax(start_shift, end_shift);
   int newer = MathMin(start_shift, end_shift);
   int count = older - newer + 1;
   if(count <= 0)
   {
      why = "orb_bad_shift_range";
      return false;
   }
   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   int got = CopyRates(_Symbol, PERIOD_M1, newer, count, rr);
   if(got <= 0)
   {
      why = "orb_no_history_copy";
      return false;
   }
   double hi = 0.0;
   double lo = 0.0;
   for(int i = 0; i < got; i++)
   {
      if(hi <= 0.0 || rr[i].high > hi)
         hi = rr[i].high;
      if(lo <= 0.0 || rr[i].low < lo)
         lo = rr[i].low;
   }
   if(hi <= 0.0 || lo <= 0.0 || hi <= lo)
   {
      why = "orb_bad_range_values";
      return false;
   }
   g_orb_high = hi;
   g_orb_low = lo;
   int range_pts = (_Point > 0.0 ? (int)MathRound((g_orb_high - g_orb_low) / _Point) : 0);
   if(range_pts < MinORBRangePoints || range_pts > MaxORBRangePoints)
   {
      why = StringFormat("orb_range_out_of_bounds:%d", range_pts);
      return false;
   }
   g_orb_ready = true;
   return true;
}

void UpdateORB()
{
   if(!UseORB)
      return;
   datetime day = DayStartGMT();
   if(g_orb_session_day != day)
      ResetORBForDay();
   if(g_orb_ready)
      return;
   datetime now = TimeGMT();
   if(now < g_orb_window_start)
      return;
   if(now > g_orb_window_end)
   {
      // If EA was attached after the ORB window, we may not have built g_orb_high/low in real-time.
      // Reconstruct from historical M1 bars for this session.
      if(g_orb_high <= 0.0 || g_orb_low <= 0.0)
      {
         string why = "";
         bool ok = BuildORBFromHistory(why);
         if(EnableDebugPrint)
            Print("v4 orb build from history ok=", (ok ? "1" : "0"), " why=", why);
      }
      else if(_Point > 0.0)
      {
         int range_pts = (int)MathRound((g_orb_high - g_orb_low) / _Point);
         if(range_pts >= MinORBRangePoints && range_pts <= MaxORBRangePoints)
            g_orb_ready = true;
      }
      return;
   }
   MqlRates r0[];
   ArraySetAsSeries(r0, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 1, r0) < 1)
      return;
   if(g_orb_high <= 0.0 || r0[0].high > g_orb_high)
      g_orb_high = r0[0].high;
   if(g_orb_low <= 0.0 || r0[0].low < g_orb_low)
      g_orb_low = r0[0].low;
}

bool ORBWindowActive()
{
   if(!UseORB)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.hour < ORBStartHourGMT || dt.hour >= ORBEndHourGMT)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Trend filter                                                     |
//+------------------------------------------------------------------+
bool GetM5Trend(
   bool &bull,
   bool &bear,
   double &ema20,
   double &ema50,
   double &rsi,
   double &adx
)
{
   bull = false;
   bear = false;
   ema20 = 0.0;
   ema50 = 0.0;
   rsi = 0.0;
   adx = 0.0;

   if(!CopyValue(h_m5_ema20, 0, 1, ema20))
      return false;
   if(!CopyValue(h_m5_ema50, 0, 1, ema50))
      return false;
   if(!CopyValue(h_m5_rsi14, 0, 1, rsi))
      return false;
   if(!CopyValue(h_m5_adx14, 0, 1, adx))
      return false;

   double close5 = 0.0;
   if(!CopyClose(PERIOD_M5, 1, close5))
      return false;

   if(adx < MinM5ADX)
      return true;
   bull = (ema20 > ema50 && close5 > ema20 && rsi > 50.0);
   bear = (ema20 < ema50 && close5 < ema20 && rsi < 50.0);
   return true;
}

//+------------------------------------------------------------------+
//| M1 trigger                                                       |
//+------------------------------------------------------------------+
bool M1Trigger(int &sig, double &ema9, double &ema21, double &rsi, double &body_ratio)
{
   sig = 0;
   ema9 = 0.0;
   ema21 = 0.0;
   rsi = 0.0;
   body_ratio = 0.0;

   if(!CopyValue(h_m1_ema9, 0, 1, ema9))
      return false;
   if(!CopyValue(h_m1_ema21, 0, 1, ema21))
      return false;
   if(!CopyValue(h_m1_rsi14, 0, 1, rsi))
      return false;

   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, rr) < 1)
      return false;

   double o = rr[0].open;
   double c = rr[0].close;
   double h = rr[0].high;
   double l = rr[0].low;
   double rng = (h - l);
   if(rng > 0.0)
      body_ratio = MathAbs(c - o) / rng;
   else
      body_ratio = 0.0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;

   if(ema9 > ema21 && mid > ema9 && c > o && rsi > 52.0 && body_ratio >= MinBodyRatio)
      sig = 1;
   else if(ema9 < ema21 && mid < ema9 && c < o && rsi < 48.0 && body_ratio >= MinBodyRatio)
      sig = -1;
   else
      sig = 0;
   return true;
}

//+------------------------------------------------------------------+
//| Position management                                              |
//+------------------------------------------------------------------+
int OpenPositionsTotalEA()
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      count++;
   }
   return count;
}

void ManagePositions()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double cur = (type == POSITION_TYPE_BUY ? bid : ask);
      double profitPts = 0.0;
      if(point > 0.0)
      {
         if(type == POSITION_TYPE_BUY)
            profitPts = (cur - open_price) / point;
         else
            profitPts = (open_price - cur) / point;
      }

      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
      if(MaxHoldSeconds > 0 && (TimeCurrent() - open_time) >= MaxHoldSeconds && profitPts < (double)MaxHoldMinProfitPts)
      {
         g_trade.PositionClose(ticket);
         continue;
      }

      if(BreakEvenAfterPts > 0 && profitPts >= (double)BreakEvenAfterPts)
      {
         double be = open_price;
         if(type == POSITION_TYPE_BUY)
            be = open_price + BreakEvenPlusPts * point;
         else
            be = open_price - BreakEvenPlusPts * point;
         be = NormalizeDouble(be, digits);
         bool move = false;
         if(type == POSITION_TYPE_BUY && (sl <= 0.0 || sl < be - 0.5 * point))
            move = true;
         if(type == POSITION_TYPE_SELL && (sl <= 0.0 || sl > be + 0.5 * point))
            move = true;
         if(move)
         {
            double newTp = tp;
            if(EnableTP2 && point > 0.0)
            {
               if(type == POSITION_TYPE_BUY)
                  newTp = NormalizeDouble(open_price + TP2_Points * point, digits);
               else
                  newTp = NormalizeDouble(open_price - TP2_Points * point, digits);
            }
            g_trade.PositionModify(ticket, be, newTp);
         }
      }

      if(TrailStartPts > 0 && TrailDistancePts > 0 && profitPts >= (double)TrailStartPts)
      {
         double trail = 0.0;
         if(type == POSITION_TYPE_BUY)
            trail = NormalizeDouble(bid - TrailDistancePts * point, digits);
         else
            trail = NormalizeDouble(ask + TrailDistancePts * point, digits);
         bool move = false;
         if(type == POSITION_TYPE_BUY && (sl <= 0.0 || trail > sl + 0.5 * point))
            move = true;
         if(type == POSITION_TYPE_SELL && (sl <= 0.0 || trail < sl - 0.5 * point))
            move = true;
         if(move)
         {
            double newTp2 = tp;
            if(EnableTP2 && point > 0.0)
            {
               if(type == POSITION_TYPE_BUY)
                  newTp2 = NormalizeDouble(open_price + TP2_Points * point, digits);
               else
                  newTp2 = NormalizeDouble(open_price - TP2_Points * point, digits);
            }
            g_trade.PositionModify(ticket, trail, newTp2);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Bar helpers                                                      |
//+------------------------------------------------------------------+
bool NewM1Bar()
{
   static datetime last = 0;
   datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 <= 0)
      return false;
   if(last == 0)
   {
      last = t0;
      return false;
   }
   if(t0 != last)
   {
      last = t0;
      return true;
   }
   return false;
}

bool ShouldSkipFirstSeconds()
{
   datetime bar_open = iTime(_Symbol, PERIOD_M1, 0);
   if(bar_open <= 0)
      return false;
   int sec_in = (int)(TimeCurrent() - bar_open);
   return (sec_in < MinSecondsAfterBarOpen);
}

bool TradesTodayOk()
{
   datetime now = TimeCurrent();
   datetime day_start = DayStartGMT();
   if(!HistorySelect(day_start, now))
      return true;
   int count = 0;
   int deals = (int)HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      long mg = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
      if((int)mg != MagicNumber)
         continue;
      string sym = (string)HistoryDealGetString(deal, DEAL_SYMBOL);
      if(sym != _Symbol)
         continue;
      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         count++;
   }
   return (count < MaxTradesPerDay);
}

void UpdateLossStreak()
{
   static datetime lastCheck = 0;
   datetime now = TimeCurrent();
   datetime from = (lastCheck > 0 ? lastCheck : (now - 3 * 24 * 60 * 60));
   if(!HistorySelect(from, now))
   {
      lastCheck = now;
      return;
   }
   int deals = (int)HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(lastCheck > 0 && t <= lastCheck)
         continue;
      long mg = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
      if((int)mg != MagicNumber)
         continue;
      string sym = (string)HistoryDealGetString(deal, DEAL_SYMBOL);
      if(sym != _Symbol)
         continue;
      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT)
         continue;
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                    + HistoryDealGetDouble(deal, DEAL_SWAP);
      if(profit < 0.0)
         g_loss_streak++;
      else if(profit > 0.0)
         g_loss_streak = 0;
   }
   lastCheck = now;
}

bool ComputeORBSignal(const double close1, int &sig, string &reason)
{
   sig = 0;
   reason = "";
   if(!UseORB || !g_orb_ready)
      return true;
   if(!ORBWindowActive())
      return true;
   if(g_orb_trades_today >= MaxORBTradesPerDay)
      return true;
   double up = g_orb_high + ORBBufferPoints * _Point;
   double dn = g_orb_low - ORBBufferPoints * _Point;
   if(close1 > up)
   {
      sig = 1;
      reason = "orb_break_up";
   }
   else if(close1 < dn)
   {
      sig = -1;
      reason = "orb_break_dn";
   }
   return true;
}

bool ComputeVWAPSignal(const int m1_sig, const bool bull, const bool bear, const double mid, int &sig, string &reason)
{
   sig = 0;
   reason = "";
   if(!UseVWAPTrend)
      return true;
   if(g_vwap <= 0.0)
      return true;
   int dist = DistanceFromVWAPPoints(mid);
   if(dist > MaxDistanceFromVWAPPoints)
   {
      reason = "too_far_from_vwap";
      return true;
   }
   if(m1_sig == 1 && mid > g_vwap && (!UseM5TrendFilter || bull))
   {
      sig = 1;
      reason = "vwap_trend_buy";
   }
   else if(m1_sig == -1 && mid < g_vwap && (!UseM5TrendFilter || bear))
   {
      sig = -1;
      reason = "vwap_trend_sell";
   }
   return true;
}

bool RangeFadeSignal(
   const double m5_adx,
   const double body_ratio,
   int &sig,
   string &reason
)
{
   sig = 0;
   reason = "";
   if(!UseRangeFade)
      return true;
   if(m5_adx >= RangeFadeMaxM5ADX)
      return true;
   if(g_vwap <= 0.0)
      return true;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;
   int dist_pts = DistanceFromVWAPPoints(mid);
   if(dist_pts < RangeVWAPBandPoints)
      return true;

   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, rr) < 1)
      return true;
   double o = rr[0].open;
   double c = rr[0].close;
   double h = rr[0].high;
   double l = rr[0].low;
   double rng = (h - l);
   if(rng <= 0.0)
      return true;

   double upper_wick = h - MathMax(o, c);
   double lower_wick = MathMin(o, c) - l;
   double wick_ratio = MathMax(upper_wick, lower_wick) / rng;

   if(l < (g_vwap - RangeVWAPBandPoints * _Point) && c > o && wick_ratio >= MinWickRatio && body_ratio >= MinBodyRatio)
   {
      sig = 1;
      reason = "range_fade_buy";
   }
   else if(h > (g_vwap + RangeVWAPBandPoints * _Point) && c < o && wick_ratio >= MinWickRatio && body_ratio >= MinBodyRatio)
   {
      sig = -1;
      reason = "range_fade_sell";
   }

   return true;
}

bool ExecuteTrade(
   const int dir,
   const string mode,
   const string reason,
   const double ema9,
   const double ema21,
   const double rsi,
   const int spread_pts,
   const double m5_ema20,
   const double m5_ema50,
   const double m5_rsi,
   const double m5_adx
)
{
   string iso = ToISO(TimeGMT());
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   ENUM_ORDER_TYPE otype = (dir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double entry = (dir == 1 ? ask : bid);
   double vol = ChooseVolume();

   int sl_pts = SL_Points;
   int tp_pts = (EnableTP2 ? TP2_Points : TP_Points);
   int be_after = BreakEvenAfterPts;
   int tr_start = TrailStartPts;
   int tr_dist = TrailDistancePts;

   if(mode == "RANGE")
   {
      sl_pts = RangeSL_Points;
      tp_pts = RangeTP_Points;
      be_after = RangeBEAfterPts;
      tr_start = RangeTrailStartPts;
      tr_dist = RangeTrailDistPts;
   }

   string why = "";
   if(!StopsOk(sl_pts, tp_pts, why))
   {
      LogTradeCSV(iso, "SKIP", (dir == 1 ? "BUY" : "SELL"), vol, entry, 0.0, 0.0, 0.0, why);
      g_last_skip = why;
      return false;
   }

   if(!MoneyRiskOkOrAdjust(otype, vol, entry, sl_pts, why))
   {
      LogTradeCSV(iso, "SKIP", (dir == 1 ? "BUY" : "SELL"), vol, entry, 0.0, 0.0, 0.0, why);
      g_last_skip = why;
      return false;
   }

   double sl = (dir == 1 ? entry - sl_pts * point : entry + sl_pts * point);
   double tp = (dir == 1 ? entry + tp_pts * point : entry - tp_pts * point);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(!MarginOk(otype, vol, entry, why))
   {
      LogTradeCSV(iso, "SKIP", (dir == 1 ? "BUY" : "SELL"), vol, entry, sl, tp, 0.0, why);
      g_last_skip = why;
      return false;
   }

   if(!OrderCheckDeal(otype, vol, entry, sl, tp, why))
   {
      LogTradeCSV(iso, "OPEN_FAIL", (dir == 1 ? "BUY" : "SELL"), vol, entry, sl, tp, 0.0, why);
      g_last_skip = why;
      return false;
   }

   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   bool ok = false;
   if(dir == 1)
      ok = g_trade.Buy(vol, _Symbol, entry, sl, tp, mode + "|" + reason);
   else
      ok = g_trade.Sell(vol, _Symbol, entry, sl, tp, mode + "|" + reason);

   if(!ok)
   {
      string d = g_trade.ResultRetcodeDescription();
      LogTradeCSV(iso, "ORDER_FAIL", (dir == 1 ? "BUY" : "SELL"), vol, entry, sl, tp, 0.0, d);
      g_last_skip = d;
      return false;
   }

   ulong ticket = g_trade.ResultOrder();
   LogTradeCSV(iso, "OPEN", (dir == 1 ? "BUY" : "SELL"), vol, entry, sl, tp, 0.0, mode + "|" + reason);

   int dist_vwap = DistanceFromVWAPPoints(entry);
   LogMlCSV(
      iso,
      "OPEN",
      (long)ticket,
      (dir == 1 ? "BUY" : "SELL"),
      0.0,
      ema9,
      ema21,
      rsi,
      spread_pts,
      g_vwap,
      dist_vwap,
      m5_ema20,
      m5_ema50,
      m5_rsi,
      m5_adx,
      mode,
      g_orb_high,
      g_orb_low,
      reason
   );
   return true;
}

void UpdateDashboard(const int spread_pts, const bool m5_bull, const bool m5_bear, const double m5_adx)
{
   string trend = "NEUTRAL";
   if(m5_bull)
      trend = "BULL";
   else if(m5_bear)
      trend = "BEAR";

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;
   int dist = DistanceFromVWAPPoints(mid);

   double dd = DailyDrawdownPct();
   string txt =
      "GoldScalper_Aggressive_v4_VWAP_ORB\n" +
      "Mode: " + g_last_mode + "\n" +
      "VWAP: " + DoubleToString(g_vwap, 2) +
      " | dist_pts: " + (string)dist +
      " / max " + (string)MaxDistanceFromVWAPPoints + "\n" +
      "M5 trend: " + trend + " | ADX: " + DoubleToString(m5_adx, 1) + "\n" +
      "ORB: " + (g_orb_ready ? "READY" : "BUILDING") +
      " | H: " + DoubleToString(g_orb_high, 2) +
      " L: " + DoubleToString(g_orb_low, 2) +
      " | trades: " + (string)g_orb_trades_today + "/" + (string)MaxORBTradesPerDay + "\n" +
      "Spread: " + (string)spread_pts + " / max " + (string)SpreadLimit +
      (spread_pts > SpreadLimit ? "  BLOCKED\n" : "\n") +
      "Daily DD: " + DoubleToString(dd, 2) + "% / " + DoubleToString(MaxDailyLossPercent, 2) + "%\n" +
      "Open EA trades: " + (string)OpenPositionsTotalEA() + " / " + (string)MaxTrades + "\n" +
      "Last signal: " + g_last_signal + "\n" +
      "Last skip: " + g_last_skip + "\n";
   Comment(txt);
}

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_day_key = "";
   CheckDailyReset();
   ResetORBForDay();
   UpdateVWAP();
   if(UseORB && TimeGMT() > g_orb_window_end)
   {
      string why = "";
      bool ok = BuildORBFromHistory(why);
      if(EnableDebugPrint)
         Print("v4 init orb build ok=", (ok ? "1" : "0"), " why=", why);
   }

   h_m1_ema9 = iMA(_Symbol, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
   h_m1_ema21 = iMA(_Symbol, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
   h_m1_rsi14 = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);

   h_m5_ema20 = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   h_m5_ema50 = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   h_m5_rsi14 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   h_m5_adx14 = iADX(_Symbol, PERIOD_M5, 14);

   if(h_m1_ema9 == INVALID_HANDLE || h_m1_ema21 == INVALID_HANDLE || h_m1_rsi14 == INVALID_HANDLE)
      return INIT_FAILED;
   if(h_m5_ema20 == INVALID_HANDLE || h_m5_ema50 == INVALID_HANDLE || h_m5_rsi14 == INVALID_HANDLE || h_m5_adx14 == INVALID_HANDLE)
      return INIT_FAILED;

   EnsureMlHeader();
   WriteHeaderIfNeeded(TradeLogCsv, "time,symbol,event,side,volume,price,sl,tp,profit,reason\n");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   if(h_m1_ema9 != INVALID_HANDLE) IndicatorRelease(h_m1_ema9);
   if(h_m1_ema21 != INVALID_HANDLE) IndicatorRelease(h_m1_ema21);
   if(h_m1_rsi14 != INVALID_HANDLE) IndicatorRelease(h_m1_rsi14);
   if(h_m5_ema20 != INVALID_HANDLE) IndicatorRelease(h_m5_ema20);
   if(h_m5_ema50 != INVALID_HANDLE) IndicatorRelease(h_m5_ema50);
   if(h_m5_rsi14 != INVALID_HANDLE) IndicatorRelease(h_m5_rsi14);
   if(h_m5_adx14 != INVALID_HANDLE) IndicatorRelease(h_m5_adx14);
}

void OnTick()
{
   CheckDailyReset();
   UpdateORB();
   UpdateVWAP();
   ManagePositions();

   int spread_pts = SpreadPoints();
   bool bull = false;
   bool bear = false;
   double m5_ema20 = 0.0, m5_ema50 = 0.0, m5_rsi = 0.0, m5_adx = 0.0;
   GetM5Trend(bull, bear, m5_ema20, m5_ema50, m5_rsi, m5_adx);

   UpdateDashboard(spread_pts, bull, bear, m5_adx);

   datetime bar0 = iTime(_Symbol, PERIOD_M1, 0);
   if(bar0 <= 0)
      return;
   if(bar0 != g_active_bar_time)
   {
      g_active_bar_time = bar0;
      g_bar_evaluated = false;
   }

   if(g_bar_evaluated)
      return;

   int sec_in = (int)(TimeCurrent() - bar0);
   if(sec_in < MinSecondsAfterBarOpen)
   {
      g_last_skip = "waiting_after_bar_open";
      return;
   }
   g_bar_evaluated = true;

   UpdateLossStreak();

   if(!DailyLossOk())
   {
      g_last_skip = "daily_loss_limit";
      return;
   }
   if(g_loss_streak >= MaxConsecutiveLosses)
   {
      g_last_skip = "loss_streak_limit";
      return;
   }
   if(!TradesTodayOk())
   {
      g_last_skip = "max_trades_per_day";
      return;
   }
   if(spread_pts > SpreadLimit)
   {
      g_last_skip = "spread_limit";
      return;
   }
   datetime now = TimeCurrent();
   if(g_last_trade_time > 0 && (now - g_last_trade_time) < CooldownSeconds)
   {
      g_last_skip = "cooldown";
      return;
   }
   if(OpenPositionsTotalEA() >= MaxTrades)
   {
      g_last_skip = "max_open_trades";
      return;
   }

   int m1_sig = 0;
   double ema9 = 0.0, ema21 = 0.0, rsi = 0.0, body_ratio = 0.0;
   if(!M1Trigger(m1_sig, ema9, ema21, rsi, body_ratio))
   {
      g_last_skip = "indicator_read_failed";
      DebugPrintDecision("v4 skip indicator_read_failed", spread_pts, bull, bear, m5_adx, m1_sig, ema9, ema21, rsi, body_ratio, 0.0);
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;
   double close1 = 0.0;
   CopyClose(PERIOD_M1, 1, close1);

   int dir = 0;
   string mode = "NONE";
   string reason = "";

   int orb_sig = 0;
   string orb_reason = "";
   ComputeORBSignal(close1, orb_sig, orb_reason);
   if(UseORB && orb_sig != 0)
   {
      dir = orb_sig;
      mode = "ORB";
      reason = orb_reason;
   }

   if(dir == 0)
   {
      int vwap_sig = 0;
      string vwap_reason = "";
      ComputeVWAPSignal(m1_sig, bull, bear, mid, vwap_sig, vwap_reason);
      if(vwap_sig != 0)
      {
         dir = vwap_sig;
         mode = "VWAP_TREND";
         reason = vwap_reason;
      }
   }

   if(dir == 0)
   {
      int r_sig = 0;
      string r_reason = "";
      RangeFadeSignal(m5_adx, body_ratio, r_sig, r_reason);
      if(r_sig != 0)
      {
         dir = r_sig;
         mode = "RANGE";
         reason = r_reason;
      }
   }

   if(dir == 0)
   {
      g_last_signal = "HOLD";
      g_last_mode = "NONE";
      // Provide a more actionable reason for the dashboard/logs.
      if(UseORB && !g_orb_ready)
         g_last_skip = "orb_not_ready";
      else if(UseORB && g_orb_ready && !ORBWindowActive())
         g_last_skip = "orb_outside_window";
      else if(UseVWAPTrend && g_vwap <= 0.0)
         g_last_skip = "vwap_not_ready";
      else if(UseVWAPTrend && g_vwap > 0.0 && DistanceFromVWAPPoints(mid) > MaxDistanceFromVWAPPoints)
         g_last_skip = "vwap_too_far";
      else if(m1_sig == 0)
         g_last_skip = "m1_trigger_false";
      else if(UseM5TrendFilter && !(bull || bear))
         g_last_skip = "m5_trend_neutral";
      else
         g_last_skip = "no_setup";
      DebugPrintDecision("v4 skip "+g_last_skip, spread_pts, bull, bear, m5_adx, m1_sig, ema9, ema21, rsi, body_ratio, mid);
      return;
   }

   if(dir == 1 && BuyBlockedNowGMT())
   {
      g_last_signal = "HOLD";
      g_last_mode = mode;
      g_last_skip = "buy_block_window";
      return;
   }

   if(UseM5TrendFilter)
   {
      if(dir == 1 && !bull)
      {
         g_last_skip = "m5_not_bull";
         return;
      }
      if(dir == -1 && !bear)
      {
         g_last_skip = "m5_not_bear";
         return;
      }
   }

   if(mode == "VWAP_TREND")
   {
      int dist = DistanceFromVWAPPoints(mid);
      if(dist > MaxDistanceFromVWAPPoints)
      {
         g_last_skip = "vwap_dist_limit";
         return;
      }
   }

   bool ok = ExecuteTrade(dir, mode, reason, ema9, ema21, rsi, spread_pts, m5_ema20, m5_ema50, m5_rsi, m5_adx);
   if(ok)
   {
      g_last_trade_time = TimeCurrent();
      g_last_signal = (dir == 1 ? "BUY" : "SELL");
      g_last_mode = mode;
      g_last_skip = "";
      if(mode == "ORB")
         g_orb_trades_today++;
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   ulong deal = trans.deal;
   if(deal == 0)
      return;
   if(!HistoryDealSelect(deal))
      return;

   long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
   if((int)magic != MagicNumber)
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
   double price = HistoryDealGetDouble(deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(deal, DEAL_SWAP);

   string iso = ToISO(TimeGMT());
   double net = profit + commission + swap;
   LogTradeCSV(iso, "CLOSE", side, volume, price, 0.0, 0.0, net, "deal_close");

   double ema9 = 0.0, ema21 = 0.0, rsi = 0.0, body_ratio = 0.0;
   int m1_sig = 0;
   M1Trigger(m1_sig, ema9, ema21, rsi, body_ratio);

   int spread_pts = SpreadPoints();
   bool bull = false, bear = false;
   double m5_ema20 = 0.0, m5_ema50 = 0.0, m5_rsi = 0.0, m5_adx = 0.0;
   GetM5Trend(bull, bear, m5_ema20, m5_ema50, m5_rsi, m5_adx);

   int dist_vwap = DistanceFromVWAPPoints(price);
   long pos_id = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   LogMlCSV(
      iso,
      "CLOSE",
      pos_id,
      side,
      net,
      ema9,
      ema21,
      rsi,
      spread_pts,
      g_vwap,
      dist_vwap,
      m5_ema20,
      m5_ema50,
      m5_rsi,
      m5_adx,
      g_last_mode,
      g_orb_high,
      g_orb_low,
      "deal_close"
   );
}

