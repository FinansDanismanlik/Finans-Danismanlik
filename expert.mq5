#property strict

//========================
//  INPUTS
//========================
input double TickSizeInp   = 0.0001;
input double MinLotsInp    = 0.01;
input double LotStepInp    = 0.01;
input double DeviInp       = 500;

input int TF_Signal        = PERIOD_M5;
input int TF_Trend         = PERIOD_H1;

input int emaFastLen       = 20;
input int emaSlowLen       = 50;
input int rsiLength        = 14;
input int adxPeriod        = 14;
input double adxMinTrend   = 20.0;
input int atrLength        = 14;

input double ATR_SL_Mult   = 1.0;
input double ATR_TrailMult = 1.3;

input int MaxPerDirection  = 1;
input bool useSpreadFilter = true;
input double maxSpread     = 900.0;

input bool useFixedLots    = true;
input double fixedLots     = 0.03;

input ulong MagicNumber    = 56001;
input bool debugLogs       = false;

//========================
//  GLOBALS
//========================
int hFastSig, hSlowSig, hRSIsig, hATRsig, hADXsig;
int hFastHTF, hSlowHTF;
datetime lastBar = 0;
ENUM_TIMEFRAMES TFsig, TFhtf;

void DPrint(string s){ if(debugLogs) Print(s); }

//========================
//  INIT
//========================
int OnInit()
{
   TFsig  = (ENUM_TIMEFRAMES)TF_Signal;
   TFhtf  = (ENUM_TIMEFRAMES)TF_Trend;
   hFastSig = iMA(_Symbol,TFsig,emaFastLen,0,MODE_EMA,PRICE_CLOSE);
   hSlowSig = iMA(_Symbol,TFsig,emaSlowLen,0,MODE_EMA,PRICE_CLOSE);
   hRSIsig  = iRSI(_Symbol,TFsig,rsiLength,PRICE_CLOSE);
   hATRsig  = iATR(_Symbol,TFsig,atrLength);
   hADXsig  = iADX(_Symbol,TFsig,adxPeriod);
   hFastHTF = iMA(_Symbol,TFhtf,emaFastLen,0,MODE_EMA,PRICE_CLOSE);
   hSlowHTF = iMA(_Symbol,TFhtf,emaSlowLen,0,MODE_EMA,PRICE_CLOSE);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}
//========================
//  UTILS
//========================
double TickSize(){ return (TickSizeInp>0?TickSizeInp:_Point); }
double MinLots(){ return (MinLotsInp>0?MinLotsInp:SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)); }
double LotStep(){ return (LotStepInp>0?LotStepInp:SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)); }

int CountDir(ENUM_POSITION_TYPE type)
{
   int total = 0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         total++;
   }
   return total;
}

double NormalizeToTick(double p)
{
   double ts=TickSize();
   return MathRound(p/ts)*ts;
}

double ClampLots(double l)
{
   double vmin=MinLots(), step=LotStep(), vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   l=MathMax(vmin,MathMin(l,vmax));
   if(step>0) l=MathFloor(l/step)*step;
   if(l<vmin) l=vmin;
   return l;
}

double Buf(int h)
{
   double a[];
   ArraySetAsSeries(a,true);
   if(CopyBuffer(h,0,0,1,a)!=1) return 0.0;
   return a[0];
}

