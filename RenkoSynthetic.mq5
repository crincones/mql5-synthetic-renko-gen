//+------------------------------------------------------------------+
//|                                             RenkoSynthetic.mq5  |
//|                         EA para geração de símbolo Renko         |
//|                                                                  |
//|  v3.12 — Configuração por ativo e reconstrução mais leve        |
//|  v3.11 — Corte de pregão e brick em formação no gráfico         |
//|  v3.08 — Correções de Renko R-1 e Precisão de Agressão          |
//|  v3.07 — Correções de consistência no fluxo de barras ao vivo   |
//|                                                                  |
//|  MUDANÇAS vs v3.11:                                              |
//|                                                                  |
//|  [G1] Configuração por ativo (InpConfigModo). A última           |
//|       configuração usada em cada ativo base é gravada em         |
//|       MQL5\Files\RenkoSynthetic\<ativo>.cfg e reaplicada quando  |
//|       o EA volta a ser colocado no mesmo ativo. Um EA não altera |
//|       os próprios inputs, então o código usa g_set (configuração |
//|       efetiva): input diferente do padrão vale; input no padrão  |
//|       cede ao valor salvo. O log e uma linha de status no        |
//|       gráfico dizem o que veio do arquivo.                       |
//|                                                                  |
//|  [M1] RebuildHistory lê um dia de ticks por vez em vez de todos  |
//|       os InpHistoryDays de uma só vez: o pico de memória cai     |
//|       para o de um único pregão. Mesmos ticks, mesma ordem.      |
//|                                                                  |
//|  [M2] UpdateRenkoIncremental busca ticks a partir do último tick |
//|       visto (last_seen_ms) em vez do fechamento da última barra. |
//|       O filtro [C1] já descartava o que vinha antes, então o     |
//|       gráfico é idêntico e cada ciclo copia muito menos ticks.   |
//|                                                                  |
//|  MUDANÇAS vs v3.08:                                              |
//|                                                                  |
//|  [R4] Corte de pregão (InpResetDiario). Na virada do dia (hora   |
//|       do servidor, extraída do timestamp do tick) o brick em     |
//|       formação é descartado e a grade reancora no primeiro preço |
//|       do dia novo, como no começo da série. Sem isso o gap       |
//|       noturno fica escondido dentro de um brick e a sequência    |
//|       cola dois pregões num só. CheckHistoryIntegrity aceita a   |
//|       descontinuidade de preço na virada de dia e RebuildHistory |
//|       começa a varredura no início de um dia. Com o input        |
//|       desligado o gráfico é idêntico ao da v3.08.                |
//|                                                                  |
//|  [P1] Brick em formação como barra provisória                    |
//|       (InpShowFormingBrick). O brick que ainda não fechou é      |
//|       escrito no próprio símbolo sintético, no slot do próximo   |
//|       timestamp, para o MT5 desenhá-lo com o estilo de candle do |
//|       gráfico. Ela não consome timestamp nem altera o estado do  |
//|       gerador; é apagada antes de toda verificação de            |
//|       integridade e no OnDeinit, e seu timestamp fica numa       |
//|       Global Variable para que um restart saiba apagá-la.        |
//|                                                                  |
//|  CORREÇÕES vs v3.07:
//|  [C5] Inserido tamanho de tijolo R-1 para cálculo de direção e triggers
//|
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
#property version "3.12"
#property strict

#include <Trade\SymbolInfo.mqh>

//--- Padrões COMPILADOS dos inputs. O modo Automático de InpConfigModo
//--- compara cada input com estes valores para saber se o usuário
//--- mexeu nele (ver "CONFIGURAÇÃO POR ATIVO"). [G1]
#define DEF_RENKO_TICKS 11
#define DEF_DIAS_HISTORICO 5
#define DEF_INTERVALO_MS 500
#define DEF_TEMPLATE ""
#define DEF_FORCAR_RECONSTRUCAO true
#define DEF_RESET_DIARIO true
#define DEF_USAR_LIMIAR_AGRESSAO false
#define DEF_LIMIAR_AGRESSAO 0
#define DEF_BRICK_EM_FORMACAO true

enum ENUM_RENKO_CFGMODE
{
    RENKO_CFG_AUTO = 0,   // Automático: input alterado vale; o resto vem da última config do ativo
    RENKO_CFG_INPUTS = 1, // Só os inputs (ignora a config salva e grava por cima)
    RENKO_CFG_OFF = 2     // Desligado (não lê nem grava)
};

//+------------------------------------------------------------------+
//| INPUTS DO USUÁRIO                                                |
//+------------------------------------------------------------------+
input ENUM_RENKO_CFGMODE InpConfigModo = RENKO_CFG_AUTO; // Configuração por ativo (MQL5\Files\RenkoSynthetic) [G1]
input int InpRenkoSizeTicks = DEF_RENKO_TICKS;      // Tamanho da barra Renko (ticks)
input int InpHistoryDays = DEF_DIAS_HISTORICO;          // Dias de histórico a processar
input int InpUpdateIntervalMs = DEF_INTERVALO_MS;   // Intervalo de atualização (ms)
input string InpTemplate = DEF_TEMPLATE;         // Template para o gráfico Renko
input bool InpForceRebuild = DEF_FORCAR_RECONSTRUCAO;     // Forçar reconstrução total do histórico
input bool InpResetDiario = DEF_RESET_DIARIO;      // Reancorar a grade a cada dia novo [R4]
input bool UsarLimiarAgressao = DEF_USAR_LIMIAR_AGRESSAO; // Usar limiar de agressão para filtrar ticks
input int LimiarAgressao = DEF_LIMIAR_AGRESSAO;          // Abaixo disto é considerado Agressão (0 desativa)
input bool InpShowFormingBrick = DEF_BRICK_EM_FORMACAO; // Desenhar o brick em formação como barra provisória [P1]

