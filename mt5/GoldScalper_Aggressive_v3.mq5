//+------------------------------------------------------------------+
//| GoldScalper_Aggressive_v3.mq5                                    |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

// Aggressive M1 micro-scalping EA (XAUUSD-optimized).

// -----------------------------------
// INPUTS
// -----------------------------------
input int    MagicNumber          = 20260501;
input double RiskPercent          = 0.5;     // present per requirements (not used for lot sizing)
input int    TP_Points            = 25;     // TP1
input int    TP2_Points           = 60;     // TP2 (runner)
input int    SL_Points            = 120;    // wider initial SL to avoid early whipsaw
input bool   EnableTP2            = true;
input double TP1_PartialClosePct  = 60.0;   // close this % at TP1, keep rest for TP2 (0 disables)
input int    BreakEvenAfterPts    = 20;     // once in profit by this many points, move SL to entry
input int    BreakEvenPlusPts     = 2;      // extra points beyond entry when moving to BE
input int    TrailStartPts        = 35;     // start trailing after this profit (points)
input int    TrailDistancePts     = 20;     // keep SL this far behind price (points)
input int    MaxTrades            = 5;      // total concurrent positions this EA may hold
input int    TypicalEntriesPerSignal = 5;   // desired stack size on strong signals (capped by MaxTrades)
input int    MinEntriesPerSignal  = 1;      // weak signals still take at least 1 trade
input double StrongRsiBoost       = 6.0;    // extra RSI distance beyond threshold to scale up entries
input int    StrongEmaGapPoints   = 25;     // EMA gap (points) to scale up entries
input int    SpreadLimit          = 60; // Gold often exceeds 60 pts on demo; raise if chart shows spread BLOCKED
input int    MaxLossStreak        = 3;
input double MaxDailyLossPercent  = 5.0;
input int    CooldownSeconds      = 5;
input bool   EnableTradeLog       = true;
input bool   TradeLogToCommonFolder = true; // true = Common\\Files (shared, easiest for python); false = this terminal MQL5\\Files (Open Data Folder)
input string TradeLogCsv          = "trades_aggressive_v3.csv";
input bool   EnableMlLog          = true;
input string MlLogCsv             = "trades_aggressive_v3_ml.csv"; // ML-ready log with indicators + position_id

// -----------------------------------
// GLOBALS
// -----------------------------------
int      lossStreak    = 0;
datetime lastTradeTime = 0;
double   startBalance  = 0.0;

// Trade object
CTrade trade;

// Indicator handles (PERIOD_M1)
int hEma9  = INVALID_HANDLE;
int hEma21 = INVALID_HANDLE;
int hRsi14 = INVALID_HANDLE;

string g_status_line = "starting";

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string ToISO(datetime t)
{
   // Converts "YYYY.MM.DD HH:MI:SS" -> "YYYY-MM-DDTHH:MI:SSZ"
   string s = TimeToString(t, TIME_DATE|TIME_SECONDS);
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return s + "Z";
}

string CsvEscape(const string s)
{
   string out = s;
   StringReplace(out, "\"", "\"\"");
   return "\"" + out + "\"";
}

int TradeLogDiskFlags()
{
   return TradeLogToCommonFolder ? FILE_COMMON : 0;
}

string TradeLogResolvedHint()
{
   if(TradeLogToCommonFolder)
      return "[COMMON] Files\\" + TradeLogCsv + "  -> MT5: File -> Open Common Data Folder -> Files";
   string root = TerminalInfoString(TERMINAL_DATA_PATH);
   return root + "\\MQL5\\Files\\" + TradeLogCsv + "  -> MT5: File -> Open Data Folder -> MQL5 -> Files";
}

string LogResolvedHintFor(const string filename)
{
   if(TradeLogToCommonFolder)
      return "[COMMON] Files\\" + filename + "  -> MT5: File -> Open Common Data Folder -> Files";
   string root = TerminalInfoString(TERMINAL_DATA_PATH);
   return root + "\\MQL5\\Files\\" + filename + "  -> MT5: File -> Open Data Folder -> MQL5 -> Files";
}

