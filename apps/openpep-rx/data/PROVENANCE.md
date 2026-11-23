# Medicamentos controlados (autocompletar da receita)

`gerar.mjs` produz `data/medicamentos-controlados.json`. O arquivo reúne as substâncias das listas A1, A2, A3, B1 e B2 da Portaria SVS/MS 344/1998 que tiveram dispensação no SNGPC, ordenadas pelo volume vendido. Cada substância traz até 6 apresentações (concentração, forma farmacêutica, unidade e quantidade), com a embalagem mais vendida.

## Como rodar

```sh
node scripts/medicamentos/gerar.mjs                   # 2026-06 a 2026-08
node scripts/medicamentos/gerar.mjs --meses=202608    # um mês só
node scripts/medicamentos/gerar.mjs --relatorio       # + top 10 por tipo e descrições não lidas
node scripts/medicamentos/gerar.mjs --verificar-listas  # confere as listas embutidas com o texto da RDC
```

Requisitos: Node 24, com o ICU completo das builds oficiais (necessário para `TextDecoder('windows-1252')`), e `curl`. O script não usa dependências npm.

- Os CSVs mensais do SNGPC têm cerca de 1,2 GB cada. Eles não são gravados em disco: o script faz `curl` e vai somando as linhas enquanto baixa (os 3 meses rodam em paralelo, levando uns 4 a 5 min).
- Os agregados (cerca de 1,4 MB por mês) e a lista CMED (16 MB) ficam em cache em `--cache=DIR`, em `$MEDICAMENTOS_CACHE` ou em `<tmpdir>/cockpit-rx-medicamentos`. Com o cache pronto, a geração leva menos de 1 s. Use `--refazer` para baixar tudo de novo.
- O script valida o resultado antes de gravar e aborta em caso de erro. A validação cobre:
  - a regex de caracteres da fonte do PDF;
  - os tamanhos máximos (nome ≤ 120, concentração ≤ 40, forma ≤ 60, unidade ≤ 40);
  - `quantidade` inteira de 1 a 999;
  - a ordenação;
  - que não haja `(concentracao, forma)` repetida;
  - que a soma das vendas das apresentações não passe das vendas da substância.

## Fontes

| O quê | Fonte |
|---|---|
| Vendas | Anvisa, dados abertos SNGPC, *Venda de medicamentos industrializados*: <https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/> (`EDA_Industrializados_AAAAMM.csv`, ISO-8859-1/windows-1252, `;`). Período: **2026-06 a 2026-08** (setembro/2026 estava parcial). |
| Códigos de receituário | *Dados Abertos – Venda de Medicamentos Industrializados Sujeitos à Escrituração no SNGPC: Documentação e Dicionário de Dados*, v3.00 (10/02/2026): <https://dados.anvisa.gov.br/dados/Dicionario_de_Dados_Painel_SNGPC_Venda_de_Industrializados.pdf> |
| Listas | **RDC nº 1.036, de 9/7/2026** (DOU 13/7/2026, Seção 1), com o Anexo I consolidado. Texto: <https://anvisalegis.datalegis.net/action/ActionDatalegis.php?acao=abrirTextoAto&tipo=RDC&numeroAto=00001036&seqAto=000&valorAno=2026&orgao=RDC/DC/ANVISA/MS&codTipo=&desItem=&desItemFim=&cod_menu=1696&cod_modulo=134&pesquisa=true>. Em 29/9/2026, é a RDC mais recente da página oficial <https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/controlados/lista-substancias>. O cabeçalho do anexo diz "Atualização n. 101", mas a tabela da Anvisa numera essa RDC como 102. |
| Formas farmacêuticas | Anvisa, *Vocabulário Controlado de Formas Farmacêuticas, Vias de Administração e Embalagens de Medicamentos* (2011): <https://www.gov.br/anvisa/pt-br/centraisdeconteudo/publicacoes/medicamentos/publicacoes-sobre-medicamentos/vocabulario-controlado.pdf> |
| Nomes comerciais (`busca`) | Lista de preços CMED, dados abertos: <https://dados.anvisa.gov.br/dados/TA_PRECO_MEDICAMENTO.csv>. Entram produtos não genéricos com "COMERCIALIZAÇÃO 2025 = Sim", no máximo 8 por substância, com o de referência (Novo) primeiro. Use `--sem-cmed` para gerar sem eles. |

Os valores de `TP_RECEITUARIO` segundo o dicionário de dados:

- 1: Receita de Controle Especial em 2 vias (Receita Branca)
- 2: Notificação de Receita B (Notificação Azul)
- 3: Notificação de Receita Especial (Notificação Branca)
- 4: Notificação de Receita A (Notificação Amarela)
- 5: Receita Antimicrobiano e GLP-1 em 2 vias

O dicionário **não tem código para a Notificação de Receita B2**: ela é escriturada como 2. Por isso `receituario` fica `{"NRA":"4","NRB":"2","NRB2":"2"}`. Os dados confirmam isso, porque a sibutramina aparece sob o código 2.

`fontes.listas.url` aponta para a página da Anvisa, e não para o texto da RDC, porque a URL do anvisalegis tem `=` e `_`, caracteres fora da regex permitida.

## Regras de montagem

