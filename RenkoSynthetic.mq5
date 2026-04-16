//+------------------------------------------------------------------+
//|                                              RenkoSynthetic.mq5  |
//|                         EA para geração de símbolo Renko         |
//|                                                                  |
//|  v3.06 — Correções de consistência no fluxo de barras ao vivo   |
//|                                                                  |
//|  CORREÇÕES vs v3.05:                                             |
//|                                                                  |
//|  [C1] Separação de last_bar_close_ms e last_seen_ms             |
//|   • last_bar_close_ms: avança SOMENTE quando uma barra fecha.   |
//|     É a âncora do CopyTicksRange — garante que todos os ticks   |
//|     desde o fechamento da última barra sejam considerados        |
//|     para a barra em formação.                                    |
//|   • last_seen_ms: avança com qualquer tick processado.           |
//|     Usado como filtro dentro de ProcessTick para evitar          |
//|     double-counting quando o CopyTicksRange re-entrega ticks     |
//|     já acumulados em current_bar.                                |
//|                                                                  |
//|  [C2] open_time_ms da nova barra = primeiro tick real dela       |
//|   • InitCurrentBarFromClose deixa open_time_ms = 0.             |
//|   • O open_time_ms é definido no início de ProcessTick,          |
//|     ANTES da acumulação de agressão, quando open_time_ms == 0.  |
//|     Assim o spread (duração) reflete o intervalo exato entre     |
//|     o primeiro tick da barra e o tick que a fechou.             |
//|                                                                  |
//|  [C3] Acumulação de agressão APÓS inicialização do open_time_ms |
//|   • Ordem corrigida: inicializa open_time_ms → acumula agressão.|
//|     Na v3.05 a ordem era invertida, causando o primeiro tick     |
//|     da barra ser acumulado antes do open_time_ms ser definido.  |
//|                                                                  |
//|  [C4] SaveGlobalVars em ponto único de saída                    |
//|   • UpdateRenkoIncremental tem um único ponto de saída que       |
//|     sempre chama SaveGlobalVars, eliminando branches duplicados  |
//|     e o risco de um return antecipado dessincronizar o estado.  |
//|                                                                  |
//|  Herdadas da v3.05:                                              |
//|   • AllocBarTimestamp() — timestamps estritamente crescentes     |
//|   • cur_high/low atualizados dentro do while (wicks corretos)   |
//|   • sem double-counting de agressão                              |
//|   • sem bloco "if(emitted)" redundante                           |
//+------------------------------------------------------------------+
#property copyright "Carlos Rincones"
#property link "https://github.com/crincones"
#property version "3.06"
#property strict

#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS DO USUÁRIO                                                |
//+------------------------------------------------------------------+
input int InpRenkoSizeTicks = 20;    // Tamanho da barra Renko (ticks)
input int InpHistoryDays = 30;       // Dias de histórico a processar
input int InpUpdateIntervalMs = 500; // Intervalo de atualização (ms)
input string InpTemplate = "";       // Template para o gráfico Renko
input bool InpForceRebuild = false;  // Forçar reconstrução total do histórico

//+------------------------------------------------------------------+
//| CONSTANTES E ENUMERAÇÕES                                         |
//+------------------------------------------------------------------+
enum ENUM_ASSET_TYPE
{
    ASSET_FOREX = 0,
    ASSET_EXCHANGE = 1
};

//+------------------------------------------------------------------+
//| ESTRUTURAS INTERNAS                                              |
//+------------------------------------------------------------------+

struct RenkoBarState
{
    datetime open_time;
    long open_time_ms; // 0 = aguardando primeiro tick real da barra [C2]
    double open_price;
    double high_price;
    double low_price;
    int direction;
    long buy_aggression;
    long sell_aggression;
    long start_ms;
    long last_tick_ms;
    bool is_closed;
};

struct EAContext
{
    string base_symbol;
    string renko_symbol;
    double renko_size;
    double point_size;
    int digits;
    ENUM_ASSET_TYPE asset_type;
    uint flag_type;

    double last_close;
    double last_open;
    int last_direction;

    // [C1] — dois contadores com responsabilidades distintas
    long last_bar_close_ms; // ms do tick que fechou a última barra → âncora do CopyTicksRange
    long last_seen_ms;      // ms do último tick processado → filtro anti-double-count

    RenkoBarState current_bar;

    bool initialized;
    bool integrity_ok;
};

//+------------------------------------------------------------------+
//| VARIÁVEIS GLOBAIS DO EA                                          |
//+------------------------------------------------------------------+
EAContext g_ctx;
datetime g_last_reconnect = 0;

// ---- Relógio de timestamps Renko (v3.05, mantido em v3.06) -------
datetime g_next_bar_time = 0;

// ---- Nomes das Global Variables ----------------------------------
string GV_BAR_SIZE = "";
string GV_LAST_CLOSE_MS = ""; // [C1] era GV_LAST_TIME (last_processed_ms), agora = last_bar_close_ms
string GV_LAST_SEEN_MS = "";  // [C1] novo: last_seen_ms
string GV_LAST_CLOSE = "";
string GV_LAST_OPEN = "";
string GV_LAST_DIR = "";
string GV_NEXT_BAR_TIME = "";

string GV_CUR_OPEN_MS = "";
string GV_CUR_OPEN_P = "";
string GV_CUR_HIGH = "";
string GV_CUR_LOW = "";
string GV_CUR_BUY = "";
string GV_CUR_SELL = "";

string GV_CHART_INIT_UPDATED = "";