bool WriteCSVHeaderIfNeeded(const string csv_file, const string header_line)
{
   int h = FileOpen(csv_file, FILE_READ|FILE_WRITE|FILE_CSV|TradeLogDiskFlags(), ',');
   if(h == INVALID_HANDLE)
   {
      h = FileOpen(csv_file, FILE_WRITE|FILE_CSV|TradeLogDiskFlags(), ',');
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

void LogTradeEvent(const string iso_time, const string sym, const string event, const string side, double volume, double price, double sl, double tp, double profit, const string reason)
{
   if(!EnableTradeLog) return;
   if(!WriteCSVHeaderIfNeeded(TradeLogCsv, "time,symbol,event,side,volume,price,sl,tp,profit,reason\n"))
   {
      Print("Trade log: header/create FAILED file=", TradeLogCsv, " err=", GetLastError(), " hint=", TradeLogResolvedHint());
      return;
   }
   int h = FileOpen(TradeLogCsv, FILE_READ|FILE_WRITE|FILE_TXT|TradeLogDiskFlags());
   if(h == INVALID_HANDLE)
   {
      Print("Trade log: open FAILED file=", TradeLogCsv, " err=", GetLastError(), " hint=", TradeLogResolvedHint());
      return;
   }
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat("%s,%s,%s,%s,%.2f,%.5f,%.5f,%.5f,%.2f,%s\n",
                              iso_time, sym, event, side, volume, price, sl, tp, profit, CsvEscape(reason));
   FileWriteString(h, line);
   FileClose(h);
}

bool WriteMlHeaderIfNeeded()
{
   if(!EnableMlLog) return false;
   return WriteCSVHeaderIfNeeded(
      MlLogCsv,
      "time,symbol,event,position_id,deal_id,side,volume,price,sl,tp,ema9,ema21,rsi,spread_pts,profit,reason\n"
   );
}

void LogMlEvent(
   const string iso_time,
   const string sym,
   const string event,
   const long position_id,
   const long deal_id,
   const string side,
   const double volume,
   const double price,
   const double sl,
   const double tp,
   const double ema9,
   const double ema21,
   const double rsi,
   const int spread_pts,
   const double profit,
   const string reason
)
{
   if(!EnableMlLog) return;
   if(!WriteMlHeaderIfNeeded())
      return;
   int h = FileOpen(MlLogCsv, FILE_READ|FILE_WRITE|FILE_TXT|TradeLogDiskFlags());
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   string line = StringFormat(
      "%s,%s,%s,%I64d,%I64d,%s,%.2f,%.5f,%.5f,%.5f,%.5f,%.5f,%.2f,%d,%.2f,%s\n",
      iso_time, sym, event,
      (long)position_id, (long)deal_id,
      side, volume, price, sl, tp, ema9, ema21, rsi, spread_pts, profit, CsvEscape(reason)
   );
   FileWriteString(h, line);
   FileClose(h);
}

void EnsureTradeFillingMode()
{
   long fill = (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

void UpdateChartComment(const int spread_pts)
{
   double lossPct = 0.0;
   if(startBalance > 0.0)
      lossPct = (startBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / startBalance * 100.0;

   string txt =
      "GoldScalper_Aggressive_v3\n"
      "Spread(points): " + (string)spread_pts + " / max " + (string)SpreadLimit +
      (spread_pts > SpreadLimit ? "  <-- BLOCKED, raise SpreadLimit\n" : "\n") +
      "Open EA trades: " + (string)CountTrades() + " / " + (string)MaxTrades + "\n"
      "Loss streak: " + (string)lossStreak + " / " + (string)MaxLossStreak + "\n"
      "Daily DD approx: " + DoubleToString(lossPct, 2) + "% / max " + DoubleToString(MaxDailyLossPercent, 2) + "%\n"
      "Cooldown(s): " + (string)CooldownSeconds + "\n"
      "---\n"
      + g_status_line;
   Comment(txt);
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsNewM1Candle()
{
   static datetime lastBarTime = 0;
   datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   if(t0 <= 0)
      return false;
   if(lastBarTime == 0)
   {
      lastBarTime = t0;
      return false;
   }
   if(t0 != lastBarTime)
   {
      lastBarTime = t0;
      return true;
   }
   return false;
}

double NormalizeVolume(double vol)
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0)
      vstep = 0.01;

   // Clamp first
   vol = MathMax(vmin, MathMin(vmax, vol));

   // Step normalize
   double steps = MathFloor((vol - vmin) / vstep + 1e-9);
   double out = vmin + steps * vstep;
   out = MathMax(vmin, MathMin(vmax, out));

   // Digits from step
   int digits = 0;
   double s = vstep;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
   {
      s *= 10.0;
      digits++;
   }
   return NormalizeDouble(out, digits);
}

double LotSizeForBalance()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double vol = 0.01;
   if(bal < 50.0) vol = 0.01;
   else if(bal <= 100.0) vol = 0.02;
   else vol = 0.03;
   return NormalizeVolume(vol);
}

bool CanAffordVolume(const ENUM_ORDER_TYPE type, const double volume, const double price)
{
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin))
      return false;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return (margin > 0.0 && freeMargin >= margin);
}

double AffordableVolume(const ENUM_ORDER_TYPE type, const double desired, const double price)
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = 0.01;

   double vol = NormalizeVolume(desired);
   // Walk down by step until affordable or we hit min.
   for(int i = 0; i < 200; i++)
   {
      if(vol < vmin - 1e-12)
         break;
      if(CanAffordVolume(type, vol, price))
         return NormalizeVolume(vol);
      vol = vol - vstep;
   }
   return 0.0; // cannot afford even min lot
}