- **Tipo**: A1, A2 e A3 viram `NRA`; B1 vira `NRB`; B2 vira `NRB2`. As listas vêm embutidas no script, copiadas da RDC 1.036, e ele confere as classificações pedidas. Por exemplo, zolpidem é B1; metilfenidato e lisdexanfetamina são A3; codeína e tramadol são A2.
- **Correspondência**: `DS_PRINCIPIO_ATIVO` é dividido em `+` e cada componente é comparado, por palavra inteira, com os nomes das listas. Cobre sais e ésteres (adendo 1.1): "Hemitartarato de zolpidem" casa com zolpidem.
- **Agrupamento e nome**:
  - Linhas que só diferem em caixa, acentos, hífens ou termos de hidratação são unidas. "Sulfato de morfina pentaidratado" vira "Sulfato de morfina", e "Cloridrato monohidratado de sibutramina" vira "Cloridrato de sibutramina".
  - Componentes repetidos são removidos: "metilfenidato + metilfenidato + metilfenidato" fica só metilfenidato.
  - O sal é mantido. Por isso "Hemitartarato de zolpidem" e "Zolpidem" (17 embalagens) saem como entradas separadas, assim como "Maleato de midazolam", "Midazolam" e "Cloridrato de midazolam".
- **Ranking (`vendas`)**: soma de `QT_VENDIDA`, que conta **embalagens** (caixas ou frascos), nas linhas com o código da notificação do tipo: 4 para NRA, 2 para NRB e NRB2. Se a substância não tem nenhuma linha com esse código, usa o total. As apresentações saem das mesmas linhas.
- **Combinações**: a substância controlada vem primeiro no nome e na concentração. A ordem das doses na descrição do SNGPC não segue a dos princípios ativos (ex.: `FOSFATO DE CODEÍNA + PARACETAMOL | 500MG + 30MG`). Por isso as doses são atribuídas por magnitude, com a tabela `COMBINACOES`, que diz qual componente tem a maior dose: "Fosfato de codeína + paracetamol" sai com "30 mg + 500 mg". Uma combinação fora da tabela com doses diferentes é descartada e aparece no relatório.
- **Forma**: vem das abreviações do Vocabulário Controlado; a via é incorporada quando faz parte do nome ("solução oral", "comprimido sublingual", "adesivo transdérmico"). Mapeamentos específicos:
  - `SOL GOT` e `SOL OR GOT` viram **"solução oral"**, para juntar as gotas orais com `SOL OR`.
  - Termos antigos: `CAP GEL (DURA)` vira "cápsula dura"; `COM LIB LENTA/CONTR` vira "comprimido de liberação prolongada"; `CAP GEL C/ MCGRAN AP` vira "cápsula dura de liberação prolongada".
  - Vias de injetáveis (IV/IM/EPI) são descartadas.
- **Concentração**: vírgula decimal, zeros finais removidos ("2,0 MG" vira "2 mg"), `mcg`, `mg/mL` e `mcg/h`. Mantém a unidade da fonte: "0,05 mg/mL" não é convertido.
- **Quantidade e unidade**: vêm da embalagem mais vendida para cada `(concentracao, forma)`.
  - Sólidos: número de unidades, com `CT 3 BL X 10` = 30; unidade "comprimidos" ou "cápsulas".
  - Adesivos: número por embalagem, unidade "adesivos".
  - Líquidos e injetáveis: número de recipientes, com a unidade descrevendo o recipiente, como "1 frasco de 20 mL", "50 ampolas de 1 mL" ou "25 frascos-ampola de 10 mL". Para ampolas, a quantidade é o número de ampolas da caixa, e não 1.
  - Acessórios depois de `+` (conta-gotas, seringa dosadora) são ignorados.

## Apresentações que vão na Receita de Controle Especial

Por decisão do prescritor (29/09/2026), algumas apresentações ficam no catálogo com `"receita": "RCE"` (regra `RCE` em `gerar.mjs`):

- tramadol até 100 mg por unidade, isolado ou associado;
- codeína + paracetamol com até 30 mg de codeína;
- buprenorfina em adesivo.

Em 30/09/2026 o prescritor estendeu a regra à letra dos adendos: codeína até 100 mg por unidade, isolada ou associada (inclui + paracetamol e + diclofenaco), e oxicodona de liberação prolongada até 40 mg, isolada ou com naloxona. O catálogo da RCE (`data/medicamentos-rce.json`) oferece todas essas apresentações; o formulário as tira da lista das notificações quando esse catálogo carrega, para aparecerem uma vez só.

## Decisões e limitações conhecidas

- **Isenções parciais mantidas em NRA**: nesses casos, a maior parte das vendas é em Receita de Controle Especial (código 1).
  - A2, adendos 2 e 3: preparações com até 100 mg de codeína ou tramadol por unidade vão em Receita de Controle Especial. Isso cobre quase todo o mercado: o tramadol tem 3,35 mi de embalagens no código 1 contra 57 mil no código 4.
  - A1, adendo 5: oxicodona LP até 40 mg vai em Receita de Controle Especial.
  - A1, adendo 8: buprenorfina em adesivo matricial vai em Receita de Controle Especial.
- **Excluídas por isenção total**: são substâncias B1 cujo adendo tira todas as preparações da notificação.
  - Fenobarbital, metilfenobarbital, barbital e barbexaclona (adendo 2) e perampanel (adendo 9) vão em Receita de Controle Especial.
  - Carisoprodol (adendo 16) é vendido sob prescrição sem retenção.
  - O fenobarbital teria cerca de 42 mil embalagens em NRB. Para incluí-los, remova-os de `ISENTAS`.