#define OBJ_STATUS_TYPE "RenkoStatus_Type"
#define OBJ_STATUS_INTEG "RenkoStatus_Integrity"

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    g_ctx.base_symbol = Symbol();
    g_ctx.initialized = false;
    g_ctx.integrity_ok = false;

    g_ctx.renko_symbol = g_ctx.base_symbol + "_" + IntegerToString(InpRenkoSizeTicks) + "_RE";

    GV_BAR_SIZE = g_ctx.renko_symbol + "_bar_size";
    GV_LAST_CLOSE_MS = g_ctx.renko_symbol + "_last_bar_close_ms"; // [C1]
    GV_LAST_SEEN_MS = g_ctx.renko_symbol + "_last_seen_ms";       // [C1]
    GV_LAST_CLOSE = g_ctx.renko_symbol + "_last_close";
    GV_LAST_OPEN = g_ctx.renko_symbol + "_last_open";
    GV_LAST_DIR = g_ctx.renko_symbol + "_last_dir";
    GV_NEXT_BAR_TIME = g_ctx.renko_symbol + "_next_bar_time";

    GV_CUR_OPEN_MS = g_ctx.renko_symbol + "_cur_open_ms";
    GV_CUR_OPEN_P = g_ctx.renko_symbol + "_cur_open_p";
    GV_CUR_HIGH = g_ctx.renko_symbol + "_cur_high";
    GV_CUR_LOW = g_ctx.renko_symbol + "_cur_low";
    GV_CUR_BUY = g_ctx.renko_symbol + "_cur_buy";
    GV_CUR_SELL = g_ctx.renko_symbol + "_cur_sell";

    GV_CHART_INIT_UPDATED = g_ctx.renko_symbol + "_init_updated";
    GlobalVariableSet(GV_CHART_INIT_UPDATED, (double)0.0); // Valor para ser lido por indicadores externos para alertas

    Print("=== RenkoSynthetic EA v3.06 iniciando ===");
    Print("Símbolo base   : ", g_ctx.base_symbol);
    Print("Símbolo Renko  : ", g_ctx.renko_symbol);
    Print("Tamanho Renko  : ", InpRenkoSizeTicks, " ticks");

    g_ctx.asset_type = DetectAssetType(g_ctx.base_symbol);
    g_ctx.flag_type = (g_ctx.asset_type == ASSET_FOREX) ? COPY_TICKS_INFO : COPY_TICKS_TRADE;
    Print("Tipo detectado : ", (g_ctx.asset_type == ASSET_FOREX) ? "FOREX" : "BOLSA");

    g_ctx.digits = (int)SymbolInfoInteger(g_ctx.base_symbol, SYMBOL_DIGITS);
    g_ctx.point_size = SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_POINT);
    g_ctx.renko_size = InpRenkoSizeTicks * g_ctx.point_size;

    Print("Digits         : ", g_ctx.digits);
    Print("Point          : ", g_ctx.point_size);
    Print("Renko size ($) : ", DoubleToString(g_ctx.renko_size, g_ctx.digits));

    if (!EnsureSyntheticSymbolExists())
    {
        Print("ERRO: Não foi possível criar/verificar o símbolo sintético.");
        DrawStatusText(false);
        return INIT_FAILED;
    }

    LoadGlobalVars();

    bool need_rebuild = InpForceRebuild;

    if (!need_rebuild)
    {
        need_rebuild = !CheckHistoryIntegrity();
        if (need_rebuild)
            Print("Integridade comprometida. Iniciando reconstrução total.");
        else
            Print("Integridade OK. Retomando incrementalmente.");
    }
    else
    {
        Print("Reconstrução forçada pelo usuário.");
    }

    if (need_rebuild)
    {
        g_ctx.integrity_ok = false;
        ClearSyntheticHistory();
        ResetRenkoState();
        if (!RebuildHistory())
        {
            Print("ERRO na reconstrução histórica.");
            DrawStatusText(false);
            return INIT_FAILED;
        }
    }
    else
    {
        g_ctx.integrity_ok = true;
        RestoreCurrentBarFromGV();
    }

    DrawStatusText(g_ctx.integrity_ok);
    EventSetMillisecondTimer(InpUpdateIntervalMs);

    g_ctx.initialized = true;

    GlobalVariableSet(GV_CHART_INIT_UPDATED, (double)1.0); // Valor para ser lido por indicadores externos para alertas

    Print("=== EA inicializado com sucesso ===");
    Print("last_bar_close_ms : ", g_ctx.last_bar_close_ms);
    Print("last_seen_ms      : ", g_ctx.last_seen_ms);
    Print("Próximo timestamp Renko: ", TimeToString(g_next_bar_time, TIME_DATE | TIME_SECONDS));
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    ObjectDelete(0, OBJ_STATUS_TYPE);
    ObjectDelete(0, OBJ_STATUS_INTEG);
    Print("RenkoSynthetic EA encerrado. Motivo: ", reason);
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (!g_ctx.initialized)
        return;

    datetime now = TimeCurrent();
    if (now - g_last_reconnect > 30 && !g_ctx.integrity_ok)
    {
        g_last_reconnect = now;
        if (CheckHistoryIntegrity())
        {
            g_ctx.integrity_ok = true;
            DrawStatusText(true);
            Print("Integridade restabelecida após reconexão.");
        }
    }

    UpdateRenkoIncremental();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
    if (!g_ctx.initialized)
        return;
    // UpdateRenkoIncremental();
}

//==================================================================//
//             RELÓGIO DE TIMESTAMPS (v3.05, mantido em v3.06)     //
//==================================================================//

