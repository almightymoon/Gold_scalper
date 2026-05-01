//+------------------------------------------------------------------+
//| GoldScalper_Aggressive_v3.mq5                                    |
//| Aggressive M1 micro-scalping EA (XAUUSD-optimized)               |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>

// -----------------------------------
// INPUTS
// -----------------------------------
input int    MagicNumber          = 20260501;
input double RiskPercent          = 0.5;     // present per requirements (not used for lot sizing)
input int    TP_Points            = 25;
input int    SL_Points            = 50;
input int    MaxTrades            = 3;
input int    SpreadLimit          = 60; // Gold often exceeds 60 pts on demo; raise if chart shows spread BLOCKED
input int    MaxLossStreak        = 3;
input double MaxDailyLossPercent  = 5.0;
input int    CooldownSeconds      = 5;

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
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
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

int GetSignal()
{
   // Use CLOSED candle (shift=1) for candle direction and indicator reads
   double ema9 = 0.0, ema21 = 0.0, rsi = 0.0;
   if(!CopyValue(hEma9, 0, 1, ema9))  return 0;
   if(!CopyValue(hEma21, 0, 1, ema21)) return 0;
   if(!CopyValue(hRsi14, 0, 1, rsi))  return 0;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 2, rates) < 2)
      return 0;

   double lastOpen  = rates[0].open;
   double lastClose = rates[0].close;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;

   // BUY conditions
   if(ema9 > ema21 && mid > ema9 && lastClose > lastOpen && rsi > 52.0)
      return 1;

   // SELL conditions
   if(ema9 < ema21 && mid < ema9 && lastClose < lastOpen && rsi < 48.0)
      return -1;

   return 0;
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

void OpenTrade(const int signal)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

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
               " freeMargin=", DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN), 2));
         return;
      }
      double sl = NormalizeDouble(ask - SL_Points * _Point, digits);
      double tp = NormalizeDouble(ask + TP_Points * _Point, digits);
      bool ok = trade.Buy(vol, _Symbol, ask, sl, tp, "Aggressive_v3");
      if(ok)
      {
         lastTradeTime = TimeCurrent();
         g_status_line = "BUY opened OK";
         Print("BUY opened vol=", DoubleToString(vol, 2), " SLpts=", SL_Points, " TPpts=", TP_Points);
      }
      else
      {
         g_status_line = "BUY failed: " + trade.ResultRetcodeDescription();
         Print("BUY failed retcode=", (int)trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
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
               " freeMargin=", DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN), 2));
         return;
      }
      double sl = NormalizeDouble(bid + SL_Points * _Point, digits);
      double tp = NormalizeDouble(bid - TP_Points * _Point, digits);
      bool ok = trade.Sell(vol, _Symbol, bid, sl, tp, "Aggressive_v3");
      if(ok)
      {
         lastTradeTime = TimeCurrent();
         g_status_line = "SELL opened OK";
         Print("SELL opened vol=", DoubleToString(vol, 2), " SLpts=", SL_Points, " TPpts=", TP_Points);
      }
      else
      {
         g_status_line = "SELL failed: " + trade.ResultRetcodeDescription();
         Print("SELL failed retcode=", (int)trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription());
      }
      return;
   }
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

   int sig = GetSignal();
   if(sig == 0)
   {
      g_status_line = "SKIP: no EMA/RSI signal this bar";
      Print("Skip: no signal");
      UpdateChartComment(spreadPts);
      return;
   }

   g_status_line = (sig == 1 ? "Opening BUY..." : "Opening SELL...");
   UpdateChartComment(spreadPts);
   OpenTrade(sig);
   UpdateChartComment(spreadPts);
}