//==================================================================//
//                    CONFIGURAÇÃO POR ATIVO  [G1]                  //
//==================================================================//
//
// O EA guarda a última configuração usada em cada ativo base em
// MQL5\Files\RenkoSynthetic\<ativo>.cfg (texto CHAVE=valor) e a
// reaplica quando é colocado de novo no mesmo ativo.
//
// Um EA não consegue alterar os próprios inputs, então o código usa
// g_set (a configuração EFETIVA), nunca os inputs diretamente. No
// modo Automático, para cada parâmetro:
//   - input diferente do padrão compilado => o usuário mexeu: vale o
//     input;
//   - input no padrão => vale o valor salvo do ativo, se houver.
// A configuração efetiva é regravada a cada início. Para voltar um
// parâmetro ao padrão quando o salvo é outro, use o modo "Só os
// inputs" uma vez. O log lista tudo o que veio do arquivo.
//
//==================================================================//

struct RenkoSettings
{
    int renko_size_ticks;
    int history_days;
    int update_interval_ms;
    string chart_template;
    bool force_rebuild;
    bool reset_diario;
    bool usar_limiar_agressao;
    int limiar_agressao;
    bool show_forming_brick;
};

RenkoSettings g_set;        // configuração efetiva (inputs + .cfg do ativo)
string g_cfg_keys[];        // conteúdo lido do .cfg
string g_cfg_vals[];
int g_cfg_from_file = 0;    // quantos parâmetros vieram do arquivo
string g_cfg_path = "";

string CfgFileName(const string base_symbol)
{
    string safe = base_symbol;
    string bad = "\\/:*?\"<>|";
    for (int i = 0; i < StringLen(bad); i++)
        StringReplace(safe, StringSubstr(bad, i, 1), "_");
    return "RenkoSynthetic\\" + safe + ".cfg";
}

void CfgRead(const string path)
{
    ArrayResize(g_cfg_keys, 0);
    ArrayResize(g_cfg_vals, 0);
    if (!FileIsExist(path))
        return;
    int h = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
    if (h == INVALID_HANDLE)
    {
        Print("[CFG] Não foi possível ler ", path, " (erro ", GetLastError(), ").");
        return;
    }
    while (!FileIsEnding(h))
    {
        string line = FileReadString(h);
        int eq = StringFind(line, "=");
        if (eq <= 0 || StringGetCharacter(line, 0) == '#')
            continue;
        int n = ArraySize(g_cfg_keys);
        ArrayResize(g_cfg_keys, n + 1);
        ArrayResize(g_cfg_vals, n + 1);
        g_cfg_keys[n] = StringSubstr(line, 0, eq);
        g_cfg_vals[n] = StringSubstr(line, eq + 1);
    }
    FileClose(h);
}

bool CfgFind(const string key, string &val)
{
    for (int i = 0; i < ArraySize(g_cfg_keys); i++)
        if (g_cfg_keys[i] == key)
        {
            val = g_cfg_vals[i];
            return true;
        }
    return false;
}

//--- valor efetivo de um parâmetro (como texto): ver regra no cabeçalho
string CfgPick(const string key, const string input_val, const string def_val)
{
    if (InpConfigModo != RENKO_CFG_AUTO || input_val != def_val)
        return input_val;
    string saved = "";
    if (!CfgFind(key, saved) || saved == input_val)
        return input_val;
    g_cfg_from_file++;
    Print("[CFG]   ", key, " = ", saved, "  (salvo do ativo; input no padrão ", def_val, ")");
    return saved;
}

string CfgB(const bool v) { return v ? "1" : "0"; }