//+------------------------------------------------------------------+
//| AllocBarTimestamp                                                |
//|  Aloca o próximo timestamp disponível para uma barra Renko.      |
//|  Invariante: time[n+1] >= time[n] + 1  sempre.                  |
//+------------------------------------------------------------------+
datetime AllocBarTimestamp(long tick_ms)
{
    datetime tick_s = (datetime)(tick_ms / 1000);
    datetime candidate = (tick_s > g_next_bar_time) ? tick_s : g_next_bar_time;
    g_next_bar_time = candidate + 1;
    return candidate;
}

//==================================================================//
//                    DETECÇÃO DE TIPO DE ATIVO                     //
//==================================================================//

ENUM_ASSET_TYPE DetectAssetType(const string symbol)
{
    long category = SymbolInfoInteger(symbol, SYMBOL_TRADE_CALC_MODE);
    Print("Detectando tipo de ativo. Categoria: ", (ENUM_SYMBOL_CALC_MODE)category);

    if (category == SYMBOL_CALC_MODE_FOREX ||
        category == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE ||
        category == SYMBOL_CALC_MODE_CFD ||
        category == SYMBOL_CALC_MODE_CFDINDEX ||
        category == SYMBOL_CALC_MODE_CFDLEVERAGE)
        return ASSET_FOREX;

    string path = SymbolInfoString(symbol, SYMBOL_PATH);
    string pathLower = _StringToLower(path);
    if (StringFind(pathLower, "forex") >= 0 || StringFind(pathLower, "fx") >= 0)
        return ASSET_FOREX;

    return ASSET_EXCHANGE;
}

string _StringToLower(const string s)
{
    string result = s;
    StringToLower(result);
    return result;
}

//==================================================================//
//                    GESTÃO DO SÍMBOLO SINTÉTICO                   //
//==================================================================//

bool EnsureSyntheticSymbolExists()
{
    if (!SymbolSelect(g_ctx.renko_symbol, true))
    {
        if (!CustomSymbolCreate(g_ctx.renko_symbol, "\\Custom\\Renko", g_ctx.base_symbol))
        {
            int err = GetLastError();
            if (err != 5304)
            {
                Print("Erro ao criar símbolo sintético: ", err);
                return false;
            }
        }
        SymbolSelect(g_ctx.renko_symbol, true);
    }

    CopySymbolProperties();
    return true;
}

void CopySymbolProperties()
{
    string sym = g_ctx.base_symbol;
    string rsym = g_ctx.renko_symbol;

    CustomSymbolSetInteger(rsym, SYMBOL_DIGITS, SymbolInfoInteger(sym, SYMBOL_DIGITS));
    CustomSymbolSetDouble(rsym, SYMBOL_TRADE_TICK_SIZE, SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE));
    CustomSymbolSetDouble(rsym, SYMBOL_TRADE_TICK_VALUE, SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE));
    CustomSymbolSetDouble(rsym, SYMBOL_POINT, SymbolInfoDouble(sym, SYMBOL_POINT));

    string desc = SymbolInfoString(sym, SYMBOL_DESCRIPTION);
    CustomSymbolSetString(rsym, SYMBOL_DESCRIPTION, desc + " [Renko " + IntegerToString(InpRenkoSizeTicks) + "]");
    CustomSymbolSetString(rsym, SYMBOL_CURRENCY_BASE, SymbolInfoString(sym, SYMBOL_CURRENCY_BASE));
    CustomSymbolSetString(rsym, SYMBOL_CURRENCY_PROFIT, SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT));
    CustomSymbolSetInteger(rsym, SYMBOL_TRADE_CALC_MODE, SymbolInfoInteger(sym, SYMBOL_TRADE_CALC_MODE));

    Print("Propriedades copiadas do ativo base para o símbolo sintético.");
}

void ClearSyntheticHistory()
{
    CustomRatesDelete(g_ctx.renko_symbol, 0, TimeCurrent() + 86400);
    Print("Histórico do símbolo sintético apagado.");
}

//==================================================================//
//                    PERSISTÊNCIA – GLOBAL VARIABLES               //
//==================================================================//

void LoadGlobalVars()
{
    if (GlobalVariableCheck(GV_BAR_SIZE))
    {
        double saved_size = GlobalVariableGet(GV_BAR_SIZE);
        if (MathAbs(saved_size - g_ctx.renko_size) > g_ctx.point_size * 0.5)
        {
            Print("Tamanho de barra mudou. Forçando reconstrução.");
            ResetGlobalVars();
            return;
        }
    }

    if (GlobalVariableCheck(GV_LAST_CLOSE))
        g_ctx.last_close = GlobalVariableGet(GV_LAST_CLOSE);
    if (GlobalVariableCheck(GV_LAST_OPEN))
        g_ctx.last_open = GlobalVariableGet(GV_LAST_OPEN);
    if (GlobalVariableCheck(GV_LAST_DIR))
        g_ctx.last_direction = (int)GlobalVariableGet(GV_LAST_DIR);

    // [C1] carrega os dois contadores distintos
    if (GlobalVariableCheck(GV_LAST_CLOSE_MS))
        g_ctx.last_bar_close_ms = (long)GlobalVariableGet(GV_LAST_CLOSE_MS);
    if (GlobalVariableCheck(GV_LAST_SEEN_MS))
        g_ctx.last_seen_ms = (long)GlobalVariableGet(GV_LAST_SEEN_MS);

    if (GlobalVariableCheck(GV_NEXT_BAR_TIME))
        g_next_bar_time = (datetime)GlobalVariableGet(GV_NEXT_BAR_TIME);
    else
        g_next_bar_time = 0;

    Print("Global Variables carregadas.",
          " close=", DoubleToString(g_ctx.last_close, g_ctx.digits),
          " open=", DoubleToString(g_ctx.last_open, g_ctx.digits),
          " dir=", g_ctx.last_direction,
          " last_close_ms=", g_ctx.last_bar_close_ms,
          " last_seen_ms=", g_ctx.last_seen_ms,
          " next_ts=", TimeToString(g_next_bar_time, TIME_DATE | TIME_SECONDS));
}