//========================
//  SEND ORDER (WITHOUT TP, ONLY SL)
//========================
ulong SendOrder(int dir,double sl)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double lots=(useFixedLots ? ClampLots(fixedLots) : ClampLots(MinLots()));

   MqlTradeRequest q;
   MqlTradeResult  r;
   ZeroMemory(q);
   ZeroMemory(r);

   q.magic      = MagicNumber;
   q.action     = TRADE_ACTION_DEAL;
   q.symbol     = _Symbol;
   q.volume     = lots;
   q.type       = (dir==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   q.deviation  = (int)DeviInp;
   q.type_filling = ORDER_FILLING_IOC;
   q.type_time    = ORDER_TIME_GTC;
   q.price        = (dir==1 ? ask : bid);
   q.sl           = sl;

   if(!OrderSend(q,r))
      return 0;

   if(r.retcode != TRADE_RETCODE_DONE && r.retcode != TRADE_RETCODE_DONE_PARTIAL)
      return 0;

   return r.order;
}
//========================
//  ONTICK — SIGNAL & ENTRY
//========================
void OnTick()
{
   datetime ct=iTime(_Symbol,TFsig,0);
   if(ct==lastBar || ct==0) return;
   lastBar=ct;

   if(useSpreadFilter && SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)>maxSpread) return;

   // --- INDICATOR DATA
   double emaF = Buf(hFastSig);
   double emaS = Buf(hSlowSig);
   double rsi  = Buf(hRSIsig);
   double atr  = Buf(hATRsig);
   double adx  = Buf(hADXsig);
   double emaFh= Buf(hFastHTF);
   double emaSh= Buf(hSlowHTF);

   if(emaF==0||emaS==0||emaFh==0||emaSh==0||atr<=0) return;

   // --- TREND FILTER (H1)
   bool trendUp   = (emaFh > emaSh);
   bool trendDown = (emaFh < emaSh);

   // --- FLAT FILTER (ADX)
   if(adx < adxMinTrend) return;

   // --- SIGNAL
   int dir = 0;
   if(emaF > emaS && trendUp && rsi <= 65)  dir=1;   // BUY
   if(emaF < emaS && trendDown && rsi >= 35) dir=-1; // SELL
   if(dir==0) return;

   // --- POSITION LIMIT
   if(dir==1 && CountDir(POSITION_TYPE_BUY) >= MaxPerDirection)  return;
   if(dir==-1 && CountDir(POSITION_TYPE_SELL) >= MaxPerDirection) return;

   // --- ENTRY PRICE & SL (TP YOK)
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double entry=(dir==1?ask:bid);
   double sl=(dir==1?NormalizeToTick(entry - atr * ATR_SL_Mult)
                    :NormalizeToTick(entry + atr * ATR_SL_Mult));

   // --- SEND ORDER (ONLY SL)
   SendOrder(dir,sl);

   // --- AFTER ENTRY: MANAGE (TRAILING IN NEXT BLOCK)
   PositionManager();
}
//========================
//  POSITION MANAGER — ONLY TRAILING EXIT
//========================
void PositionManager()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      int type   = (int)PositionGetInteger(POSITION_TYPE);
      double sl  = PositionGetDouble(POSITION_SL);
      double atr = Buf(hATRsig);
      if(atr <= 0) continue;

      double price = (type==POSITION_TYPE_BUY ?
                      SymbolInfoDouble(_Symbol,SYMBOL_BID) :
                      SymbolInfoDouble(_Symbol,SYMBOL_ASK));

      double trailDist = atr * ATR_TrailMult;
      double targetSL;

      // BUY trailing
      if(type == POSITION_TYPE_BUY)
      {
         targetSL = NormalizeToTick(price - trailDist);
         if(targetSL > sl) SetSLTP(tk, targetSL, 0.0);
      }

      // SELL trailing
      else
      {
         targetSL = NormalizeToTick(price + trailDist);
         if(targetSL < sl || sl == 0.0) SetSLTP(tk, targetSL, 0.0);
      }
   }
}
//========================
//  SL/TP UPDATE
//========================
bool SetSLTP(ulong tk,double sl,double tp)
{
   if(!PositionSelectByTicket(tk)) return false;
   MqlTradeRequest q;
   MqlTradeResult  r;
   ZeroMemory(q);
   ZeroMemory(r);
   q.action  = TRADE_ACTION_SLTP;
   q.symbol  = _Symbol;
   q.position= tk;
   q.sl      = sl;
   q.tp      = tp;
   if(!OrderSend(q,r)) return false;
   return (r.retcode == 10009);
}

//========================
//  TIMER (JUST MANAGE OPEN TRADES)
//========================
void OnTimer()
{
   PositionManager();
}

//========================
//  DEINIT
//========================
void OnDeinit(const int reason)
{
   EventKillTimer();
}