//+------------------------------------------------------------------+
//| LoadSettings — monta g_set e regrava o .cfg do ativo             |
//+------------------------------------------------------------------+
void LoadSettings(const string base_symbol)
{
    g_cfg_from_file = 0;
    g_cfg_path = CfgFileName(base_symbol);
    ArrayResize(g_cfg_keys, 0);
    ArrayResize(g_cfg_vals, 0);
    if (InpConfigModo == RENKO_CFG_AUTO)
        CfgRead(g_cfg_path);

    g_set.renko_size_ticks = (int)StringToInteger(CfgPick("RENKO_TICKS", IntegerToString(InpRenkoSizeTicks), IntegerToString(DEF_RENKO_TICKS)));
    g_set.history_days = (int)StringToInteger(CfgPick("DIAS_HISTORICO", IntegerToString(InpHistoryDays), IntegerToString(DEF_DIAS_HISTORICO)));
    g_set.update_interval_ms = (int)StringToInteger(CfgPick("INTERVALO_MS", IntegerToString(InpUpdateIntervalMs), IntegerToString(DEF_INTERVALO_MS)));
    g_set.chart_template = CfgPick("TEMPLATE", InpTemplate, DEF_TEMPLATE);
    g_set.force_rebuild = (StringToInteger(CfgPick("FORCAR_RECONSTRUCAO", CfgB(InpForceRebuild), CfgB(DEF_FORCAR_RECONSTRUCAO))) != 0);
    g_set.reset_diario = (StringToInteger(CfgPick("RESET_DIARIO", CfgB(InpResetDiario), CfgB(DEF_RESET_DIARIO))) != 0);
    g_set.usar_limiar_agressao = (StringToInteger(CfgPick("USAR_LIMIAR_AGRESSAO", CfgB(UsarLimiarAgressao), CfgB(DEF_USAR_LIMIAR_AGRESSAO))) != 0);
    g_set.limiar_agressao = (int)StringToInteger(CfgPick("LIMIAR_AGRESSAO", IntegerToString(LimiarAgressao), IntegerToString(DEF_LIMIAR_AGRESSAO)));
    g_set.show_forming_brick = (StringToInteger(CfgPick("BRICK_EM_FORMACAO", CfgB(InpShowFormingBrick), CfgB(DEF_BRICK_EM_FORMACAO))) != 0);

    //--- sanidade de valores vindos de um arquivo editado à mão
    if (g_set.renko_size_ticks < 2)
        g_set.renko_size_ticks = InpRenkoSizeTicks;
    if (g_set.history_days < 1)
        g_set.history_days = InpHistoryDays;
    if (g_set.update_interval_ms < 50)
        g_set.update_interval_ms = InpUpdateIntervalMs;

    if (InpConfigModo == RENKO_CFG_OFF)
    {
        Print("[CFG] Configuração por ativo DESLIGADA: valem os inputs.");
        return;
    }
    if (InpConfigModo == RENKO_CFG_INPUTS)
        Print("[CFG] Modo \"Só os inputs\": a config salva foi ignorada e será regravada.");
    else if (g_cfg_from_file > 0)
        Print("[CFG] ", g_cfg_from_file, " parâmetro(s) vieram de ", g_cfg_path, " (lista acima).");
    else
        Print("[CFG] Nenhum parâmetro veio do arquivo: valem os inputs (", g_cfg_path, ").");
    SaveSettings();
}

//--- grava a configuração efetiva (só reescreve o arquivo se mudou)
void SaveSettings()
{
    if (MQLInfoInteger(MQL_TESTER))
        return;
    string k[], v[];
    int n = 9;
    ArrayResize(k, n);
    ArrayResize(v, n);
    k[0] = "RENKO_TICKS"; v[0] = IntegerToString(g_set.renko_size_ticks);
    k[1] = "DIAS_HISTORICO"; v[1] = IntegerToString(g_set.history_days);
    k[2] = "INTERVALO_MS"; v[2] = IntegerToString(g_set.update_interval_ms);
    k[3] = "TEMPLATE"; v[3] = g_set.chart_template;
    k[4] = "FORCAR_RECONSTRUCAO"; v[4] = CfgB(g_set.force_rebuild);
    k[5] = "RESET_DIARIO"; v[5] = CfgB(g_set.reset_diario);
    k[6] = "USAR_LIMIAR_AGRESSAO"; v[6] = CfgB(g_set.usar_limiar_agressao);
    k[7] = "LIMIAR_AGRESSAO"; v[7] = IntegerToString(g_set.limiar_agressao);
    k[8] = "BRICK_EM_FORMACAO"; v[8] = CfgB(g_set.show_forming_brick);

    bool same = (ArraySize(g_cfg_keys) == n);
    for (int i = 0; i < n && same; i++)
    {
        string cur = "";
        same = (CfgFind(k[i], cur) && cur == v[i]);
    }
    if (same)
        return;

    FolderCreate("RenkoSynthetic");
    int h = FileOpen(g_cfg_path, FILE_WRITE | FILE_TXT | FILE_ANSI);
    if (h == INVALID_HANDLE)
    {
        Print("[CFG] Não foi possível gravar ", g_cfg_path, " (erro ", GetLastError(), ").");
        return;
    }
    FileWriteString(h, "# RenkoSynthetic - ultima configuracao usada neste ativo\r\n");
    for (int i = 0; i < n; i++)
        FileWriteString(h, k[i] + "=" + v[i] + "\r\n");
    FileClose(h);
    Print("[CFG] Configuração gravada em ", g_cfg_path);
}

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
    double renko_size;      // N × point_size  (valor bruto do input)
    double real_renko_size; // (N - 1) × point_size  (tamanho real do tijolo)
    double point_size;
    double tick_size; // menor variação do ativo
    int digits;
    ENUM_ASSET_TYPE asset_type;
    uint flag_type;

    double last_close;
    double last_open;
    int last_direction;

    long last_bar_close_ms;
    long last_seen_ms;

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
string GV_PROV_TIME = ""; // [P1] timestamp da barra provisória

// ---- Estado auxiliar ----------------------------------------------
double g_cur_last_price = 0; // [P1] último preço visto (close da provisória)
double g_prev_bid = 0;       // agressão FOREX: mid-price anterior
double g_prev_ask = 0;       //   (era static; agora zera no corte de pregão)

// ---- Barra provisória (brick em formação) [P1] --------------------
long g_prov_ts = 0;           // timestamp da provisória no gráfico (0 = nenhuma)
MqlRates g_prov_bar;          // última provisória escrita, evita reescrita inútil
datetime g_first_commit = 0;  // 1ª barra real gravada no ciclo do timer