void SaveGlobalVars()
{
    GlobalVariableSet(GV_BAR_SIZE, g_ctx.renko_size);
    GlobalVariableSet(GV_LAST_CLOSE_MS, (double)g_ctx.last_bar_close_ms); // [C1]
    GlobalVariableSet(GV_LAST_SEEN_MS, (double)g_ctx.last_seen_ms);       // [C1]
    GlobalVariableSet(GV_LAST_CLOSE, g_ctx.last_close);
    GlobalVariableSet(GV_LAST_OPEN, g_ctx.last_open);
    GlobalVariableSet(GV_LAST_DIR, (double)g_ctx.last_direction);
    GlobalVariableSet(GV_NEXT_BAR_TIME, (double)g_next_bar_time);

    GlobalVariableSet(GV_CUR_OPEN_MS, (double)g_ctx.current_bar.open_time_ms);
    GlobalVariableSet(GV_CUR_OPEN_P, g_ctx.current_bar.open_price);
    GlobalVariableSet(GV_CUR_HIGH, g_ctx.current_bar.high_price);
    GlobalVariableSet(GV_CUR_LOW, g_ctx.current_bar.low_price);
    GlobalVariableSet(GV_CUR_BUY, (double)g_ctx.current_bar.buy_aggression);
    GlobalVariableSet(GV_CUR_SELL, (double)g_ctx.current_bar.sell_aggression);
}

void RestoreCurrentBarFromGV()
{
    ZeroMemory(g_ctx.current_bar);
    g_ctx.current_bar.direction = g_ctx.last_direction;

    if (GlobalVariableCheck(GV_CUR_OPEN_MS) && GlobalVariableCheck(GV_CUR_OPEN_P))
    {
        long saved_ms = (long)GlobalVariableGet(GV_CUR_OPEN_MS);

        // [C2] open_time_ms == 0 é sentinela válido — não descarta
        if (saved_ms >= g_ctx.last_bar_close_ms)
        {
            // saved_ms pode ser 0 se a barra foi iniciada mas ainda não
            // recebeu nenhum tick real (caso de restart imediato após
            // InitCurrentBarFromClose). Isso é válido — o primeiro tick
            // ao vivo definirá o open_time_ms.
            g_ctx.current_bar.open_time_ms = saved_ms;
            g_ctx.current_bar.open_time = (saved_ms > 0) ? (datetime)(saved_ms / 1000) : 0;
            g_ctx.current_bar.open_price = GlobalVariableGet(GV_CUR_OPEN_P);
            g_ctx.current_bar.high_price = GlobalVariableGet(GV_CUR_HIGH);
            g_ctx.current_bar.low_price = GlobalVariableGet(GV_CUR_LOW);
            g_ctx.current_bar.buy_aggression = (long)GlobalVariableGet(GV_CUR_BUY);
            g_ctx.current_bar.sell_aggression = (long)GlobalVariableGet(GV_CUR_SELL);
            g_ctx.current_bar.start_ms = saved_ms;
            g_ctx.current_bar.last_tick_ms = saved_ms;

            Print("Barra em formação restaurada: open=", DoubleToString(g_ctx.current_bar.open_price, g_ctx.digits),
                  " H=", DoubleToString(g_ctx.current_bar.high_price, g_ctx.digits),
                  " L=", DoubleToString(g_ctx.current_bar.low_price, g_ctx.digits),
                  " buy=", g_ctx.current_bar.buy_aggression,
                  " sell=", g_ctx.current_bar.sell_aggression,
                  " open_time_ms=", saved_ms);
            return;
        }
    }

    Print("Barra em formação: sem estado salvo válido, iniciando do zero.");
}

void ResetGlobalVars()
{
    GlobalVariableDel(GV_BAR_SIZE);
    GlobalVariableDel(GV_LAST_CLOSE_MS); // [C1]
    GlobalVariableDel(GV_LAST_SEEN_MS);  // [C1]
    GlobalVariableDel(GV_LAST_CLOSE);
    GlobalVariableDel(GV_LAST_OPEN);
    GlobalVariableDel(GV_LAST_DIR);
    GlobalVariableDel(GV_NEXT_BAR_TIME);
    GlobalVariableDel(GV_CUR_OPEN_MS);
    GlobalVariableDel(GV_CUR_OPEN_P);
    GlobalVariableDel(GV_CUR_HIGH);
    GlobalVariableDel(GV_CUR_LOW);
    GlobalVariableDel(GV_CUR_BUY);
    GlobalVariableDel(GV_CUR_SELL);

    g_ctx.last_close = 0;
    g_ctx.last_open = 0;
    g_ctx.last_bar_close_ms = 0; // [C1]
    g_ctx.last_seen_ms = 0;      // [C1]
    g_ctx.last_direction = 0;
    g_next_bar_time = 0;
}

void ResetRenkoState()
{
    ResetGlobalVars();
    ResetCurrentBar();
}

void ResetCurrentBar()
{
    ZeroMemory(g_ctx.current_bar);
    g_ctx.current_bar.direction = g_ctx.last_direction;
    // open_time_ms permanece 0 — sentinela [C2]
}

//==================================================================//
//                    VERIFICAÇÃO DE INTEGRIDADE                    //
//==================================================================//