- **Cannabis**: não está nominalmente nas listas.
  - Produtos de Cannabis caem na A3 pelos adendos 2 e 10, mas, com THC ≤ 0,2%, vão em Receita de Controle Especial (adendo 12). O canabidiol sintético é C1.
  - O SNGPC não informa o teor de THC. Por isso, entram só as apresentações de "Cannabis sativa L." e "Canabidiol + tetraidrocanabinol" dispensadas majoritariamente (> 50%) com Notificação A.
  - "Canabidiol" isolado fica de fora, porque é ~82% código 1.
- **Cetamina e escetamina** permanecem em NRB, embora o uso seja restrito a estabelecimentos de saúde. Pela RDC 1.036, também são B1 o triexifenidil, o lemborexante e o remimazolam.
- **Qualidade da fonte**:
  - Há código de receituário trocado na origem (clonazepam com código 4, antidepressivos C1 com código 2).
  - Os dados vêm só de farmácias e drogarias privadas.
  - Aparecem embalagens hospitalares (ex.: morfina injetável em caixa com 50 ampolas).
  - Há erros de digitação (ex.: "1,05 mg + 25 mg" de bromazepam + sulpirida).
  - A mesma buprenorfina aparece como "10 mg" e "10 mcg/h", e o diazepam injetável como "5 mg/mL" e "10 mg/2 mL". O script mantém as duas formas como estão.
- **Volume pequeno**: substâncias com poucas vendas continuam no arquivo. Mazindol tem 1 embalagem e femproporex tem 9.
- **Fora do período**: a fentanila em adesivo não teve venda no período; só aparece o citrato de fentanila injetável.
- Uma substância sem nenhuma apresentação legível é descartada e aparece no relatório. Em 2026-06 a 2026-08, o único caso foi "Cloridrato de sibutramina + estearato de magnésio", com 1 embalagem.
- Os nomes comerciais da CMED não têm volume de vendas. A ordem é: referência (Novo), depois o número de apresentações na CMED, depois a ordem alfabética.

## Retenção de receita (antimicrobianos e GLP-1)

`gerar-retencao.mjs` gera `data/medicamentos-retencao.json`. O arquivo cobre os medicamentos vendidos sob prescrição com retenção da 2ª via, receita em 2 vias e escrituração com código 5 (`TP_RECEITUARIO` "Antimicrobiano e GLP-1"). Ele usa o mesmo cache de `gerar.mjs` (`sngpc-AAAAMM.tsv` e `cmed.csv`). Ele não importa `gerar.mjs`, que executa ao ser carregado; as funções comuns foram copiadas.

```sh
node scripts/medicamentos/gerar-retencao.mjs              # 2026-06 a 2026-08
node scripts/medicamentos/gerar-retencao.mjs --relatorio  # tabela GLP-1, top 20, não lidas, sem CMED, exclusões
```

### Escopo legal (conferido em 29/9/2026)

- **Norma-base: RDC nº 471, de 23/2/2021**, na redação da **RDC nº 973, de 23/4/2025** (DOU 24/4/2025, em vigor desde 23/6/2025). A RDC vale para "substâncias isoladas ou em associação … listadas na Instrução Normativa específica" e também para os sais, éteres, ésteres e isômeros dessas substâncias. A receita não tem modelo próprio.
  - Texto: <https://anvisalegis.datalegis.net/action/ActionDatalegis.php?acao=abrirTextoAto&tipo=RDC&numeroAto=00000471&seqAto=000&valorAno=2021&orgao=RDC%2FDC%2FANVISA%2FMS&codTipo=&desItem=&desItemFim=&cod_menu=1696&cod_modulo=134&pesquisa=true>
- **Lista: IN nº 360, de 23/4/2025** (DOU 24/4/2025, retificada em 2/6/2025). O anvisalegis a marca como "Vigente" e não traz notas de alteração. Ela revogou a IN 244/2023.
  - Art. 1º: 131 antimicrobianos. O texto publicado não tem o item 42. A receita vale 10 dias.
  - § 1º: a lista "não se aplica aos antimicrobianos de uso exclusivo hospitalar".
  - Art. 2º: GLP-1 (semaglutida, liraglutida, dulaglutida, tirzepatida e lixisenatida), "isoladas ou em associação". A receita vale 90 dias.
  - Texto: <https://anvisalegis.datalegis.net/action/ActionDatalegis.php?acao=abrirTextoAto&tipo=INM&numeroAto=00000360&seqAto=000&valorAno=2025&orgao=DC%2FANVISA%2FMS&codTipo=&desItem=&desItemFim=&cod_menu=1696&cod_modulo=134&pesquisa=true>
- **Associações com insulina estão no escopo**: insulina degludeca + liraglutida (Xultophy) e insulina glargina + lixisenatida (Soliqua).
  - O texto da IN diz "isoladas ou em associação".
  - A notícia da Anvisa sobre a norma cita Soliqua e Xultophy.
  - No SNGPC há 112 mil embalagens dessas associações com código 5.
- **Tópicos, oftálmicos, otológicos e vaginais estão no escopo**.
  - Nem a RDC 471 nem a IN 360 excluem vias; a única exclusão é o uso exclusivo hospitalar.
  - O SNGPC registra esses produtos com código 5.
  - A exceção são os medicamentos isentos de prescrição (MIP), como neomicina ou neomicina + bacitracina de uso dermatológico (RDC 138/2003). Eles não são "de uso sob prescrição" e saem pela tarja da CMED; veja abaixo.