#define OBJ_STATUS_TYPE "RenkoStatus_Type"
#define OBJ_STATUS_INTEG "RenkoStatus_Integrity"
#define OBJ_STATUS_CFG "RenkoStatus_Config"

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    g_ctx.base_symbol = Symbol();
    LoadSettings(g_ctx.base_symbol); // [G1] daqui em diante o código usa g_set
    g_ctx.initialized = false;
    g_ctx.integrity_ok = false;

    g_ctx.renko_symbol = g_ctx.base_symbol + "_" + IntegerToString(g_set.renko_size_ticks) + "_RE";

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

    GV_PROV_TIME = g_ctx.renko_symbol + "_prov_time"; // [P1]
    ZeroMemory(g_prov_bar);
    g_prov_ts = GlobalVariableCheck(GV_PROV_TIME) ? (long)GlobalVariableGet(GV_PROV_TIME) : 0;

    Print("=== RenkoSynthetic EA v3.12 iniciando ===");
    Print("Símbolo base   : ", g_ctx.base_symbol);
    Print("Símbolo Renko  : ", g_ctx.renko_symbol);
    Print("Tamanho Renko  : ", g_set.renko_size_ticks, " ticks");

    g_ctx.asset_type = DetectAssetType(g_ctx.base_symbol);
    g_ctx.flag_type = (g_ctx.asset_type == ASSET_FOREX) ? COPY_TICKS_INFO : COPY_TICKS_TRADE;
    Print("Tipo detectado : ", (g_ctx.asset_type == ASSET_FOREX) ? "FOREX" : "BOLSA");

    g_ctx.digits = (int)SymbolInfoInteger(g_ctx.base_symbol, SYMBOL_DIGITS);

    g_ctx.point_size = SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_POINT);
    g_ctx.tick_size = SymbolInfoDouble(g_ctx.base_symbol, SYMBOL_TRADE_TICK_SIZE);
    if (g_ctx.tick_size <= 0)
        g_ctx.tick_size = g_ctx.point_size; // fallback seguro

    g_ctx.renko_size = g_set.renko_size_ticks * g_ctx.tick_size;            // 50 × 5 = 250
    g_ctx.real_renko_size = (g_set.renko_size_ticks - 1) * g_ctx.tick_size; // 49 × 5 = 245

    g_ctx.real_renko_size =
        NormalizeDouble(g_ctx.real_renko_size, g_ctx.digits);

    g_ctx.renko_size =
        NormalizeDouble(g_ctx.renko_size, g_ctx.digits);

    Print("Tick size      : ", g_ctx.tick_size);
    Print("Renko size     : ", DoubleToString(g_ctx.renko_size, g_ctx.digits));
    Print("Real renko size: ", DoubleToString(g_ctx.real_renko_size, g_ctx.digits));
    Print("Corte de pregão: ", g_set.reset_diario
              ? "a grade reancora a cada dia novo [R4]"
              : "nenhum — a grade e o brick em formação atravessam a noite");

    if (!EnsureSyntheticSymbolExists())
    {
        Print("ERRO: Não foi possível criar/verificar o símbolo sintético.");
        DrawStatusText(false);
        return INIT_FAILED;
    }

    // [P1] A provisória deixada pela sessão anterior é só renderização:
    // apaga ANTES de verificar a integridade, que deve ver apenas
    // barras fechadas.
    RemoveProvisionalBar();

    LoadGlobalVars();

    bool need_rebuild = g_set.force_rebuild;

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

    RefreshProvisionalBar(); // [P1] só depois de o histórico estar íntegro

    DrawStatusText(g_ctx.integrity_ok);
    EventSetMillisecondTimer(g_set.update_interval_ms);

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
    RemoveProvisionalBar(); // [P1] deixa o gráfico só com barras fechadas
    ObjectDelete(0, OBJ_STATUS_TYPE);
    ObjectDelete(0, OBJ_STATUS_INTEG);
    ObjectDelete(0, OBJ_STATUS_CFG);
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
        RemoveProvisionalBar(); // [P1] a checagem só pode ver barras fechadas
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
    CustomSymbolSetString(rsym, SYMBOL_DESCRIPTION, desc + " [Renko " + IntegerToString(g_set.renko_size_ticks) + "]");
    CustomSymbolSetString(rsym, SYMBOL_CURRENCY_BASE, SymbolInfoString(sym, SYMBOL_CURRENCY_BASE));
    CustomSymbolSetString(rsym, SYMBOL_CURRENCY_PROFIT, SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT));
    CustomSymbolSetInteger(rsym, SYMBOL_TRADE_CALC_MODE, SymbolInfoInteger(sym, SYMBOL_TRADE_CALC_MODE));

    Print("Propriedades copiadas do ativo base para o símbolo sintético.");
}

void ClearSyntheticHistory()
{
    CustomRatesDelete(g_ctx.renko_symbol, 0, TimeCurrent() + 86400);

    // [P1] a provisória foi apagada junto — esquece o ponteiro para não
    // apagar depois um slot reaproveitado por uma barra da reconstrução.
    g_prov_ts = 0;
    ZeroMemory(g_prov_bar);
    GlobalVariableSet(GV_PROV_TIME, 0.0);

    Print("Histórico do símbolo sintético apagado.");
}