bool CheckHistoryIntegrity()
{
    if (!GlobalVariableCheck(GV_LAST_CLOSE) || g_ctx.last_close == 0)
    {
        Print("Integridade: sem estado salvo. Reconstrução necessária.");
        return false;
    }

    MqlRates rates[];
    int count = CopyRates(g_ctx.renko_symbol, PERIOD_M1, 0, int(TimeCurrent() + 86400), rates);
    if (count <= 0)
    {
        Print("Integridade: símbolo sintético vazio. Reconstrução necessária.");
        return false;
    }

    double tol = g_ctx.point_size * 0.5;
    for (int i = 0; i < count - 1; i++)
    {
        int dir_curr = (rates[i].close > rates[i].open) ? 1 : -1;
        int dir_next = (rates[i + 1].close > rates[i + 1].open) ? 1 : -1;
        double expected_open = (dir_curr == dir_next) ? rates[i].close : rates[i].open;
        double diff = MathAbs(rates[i + 1].open - expected_open);
        if (diff > tol)
        {
            Print("Integridade: gap de preço na barra ", i,
                  " expected_open=", DoubleToString(expected_open, g_ctx.digits),
                  " actual=", DoubleToString(rates[i + 1].open, g_ctx.digits));
            return false;
        }

        if (rates[i + 1].time <= rates[i].time)
        {
            Print("Integridade: timestamp não-crescente na barra ", i,
                  " t[i]=", TimeToString(rates[i].time, TIME_DATE | TIME_SECONDS),
                  " t[i+1]=", TimeToString(rates[i + 1].time, TIME_DATE | TIME_SECONDS));
            return false;
        }
    }

    double renko_last_close = rates[count - 1].close;
    if (MathAbs(renko_last_close - g_ctx.last_close) > g_ctx.point_size * 0.5)
    {
        Print("Integridade: divergência no último close.",
              " GV=", g_ctx.last_close, " Renko=", renko_last_close);
        return false;
    }

    Print("Integridade verificada OK. Total de barras: ", count);
    return true;
}

//==================================================================//
//                    CONSTRUÇÃO DO HISTÓRICO                       //
//==================================================================//

bool RebuildHistory()
{
    Print("Iniciando reconstrução do histórico Renko...");

    datetime date_from = TimeCurrent() - (datetime)(InpHistoryDays * 86400);
    datetime date_to = TimeCurrent();

    MqlTick ticks[];
    ulong from_ms = (ulong)(date_from * 1000);
    ulong to_ms = (ulong)(date_to * 1000);

    Print(" from: ", TimeToString(date_from, TIME_DATE | TIME_SECONDS),
          " | to: ", TimeToString(date_to, TIME_DATE | TIME_SECONDS));

    int tick_count = CopyTicksRange(g_ctx.base_symbol, ticks, g_ctx.flag_type, from_ms, to_ms);
    if (tick_count <= 0)
    {
        Print("ERRO: Nenhum tick obtido para reconstrução. Código: ", GetLastError());
        return false;
    }

    Print("Ticks obtidos para reconstrução: ", tick_count);

    // Zera estado completo
    g_ctx.last_close = 0;
    g_ctx.last_open = 0;
    g_ctx.last_direction = 0;
    g_ctx.last_bar_close_ms = 0; // [C1]
    g_ctx.last_seen_ms = 0;      // [C1]
    g_next_bar_time = 0;
    ZeroMemory(g_ctx.current_bar);

    int bars_created = 0;
    for (int i = 0; i < tick_count; i++)
        ProcessTick(ticks[i], bars_created);

    SaveGlobalVars();
    Print("Reconstrução concluída. Barras Renko geradas: ", bars_created);
    return true;
}

//==================================================================//
//                    ATUALIZAÇÃO INCREMENTAL                       //
//==================================================================//

//+------------------------------------------------------------------+
//| UpdateRenkoIncremental                                           |
//|                                                                  |
//| [C1] from_ms usa last_bar_close_ms — âncora no fechamento da    |
//|      última barra, não no último tick visto.                     |
//|                                                                  |
//| [C4] Ponto único de saída: SaveGlobalVars é sempre chamado,     |
//|      independente de barras terem sido criadas ou não.           |
//+------------------------------------------------------------------+
void UpdateRenkoIncremental()
{
    // [C1] Busca ticks desde o fechamento da última barra.
    // Ticks já processados (between last_bar_close_ms e last_seen_ms)
    // serão re-entregues mas descartados dentro de ProcessTick pelo
    // filtro last_seen_ms.
    ulong from_ms = (g_ctx.last_bar_close_ms > 0)
                        ? (ulong)(g_ctx.last_bar_close_ms) // inclui o tick de fechamento
                        : (ulong)((TimeCurrent() - 86400) * 1000);
    ulong to_ms = (ulong)TimeCurrent() * 1000 + 1000;

    MqlTick ticks[];
    int tick_count = CopyTicksRange(g_ctx.base_symbol, ticks, g_ctx.flag_type, from_ms, to_ms);

    int bars_created = 0;

    if (tick_count > 0)
    {
        for (int i = 0; i < tick_count; i++)
            ProcessTick(ticks[i], bars_created);
    }
    else if (g_ctx.last_close > 0)
    {
        InjectSyntheticTickIfGap();
    }

    // [C4] Ponto único de saída — sempre salva, independente do resultado.
    SaveGlobalVars();

    if (bars_created > 0)
        TryOpenRenkoChart();
}

