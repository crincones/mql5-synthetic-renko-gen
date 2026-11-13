# 💹 RenkoSynthetic EA (v3.12)

**Expert Advisor para MetaTrader 5 (MQL5) para geração de gráficos Renko, publicados em ativos sintéticos, para ativos BOLSA e FOREX**

![MQL5](https://img.shields.io/badge/Language-MQL5-blue.svg)
![Status](https://img.shields.io/badge/Status-Stable-green.svg)
![Version](https://img.shields.io/badge/Version-3.12-orange.svg)

---

## 📝 Descrição

O **RenkoSynthetic** é um gerador de ativos customizados que transforma o fluxo de ticks de um ativo base (como índices sintéticos ou pares de moedas) em um gráfico de barras Renko.

Diferente de geradores comuns, ele foi otimizado para manter a integridade dos dados mesmo após reconexões ou reinicializações do terminal, utilizando persistência via *Global Variables*.

Além disso, na estrutura `MqlRates` criada para o símbolo sintético com as barras Renko, os campos são utilizados de forma não convencional para armazenar informações adicionais de fluxo:

- `tick_volume` → representa a **agressão de compra**
- `real_volume` → representa a **agressão de venda**
- `spread` → representa o **tempo de duração da barra**

Essa adaptação permite embutir informações de microestrutura diretamente nas barras do gráfico sintético.

### 🖼️ Demonstração Visual

| Ativo Base (Original)                       | Ativo Sintético (Renko Gerado)                            |
| :------------------------------------------ | :-------------------------------------------------------- |
| ![Imagem do Ativo Base](img/baseSymbol.png) | ![Imagem do Ativo Renko](img/renkoSymbol.png)             |
| *Símbolo base com EA adicionado*            | *Gráfico Renko gerado.* **DEVE-SE USAR TEMPO GRÁFICO M1** |

---

## 🚀 Principais Novidades (v3.12)

- **[G1] Configuração por ativo:** a última configuração usada em cada ativo base é gravada em `MQL5\Files\RenkoSynthetic\<ativo>.cfg` e reaplicada quando o EA volta a ser colocado no mesmo ativo. Detalhes na seção [Configuração por ativo](#-configuração-por-ativo).
- **[M1] Reconstrução com menos memória:** o histórico é lido um dia de ticks por vez, em vez de todos os `InpHistoryDays` de uma só vez. O pico de memória passa a ser o de um único pregão; os ticks passam pelo mesmo processamento, na mesma ordem. Se a leitura de um dia falhar, o EA tenta de novo, avisa no log e segue com os demais dias (só aborta se nenhum tick for obtido).
- **[M2] Atualização incremental mais leve:** a cada ciclo do timer a busca de ticks começa no último tick já visto (`last_seen_ms`), e não mais no fechamento da última barra. O filtro [C1] já descartava o que vinha antes, então o gráfico gerado é o mesmo — o EA só deixa de copiar e percorrer, duas vezes por segundo, todos os ticks do tijolo em formação.

### v3.11

- **[R4] Corte de pregão:** na virada do dia (hora do servidor, tirada do timestamp do tick) o tijolo em formação é descartado e a grade reancora no primeiro preço do dia novo. O gap noturno deixa de ficar escondido dentro de um tijolo e a sequência de um pregão não se mistura com a do seguinte. A verificação de integridade aceita a descontinuidade de preço na virada de dia, e a reconstrução começa no início de um dia. Com `InpResetDiario = false` o gráfico é idêntico ao da v3.08.
- **[P1] Tijolo em formação no gráfico:** o tijolo que ainda não fechou é desenhado como uma barra provisória no próprio símbolo sintético, com o estilo de candle do gráfico e a agressão acumulada até o momento. Ela não consome timestamp nem altera o estado do gerador, é apagada antes de toda verificação de integridade e ao remover o EA, e um restart do terminal sabe apagar a provisória deixada pela sessão anterior. Desligável com `InpShowFormingBrick = false`.

### v3.08

- **[C5] Tijolo R-1:** o gatilho usa `N` ticks a partir da âncora e o corpo do tijolo tem `N-1` ticks (`InpRenkoSizeTicks = N`).

### v3.06 / v3.07

Foco em **consistência de fluxo ao vivo** e precisão milimétrica nos timestamps:

- **[C1] Filtro Anti-Double-Count:** Separação lógica entre o fechamento da barra (`last_bar_close_ms`) e o último tick visto (`last_seen_ms`), evitando o acúmulo duplicado de agressão.
- **[C2] Timestamp de Abertura Real:** O `open_time_ms` da barra reflete o primeiro tick real que pertence a ela, garantindo que a duração (spread) seja exata.
- **[C3] Ordem de Acumulação Corrigida:** Inicialização do tempo de abertura antes da contagem de agressão para garantir que o primeiro tick seja computado corretamente.
- **[C4] Persistência Robusta:** Ponto único de saída no processamento incremental para garantir que o estado seja salvo em qualquer cenário, eliminando riscos de dessincronização.

---

## ⚙️ Configurações de Usuário

O EA permite ajustes finos para se adaptar a diferentes volatilidades e necessidades de histórico:

| Parâmetro             | Descrição                                                         |
| :-------------------- | :---------------------------------------------------------------- |
| `InpConfigModo`       | Configuração por ativo: Automático, Só os inputs ou Desligado [G1]. |
| `InpRenkoSizeTicks`   | Tamanho de cada tijolo Renko em ticks.                            |
| `InpHistoryDays`      | Quantidade de dias para processar na reconstrução inicial.        |
| `InpUpdateIntervalMs` | Frequência de atualização do gráfico em milissegundos.            |
| `InpTemplate`         | Template (.tpl) a ser aplicado automaticamente no gráfico gerado. |
| `InpForceRebuild`     | Força a limpeza e reconstrução total do histórico.                |
| `InpResetDiario`      | Reancora a grade a cada dia novo (corte de pregão) [R4].          |
| `UsarLimiarAgressao`  | Ativa o filtro de agressão por tamanho de negócio (bolsa).        |
| `LimiarAgressao`      | Só negócios com volume abaixo deste valor contam como agressão.   |
| `InpShowFormingBrick` | Desenha o tijolo em formação como barra provisória [P1].          |

> **Print das Configurações:**  
> ![Configurações de Usuário](img/param.png)
>
> *O print é anterior à v3.12 e ainda não mostra o parâmetro `InpConfigModo`.*

---

## 💾 Configuração por ativo

A partir da v3.12 o EA lembra a última configuração usada em cada ativo. Ao iniciar, ele grava todos os parâmetros da tabela acima em `MQL5\Files\RenkoSynthetic\<ativo>.cfg` (texto `CHAVE=valor`, um arquivo por símbolo base) e os reaplica na próxima vez que for colocado no mesmo ativo.

Um EA não consegue alterar os próprios inputs, então a janela de inputs (F7) continua mostrando os valores padrão. No modo **Automático**, a regra para cada parâmetro é:

- **input diferente do padrão** → você mexeu nele: vale o input, e ele passa a ser o valor salvo;
- **input no padrão** → vale o valor salvo do ativo, se houver.

Para saber o que está valendo, o EA escreve no log uma linha por parâmetro vindo do arquivo e mostra no gráfico base uma linha de status, por exemplo `RENKO 15 ticks | 3 parâmetro(s) da config salva do ativo (ver log)`.

| Modo (`InpConfigModo`) | Comportamento                                                        |
| :--------------------- | :------------------------------------------------------------------- |
| Automático (padrão)    | A regra acima.                                                       |
| Só os inputs           | Ignora o arquivo, usa exatamente os inputs e grava por cima.         |
| Desligado              | Não lê nem grava nada.                                               |

**Pontos de atenção:**

- **Voltar um parâmetro ao padrão:** se o valor salvo é 15 ticks e você quer o padrão 11, deixar 11 no input não basta — o EA não distingue "deixei no padrão" de "escolhi o padrão". Use o modo *Só os inputs* uma vez.
- **Dois Renkos no mesmo ativo:** o arquivo é um por ativo base. Com dois gráficos do mesmo ativo em tamanhos diferentes, o que estiver no padrão assumiria o tamanho salvo pelo outro na próxima reinicialização. Nesse caso use *Só os inputs* ou *Desligado* em ambos.
- **Troca de vencimento:** o arquivo usa o nome exato do símbolo; um contrato novo começa nos padrões.

---

## 🛠️ Tecnologias e Lógica Interna

- **Detecção Automática de Ativo:** Identifica se o símbolo é **Forex** ou **Bolsa (Exchange)** para ajustar o modo de cálculo de agressão e flags de ticks.
- **Estimativa de Agressão:**
  - **Exchange:** Baseado em flags reais de `BUY`/`SELL`.
  - **Forex:** Baseado na variação do *Mid-Price* entre ticks.
- **Relógio de Timestamps:** Garante que cada barra tenha um timestamp estritamente crescente, essencial para a plotagem correta no MT5.
- **Gestão de Símbolos:** Cria automaticamente o símbolo com o sufixo `_RE` na pasta `Custom\Renko`.
- **Leitura de ticks:** a reconstrução lê um dia por vez [M1] e a atualização ao vivo busca apenas os ticks posteriores ao último já visto [M2].

---

## 📂 Estrutura do Código

O código está organizado em blocos modulares para facilitar a manutenção:

1. **Configuração por ativo:** `LoadSettings` e `SaveSettings` montam a configuração efetiva (`g_set`) e gravam o `.cfg`
2. **Persistência de estado:** `SaveGlobalVars` e `LoadGlobalVars`
3. **Integridade:** `CheckHistoryIntegrity` valida gaps de preço e timestamps
4. **Histórico:** `RebuildHistory` reconstrói o gráfico dia a dia; `UpdateRenkoIncremental` atualiza ao vivo
5. **Processamento:** `ProcessTick` gerencia o loop principal de criação de barras
6. **Corte de pregão:** `DiaDoTick` e `ResetDia` reancoram a grade na virada do dia
7. **Barra provisória:** `RefreshProvisionalBar` e `RemoveProvisionalBar` desenham e apagam o tijolo em formação
8. **Interface:** `DrawStatusText` exibe o tipo de ativo, a integridade e a origem da configuração no gráfico

---

## ✒️ Autor

- **Desenvolvedor:** `#property copyright "Carlos Rincones"`
- **GitHub:** https://github.com/crincones

---

*Este README foi gerado com base na análise técnica do código fonte RenkoSynthetic.mq5 v3.12.*