- Em `fontes`:
  - `antimicrobianos.url` aponta para a página do CONASS que reproduz a IN 360.
  - `glp1.url` aponta para a notícia oficial da Anvisa.
  - Não usei as URLs oficiais do texto (anvisalegis, bvsms, DOU) porque todas têm `=` ou `_`, caracteres fora da regex permitida.
  - `cmed.url` é a pasta de dados abertos; o arquivo é `TA_PRECO_MEDICAMENTO.csv`, a lista publicada em 21/07/2026.

### Regras de montagem

- **Entra no arquivo**: princípio ativo com pelo menos um componente da IN 360, ou um sal ou éster dele. Exemplos: benzoilmetronidazol, hiclato de doxiciclina, fosfomicina trometamol. Ficam de fora:
  - Substâncias que não estão na lista, mesmo antimicrobianas (rifaximina, nistatina, albendazol). Exceção: o **cefdinir**; veja "Decisões do prescritor".
  - Erros de codificação no código 5, como venlafaxina (794 mil), escitalopram e quetiapina. No total, 503 princípios ativos e 955 mil embalagens.
  - Apresentações que a CMED marca como "Tarja Sem Tarja" (MIP): neomicina + bacitracina pomada, 788 embalagens.
  - Apresentações que a CMED marca com "RESTRIÇÃO HOSPITALAR = Sim". Usei esse campo como aproximação do "uso exclusivo hospitalar" da IN, § 1º. A única exceção é o kit IM de ceftriaxona + lidocaína. A lista do que essa regra exclui está em "Excluídas por uso hospitalar".
- **Agrupamento**: o grupo é o conjunto de bases sem sal e sem hidratação. `chave` junta essas bases com `+`, na ordem do nome impresso:
  - primeiro os componentes da lista, em ordem alfabética;
  - os inibidores de beta-lactamase (clavulanato, sulbactam, tazobactam) vêm por último entre eles;
  - depois os demais componentes;
  - no GLP-1, a ordem é a do SNGPC ("insulina degludeca+liraglutida").
  - Grafias da DCB: ciprofloxacino, cefadroxila, benzilpenicilina (penicilina G), clavulanato (ácido clavulânico).
  - O `nome` é a grafia mais vendida, com os sais.
- **`uso`**: sai da via na descrição. OFT dá oftálmico, OTO dá otológico, VAG/GINEC/OVL dá vaginal, DERM/TOP/NAS dá tópico, e o resto é sistêmico. A mesma substância pode aparecer em mais de um `uso` (metronidazol: sistêmico, vaginal e tópico). O par (`chave`, `uso`) é único.
- **Doses de associações**: a ordem das doses na descrição não segue a ordem, alfabética, dos princípios ativos (ex.: `DEXAMETASONA + TOBRAMICINA | 3 MG/ML + 1 MG/ML`). A tabela `ASSOCIACOES` diz, para cada associação, qual componente tem a maior dose em massa e quais são dosados em UI/U, conforme a composição da bula. As doses são atribuídas por unidade e magnitude e impressas na ordem do nome ("Tobramicina + dexametasona 3 mg/mL + 1 mg/mL").
  - Associação com doses diferentes fora da tabela é descartada e aparece no relatório.
  - Quando a concentração passa de 40 caracteres, ela é fatorada: `(3,5 mg + 10.000 UI + 0,25 mg + 20 mg)/mL`.
- **Formas**: seguem as abreviações do Vocabulário Controlado, com a via incorporada ao nome quando faz parte dele ("solução oftálmica", "pó para suspensão oral", "creme vaginal"); `via` é um campo à parte.
  - Os kits de H. pylori (amoxicilina + claritromicina + IBP) saem com `forma: "kit"`, que não é termo do vocabulário.
  - Injetáveis sem via na descrição herdam a via injetável mais vendida do grupo. Se o grupo não tiver nenhuma, saem com `"injetável"`.
- **Unidade e quantidade**: seguem a regra de `gerar.mjs` (unidades contáveis no plural; recipiente com volume: "frasco de 5 mL", "bisnaga de 30 g"). Pó injetável sai como "frasco-ampola com diluente", sem volume.
  - Massa normalizada: 0,5 g vira 500 mg; 1000 mg vira 1 g; 0,05 mg/mL vira 50 mcg/mL.
  - Fosfomicina trometamol sai como "5,631 g", a massa do sal, como está no registro (equivale a 3 g de fosfomicina).
- **Marcas e genérico** (lista de preços CMED):
  - Cada descrição do SNGPC é casada com a coluna APRESENTAÇÃO da CMED, pelo mesmo texto de registro, ignorando espaços e pontos de milhar, e pela mesma substância.
  - `marcas`: produtos não genéricos cujo nome não é o da própria substância, ordenados pelo volume do SNGPC que casou com eles; no máximo 8.
  - `generico`: `true` se alguma apresentação casada é genérica.
  - 620 descrições (1,1 mi de embalagens, ~3%) não acharam par. Como as apresentações juntam várias descrições com a mesma concentração, forma e via, marcas e genérico vêm das descrições irmãs; só fica `marcas: []` quando nenhuma irmã casou.
  - O laboratório é lido da CMED, mas não é gravado (não está no esquema).