void InjectSyntheticTickIfGap()
{
    double ref_price = (g_ctx.asset_type == ASSET_EXCHANGE)
                           ? SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_LAST)
                           : SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_BID);

    if (ref_price <= 0)
        ref_price = SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_BID);
    if (ref_price <= 0)
        return;

    if (MathAbs(ref_price - g_ctx.last_close) < g_ctx.renko_size)
        return;

    double spread = SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_ASK) -
                    SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_BID);
    if (spread <= 0 && g_ctx.asset_type == ASSET_FOREX)
        return;

    MqlTick synthetic;
    ZeroMemory(synthetic);
    synthetic.time = TimeCurrent();
    synthetic.time_msc = (long)TimeCurrent() * 1000;
    synthetic.bid = ref_price;
    synthetic.ask = ref_price + g_ctx.point_size;
    synthetic.last = ref_price;
    synthetic.volume = 0;
    synthetic.flags = (g_ctx.asset_type == ASSET_FOREX) ? TICK_FLAG_BID : TICK_FLAG_LAST;

    int bars_created = 0;
    ProcessTick(synthetic, bars_created);

    // Nota: SaveGlobalVars e TryOpenRenkoChart são chamados pelo
    // ponto único de saída em UpdateRenkoIncremental. [C4]
}

//==================================================================//
//                    PROCESSAMENTO DE TICK                         //
//==================================================================//

double GetRelevantPrice(const MqlTick &tick)
{
    if (g_ctx.asset_type == ASSET_FOREX)
        return tick.bid;
    if (tick.last > 0 && bool(tick.flags & TICK_FLAG_LAST))
        return tick.last;
    return tick.bid;
}

void EstimateAggression(const MqlTick &tick, long &buy_vol, long &sell_vol)
{
    buy_vol = sell_vol = 0;
    long vol = (long)tick.volume;
    if (vol <= 0)
        vol = 1;

    if (g_ctx.asset_type == ASSET_EXCHANGE)
    {
        bool is_buy = (tick.flags & TICK_FLAG_BUY) != 0;
        bool is_sell = (tick.flags & TICK_FLAG_SELL) != 0;
        if (is_buy && !is_sell)
            buy_vol = vol;
        if (is_sell && !is_buy)
            sell_vol = vol;
    }
    else
    {
        static double prev_bid = 0, prev_ask = 0;
        if (prev_bid == 0)
        {
            prev_bid = tick.bid;
            prev_ask = tick.ask;
        }
        double mid_prev = (prev_bid + prev_ask) / 2.0;
        double mid_curr = (tick.bid + tick.ask) / 2.0;
        if (mid_curr > mid_prev)
            buy_vol = vol;
        else if (mid_curr < mid_prev)
            sell_vol = vol;
        else
        {
            buy_vol = vol / 2;
            sell_vol = vol - buy_vol;
        }
        prev_bid = tick.bid;
        prev_ask = tick.ask;
    }
}