int CountTrades()
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
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol)
         continue;
      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if((int)mg != MagicNumber)
         continue;
      count++;
   }
   return count;
}

bool SpreadOk(int &out_spread_points)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(_Point <= 0.0)
   {
      out_spread_points = 0;
      return false;
   }
   int spread_pts = (int)MathRound((ask - bid) / _Point);
   out_spread_points = spread_pts;
   return (spread_pts <= SpreadLimit);
}

bool DailyLossOk(double &out_loss_percent)
{
   out_loss_percent = 0.0;
   if(startBalance <= 0.0)
      return true;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   out_loss_percent = (startBalance - eq) / startBalance * 100.0;
   return (out_loss_percent < MaxDailyLossPercent);
}

bool ModifyPositionSLTP(const ulong ticket, const double new_sl, const double new_tp)
{
   if(ticket == 0)
      return false;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.magic    = MagicNumber;
   req.sl       = new_sl;
   req.tp       = new_tp;

   if(!OrderSend(req, res))
      return false;
   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL);
}

double PointsProfitForPosition(const long type, const double open_price, const double bid, const double ask)
{
   if(_Point <= 0.0)
      return 0.0;
   // For BUY profit measured from bid; for SELL from ask
   if(type == POSITION_TYPE_BUY)
      return (bid - open_price) / _Point;
   if(type == POSITION_TYPE_SELL)
      return (open_price - ask) / _Point;
   return 0.0;
}

string GV_TP1DoneName(const ulong ticket)
{
   return "GSA3_TP1DONE_" + (string)MagicNumber + "_" + (string)ticket;
}

bool IsTP1Done(const ulong ticket)
{
   string n = GV_TP1DoneName(ticket);
   return GlobalVariableCheck(n) && GlobalVariableGet(n) > 0.5;
}

void MarkTP1Done(const ulong ticket)
{
   GlobalVariableSet(GV_TP1DoneName(ticket), 1.0);
}