- **GLP-1: todas as apresentações com preço na CMED**, inclusive as sem venda no período (`vendas: 0`). Apresentações com os mesmos campos são unidas, somando as marcas: Ozempic e Extensior, Wegovy e Poviztra, e as canetas de 1 mg (4 × 1 mg em 3 mL) de Ozempic, Extensior, Wegovy, Poviztra e Ozivy. `dose`, `doses` e `dispositivo` vêm do texto do registro combinado com as bulas:
  - Seringa preenchida com caneta aplicadora (Mounjaro, Trulicity) ou frasco-ampola (Mounjaro FA): dose única = concentração × volume. A concentração sai como "2,5 mg/0,5 mL".
  - Mounjaro Multidose (2,4 mL): 4 doses fixas de 0,6 mL; sai como "2,5 mg/0,6 mL".
  - Semaglutida em caneta:
    - "(DOSES 0,25MG E 0,5 MG)" ou 6 agulhas: dose "0,25 mg ou 0,5 mg", sem número fixo de doses.
    - As demais: 4 doses fixas de (conteúdo total ÷ 4), ou seja, 0,25; 0,5; 1; 1,7 ou 2,4 mg (Wegovy/Poviztra, e Ozempic/Extensior/Ozivy 1 mg).
    - A concentração fica a do registro (mg/mL).
  - Doses ajustáveis:
    - liraglutida: Victoza e Lirux de 0,6 a 1,8 mg; Saxenda e Olire de 0,6 a 3 mg;
    - Xultophy: 1 a 50 U + 0,036 a 1,8 mg;
    - Soliqua 100/50: 10 a 40 U + 5 a 20 mcg;
    - Soliqua 100/33: 30 a 60 U + 10 a 20 mcg.
  - O texto do SNGPC não traz a marca. Quando uma descrição casa com marcas de doses diferentes (a mesma descrição EMS de Lirux e Olire), as vendas são divididas igualmente.
  - O campo "COMERCIALIZAÇÃO 2025" da CMED só diz se o produto foi vendido em 2025; lançamentos de 2026 aparecem com "Não". O script não usa esse campo para filtrar; ele só entra no `--relatorio`.
- **Ranking**: `vendas` soma as embalagens com código 5, ou o total, quando a substância não tem nenhuma linha com código 5. GLP-1 vem antes dos antimicrobianos; dentro de cada classe, a ordem é por vendas. Antimicrobianos têm no máximo 8 apresentações; GLP-1 tem todas.

### Decisões do prescritor (29/9/2026)

1. **Cefdinir incluído, embora fora da IN 360/2025.** As farmácias retêm a receita: são 70 mil embalagens com código 5. A substância sai com `"fora_da_lista": true`; a lista das exceções fica em `FORA_DA_LISTA`. `chave`: `cefdinir`. Apresentações: Terza e Tercen, 50 e 25 mg/mL, pó para suspensão oral.
2. **Kit IM de ceftriaxona + lidocaína incluído**, apesar de a CMED marcá-lo com restrição hospitalar. Ele é usado no tratamento ambulatorial da gonorreia. A exceção fica em `HOSPITALAR_LIBERADO` e vale para `ceftriaxona+lidocaina` por via intramuscular. Ela devolveu 33,6 mil embalagens à apresentação "1 g + 10 mg/mL" (Rocefin, Triaxton). As demais exclusões hospitalares continuam; veja a lista abaixo.
3. **Produtos antes não lidos, incluídos com a composição da bula** (linhas novas em `ASSOCIACOES` e, para descrições sem dose, em `COMPOSICAO_BULA`):
   - **Oto-Betnovate** (Farmoquímica), `clorfenesina+betametasona+tetracaina`, otológico, 121 mil.
     - Bula: por mL, valerato de betametasona 1,214 mg (= 1 mg de betametasona), clorfenesina 10 mg, cloridrato de tetracaína 5 mg.
     - Sai como "10 mg/mL + 1 mg/mL + 5 mg/mL".
     - Fonte: <https://img.drogasil.com.br/raiadrogasil_bula/OTOBETNOVATE.pdf>
   - **Decadron Nasal** (Aché), `neomicina+dexametasona+fenilefrina`, tópico (via nasal), 70,5 mil.
     - Bula: por mL, sulfato de neomicina 5,83 mg (= 3,5 mg de neomicina), fosfato dissódico de dexametasona 0,546 mg (= 0,5 mg de dexametasona fosfato), cloridrato de fenilefrina 5 mg.
     - Sai como "3,5 mg/mL + 0,5 mg/mL + 5 mg/mL".
     - Fonte: <https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Decadron-Nasal-Profissional-Consulta-Remedios.pdf>
   - **Trivagel-N creme vaginal** (Marjan), `neomicina+dexametasona+nistatina`, vaginal, 106 mil.
     - A descrição do SNGPC não traz dose.
     - Bula: cada 5 g contém dexametasona (fosfato dissódico) 0,32 mg, nistatina 100.000 UI, sulfato de neomicina 10 mg, tirotricina 2 mg, propionato de sódio 50 mg e ácido bórico 150 mg.
     - Nome e concentração seguem os três ativos do registro (SNGPC/CMED): "(10 mg + 0,32 mg + 100.000 UI)/5 g". Tirotricina, propionato de sódio e ácido bórico não entram.
     - Fonte: <https://www.marjan.com.br/wp-content/uploads/2022/11/BULA-TRIVAGEL-N-CREME-VAG_408438_A.pdf>
   - **Dermacerium** creme e HS gel (Cristália), `sulfadiazina+cerio`, tópico, 25 mil.
     - O SNGPC escreve "1 + 0,4", sem unidade.
     - Bula: cada 1 g contém sulfadiazina de prata 10 mg e nitrato de cério 4 mg.
     - Sai como "1% + 0,4%", como na CMED. A bula também descreve o Dermacerium 2,2% (22 mg de nitrato de cério/g), que não aparece no SNGPC.
     - Fonte: <https://img.drogasil.com.br/raiadrogasil_bula/Dermacerium.pdf>