//+------------------------------------------------------------------+
//| ProcessTick v3.06                                                |
//|                                                                  |
//| Fluxo corrigido:                                                 |
//|                                                                  |
//| 1. [C1] Filtro anti-double-count: descarta ticks com            |
//|    time_msc <= last_seen_ms. Esses ticks já foram acumulados     |
//|    em current_bar na chamada anterior do timer.                  |
//|                                                                  |
//| 2. [C3] Inicializa open_time_ms da barra ANTES de acumular      |
//|    agressão. Garante que o primeiro tick real da barra define    |
//|    o open_time_ms correto.                                       |
//|                                                                  |
//| 3. [C2] open_time_ms = 0 é sentinela: a barra existe (tem       |
//|    open_price) mas ainda não recebeu seu primeiro tick real.     |
//|    O open_time_ms é definido aqui, neste tick.                   |
//|                                                                  |
//| 4. Acumula agressão.                                             |
//|                                                                  |
//| 5. Loop while: atualiza wicks, verifica triggers, emite barras.  |
//|                                                                  |
//| 6. Atualiza last_seen_ms ao final (todo tick visto).             |
//+------------------------------------------------------------------+
void ProcessTick(const MqlTick &tick, int &bars_created)
{
    double price = GetRelevantPrice(tick);
    if (price <= 0)
        return;

    long tick_ms = tick.time_msc;

    // ------------------------------------------------------------------
    // [C1] Filtro anti-double-count.
    // Durante o rebuild não existe last_seen_ms significativo (é 0),
    // então ticks históricos passam normalmente.
    // Durante operação ao vivo, ticks entre last_bar_close_ms e
    // last_seen_ms são re-entregues pelo CopyTicksRange mas devem
    // ser ignorados — suas agressões já estão em current_bar.
    // ------------------------------------------------------------------
    if (tick_ms <= g_ctx.last_seen_ms)
        return;

    // ------------------------------------------------------------------
    // Inicialização: primeiro tick de toda a sessão define nível base.
    // ------------------------------------------------------------------
    if (g_ctx.last_close == 0)
    {
        g_ctx.last_close = AlignToGrid(price);
        g_ctx.last_open = g_ctx.last_close;
        g_ctx.last_direction = 0;

        // [C2][C3] open_time_ms definido aqui, antes de qualquer acumulação
        InitCurrentBar(g_ctx.last_close, tick_ms);

        if (g_next_bar_time == 0)
            g_next_bar_time = (datetime)(tick_ms / 1000);

        // Atualiza last_seen_ms mesmo no tick de inicialização
        g_ctx.last_seen_ms = tick_ms;
        return;
    }

    // ------------------------------------------------------------------
    // [C2][C3] Se a barra em formação ainda não tem open_time_ms
    // (sentinela = 0), este é o primeiro tick real dela.
    // Define open_time_ms ANTES de acumular agressão.
    // ------------------------------------------------------------------
    if (g_ctx.current_bar.open_time_ms == 0)
    {
        double op = (g_ctx.current_bar.open_price > 0)
                        ? g_ctx.current_bar.open_price
                        : g_ctx.last_close;
        InitCurrentBar(op, tick_ms);
    }

    // ------------------------------------------------------------------
    // Acumula agressão APÓS garantir que open_time_ms está definido [C3]
    // ------------------------------------------------------------------
    long buy_vol = 0, sell_vol = 0;
    EstimateAggression(tick, buy_vol, sell_vol);
    g_ctx.current_bar.buy_aggression += buy_vol;
    g_ctx.current_bar.sell_aggression += sell_vol;

    // ------------------------------------------------------------------
    // LOOP PRINCIPAL — consome todo o deslocamento de preço.
    //
    // A agressão é creditada na barra que fecha e os contadores são
    // zerados em InitCurrentBarFromClose para a próxima barra.
    // ------------------------------------------------------------------
    while (true)
    {
        // Atualiza wicks com o preço atual
        if (price > g_ctx.current_bar.high_price)
            g_ctx.current_bar.high_price = price;
        if (price < g_ctx.current_bar.low_price)
            g_ctx.current_bar.low_price = price;

        double anchor_up = (g_ctx.last_direction == -1) ? g_ctx.last_open : g_ctx.last_close;
        double anchor_dn = (g_ctx.last_direction == 1) ? g_ctx.last_open : g_ctx.last_close;

        bool trigger_up = (price >= anchor_up + g_ctx.renko_size);
        bool trigger_dn = (price <= anchor_dn - g_ctx.renko_size);

        if (!trigger_up && !trigger_dn)
            break;

        MqlRates bar;
        ZeroMemory(bar);
        bar.time = AllocBarTimestamp(tick_ms);

        if (trigger_up)
        {
            double bar_open = (g_ctx.last_direction == -1) ? g_ctx.last_open : g_ctx.last_close;
            double bar_close = bar_open + g_ctx.renko_size;

            bar.open = bar_open;
            bar.close = bar_close;
            bar.high = bar_close;                                     // HIGH nunca passa do close em barra de alta
            bar.low = MathMin(bar_open, g_ctx.current_bar.low_price); // wick inferior
            if (bar.low > bar_open)
                bar.low = bar_open;
            if (bar.high < bar_close)
                bar.high = bar_close;

            bar.tick_volume = g_ctx.current_bar.buy_aggression;
            bar.real_volume = g_ctx.current_bar.sell_aggression;

            // Duração: do primeiro tick real da barra até o tick que a fechou [C2]
            long open_ms = (g_ctx.current_bar.open_time_ms > 0)
                               ? g_ctx.current_bar.open_time_ms
                               : tick_ms;
            bar.spread = (int)MathMin(tick_ms - open_ms, 2147483647);

            CommitRenkoBar(bar, bars_created);

            g_ctx.last_open = bar_open;
            g_ctx.last_close = bar_close;
            g_ctx.last_direction = 1;
            g_ctx.last_bar_close_ms = tick_ms; // [C1] âncora avança apenas ao fechar

            // [C2] Próxima barra começa sem open_time_ms — será definido
            // pelo primeiro tick real que ela receber.
            InitCurrentBarFromClose(g_ctx.last_close);
            continue;
        }

        if (trigger_dn)
        {
            double bar_open = (g_ctx.last_direction == 1) ? g_ctx.last_open : g_ctx.last_close;
            double bar_close = bar_open - g_ctx.renko_size;

            bar.open = bar_open;
            bar.close = bar_close;
            bar.low = bar_close;                                        // LOW nunca passa do close em barra de baixa
            bar.high = MathMax(bar_open, g_ctx.current_bar.high_price); // wick superior
            if (bar.high < bar_open)
                bar.high = bar_open;
            if (bar.low > bar_close)
                bar.low = bar_close;

            bar.tick_volume = g_ctx.current_bar.buy_aggression;
            bar.real_volume = g_ctx.current_bar.sell_aggression;

            // Duração: do primeiro tick real da barra até o tick que a fechou [C2]
            long open_ms = (g_ctx.current_bar.open_time_ms > 0)
                               ? g_ctx.current_bar.open_time_ms
                               : tick_ms;
            bar.spread = (int)MathMin(tick_ms - open_ms, 2147483647);

            CommitRenkoBar(bar, bars_created);

            g_ctx.last_open = bar_open;
            g_ctx.last_close = bar_close;
            g_ctx.last_direction = -1;
            g_ctx.last_bar_close_ms = tick_ms; // [C1] âncora avança apenas ao fechar

            // [C2] Próxima barra começa sem open_time_ms
            InitCurrentBarFromClose(g_ctx.last_close);
            continue;
        }

    } // fim while

    // ------------------------------------------------------------------
    // [C1] Atualiza last_seen_ms ao final — após processar o tick.
    // ------------------------------------------------------------------
    if (tick_ms > g_ctx.last_seen_ms)
        g_ctx.last_seen_ms = tick_ms;
}

//==================================================================//
//                    GERENCIAMENTO DE BARRAS                       //
//==================================================================//

//+------------------------------------------------------------------+
//| InitCurrentBar                                                   |
//| Usado na inicialização da sessão e na restauração pós-restart.   |
//| open_time_ms é definido com tick_ms — tick já conhecido.         |
//+------------------------------------------------------------------+
void InitCurrentBar(double open_price, long tick_ms)
{
    g_ctx.current_bar.open_time_ms = tick_ms;
    g_ctx.current_bar.open_time = (datetime)(tick_ms / 1000);
    g_ctx.current_bar.open_price = open_price;
    g_ctx.current_bar.high_price = open_price;
    g_ctx.current_bar.low_price = open_price;
    g_ctx.current_bar.buy_aggression = 0;
    g_ctx.current_bar.sell_aggression = 0;
    g_ctx.current_bar.start_ms = tick_ms;
    g_ctx.current_bar.last_tick_ms = tick_ms;
    g_ctx.current_bar.is_closed = false;
    g_ctx.current_bar.direction = g_ctx.last_direction;
}