//==================================================================//
//                BARRA PROVISÓRIA (BRICK EM FORMAÇÃO) [P1]         //
//==================================================================//

//+------------------------------------------------------------------+
//| RemoveProvisionalBar                                             |
//|                                                                  |
//| Idempotente. Depois desta chamada o símbolo sintético contém     |
//| exclusivamente barras fechadas.                                  |
//+------------------------------------------------------------------+
void RemoveProvisionalBar()
{
    if (g_prov_ts <= 0)
        return;

    datetime ts = (datetime)g_prov_ts;
    CustomRatesDelete(g_ctx.renko_symbol, ts, ts);

    g_prov_ts = 0;
    ZeroMemory(g_prov_bar);
    GlobalVariableSet(GV_PROV_TIME, 0.0);
}

//+------------------------------------------------------------------+
//| RefreshProvisionalBar                                            |
//|                                                                  |
//| Escreve o brick em formação no slot g_next_bar_time — o mesmo    |
//| que AllocBarTimestamp usaria se o brick fechasse agora. Assim    |
//| ela fica sempre depois da última barra fechada e nunca colide    |
//| com uma barra existente. Não consome o timestamp.                |
//|                                                                  |
//| Não reescreve quando nada mudou: reescrever no mesmo slot é      |
//| barato, mas trocar de slot força recálculo dos indicadores.      |
//+------------------------------------------------------------------+
void RefreshProvisionalBar()
{
    if (!g_set.show_forming_brick || g_ctx.last_close <= 0 || g_next_bar_time <= 0)
    {
        RemoveProvisionalBar();
        return;
    }

    datetime ts = g_next_bar_time;

    double open_p = g_ctx.current_bar.open_price;
    if (open_p <= 0)
        open_p = g_ctx.last_close;

    double close_p = (g_cur_last_price > 0) ? g_cur_last_price : open_p;

    double hi = g_ctx.current_bar.high_price;
    double lo = g_ctx.current_bar.low_price;
    if (hi <= 0)
        hi = MathMax(open_p, close_p);
    if (lo <= 0)
        lo = MathMin(open_p, close_p);

    MqlRates bar;
    ZeroMemory(bar);
    bar.time = ts;
    bar.open = open_p;
    bar.close = close_p;
    bar.high = MathMax(hi, MathMax(open_p, close_p));
    bar.low = MathMin(lo, MathMin(open_p, close_p));
    bar.tick_volume = g_ctx.current_bar.buy_aggression; // mesma convenção das barras fechadas
    bar.real_volume = g_ctx.current_bar.sell_aggression;
    bar.spread = 0;

    //--- nada mudou desde a última escrita?
    if (g_prov_ts == (long)ts &&
        g_prov_bar.open == bar.open && g_prov_bar.close == bar.close &&
        g_prov_bar.high == bar.high && g_prov_bar.low == bar.low &&
        g_prov_bar.tick_volume == bar.tick_volume &&
        g_prov_bar.real_volume == bar.real_volume)
        return;

    //--- mudou de slot: apaga o slot antigo antes de ocupar o novo
    if (g_prov_ts > 0 && g_prov_ts != (long)ts)
        RemoveProvisionalBar();

    MqlRates arr[1];
    arr[0] = bar;
    if (CustomRatesUpdate(g_ctx.renko_symbol, arr) < 0)
    {
        Print("[P1] Erro ao escrever barra provisória: ", GetLastError(),
              " | time=", TimeToString(ts, TIME_DATE | TIME_SECONDS));
        return;
    }

    g_prov_bar = bar;
    g_prov_ts = (long)ts;
    GlobalVariableSet(GV_PROV_TIME, (double)g_prov_ts);
}

//==================================================================//
//                    PERSISTÊNCIA – GLOBAL VARIABLES               //
//==================================================================//