Nenhuma `chave` existente mudou.

### Excluídas por uso hospitalar (CMED "RESTRIÇÃO HOSPITALAR = Sim"), para revisão

São 95 descrições e 26,1 mil embalagens com código 5 em 2026-06 a 2026-08. A lista completa, descrição por descrição, sai em `--relatorio`.

| Substância | Embalagens | O que é |
|---|---:|---|
| Ceftriaxona dissódica | 16.301 | 1 g IV: caixas de 50 ou 100 FA, e FA com diluente IV de 10 mL (9.061) |
| Sulfato de gentamicina | 3.566 | 40 mg/mL, caixas de 50 ou 100 ampolas |
| Sulfato de amicacina | 2.129 | 250 mg/mL, caixas de 50 ampolas |
| Rifamicina SV sódica | 584 | spray, caixa com 50 frascos |
| Cloridrato de vancomicina | 567 | 500 mg IV, caixas de 20 ou 50 FA |
| Benzilpenicilina benzatina | 395 | 1.200.000 e 600.000 UI, caixa com 50 FA (embalagem hospitalar) |
| Meropeném | 393 | 500 mg e 1 g IV, caixas de 10 ou 25 FA |
| Ertapeném sódico | 358 | 1 g IM/IV |
| Cloranfenicol + colagenase | 280 | pomada, caixa com 10 bisnagas |
| Amoxicilina + clavulanato de potássio | 250 | suspensão em caixa com 50 frascos; 1 g + 200 mg IV |
| Cefalotina sódica | 159 | 1 g, caixa com 50 FA |
| Cloridrato de clindamicina | 151 | 150 mg/mL injetável, caixa com 100 ampolas |
| Azitromicina | 141 | suspensão em caixa com 50 frascos |
| Sulfadiazina de prata | 118 | potes de 400 g e caixas hospitalares |
| Cloridrato de tetraciclina | 108 | 500 mg, embalagem hospitalar com 300 cápsulas |
| Piperacilina + tazobactam | 107 | 4 g + 500 mg IV |
| Outros, com menos de 100 embalagens cada | 505 | daptomicina, metronidazol, cefepima, levofloxacino, amoxicilina, cloranfenicol + desoxirribonuclease + fibrinolisina, ciprofloxacino, ceftazidima, teicoplanina, cefalexina, ampicilina, polimixina B, ampicilina + sulbactam, mupirocina, linezolida, doxiciclina, cefazolina, sulfametoxazol + trimetoprima, ceftazidima + avibactam, nitrofurantoína, Dermacerium em caixa com 60 bisnagas |

### Limitações conhecidas

- **Descrições não lidas**: 60 descrições, 10,8 mil embalagens (antes eram 334 mil). Sobram casos pequenos:
  - descrições sem forma farmacêutica: moxifloxacino 5 mg/mL "CT FR ... GOT", 6,5 mil; metronidazol "250 MG CX COM ...";
  - descrições sem dose: neomicina + hialuronidase + lidocaína otológico; ácido fusídico "2 CREM";
  - associações raras sem regra na tabela: metronidazol + benzalcônio + lisozima + nistatina; neomicina + bismuto + procaína;
  - variantes de kit de H. pylori.
- **Cobertura**: 99,9% das embalagens com código 5 das substâncias em escopo entram no arquivo.
- Metronidazol "100 mg/g gel" sem via na descrição fica como tópico (1,6 mil embalagens); provavelmente é gel vaginal.
- **Mudança de 30/9/2026**: a partir dessa data, pela nova etapa do SNCR (RDC 873/2024), as receitas sujeitas a retenção passam a ser emitidas e registradas no SNCR.

## Receita de Controle Especial (RCE)

`gerar-rce.mjs` gera `data/medicamentos-rce.json`. O esquema é o mesmo de `medicamentos-retencao.json`; em `classe` vai a lista: `C1`, `C5`, `A1-adendo`, `A2-adendo`, `A3-adendo` ou `B1-adendo`. O script usa o mesmo cache (`sngpc-AAAAMM.tsv`, `cmed.csv`) e não importa os outros geradores, porque eles executam ao ser carregados.

```sh
node scripts/medicamentos/gerar-rce.mjs --relatorio   # top 30 e exclusões por motivo
```

### Escopo (Anexo I na redação da RDC nº 1.036/2026, a mesma de `gerar.mjs`)

- **C1** (213 substâncias) e **C5** (31) são as listas "sujeitas à Receita de Controle Especial em duas vias". As exceções vêm dos adendos:
  - C1, adendo 2: loperamida é venda sem retenção; fica fora.
  - C1, adendo 4: misoprostol só pode ser usado em hospital; fica fora.
  - C1, adendo 5: a tetracaína só retém receita em uso oftálmico. Colutório e gotas otológicas (Oto-Betnovate) ficam fora.
  - C1, adendo 7: benzidamina em pó extemporâneo, solução ginecológica, spray, pastilha, colutório, pasta ou gel fica fora.
  - C1, item 13: o canabidiol só é C1 quando sintético. Veja Cannabis abaixo.
  - C5, adendo 2: anabolizante de uso tópico (testosterona gel) é venda sem retenção; fica fora.