void ManageOpenPositions()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) vstep = 0.01;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      double profitPts = PointsProfitForPosition(type, open_price, bid, ask);

      // TP1 partial close
      if(TP1_PartialClosePct > 0.0 && TP1_PartialClosePct < 100.0 && profitPts >= (double)TP_Points && !IsTP1Done(ticket))
      {
         double closeVol = NormalizeVolume(vol * (TP1_PartialClosePct / 100.0));
         // ensure we don't try to close below min step
         if(closeVol >= vmin + 1e-12 && closeVol < vol - 1e-12)
         {
            bool ok = trade.PositionClosePartial(ticket, closeVol);
            if(ok)
            {
               MarkTP1Done(ticket);
               Print("TP1 partial close ticket=", (string)ticket, " closeVol=", DoubleToString(closeVol, 2));
            }
            else
            {
               Print("TP1 partial close failed ticket=", (string)ticket, " retcode=", (int)trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
            }
         }
         else
         {
            // Can't partial-close cleanly (too small), mark done to avoid spam.
            MarkTP1Done(ticket);
         }
      }

      // Break-even move
      if(BreakEvenAfterPts > 0 && profitPts >= (double)BreakEvenAfterPts)
      {
         double be = open_price;
         if(type == POSITION_TYPE_BUY)  be = open_price + BreakEvenPlusPts * _Point;
         if(type == POSITION_TYPE_SELL) be = open_price - BreakEvenPlusPts * _Point;
         be = NormalizeDouble(be, digits);

         bool shouldMove = false;
         if(type == POSITION_TYPE_BUY && (sl <= 0.0 || sl < be - (_Point * 0.5))) shouldMove = true;
         if(type == POSITION_TYPE_SELL && (sl <= 0.0 || sl > be + (_Point * 0.5))) shouldMove = true;

         if(shouldMove)
         {
            double newTp = tp;
            // If TP2 enabled, keep TP at TP2 target.
            // If disabled, keep whatever TP is set.
            if(EnableTP2)
            {
               if(type == POSITION_TYPE_BUY)  newTp = NormalizeDouble(open_price + TP2_Points * _Point, digits);
               if(type == POSITION_TYPE_SELL) newTp = NormalizeDouble(open_price - TP2_Points * _Point, digits);
            }
            ModifyPositionSLTP(ticket, be, newTp);
         }
      }

      // Trailing stop (tighten once in profit)
      if(TrailStartPts > 0 && TrailDistancePts > 0 && profitPts >= (double)TrailStartPts)
      {
         double trail = 0.0;
         if(type == POSITION_TYPE_BUY)  trail = NormalizeDouble(bid - TrailDistancePts * _Point, digits);
         if(type == POSITION_TYPE_SELL) trail = NormalizeDouble(ask + TrailDistancePts * _Point, digits);

         bool shouldTrail = false;
         if(type == POSITION_TYPE_BUY && (sl <= 0.0 || trail > sl + (_Point * 0.5))) shouldTrail = true;
         if(type == POSITION_TYPE_SELL && (sl <= 0.0 || trail < sl - (_Point * 0.5))) shouldTrail = true;

         if(shouldTrail)
         {
            double newTp = tp;
            if(EnableTP2)
            {
               if(type == POSITION_TYPE_BUY)  newTp = NormalizeDouble(open_price + TP2_Points * _Point, digits);
               if(type == POSITION_TYPE_SELL) newTp = NormalizeDouble(open_price - TP2_Points * _Point, digits);
            }
            ModifyPositionSLTP(ticket, trail, newTp);
         }
      }
   }
}

bool CopyValue(int handle, int buffer, int shift, double &out)
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

bool GetSignalAndStrength(int &out_sig, int &out_entries)
{
   // Use CLOSED candle (shift=1) for candle direction and indicator reads
   double ema9 = 0.0, ema21 = 0.0, rsi = 0.0;
   out_sig = 0;
   out_entries = MinEntriesPerSignal;
   if(!CopyValue(hEma9, 0, 1, ema9))  return false;
   if(!CopyValue(hEma21, 0, 1, ema21)) return false;
   if(!CopyValue(hRsi14, 0, 1, rsi))  return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 2, rates) < 2)
      return false;

   double lastOpen  = rates[0].open;
   double lastClose = rates[0].close;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;

   // Strength heuristics (how far beyond thresholds we are).
   double emaGapPts = 0.0;
   if(_Point > 0.0)
      emaGapPts = MathAbs(ema9 - ema21) / _Point;

   // BUY conditions
   if(ema9 > ema21 && mid > ema9 && lastClose > lastOpen && rsi > 52.0)
   {
      out_sig = 1;
      double rsiBoost = MathMax(0.0, rsi - 52.0);
      int n = MinEntriesPerSignal;
      if(rsiBoost >= StrongRsiBoost) n++;
      if(emaGapPts >= (double)StrongEmaGapPoints) n++;
      if(rsiBoost >= StrongRsiBoost * 2.0) n++;
      if(emaGapPts >= (double)StrongEmaGapPoints * 2.0) n++;
      out_entries = (int)MathMax(MinEntriesPerSignal, MathMin((double)TypicalEntriesPerSignal, (double)n));
      return true;
   }

   // SELL conditions
   if(ema9 < ema21 && mid < ema9 && lastClose < lastOpen && rsi < 48.0)
   {
      out_sig = -1;
      double rsiBoost = MathMax(0.0, 48.0 - rsi);
      int n = MinEntriesPerSignal;
      if(rsiBoost >= StrongRsiBoost) n++;
      if(emaGapPts >= (double)StrongEmaGapPoints) n++;
      if(rsiBoost >= StrongRsiBoost * 2.0) n++;
      if(emaGapPts >= (double)StrongEmaGapPoints * 2.0) n++;
      out_entries = (int)MathMax(MinEntriesPerSignal, MathMin((double)TypicalEntriesPerSignal, (double)n));
      return true;
   }

   out_sig = 0;
   out_entries = MinEntriesPerSignal;
   return true;
}