void LoadGlobalVars()
{
    if (GlobalVariableCheck(GV_BAR_SIZE))
    {
        double saved_size = GlobalVariableGet(GV_BAR_SIZE);
        if (MathAbs(saved_size - g_ctx.renko_size) > g_ctx.tick_size * 0.5)
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
            g_cur_last_price = g_ctx.current_bar.open_price; // [P1]

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
    g_cur_last_price = 0;
    g_prev_bid = 0;
    g_prev_ask = 0;
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

    double tol = g_ctx.tick_size * 0.5;
    for (int i = 0; i < count - 1; i++)
    {
        //--- [R4] na virada de pregão a grade reancora: a descontinuidade
        //--- entre o último brick de um dia e o primeiro do seguinte é
        //--- legítima. Sem esta exceção o corte diário forçaria
        //--- reconstrução total a cada restart do EA.
        bool virou_dia = (g_set.reset_diario &&
                          DiaDoTick((long)rates[i].time * 1000) !=
                              DiaDoTick((long)rates[i + 1].time * 1000));

        int dir_curr = (rates[i].close > rates[i].open) ? 1 : -1;
        int dir_next = (rates[i + 1].close > rates[i + 1].open) ? 1 : -1;
        double expected_open = (dir_curr == dir_next) ? rates[i].close : rates[i].open;
        double diff = MathAbs(rates[i + 1].open - expected_open);
        if (diff > tol && !virou_dia)
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
    if (MathAbs(renko_last_close - g_ctx.last_close) > g_ctx.tick_size * 0.5)
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

    datetime date_from = TimeCurrent() - (datetime)(g_set.history_days * 86400);

    //--- [R4] começa a varredura na virada de dia: com a grade
    //--- reancorando por pregão, um primeiro dia truncado reancoraria
    //--- num preço do meio da sessão. Custo: até um dia a mais de ticks.
    if (g_set.reset_diario)
        date_from = (datetime)(((long)date_from / 86400) * 86400);
    datetime date_to = TimeCurrent();

    MqlTick ticks[];
    ulong from_ms = (ulong)(date_from * 1000);
    ulong to_ms = (ulong)(date_to * 1000);

    Print(" from: ", TimeToString(date_from, TIME_DATE | TIME_SECONDS),
          " | to: ", TimeToString(date_to, TIME_DATE | TIME_SECONDS));

    // Zera estado completo
    g_ctx.last_close = 0;
    g_ctx.last_open = 0;
    g_ctx.last_direction = 0;
    g_ctx.last_bar_close_ms = 0; // [C1]
    g_ctx.last_seen_ms = 0;      // [C1]
    g_next_bar_time = 0;
    g_cur_last_price = 0;
    g_prev_bid = 0;
    g_prev_ask = 0;
    ZeroMemory(g_ctx.current_bar);

    // [M1] Um dia de ticks por vez, em vez dos InpHistoryDays de uma só
    // vez: o pico de memória cai para o de um único pregão. O resultado
    // é o mesmo — os ticks passam pelo mesmo ProcessTick na mesma ordem.
    // Cada pedaço vai até a virada do dia INCLUSIVE e o seguinte começa
    // nela: um tick exatamente na fronteira pode vir duas vezes, e o
    // filtro last_seen_ms [C1] descarta a repetição.
    const ulong DAY_MS = 86400000;
    long tick_total = 0;
    int bars_created = 0;
    int chunks_failed = 0;
    int last_error = 0;

    ulong chunk_from = from_ms;
    while (chunk_from < to_ms)
    {
        ulong chunk_to = (chunk_from / DAY_MS + 1) * DAY_MS;
        if (chunk_to > to_ms)
            chunk_to = to_ms;

        ResetLastError();
        int n = CopyTicksRange(g_ctx.base_symbol, ticks, g_ctx.flag_type, chunk_from, chunk_to);
        if (n < 0)
        {
            // uma segunda tentativa: o histórico de ticks pode estar sincronizando
            ResetLastError();
            n = CopyTicksRange(g_ctx.base_symbol, ticks, g_ctx.flag_type, chunk_from, chunk_to);
        }
        if (n < 0)
        {
            last_error = GetLastError();
            chunks_failed++;
            Print("AVISO: falha ao ler os ticks de ",
                  TimeToString((datetime)(chunk_from / 1000), TIME_DATE),
                  " (código ", last_error, "). O dia ficou fora da reconstrução.");
        }
        else
        {
            for (int i = 0; i < n; i++)
                ProcessTick(ticks[i], bars_created);
            tick_total += n;
        }

        chunk_from = chunk_to;
    }
    ArrayFree(ticks);

    if (tick_total <= 0)
    {
        Print("ERRO: Nenhum tick obtido para reconstrução. Código: ", last_error);
        return false;
    }

    Print("Ticks obtidos para reconstrução: ", tick_total,
          (chunks_failed > 0 ? " — ATENÇÃO: " + IntegerToString(chunks_failed) + " dia(s) com falha de leitura" : ""));

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
//| [M2] from_ms usa last_seen_ms (nunca antes de last_bar_close_ms):|
//|      o filtro [C1] já descartava o que vinha antes, então o      |
//|      resultado é o mesmo e o ciclo copia muito menos ticks.      |
//|                                                                  |
//| [C4] Ponto único de saída: SaveGlobalVars é sempre chamado,     |
//|      independente de barras terem sido criadas ou não.           |
//+------------------------------------------------------------------+
void UpdateRenkoIncremental()
{
    // [M2] Busca ticks a partir do ÚLTIMO TICK VISTO (inclusive), não
    // mais do fechamento da última barra. ProcessTick já descartava
    // tudo com time_msc <= last_seen_ms [C1], então o que chega a ser
    // processado é idêntico — só deixa de copiar e percorrer, a cada
    // ciclo, todos os ticks do brick em formação. Sem tick visto
    // ainda, vale a âncora antiga.
    long anchor_ms = g_ctx.last_seen_ms;
    if (anchor_ms < g_ctx.last_bar_close_ms)
        anchor_ms = g_ctx.last_bar_close_ms; // nunca antes do fechamento
    ulong from_ms = (anchor_ms > 0)
                        ? (ulong)(anchor_ms)
                        : (ulong)((TimeCurrent() - 86400) * 1000);
    ulong to_ms = (ulong)TimeCurrent() * 1000 + 1000;

    MqlTick ticks[];
    int tick_count = CopyTicksRange(g_ctx.base_symbol, ticks, g_ctx.flag_type, from_ms, to_ms);

    int bars_created = 0;

    g_first_commit = 0; // [P1] registra onde cai a 1ª barra fechada do ciclo

    if (tick_count > 0)
    {
        for (int i = 0; i < tick_count; i++)
            ProcessTick(ticks[i], bars_created);
    }
    else if (g_ctx.last_close > 0)
    {
        InjectSyntheticTickIfGap();
    }

    // [P1] Reconcilia a provisória com as barras fechadas neste ciclo.
    // Se a primeira caiu exatamente no slot da provisória, já a
    // sobrescreveu — apagar aquele timestamp destruiria uma barra real.
    // Só sobra provisória órfã quando a barra fechada pegou um slot
    // POSTERIOR ao dela.
    if (g_prov_ts > 0 && g_first_commit > 0)
    {
        if (g_first_commit == (datetime)g_prov_ts)
        {
            g_prov_ts = 0; // o slot agora pertence a uma barra fechada
            ZeroMemory(g_prov_bar);
            GlobalVariableSet(GV_PROV_TIME, 0.0);
        }
        else
        {
            RemoveProvisionalBar();
        }
    }

    // [C4] Ponto único de saída — sempre salva, independente do resultado.
    SaveGlobalVars();

    if (bars_created > 0)
        TryOpenRenkoChart();

    RefreshProvisionalBar(); // [P1] redesenha o brick em formação
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
    synthetic.ask = ref_price + g_ctx.tick_size;
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
        bool condicaoLimiar = true;
        if (g_set.usar_limiar_agressao)
        {
            condicaoLimiar = vol < g_set.limiar_agressao;
        }

        bool is_buy = ((tick.flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) && (condicaoLimiar);
        bool is_sell = ((tick.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) && (condicaoLimiar);

        if (is_buy && !is_sell)
            buy_vol = vol;
        if (is_sell && !is_buy)
            sell_vol = vol;
    }
    else
    {
        if (g_prev_bid == 0)
        {
            g_prev_bid = tick.bid;
            g_prev_ask = tick.ask;
        }
        double mid_prev = (g_prev_bid + g_prev_ask) / 2.0;
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
        g_prev_bid = tick.bid;
        g_prev_ask = tick.ask;
    }
}

//+------------------------------------------------------------------+
//| DiaDoTick — o pregão a que um instante pertence [R4]             |
//|                                                                  |
//| Número do dia na hora do SERVIDOR, função pura do timestamp do   |
//| tick e nunca de TimeCurrent(): um corte pelo relógio dispararia  |
//| ao vivo mas nunca na reconstrução, onde só existem ticks, e os   |
//| dois caminhos produziriam gráficos diferentes.                   |
//+------------------------------------------------------------------+
long DiaDoTick(const long tick_ms)
{
    return (tick_ms / 1000) / 86400;
}

//+------------------------------------------------------------------+
//| ResetDia — virada de pregão [R4]                                 |
//|                                                                  |
//| Zerar last_close faz o próximo tick cair no ramo de              |
//| inicialização do ProcessTick, que reancora a grade em            |
//| AlignToGrid(primeiro preço do dia), como no começo da série. Não |
//| há brick parcial a emitir: o que estava acumulado no brick em    |
//| formação é descartado, como sempre foram os ticks anteriores ao  |
//| primeiro brick. g_next_bar_time e last_bar_close_ms são mantidos.|
//+------------------------------------------------------------------+
void ResetDia()
{
    g_ctx.last_close = 0;
    g_ctx.last_open = 0;
    g_ctx.last_direction = 0;
    g_prev_bid = 0;
    g_prev_ask = 0;
    ZeroMemory(g_ctx.current_bar);
}

double NormalizeToTick(double price)
{
    return MathRound(price / g_ctx.tick_size) * g_ctx.tick_size;
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
    // ------------------------------------------------------------------
    if (tick_ms <= g_ctx.last_seen_ms)
        return;

    // ------------------------------------------------------------------
    // [R4] Virada de pregão: o brick em formação não atravessa a noite
    // e a grade reancora no primeiro preço do dia novo.
    // ------------------------------------------------------------------
    if (g_set.reset_diario && g_ctx.last_seen_ms > 0 &&
        DiaDoTick(tick_ms) != DiaDoTick(g_ctx.last_seen_ms))
        ResetDia();

    g_cur_last_price = price; // [P1]

    // ------------------------------------------------------------------
    // Inicialização: primeiro tick de toda a sessão define nível base.
    // ------------------------------------------------------------------
    if (g_ctx.last_close == 0)
    {
        g_ctx.last_close = AlignToGrid(price);
        g_ctx.last_open = g_ctx.last_close;
        g_ctx.last_direction = 0;

        InitCurrentBar(g_ctx.last_close, tick_ms);

        if (g_next_bar_time == 0)
            g_next_bar_time = (datetime)(tick_ms / 1000);

        g_ctx.last_seen_ms = tick_ms;
        return;
    }

    // ------------------------------------------------------------------
    // [C2][C3] Primeiro tick real da barra — define open_time_ms.
    // ------------------------------------------------------------------
    if (g_ctx.current_bar.open_time_ms == 0)
    {
        double op = (g_ctx.current_bar.open_price > 0)
                        ? g_ctx.current_bar.open_price
                        : g_ctx.last_close;
        InitCurrentBar(op, tick_ms);
    }

    // ------------------------------------------------------------------
    // Acumula agressão APÓS open_time_ms estar definido [C3]
    // ------------------------------------------------------------------
    long buy_vol = 0, sell_vol = 0;
    EstimateAggression(tick, buy_vol, sell_vol);
    g_ctx.current_bar.buy_aggression += buy_vol;
    g_ctx.current_bar.sell_aggression += sell_vol;

    // ------------------------------------------------------------------
    // LOOP PRINCIPAL
    // Trigger usa real_renko_size = (N-1) × tick  [fórmula do livro]
    // Close  usa real_renko_size — tijolo fecha no nível correspondente
    // ------------------------------------------------------------------
    while (true)
    {
        if (price > g_ctx.current_bar.high_price)
            g_ctx.current_bar.high_price = price;
        if (price < g_ctx.current_bar.low_price)
            g_ctx.current_bar.low_price = price;

        double anchor_up = (g_ctx.last_direction == -1) ? g_ctx.last_open : g_ctx.last_close;
        double anchor_dn = (g_ctx.last_direction == 1) ? g_ctx.last_open : g_ctx.last_close;

        // Fórmula: dispara quando preço atinge (N-1) ticks acima/abaixo da âncora
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
            double bar_close =
                NormalizeToTick(bar_open + g_ctx.real_renko_size);

            bar.open = bar_open;
            bar.close = bar_close;
            bar.high = bar_close;
            bar.low = MathMin(bar_open, g_ctx.current_bar.low_price);
            if (bar.low > bar_open)
                bar.low = bar_open;
            if (bar.high < bar_close)
                bar.high = bar_close;

            bar.tick_volume = g_ctx.current_bar.buy_aggression;
            bar.real_volume = g_ctx.current_bar.sell_aggression;

            long open_ms = (g_ctx.current_bar.open_time_ms > 0)
                               ? g_ctx.current_bar.open_time_ms
                               : tick_ms;
            bar.spread = (int)MathMin(tick_ms - open_ms, 2147483647);

            CommitRenkoBar(bar, bars_created);

            g_ctx.last_open = bar_open;
            g_ctx.last_close = bar_close;
            g_ctx.last_direction = 1;
            g_ctx.last_bar_close_ms = tick_ms;

            InitCurrentBarFromClose(g_ctx.last_close);
            continue;
        }

        if (trigger_dn)
        {
            double bar_open = (g_ctx.last_direction == 1) ? g_ctx.last_open : g_ctx.last_close;
            double bar_close =
                NormalizeToTick(bar_open - g_ctx.real_renko_size);

            bar.open = bar_open;
            bar.close = bar_close;
            bar.low = bar_close;
            bar.high = MathMax(bar_open, g_ctx.current_bar.high_price);
            if (bar.high < bar_open)
                bar.high = bar_open;
            if (bar.low > bar_close)
                bar.low = bar_close;

            bar.tick_volume = g_ctx.current_bar.buy_aggression;
            bar.real_volume = g_ctx.current_bar.sell_aggression;

            long open_ms = (g_ctx.current_bar.open_time_ms > 0)
                               ? g_ctx.current_bar.open_time_ms
                               : tick_ms;
            bar.spread = (int)MathMin(tick_ms - open_ms, 2147483647);

            CommitRenkoBar(bar, bars_created);

            g_ctx.last_open = bar_open;
            g_ctx.last_close = bar_close;
            g_ctx.last_direction = -1;
            g_ctx.last_bar_close_ms = tick_ms;

            InitCurrentBarFromClose(g_ctx.last_close);
            continue;
        }

    } // fim while

    // ------------------------------------------------------------------
    // [C1] Atualiza last_seen_ms ao final.
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
    {
        counter++;
        if (g_first_commit == 0)
            g_first_commit = bar.time; // [P1]
    }
}

//==================================================================//
//                    ALINHAMENTO AO GRID                           //
//==================================================================//

double AlignToGrid(double price)
{
    double aligned =
        MathRound(price / g_ctx.real_renko_size) *
        g_ctx.real_renko_size;

    return NormalizeToTick(aligned);
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
        if (g_set.chart_template != "")
            ChartApplyTemplate(new_chart, g_set.chart_template);
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

    // [G1] a janela de inputs não mostra o que veio do arquivo: avisa aqui
    string cfg_text = StringFormat("RENKO %d ticks", g_set.renko_size_ticks);
    if (InpConfigModo == RENKO_CFG_OFF)
        cfg_text += " | config por ativo: desligada";
    else if (g_cfg_from_file > 0)
        cfg_text += StringFormat(" | %d parâmetro(s) da config salva do ativo (ver log)", g_cfg_from_file);
    else
        cfg_text += " | config: inputs";

    if (ObjectFind(0, OBJ_STATUS_CFG) < 0)
        ObjectCreate(0, OBJ_STATUS_CFG, OBJ_LABEL, 0, 0, 0);

    ObjectSetInteger(0, OBJ_STATUS_CFG, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, OBJ_STATUS_CFG, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, OBJ_STATUS_CFG, OBJPROP_YDISTANCE, 100);
    ObjectSetString(0, OBJ_STATUS_CFG, OBJPROP_TEXT, cfg_text);
    ObjectSetString(0, OBJ_STATUS_CFG, OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, OBJ_STATUS_CFG, OBJPROP_FONTSIZE, 10);
    ObjectSetInteger(0, OBJ_STATUS_CFG, OBJPROP_COLOR, (g_cfg_from_file > 0) ? clrOrange : clrGray);
    ObjectSetInteger(0, OBJ_STATUS_CFG, OBJPROP_SELECTABLE, false);

    ChartRedraw(0);
}

//==================================================================//
//                    FIM DO EA                                      //
//==================================================================//