- **Adendos das listas A e B que mandam preparações para a RCE**, incluídas como entradas `<lista>-adendo`. A condição é verificada apresentação por apresentação, após a atribuição das doses (`ADENDOS` no script):

  | Adendo | Substância | Condição |
  |---|---|---|
  | A1, 2 | difenoxilato | até 2,5 mg, associado a atropina |
  | A1, 3 | ópio | até 50 mg/mL (5 mg de morfina anidra/mL) |
  | A1, 5 | oxicodona | comprimido de liberação controlada, até 40 mg |
  | A1, 8 | buprenorfina | adesivo transdérmico |
  | A2, 2 | codeína, di-hidrocodeína, etilmorfina e outras | até 100 mg por unidade e até 2,5% nas formas indivisíveis |
  | A2, 3 | tramadol, isolado ou associado | até 100 mg |
  | A2, 4 | dextropropoxifeno | até 100 mg e até 2,5% |
  | A2, 5 | nalbufina | até 10 mg |
  | A2, 6 | propiram | até 100 mg |
  | A3, 10 e 12 | produtos de Cannabis | THC até 0,2% (critério abaixo) |
  | B1, 2 | fenobarbital, metilfenobarbital, barbital, barbexaclona | todas as apresentações |
  | B1, 9 | perampanel | todas as apresentações |

  - A dose é lida como em `gerar.mjs`: o primeiro número em mg do componente. Por isso tramadol 100 mg/mL em gotas conta como 100 mg e entra.
  - **Cannabis:** o SNGPC não informa o teor de THC. Entram as descrições dispensadas majoritariamente fora da Notificação A, que é o complemento da regra do catálogo de notificações. "Canabidiol" e "Cannabis sativa L." saem como `A3-adendo`. O canabidiol sintético seria C1, e também vai em RCE.
- **Ficam de fora:**
  - C2 (retinoides): os sistêmicos vão em Notificação de Receita Especial e os tópicos são venda sem retenção (adendo 2). Nenhum item de C2 usa RCE.
  - C3 (talidomida, lenalidomida, pomalidomida): têm notificação própria.
  - Esta redação do Anexo I **não tem lista C4** (antirretrovirais).
  - B1, adendo 16: carisoprodol é venda sem retenção.
  - B1, adendos 14 e 15: cetamina e escetamina só podem ser usadas em estabelecimento de saúde; seguem a notificação.
  - Qualquer produto com componente A/B sem adendo aplicável vai em notificação: clonazepam, zolpidem, bromazepam + sulpirida, morfina, metilfenidato.
- **Pendente de confirmação do prescritor.** Pela letra dos adendos, estes produtos vão em RCE e estão no arquivo. No catálogo de notificações, porém, eles continuam em NRA por decisão do prescritor, e só tramadol, codeína + paracetamol e buprenorfina em adesivo foram confirmados. Os dois catálogos oferecem hoje formas de receita diferentes para eles.
  - codeína isolada: 261 mil embalagens com código 1;
  - codeína + diclofenaco: 26;
  - oxicodona LP: 23 mil;
  - oxicodona + naloxona (Targin): 6,6 mil.

### Regras de montagem (além das do catálogo de retenção)

- **Ranking**: `vendas` soma as embalagens com código 1 (`TP_RECEITUARIO` 1). Se a substância não tem nenhuma, usa o total. Cada substância tem no máximo 6 apresentações. A lista é ordenada só por vendas.
- **`chave`**: bases sem sal, na ordem do nome impresso. A ordem é: componentes A/B (adendo) e Cannabis, depois C1/C5, depois os demais, cada grupo em ordem alfabética. Há uma exceção de ordem: levodopa + carbidopa + entacapona, em `ORDEM_NOME`.
  - Os **ésteres de depósito das listas C** ficam na chave, porque têm produtos e posologias próprios: cipionato, undecilato e decanoato de testosterona, Durateston, decanoato de nandrolona, decanoato de haloperidol, decanoato de zuclopentixol, enantato de flufenazina e palmitato de paliperidona. Eles saem separados da forma sem éster; por exemplo, "decanoato de haloperidol" separado de "haloperidol".
  - Nomes da lista usados como base: "valproato de sodio" (a lista diz "Valproato sódico") e "divalproato de sodio", ambos distintos de "acido valproico"; e "litio" para o carbonato de lítio.
- **Associações** (`ASSOCIACOES`, doses atribuídas pela composição da bula ou do registro):
  - codeína + paracetamol;
  - tramadol + paracetamol;
  - oxicodona + naloxona;
  - bupropiona + naltrexona (90 mg + 8 mg);
  - levodopa + carbidopa + entacapona;
  - Durateston: por ampola, decanoato 100 mg, fempropionato 60 mg, isocaproato 60 mg e propionato 30 mg de testosterona;
  - donepezila + memantina: as doses seguem a ordem alfabética, e não a magnitude, por causa do kit de titulação 10 + 5;
  - ácido valproico + valproato de sódio: o registro traz só a dose total, "500 mg".
- A exclusão da CMED por uso hospitalar vale igual ao catálogo de retenção.

### Excluídas com código 1 (2026-06 a 2026-08)