//+------------------------------------------------------------------+
//| InitCurrentBarFromClose  [C2]                                    |
//|                                                                  |
//| Chamado após cada fechamento de barra, dentro do loop while.     |
//| Deixa open_time_ms = 0 intencionalmente (sentinela).             |
//|                                                                  |
//| O open_time_ms real será definido no início do próximo           |
//| ProcessTick, pelo primeiro tick que pertencer a esta barra.      |
//| Isso garante que bar.spread = tempo real de formação da barra.   |
//|                                                                  |
//| Não recebe tick_ms — a barra não tem timestamp de abertura ainda.|
//+------------------------------------------------------------------+
void InitCurrentBarFromClose(double open_price)
{
    g_ctx.current_bar.open_time_ms = 0; // sentinela [C2]
    g_ctx.current_bar.open_time = 0;
    g_ctx.current_bar.open_price = open_price;
    g_ctx.current_bar.high_price = open_price;
    g_ctx.current_bar.low_price = open_price;
    g_ctx.current_bar.buy_aggression = 0;
    g_ctx.current_bar.sell_aggression = 0;
    g_ctx.current_bar.start_ms = 0;
    g_ctx.current_bar.last_tick_ms = 0;
    g_ctx.current_bar.is_closed = false;
    g_ctx.current_bar.direction = g_ctx.last_direction;
}

void CommitRenkoBar(MqlRates &bar, int &counter)
{
    // Sanitização: high/low nunca podem violar o body
    double body_max = MathMax(bar.open, bar.close);
    double body_min = MathMin(bar.open, bar.close);
    if (bar.high < body_max)
        bar.high = body_max;
    if (bar.low > body_min)
        bar.low = body_min;

    MqlRates arr[1];
    arr[0] = bar;

    int res = CustomRatesUpdate(g_ctx.renko_symbol, arr);
    if (res < 0)
        Print("ERRO ao inserir barra Renko: ", GetLastError(),
              " | time=", TimeToString(bar.time, TIME_DATE | TIME_SECONDS),
              " O=", DoubleToString(bar.open, g_ctx.digits),
              " H=", DoubleToString(bar.high, g_ctx.digits),
              " L=", DoubleToString(bar.low, g_ctx.digits),
              " C=", DoubleToString(bar.close, g_ctx.digits));
    else
        counter++;
}

//==================================================================//
//                    ALINHAMENTO AO GRID                           //
//==================================================================//

double AlignToGrid(double price)
{
    double size = g_ctx.renko_size;
    return MathRound(price / size) * size;
}

//==================================================================//
//                    ABERTURA DO GRÁFICO RENKO                     //
//==================================================================//

void TryOpenRenkoChart()
{
    long chart_id = ChartFirst();
    while (chart_id >= 0)
    {
        if (ChartSymbol(chart_id) == g_ctx.renko_symbol)
            return;
        chart_id = ChartNext(chart_id);
    }

    long new_chart = ChartOpen(g_ctx.renko_symbol, PERIOD_M1);
    if (new_chart > 0)
    {
        ChartSetInteger(new_chart, CHART_AUTOSCROLL, true);
        if (InpTemplate != "")
            ChartApplyTemplate(new_chart, InpTemplate);
        Print("Gráfico Renko aberto: ", g_ctx.renko_symbol);
    }
}

//==================================================================//
//                    TEXTOS VISUAIS NO GRÁFICO BASE                //
//==================================================================//

void DrawStatusText(bool integrity_ok)
{
    string type_text = (g_ctx.asset_type == ASSET_FOREX) ? "TIPO: FOREX" : "TIPO: BOLSA";
    string integ_text = integrity_ok ? "INTEGRIDADE: OK" : "INTEGRIDADE: COMPROMETIDA";

    if (ObjectFind(0, OBJ_STATUS_TYPE) < 0)
        ObjectCreate(0, OBJ_STATUS_TYPE, OBJ_LABEL, 0, 0, 0);

    ObjectSetInteger(0, OBJ_STATUS_TYPE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, OBJ_STATUS_TYPE, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, OBJ_STATUS_TYPE, OBJPROP_YDISTANCE, 10);
    ObjectSetString(0, OBJ_STATUS_TYPE, OBJPROP_TEXT, type_text);
    ObjectSetString(0, OBJ_STATUS_TYPE, OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, OBJ_STATUS_TYPE, OBJPROP_FONTSIZE, 18);
    ObjectSetInteger(0, OBJ_STATUS_TYPE, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, OBJ_STATUS_TYPE, OBJPROP_SELECTABLE, false);

    if (ObjectFind(0, OBJ_STATUS_INTEG) < 0)
        ObjectCreate(0, OBJ_STATUS_INTEG, OBJ_LABEL, 0, 0, 0);

    ObjectSetInteger(0, OBJ_STATUS_INTEG, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, OBJ_STATUS_INTEG, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, OBJ_STATUS_INTEG, OBJPROP_YDISTANCE, 60);
    ObjectSetString(0, OBJ_STATUS_INTEG, OBJPROP_TEXT, integ_text);
    ObjectSetString(0, OBJ_STATUS_INTEG, OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, OBJ_STATUS_INTEG, OBJPROP_FONTSIZE, 18);
    ObjectSetInteger(0, OBJ_STATUS_INTEG, OBJPROP_COLOR, integrity_ok ? clrLime : clrRed);
    ObjectSetInteger(0, OBJ_STATUS_INTEG, OBJPROP_SELECTABLE, false);

    ChartRedraw(0);
}

//==================================================================//
//                    FIM DO EA                                      //
//==================================================================//