void UpdateLossTracking()
{
   static datetime lastCheck = 0;
   datetime now = TimeCurrent();

   datetime from = (lastCheck > 0 ? lastCheck : (now - 7 * 24 * 60 * 60));
   if(from > now)
      from = now - 60;

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

      string sym = (string)HistoryDealGetString(deal, DEAL_SYMBOL);
      if(sym != _Symbol)
         continue;

      long mg = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
      if((int)mg != MagicNumber)
         continue;

      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT)
         continue;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                    + HistoryDealGetDouble(deal, DEAL_SWAP);

      if(profit < 0.0)
         lossStreak++;
      else if(profit > 0.0)
         lossStreak = 0;
   }

   lastCheck = now;
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
      why = StringFormat("OrderCheck failed (%d)", GetLastError());
      return false;
   }
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
      return false;
   }
   return true;
}

void OpenTradeOnce(const int signal)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string iso_time = ToISO(TimeGMT());
   int spreadPts = 0;
   if(_Point > 0.0)
      spreadPts = (int)MathRound((ask - bid) / _Point);

   // Snapshot indicators used for the decision (closed candle)
   double ema9 = 0.0, ema21 = 0.0, rsi = 0.0;
   CopyValue(hEma9, 0, 1, ema9);
   CopyValue(hEma21, 0, 1, ema21);
   CopyValue(hRsi14, 0, 1, rsi);

   if(_Point <= 0.0)
      return;

   if(signal == 1)
   {
      double desired = LotSizeForBalance();
      double vol = AffordableVolume(ORDER_TYPE_BUY, desired, ask);
      if(vol <= 0.0)
      {
         g_status_line = "SKIP: not enough free margin even for min lot";
         Print("Skip: not enough free margin for min lot. desired=", DoubleToString(desired, 2),
               " freeMargin=", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
         LogTradeEvent(iso_time, _Symbol, "SKIP", "BUY", desired, ask, 0.0, 0.0, 0.0, "not_enough_margin_min_lot");
         return;
      }
      double sl = NormalizeDouble(ask - SL_Points * _Point, digits);
      double tp = NormalizeDouble(ask + (EnableTP2 ? TP2_Points : TP_Points) * _Point, digits);
      string oc_why = "";
      if(!OrderCheckDeal(ORDER_TYPE_BUY, vol, ask, sl, tp, oc_why))
      {
         g_status_line = "BUY OrderCheck failed: " + oc_why;
         Print("BUY OrderCheck: ", oc_why);
         LogTradeEvent(iso_time, _Symbol, "OPEN_FAIL", "BUY", vol, ask, sl, tp, 0.0, oc_why);
         LogMlEvent(iso_time, _Symbol, "OPEN_FAIL", 0, 0, "BUY", vol, ask, sl, tp, ema9, ema21, rsi, spreadPts, 0.0, oc_why);
         return;
      }
      bool ok = trade.Buy(vol, _Symbol, ask, sl, tp, "Aggressive_v3");
      if(ok)
      {
         lastTradeTime = TimeCurrent();
         g_status_line = "BUY opened OK";
         Print("BUY opened vol=", DoubleToString(vol, 2), " SLpts=", SL_Points, " TPpts=", TP_Points);
         LogTradeEvent(iso_time, _Symbol, "OPEN", "BUY", vol, ask, sl, tp, 0.0, "opened");
         long deal_id = (long)trade.ResultDeal();
         long pos_id = 0;
         if(deal_id > 0 && HistoryDealSelect((ulong)deal_id))
            pos_id = (long)HistoryDealGetInteger((ulong)deal_id, DEAL_POSITION_ID);
         LogMlEvent(iso_time, _Symbol, "OPEN", pos_id, deal_id, "BUY", vol, ask, sl, tp, ema9, ema21, rsi, spreadPts, 0.0, "opened");
      }
      else
      {
         g_status_line = "BUY failed: " + trade.ResultRetcodeDescription();
         Print("BUY failed retcode=", (int)trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
         LogTradeEvent(iso_time, _Symbol, "OPEN_FAIL", "BUY", vol, ask, sl, tp, 0.0, trade.ResultRetcodeDescription());
         LogMlEvent(iso_time, _Symbol, "OPEN_FAIL", 0, (long)trade.ResultDeal(), "BUY", vol, ask, sl, tp, ema9, ema21, rsi, spreadPts, 0.0, trade.ResultRetcodeDescription());
      }
      return;
   }

   if(signal == -1)
   {
      double desired = LotSizeForBalance();
      double vol = AffordableVolume(ORDER_TYPE_SELL, desired, bid);
      if(vol <= 0.0)
      {
         g_status_line = "SKIP: not enough free margin even for min lot";
         Print("Skip: not enough free margin for min lot. desired=", DoubleToString(desired, 2),
               " freeMargin=", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
         LogTradeEvent(iso_time, _Symbol, "SKIP", "SELL", desired, bid, 0.0, 0.0, 0.0, "not_enough_margin_min_lot");
         return;
      }
      double sl = NormalizeDouble(bid + SL_Points * _Point, digits);
      double tp = NormalizeDouble(bid - (EnableTP2 ? TP2_Points : TP_Points) * _Point, digits);
      string oc_why = "";
      if(!OrderCheckDeal(ORDER_TYPE_SELL, vol, bid, sl, tp, oc_why))
      {
         g_status_line = "SELL OrderCheck failed: " + oc_why;
         Print("SELL OrderCheck: ", oc_why);
         LogTradeEvent(iso_time, _Symbol, "OPEN_FAIL", "SELL", vol, bid, sl, tp, 0.0, oc_why);
         LogMlEvent(iso_time, _Symbol, "OPEN_FAIL", 0, 0, "SELL", vol, bid, sl, tp, ema9, ema21, rsi, spreadPts, 0.0, oc_why);
         return;
      }
      bool ok = trade.Sell(vol, _Symbol, bid, sl, tp, "Aggressive_v3");
      if(ok)
      {
         lastTradeTime = TimeCurrent();
         g_status_line = "SELL opened OK";
         Print("SELL opened vol=", DoubleToString(vol, 2), " SLpts=", SL_Points, " TPpts=", TP_Points);
         LogTradeEvent(iso_time, _Symbol, "OPEN", "SELL", vol, bid, sl, tp, 0.0, "opened");
         long deal_id = (long)trade.ResultDeal();
         long pos_id = 0;
         if(deal_id > 0 && HistoryDealSelect((ulong)deal_id))
            pos_id = (long)HistoryDealGetInteger((ulong)deal_id, DEAL_POSITION_ID);
         LogMlEvent(iso_time, _Symbol, "OPEN", pos_id, deal_id, "SELL", vol, bid, sl, tp, ema9, ema21, rsi, spreadPts, 0.0, "opened");
      }
      else
      {
         g_status_line = "SELL failed: " + trade.ResultRetcodeDescription();
         Print("SELL failed retcode=", (int)trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
         LogTradeEvent(iso_time, _Symbol, "OPEN_FAIL", "SELL", vol, bid, sl, tp, 0.0, trade.ResultRetcodeDescription());
         LogMlEvent(iso_time, _Symbol, "OPEN_FAIL", 0, (long)trade.ResultDeal(), "SELL", vol, bid, sl, tp, ema9, ema21, rsi, spreadPts, 0.0, trade.ResultRetcodeDescription());
      }
      return;
   }
}

void OpenTrades(const int signal, const int count)
{
   int n = count;
   if(n < 1) n = 1;
   for(int i = 0; i < n; i++)
      OpenTradeOnce(signal);
}

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   EnsureTradeFillingMode();
   g_status_line = "Waiting next M1 bar (checks once per new candle)";
   Comment("GoldScalper_Aggressive_v3 loading...");

   // Indicators on M1
   hEma9  = iMA(_Symbol, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
   hEma21 = iMA(_Symbol, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
   hRsi14 = iRSI(_Symbol, PERIOD_M1, 14, PRICE_CLOSE);

   if(hEma9 == INVALID_HANDLE || hEma21 == INVALID_HANDLE || hRsi14 == INVALID_HANDLE)
   {
      Print("Indicator init failed. err=", GetLastError());
      return INIT_FAILED;
   }

   Print("GoldScalper_Aggressive_v3 initialized. startBalance=", DoubleToString(startBalance, 2));
   if(EnableTradeLog)
   {
      if(!WriteCSVHeaderIfNeeded(TradeLogCsv, "time,symbol,event,side,volume,price,sl,tp,profit,reason\n"))
         Print("Trade log: FAILED to create ", TradeLogCsv, " err=", GetLastError());
      else
         Print("Trade log (repo data/ is NOT used — MT5 folder only): ", TradeLogResolvedHint());
   }
   if(EnableMlLog)
   {
      if(!WriteMlHeaderIfNeeded())
         Print("ML log: FAILED to create ", MlLogCsv, " err=", GetLastError());
      else
         Print("ML log (for training): ", LogResolvedHintFor(MlLogCsv));
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   if(hEma9 != INVALID_HANDLE)  IndicatorRelease(hEma9);
   if(hEma21 != INVALID_HANDLE) IndicatorRelease(hEma21);
   if(hRsi14 != INVALID_HANDLE) IndicatorRelease(hRsi14);
}

void OnTick()
{
   // Manage existing positions every tick (BE / trailing / TP1 partial).
   ManageOpenPositions();

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int spreadPts = 0;
   if(_Point > 0.0)
      spreadPts = (int)MathRound((ask - bid) / _Point);

   if(!IsNewM1Candle())
   {
      g_status_line = "Waiting new M1 candle (logic runs once per bar)";
      UpdateChartComment(spreadPts);
      return;
   }

   g_status_line = "New M1 bar: evaluating...";
   UpdateChartComment(spreadPts);

   UpdateLossTracking();

   double lossPct = 0.0;
   if(!DailyLossOk(lossPct))
   {
      g_status_line = "SKIP: daily loss limit hit";
      Print("Skip: daily loss limit hit ", DoubleToString(lossPct, 2), "% >=", DoubleToString(MaxDailyLossPercent, 2), "%");
      UpdateChartComment(spreadPts);
      return;
   }

   if(!SpreadOk(spreadPts))
   {
      g_status_line = "SKIP: spread too high for SpreadLimit (increase input on Gold)";
      Print("Skip: spread too high ", (string)spreadPts, " > ", (string)SpreadLimit);
      UpdateChartComment(spreadPts);
      return;
   }

   if(lossStreak >= MaxLossStreak)
   {
      g_status_line = "SKIP: loss streak limit";
      Print("Skip: loss streak limit ", (string)lossStreak, " >= ", (string)MaxLossStreak);
      UpdateChartComment(spreadPts);
      return;
   }

   int openTrades = CountTrades();
   if(openTrades >= MaxTrades)
   {
      g_status_line = "SKIP: max positions open";
      Print("Skip: max trades reached ", (string)openTrades, " >= ", (string)MaxTrades);
      UpdateChartComment(spreadPts);
      return;
   }

   datetime now = TimeCurrent();
   if(lastTradeTime > 0 && (now - lastTradeTime) < CooldownSeconds)
   {
      g_status_line = "SKIP: cooldown";
      Print("Skip: cooldown ", (string)(now - lastTradeTime), "s < ", (string)CooldownSeconds, "s");
      UpdateChartComment(spreadPts);
      return;
   }

   int sig = 0;
   int desiredEntries = MinEntriesPerSignal;
   if(!GetSignalAndStrength(sig, desiredEntries))
   {
      g_status_line = "SKIP: indicator read failed";
      Print("Skip: indicator read failed err=", GetLastError());
      UpdateChartComment(spreadPts);
      return;
   }
   if(sig == 0)
   {
      g_status_line = "SKIP: no EMA/RSI signal this bar";
      Print("Skip: no signal");
      UpdateChartComment(spreadPts);
      return;
   }

   int openNow = CountTrades();
   int room = MaxTrades - openNow;
   int nOpen = (int)MathMax(1.0, MathMin((double)room, (double)desiredEntries));
   g_status_line = (sig == 1 ? "Signal BUY: opening " : "Signal SELL: opening ") + (string)nOpen + " / " + (string)desiredEntries;
   UpdateChartComment(spreadPts);
   OpenTrades(sig, nOpen);
   UpdateChartComment(spreadPts);
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(!EnableTradeLog) return;
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
   double price  = HistoryDealGetDouble(deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(deal, DEAL_SWAP);

   string iso_time = ToISO(TimeGMT());
   LogTradeEvent(iso_time, sym, "CLOSE", side, volume, price, 0.0, 0.0, (profit + commission + swap), "deal_close");

   // ML close row (match by position_id)
   long pos_id = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   LogMlEvent(iso_time, sym, "CLOSE", pos_id, (long)deal, side, volume, price, 0.0, 0.0, 0.0, 0.0, 0.0, 0, (profit + commission + swap), "deal_close");
}