| Motivo | Embalagens |
|---|---:|
| Fora das listas C1/C5 e sem adendo (código trocado na origem: antimicrobianos, GLP-1, princípio ativo vazio) | 1.397.844 |
| B1 sem adendo: vão em Notificação B (clonazepam 190 mil, zolpidem 152 mil, alprazolam 121 mil...) | 579.378 |
| A3 sem adendo: vão em Notificação A (metilfenidato, lisdexanfetamina) | 45.400 |
| C2, retinoides (isotretinoína 39,8 mil) | 41.925 |
| A1 sem adendo (morfina, metadona, tapentadol, fentanila) | 5.996 |
| B2 (sibutramina, anfepramona, femproporex) | 4.744 |
| C1, adendo 5: tetracaína otológica (Oto-Betnovate) | 4.184 |
| Uso restrito a hospitais (CMED) | 2.281 |
| C5, adendo 2: testosterona gel | 205 |
| Cannabis dispensada majoritariamente com Notificação A | 181 |
| C1, adendo 2: loperamida | 161 |
| Descrições não lidas (15, ex.: kit de titulação donepezila + memantina, propofol emulsão) | 159 |
| B1, adendo 16: carisoprodol | 62 |

A exclusão hospitalar tira sobretudo caixas de 25 a 100 ampolas:
- enantato de flufenazina: 983;
- tramadol injetável em caixas de 60 e cápsulas × 50: 274;
- haloperidol e decanoato de haloperidol: 159;
- fenitoína injetável: 103.

Outras dezenas saem com menos de 100 embalagens cada. A lista completa sai em `--relatorio`.

### Limitações

- O arquivo tem 111 substâncias, com 99,99% das embalagens com código 1 das substâncias em escopo:
  - por classe: C1 90, C5 8, A2-adendo 6, A1-adendo 3, A3-adendo 2, B1-adendo 2;
  - por uso: 108 sistêmicas e 3 oftálmicas.
- 846 descrições (1,7 mi de embalagens) não acharam par na CMED. Marcas e genérico vêm das descrições irmãs; os produtos de Cannabis não estão na lista CMED e ficam sem marca.
- Mantive a forma do registro mesmo quando o produto é de liberação prolongada: a venlafaxina "75 MG CAP GEL DURA" (Venlift OD, 1 mi de embalagens) sai como "cápsula dura".

## Notificações especiais: NRR e NRT

`gerar-especiais.mjs` gera `data/medicamentos-especiais.json`. O esquema é o de `medicamentos-rce.json`, com o campo `tipo` a mais em cada substância: `"NRR"` para a lista C2 e `"NRT"` para a C3. O script usa o mesmo cache e as mesmas validações de texto e tamanho. As vendas vêm do SNGPC com `TP_RECEITUARIO` 3 (Notificação de Receita Especial).

```sh
node scripts/medicamentos/gerar-especiais.mjs --relatorio
```

- **NRR (C2, retinoides sistêmicos)**, conforme o Anexo I na redação da RDC nº 1.036/2026. Os de uso tópico (adapaleno, tretinoína e isotretinoína em gel ou creme, e suas associações) são venda sob prescrição sem retenção pelo adendo 2 e ficam de fora.
- **NRT (C3, talidomida)**: a Notificação de Receita de Talidomida da RDC nº 11/2011 (validade de 20 dias, com termo de responsabilidade/esclarecimento).
  - A talidomida é dispensada só em unidades públicas e não tem venda no SNGPC. Ela entra pela lista CMED (FUNED, 100 mg comprimido, 30 comprimidos) com `vendas: 0`.
  - **Lenalidomida e pomalidomida ficam de fora.** Pelo adendo 4 da C3, elas seguem a RDC nº 735/2022, que usa a *Notificação de Receita da Lista C3*: um formulário próprio obtido conforme o Programa de Prevenção de Gravidez (PPG) do detentor do registro, e não a NRT. A CMED lista 66 apresentações dessas duas substâncias: Revlimid, Nuvyor, Lassya, Lenangio, Lyone e genéricos de lenalidomida, e Pomalyst.
- **Apresentações**: todas as apresentações sistêmicas com preço na CMED entram, com ou sem venda no período. As que não venderam saem com `vendas: 0`.
  - Ficam de fora as marcadas com "RESTRIÇÃO HOSPITALAR" (isotretinoína 20 mg em caixa com 500) e as isentas de prescrição.
  - `marcas` traz todas as marcas não genéricas, ordenadas pelo volume do SNGPC atribuído a cada uma. Nome de produto que contém a substância é reduzido ao resto ("FUNED - TALIDOMIDA" vira "Funed").
  - `quantidade` vem da embalagem mais vendida; sem venda, da embalagem mais frequente na CMED.
  - Cápsula descrita sem "DURA"/"MOLE" ("20 MG CAP BL X 100", "10 MG CAP GEL") é somada à cápsula de mesma concentração.
- **Resultado (2026-06 a 2026-08)**:
  - isotretinoína: 20 mg (637 mil embalagens) e 10 mg (12,5 mil), cápsula mole × 30;
  - acitretina: 25 mg (74) e 10 mg (62), Neotigason e genérico;
  - tretinoína 10 mg cápsula mole × 100 (Vesanoid, 7 embalagens);
  - talidomida 100 mg (0).
  - Não há isotretinoína 40 mg nem bexaroteno na CMED ou no SNGPC.
- **Excluídas com código 3**:
  - 1,16 mi de embalagens de substâncias fora das listas C2/C3, código trocado na origem (sertralina, quetiapina, pregabalina, escitalopram, tramadol...);
  - 336 de retinoides tópicos;
  - 30 de uma descrição não lida (tretinoína "1,00MG/G CREME").
