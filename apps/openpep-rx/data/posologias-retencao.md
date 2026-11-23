# Posologias de retenção: antimicrobianos e agonistas de GLP-1

`posologias-retencao.json` (29/09/2026) tem 64 chaves: 58 de antimicrobianos e 6 de GLP-1. São 180 apresentações, 334 regimes e 29 calculadoras pediátricas.

O arquivo alimenta as sugestões de posologia de um clique na receita de retenção. Nada é preenchido sem clique, e o médico revisa. Cada apresentação corresponde a uma linha de `medicamentos-retencao.json`.

## Revisão do prescritor (29/09/2026, 2ª rodada)

- **Wegovy e Poviztra 7,2 mg:** aprovado. O `texto` do regime agora traz a condição: "Usar 7,2 mg somente após pelo menos 4 semanas com 2,4 mg por semana." O Poviztra é o mesmo produto, então recebeu o mesmo texto.
- **Rybelsus:** confirmado como está.
- **Itens novos do catálogo:** `cefdinir` (voltou; fora da IN 360, incluído pelo prescritor), `clorfenesina+betametasona+tetracaina` (Oto Betnovate), `neomicina+dexametasona+nistatina` (Trivagel N), `neomicina+dexametasona+fenilefrina` (Decadron Nasal) e `sulfadiazina+cerio` (Dermacerium creme e HS Gel).
- **Ceftriaxona:**
  - O kit `ceftriaxona+lidocaina` "1 g + 10 mg/mL" ganhou posologia.
  - Nos kits IM de 1 g (as duas chaves e as duas grafias), o primeiro regime passou a ser o da gonorreia não complicada do PCDT IST 2022 (Quadro 31, edição vigente): ceftriaxona 500 mg IM, dose única. Com o frasco de 1 g, isso é metade do conteúdo reconstituído (1,75 mL de 3,5 mL).
  - As linhas de ceftriaxona e ceftriaxona+lidocaina continuam casando com o catálogo.

## Como foi feito

- **Escopo:**
  - Antimicrobianos: os de maior volume no SNGPC (receituário código 5, jun a ago/2026), com as variantes de sal somadas. Entram também os oftálmicos, otológicos, dermatológicos e vaginais desse recorte.
  - GLP-1: as apresentações à venda no Brasil em setembro de 2026.
  - A venlafaxina aparece no código 5 por erro de escrituração e ficou fora.
  - O cefdinir não está na lista da IN 360/2025 (não tem retenção), mas entrou a pedido do prescritor, como no catálogo.
- **Posologia:** vem da bula brasileira vigente, lida em PDF.
  - O Bulário Eletrônico da Anvisa bloqueia acesso automatizado (Cloudflare). Por isso a fonte é o PDF do fabricante (Novo Nordisk, Lilly, GSK, Pfizer, Novartis/Alcon, Allergan, Roche, Eurofarma, Bagó, Zambon, Abbott, Farmoquímica e outros) ou esse mesmo PDF espelhado em drogarias e agregadores (consultaremedios, drogasil, drogariasp, bula-anvisa.s3).
  - A URL lida está em `fontes`, em cada apresentação.
- **Durações que a bula não fixa** vêm de diretriz, nomeada item a item abaixo:
  - PCDT IST 2022 do Ministério da Saúde;
  - IDSA: faringite 2012, rinossinusite 2012, pele e partes moles 2014, cistite 2010;
  - ATS/IDSA PAC 2019 e AAP otite média 2013;
  - AAO Conjunctivitis PPP 2023 e AAO-HNSF otite externa 2014;
  - EAU infecções urológicas, NICE NG153/NG190, Diretriz SBC de febre reumática 2009 e V Consenso Brasileiro de H. pylori 2026.
  - Onde nem a bula nem a diretriz fixam a duração (vários tópicos), usei 7 dias por convenção, e o item diz isso.

## Junção com o catálogo

As strings foram alinhadas a `data/medicamentos-retencao.json` tal como estava em 29/09/2026 às 22:07 (113 substâncias). Com isso, todas as 180 apresentações daqui têm linha no catálogo:
- antimicrobianos, por (`chave`, `concentracao`, `forma`);
- GLP-1, por (`chave`, `concentracao`, `forma`, `dose`).

Se o catálogo mudar, rode `final.py` de novo (scratchpad `posologias/`): ele relê o catálogo, readota as strings e lista as divergências.

- **chave:** a do catálogo. A pesquisa usava outras grafias, que foram trocadas:

  | pesquisa | catálogo |
  |---|---|
  | `cefuroxima` | `axetilcefuroxima` (axetil é éster; pela regra "sem sal", o certo seria `cefuroxima`, e cabe corrigir no catálogo) |
  | `benzilpenicilina benzatina` | `benzilpenicilina` |
  | `sulfadiazina de prata` | `sulfadiazina` |
  | `cloranfenicol+retinol+aminoacidos+metionina` | `cloranfenicol+aminoacidos+metionina+retinol` |
  | `gentamicina+tolnaftato+clioquinol+betametasona` | `gentamicina+betametasona+clioquinol+tolnaftato` |
  | `benzoilmetronidazol+nistatina+benzalconio` | `benzoilmetronidazol+benzalconio+nistatina` |

  - O catálogo separa a mesma chave por `uso` (ciprofloxacino sistêmico e oftálmico; metronidazol sistêmico e vaginal). Aqui há um item por chave, e a via está na `forma` de cada apresentação.
  - `ceftriaxona` e `ceftriaxona+lidocaina` existem nos dois arquivos, com o mesmo conteúdo.
  - A suspensão de benzoilmetronidazol está só em `benzoilmetronidazol`.
- **forma:** a do catálogo, com a via no nome: `solução oftálmica`, `suspensão otológica`, `pomada oftálmica`, `creme vaginal`, `gel vaginal`, `pomada vaginal`, `granulado para solução oral`, `kit` etc. Tópicos dermatológicos continuam `pomada`, `creme` e `solução spray`.
- **concentracao:** a do catálogo, conferida por valor, não por texto.
  - O catálogo usa ponto de milhar (`6.000 UI/mL`, `1.500 mg`), fatoração (`(400 mg + 57 mg)/5 mL`), `U` na benzatina (`300.000 U/mL`), mcg na lixisenatida (`100 U/mL + 50 mcg/mL`) e, na seringa ou frasco de dose única, dose/volume (`2,5 mg/0,5 mL`).
  - O mesmo produto aparece com mais de uma grafia no SNGPC, e cada grafia virou uma linha no catálogo. A posologia foi copiada para cada uma, por exemplo:
    - `80 mg/mL + 11,4 mg/mL` e `(400 mg + 57 mg)/5 mL`;
    - `50 mg/mL` e `250 mg/5 mL`;
    - `granulado` e `granulado para solução oral` (fosfomicina);
    - `solução spray` e `solução` (rifamicina);
    - `3,5 mg/mL + 1 mg/mL` e `3,5 mg + 1 mg`;
    - neomicina 5 mg (sulfato) e 3,5 mg (base) no Maxitrol;
    - betametasona 0,64 e 0,5 mg/g no Diprogenta.
- **GLP-1:** o catálogo une marcas equivalentes numa mesma linha, com a lista em `marcas`. Aqui, cada apresentação tem uma `marca`, e a junção natural é `marca` presente em `marcas` com a mesma `dose`. As `dose` são as do catálogo (Xultophy `1 a 50 U + 0,036 a 1,8 mg`; Soliqua `10 a 40 U + 5 a 20 mcg` e `30 a 60 U + 10 a 20 mcg`). Três casos não fecham só pela marca:
  - **Semavy** (Hypera, à venda desde 04/09/2026) não está em `marcas`, porque a CMED do catálogo é de 21/07. Casa por concentração, forma e dose.
  - **Mounjaro frasco-ampola:** o catálogo tem `marcas: ["Mounjaro"]` para a caneta e para o frasco, que diferem só em `unidade`/`dispositivo`. Aqui o esquema não tem campo de unidade, então o frasco está como `marca: "Mounjaro frasco-ampola"`, com texto próprio (seringa e agulha novas, que não vêm na caixa). A UI precisa escolher o regime pelo `dispositivo` do catálogo.
  - **Mounjaro Multidose (KwikPen):** tem 6 linhas no catálogo, com preço na CMED e sem venda. Não há posologia aqui porque não achei lançamento confirmado nem bula brasileira pública. O seletor vai mostrá-lo sem sugestões.
- **quantidade:** na unidade de dispensação, cobrindo `dias`.
  - GLP-1:
    - canetas de semaglutida, liraglutida, Xultophy e Soliqua: número de canetas;
    - Mounjaro: 4 canetas de dose única por 28 dias, tanto na caixa de 4 quanto em 2 caixas de 2 (o catálogo diz "seringas preenchidas"), ou 4 frascos-ampola;
    - Trulicity: 4 canetas;
    - Rybelsus: 30 comprimidos.
    - Os semanais usam 28 dias; os diários, 30.
    - O exemplo do pedido (`quantidade: 1` para Mounjaro 2,5 mg) só faria sentido com a unidade "caixa", que o catálogo não usa.
  - Antimicrobianos: comprimidos, cápsulas, frascos, bisnagas, envelopes, frascos-ampola, óvulos e, nos kits, embalagem.
  - Suspensão pediátrica não tem quantidade: a UI calcula o volume.
- **Texto impresso:**
  - Tudo passa na regex do PDF.
  - O rótulo usa vírgula como separador. O "·" do exemplo do pedido está fora da regex.
  - O `texto` do `pediatrico` tem a lacuna `__`, e o sublinhado está fora da regex: a UI precisa trocar a lacuna pelo volume antes de imprimir.
  - 58 das 125 URLs de `fontes` têm "_". Isso só importa se `fontes` for impresso.
- **orientacoes do item:** só entra o que vale para todas as apresentações da chave. Onde há vias diferentes (ciprofloxacino, moxifloxacino, metronidazol, semaglutida com o Rybelsus), as orientações estão em cada apresentação.

## Notas legais

- **Antimicrobianos: RDC 471/2021**, alterada pela RDC 973/2025. Li o texto original de 2021.
  - A receita é o receituário comum do prescritor, sem modelo próprio, em **2 vias**.
  - A farmácia retém a 2ª via e anota data, quantidade, lote e rubrica nas duas.
  - Dados obrigatórios:
    - do paciente: nome completo, idade e sexo;
    - do medicamento: DCB, concentração, forma, posologia e quantidade em algarismos arábicos;
    - do prescritor: nome, conselho, endereço, telefone e assinatura;
    - a data.
  - **Validade: 10 dias.** Hoje ela está na IN 360/2025, art. 1º.
    - Pelo resumo do Conass, a lista tem 132 antimicrobianos.
    - Pelo README do catálogo, tem 131, porque falta o item 42.
    - A IN não se aplica ao uso exclusivo hospitalar.
  - Pode haver outros medicamentos na receita, desde que não sejam controlados.
  - **Tratamento prolongado (art. 9º):** vale por 90 dias, com "uso contínuo" e a quantidade para cada 30 dias.
- **GLP-1: RDC 973/2025 e IN 360/2025**, de 23/04/2025, em vigor desde 23/06/2025.
  - Abrangem semaglutida, liraglutida, dulaglutida, tirzepatida e lixisenatida, "isoladas ou em associação".
  - A receita é em **2 vias**, com retenção da 2ª, e **vale 90 dias**.
  - No uso contínuo, a receita traz a quantidade para cada 30 dias. Pelo P&R da Anvisa (jun/2025), cada dispensação cobre no mínimo 30 dias ou os 90 de uma vez.
  - **A conferir:** uma nota do CFF de 16/01/2026 fala em "até 30 dias por dispensação" e em emissão eletrônica integrada ao SNCR. Não achei o ato que teria mudado isso.
- **Insulinas combinadas:** pela letra "em associação", a retenção cobre Xultophy (degludeca + liraglutida) e Soliqua (glargina + lixisenatida).
  - Os dois aparecem no código 5 do SNGPC.
  - O README do catálogo diz que a notícia da Anvisa sobre a norma cita Soliqua e Xultophy.
- **Tópicos, oftálmicos, otológicos e vaginais:** segundo o README do catálogo, estão no escopo, porque nem a RDC nem a IN excluem vias. Ficam de fora só os isentos de prescrição (MIP).
- **SNCR, a partir de 30/09/2026:**
  - O README do catálogo diz que, nessa data, as receitas sujeitas a retenção passam a ser emitidas e registradas no SNCR, pela **RDC 873/2024**.
  - Um dos agentes de pesquisa citou para o mesmo tema a **RDC 1.000/2025** (prescrição eletrônica, integração ao SNCR a partir de 01/06/2026).
  - Não li nenhum dos dois textos. A divergência fica registrada e precisa ser conferida, porque afeta diretamente este sistema.
- **Fontes lidas:** a IN 360 e o texto consolidado da RDC 471 vieram de resumos oficiais (P&R da Anvisa, Conass, CFF) e do README do catálogo, que cita o anvisalegis.

## Fontes e notas por item: GLP-1

- **semaglutida** (21 apresentações: Ozempic 0,25 mg ou 0,5 mg; Ozempic 1 mg; Wegovy 0,25 mg; Wegovy 0,5 mg; Wegovy 1 mg; Wegovy 1,7 mg; Wegovy 2,4 mg; Rybelsus 3 mg; Rybelsus 7 mg; Rybelsus 14 mg; Extensior 0,25 mg ou 0,5 mg; Extensior 1 mg; Poviztra 0,25 mg; Poviztra 0,5 mg; Poviztra 1 mg; Poviztra 1,7 mg; Poviztra 2,4 mg; Ozivy 0,25 mg ou 0,5 mg; Ozivy 1 mg; Semavy 0,25 mg ou 0,5 mg; Semavy 1 mg). Bulas profissionais Novo Nordisk: Ozempic 1,5 mL e 3 mL, Wegovy (com 7,2 mg; atualização aprovada pela Anvisa em 04/05/2026), Rybelsus (aprovada em 08/09/2026: jejum de pelo menos 8 h, até 120 mL de água, esperar 30 min), Extensior (= Ozempic) e Poviztra (= Wegovy). Ozivy (EMS): bula do paciente, pois não achei a profissional; posologia igual à do Ozempic, mas a caneta em uso fica na geladeira e dura 8 semanas. Semavy (Hypera): bula profissional. Todas as doses e prazos vêm da bula. Wegovy/Poviztra 7,2 mg: o texto do regime traz a condição do prescritor (usar só após pelo menos 4 semanas com 2,4 mg por semana); são 3 injeções seguidas da caneta de 2,4 mg (3 canetas por 28 dias), só em adulto com IMC de pelo menos 30 no início, após 4 semanas ou mais com 2,4 mg. Ozempic e similares: máximo de 1 mg por semana no Brasil.
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Ozempic_1-5mL_0_25mg_0-5mg_Bula_Profissional.pdf
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Ozempic_3mL_1mg_Bula_Profissional.pdf
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Wegovy_Bula_Profissional.pdf
  - https://www.gov.br/anvisa/pt-br/assuntos/noticias-anvisa/2026/anvisa-aprova-atualizacao-da-posologia-do-medicamento-wegovy
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Rybelsus_Bula_PROFISSIONAL.pdf
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Bula_Profissional_Extensior_1,5_ml.pdf
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Bula_Profissional_Extensior_3_ml.pdf
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Poviztra_Bula_Profissional.pdf
  - https://www.sara.com.br/bula-do-paciente-ozivy-134mgml-com-1-caneta-aplicadora-com-15ml-solucao-6-agulhas-descartaveis-em/7896004796574/pdf
  - https://drogariasp.vteximg.com.br/arquivos/Ozivy-Semaglutida-1mg-1-Caneta-3ml-4-Agulhas-948683.pdf
  - https://hyperabuladigitalprod.blob.core.windows.net/leaflet-images/68c86c8cc30e797e2ed524f3-professional_1787842808712.pdf
- **tirzepatida** (12 apresentações: Mounjaro 2,5 mg; Mounjaro 5 mg; Mounjaro 7,5 mg; Mounjaro 10 mg; Mounjaro 12,5 mg; Mounjaro 15 mg; Mounjaro frasco-ampola 2,5 mg; Mounjaro frasco-ampola 5 mg; Mounjaro frasco-ampola 7,5 mg; Mounjaro frasco-ampola 10 mg; Mounjaro frasco-ampola 12,5 mg; Mounjaro frasco-ampola 15 mg). Bula profissional Lilly (fev/2026) e bula do paciente da caneta (jun/2025); IFU do frasco-ampola (mar/2026). Escalonamento: 2,5 mg por 4 semanas, +2,5 mg a cada 4 semanas ou mais, máximo 15 mg; 7,5 e 12,5 mg também como manutenção (a bula prevê manter a dose menor se a seguinte não for tolerada). Caixa de 2 canetas (nova) = mesma apresentação da de 4: 4 unidades por 28 dias. Frasco-ampola (novo): seringa e agulha não vêm na caixa; marca gravada como "Mounjaro frasco-ampola" só para separar da caneta (o registro é "Mounjaro").
  - https://bula-anvisa.s3.sa-east-1.amazonaws.com/112600202_paciente.pdf
  - https://delivery-p137454-e1438138.adobeaemcloud.com/adobe/assets/urn:aaid:aem:6e768dd5-47d3-408f-8a92-7934b46cc97f/renditions/original/as/MOUNJARO_Bula_HCP.pdf
  - https://assets.ctfassets.net/fhvti7ztpwfk/55kUsCYjaKhFUgsknRVfp2/a478b882ba37e5d13a01e1ead3fcc7a6/MOUNJARO_VIAL_IFU_24MAR26.pdf
- **insulina degludeca+liraglutida** (1 apresentação: Xultophy 1 a 50 U + 0,036 a 1,8 mg). Bula profissional Xultophy (Anvisa 22/04/2026). Início com 10 unidades (ou 16 na troca de insulina basal ou de outro GLP-1), máximo 50. Quantidades para 30 dias incluem o teste de fluxo de 2 unidades e o descarte 21 dias após aberta; nos regimes de titulação assumem a subida mais rápida: revisar.
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Xultophy%20-%20Bula%20do%20profissional%20-%20Site.pdf
- **liraglutida** (4 apresentações: Victoza 0,6 mg, 1,2 mg ou 1,8 mg; Lirux 0,6 mg, 1,2 mg ou 1,8 mg; Saxenda 0,6 mg a 3 mg; Olire 0,6 mg a 3 mg). Victoza (bula de 18/12/2024) e Saxenda (17/04/2026), Novo Nordisk; Lirux e Olire (EMS, lançados em ago/2025): bulas do paciente. Canetas de 18 mg: 1,2 mg/dia = 2 canetas/30 dias; 1,8 mg/dia = 3; Saxenda/Olire 3 mg/dia = 5; mês de escalonamento do Saxenda/Olire = 3. Agulhas não incluídas (Victoza, Saxenda, Olire; no Lirux a bula não diz explicitamente). EMS: aberta, só na geladeira, 4 semanas.
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Victoza_Bula_Profissional-05-01.pdf
  - https://product-data.raiadrogasil.io/documents/15996179.pdf
  - https://www.novonordisk.com.br/content/dam/nncorp/br/pt/pdfs/bulas/hcp/Saxenda_Bula_Profissional1.pdf
  - https://product-data.raiadrogasil.io/documents/16099082.pdf
- **dulaglutida** (2 apresentações: Trulicity 0,75 mg; Trulicity 1,5 mg). Bula profissional Trulicity (CDS 18/12/2023). Só 0,75 e 1,5 mg existem no Brasil (3 e 4,5 mg não registrados). A bula não fixa intervalo para subir de 0,75 para 1,5 mg, por isso não há regime de escalonamento. 1,5 mg vem em caixa com 2: 4 canetas = 2 caixas.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Trulicity-Profissional-Consulta-Remedios.pdf
- **insulina glargina+lixisenatida** (2 apresentações: Soliqua 10 a 40 U + 5 a 20 mcg; Soliqua 30 a 60 U + 10 a 20 mcg). Bulas profissional e do paciente do Soliqua (Sanofi). Canetas 10-40 e 30-60. A caneta aberta vale 14 dias, então 30 dias exigem pelo menos 3 canetas. O texto diz "antes do café da manhã"; a bula permite qualquer refeição, de preferência a mesma.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Soliqua-Profissional-Consulta-Remedios.pdf
  - https://bula-anvisa.s3.sa-east-1.amazonaws.com/183260393_paciente.pdf

## Fontes e notas por item: antimicrobianos

Na ordem de volume no SNGPC (código 5, jun a ago/2026).

- **amoxicilina+clavulanato** (7 apresentações: 875 mg + 125 mg comprimido revestido; 500 mg + 125 mg comprimido revestido; 80 mg/mL + 11,4 mg/mL pó para suspensão oral; 50 mg/mL + 12,5 mg/mL pó para suspensão oral; 120 mg/mL + 8,58 mg/mL pó para suspensão oral; (600 mg + 42,9 mg)/5 mL pó para suspensão oral; (400 mg + 57 mg)/5 mL pó para suspensão oral). Clavulin e Clavulin BD comprimidos e suspensões (GSK). Duração de 7 e 10 dias: a bula não fixa; IDSA rinossinusite 2012 (5 a 7 dias em adulto) e 10 dias em estreptococo/otite (IDSA 2012, AAP 2013). Pediátrico: 45 mg/kg/dia em 2 tomadas (400/57) e 40 mg/kg/dia em 3 tomadas (250/62,5), da faixa da bula; não usei 90 mg/kg/dia, que a bula não traz (ela vai até 70/10 mg/kg/dia). maxMgDia derivado da dose do adulto. Suspensão: 7 dias na geladeira. Clavulin ES (600 mg + 42,9 mg/5 mL, GSK, bula de 01/10/2025): 90/6,4 mg/kg/dia de 12/12 h por 10 dias, a partir de 3 meses (otite média recorrente ou persistente); sem experiência acima de 40 kg, por isso maxMgDia 3600 (40 kg x 90, derivado); não é intercambiável com as outras suspensões.
  - https://br.gsk.com/media/bajamm50/clavulin-bd-comprimidos-revestidos.pdf
  - https://doi.org/10.1093/cid/cir1043
  - https://br.gsk.com/media/vcpb0r5f/clavulin-comprimidos.pdf
  - https://br.gsk.com/media/cbhdozbi/clavulin-bd-suspens%C3%A3o-oral.pdf
  - https://doi.org/10.1542/peds.2012-3488
  - https://br.gsk.com/media/j5kbfuk2/clavulin-suspens%C3%A3o-oral.pdf
  - https://br.gsk.com/media/hj0pc5n0/clavulin-es-suspens%C3%A3o-oral.pdf
- **azitromicina** (7 apresentações: 500 mg comprimido revestido; 1 g comprimido revestido; 1.500 mg pó para suspensão oral; 900 mg pó para suspensão oral; 600 mg pó para suspensão oral; 40 mg/mL pó para suspensão oral; 1 g comprimido). Zitromax comprimidos (Pfizer, 06/2025); azitromicina 1 g Prati-Donaduzzi; Astro (Eurofarma) e genérico EMS em suspensão. 500 mg por 3 dias e 1 g em dose única (clamídia, conforme bula e PCDT IST). O esquema de 5 dias só entrou no frasco de 1500 mg (usa os 37,5 mL inteiros), porque não há comprimido de 250 mg no SNGPC e a bula atual do comprimido não o traz. Pediátrico: 10 mg/kg/dia por 3 dias, máximo 500 mg/dia; a bula também tem 5 dias (10 e depois 5 mg/kg), otite 30 mg/kg dose única e faringite 20 mg/kg/dia, que o objeto único não comporta. "1 g" e "1000 mg" entram duplicados porque o SNGPC usa as duas grafias.
  - https://www.pfizer.com.br/files/Zitromax_Comprimidos_Profissional_de_Saude_25.pdf
  - https://drogariasp.vteximg.com.br/arquivos/313858---azitromicina-1g-generico-prati-1-comprimido-revestido.pdf
  - https://drogariasp.vteximg.com.br/arquivos/164640---astro-900mg-eurofarma-suspensao-oral-22-5ml-v5.pdf
  - https://drogariasp.vteximg.com.br/arquivos/98019---azitromicina-600mg-generico-ems-suspensao-oral-15ml.pdf
- **cefalexina** (6 apresentações: 500 mg comprimido revestido; 500 mg cápsula dura; 500 mg comprimido; 1 g comprimido revestido; 50 mg/mL pó para suspensão oral; 50 mg/mL suspensão oral). Keflex (Bagó) e genéricos Teuto e UQ. 6/6 h por 7 dias: duração da IDSA 2014 (pele, 5 a 10 dias); 12/12 h por 10 dias (estreptococo) e por 7 dias (cistite): bula. Pediátrico 50 mg/kg/dia em 4 tomadas, máximo 4 g/dia (bula). "suspensão oral" foi tratada como a suspensão pronta e "pó para suspensão oral" como o pó; o SNGPC pode misturar as duas.
  - https://img.drogasil.com.br/raiadrogasil_bula/Keflex-Bago.pdf
  - https://doi.org/10.1093/cid/ciu444
  - https://doi.org/10.1093/cid/cis629
  - https://img.drogasil.com.br/raiadrogasil_bula/Cefalexina250mgTeuto.pdf
- **amoxicilina** (7 apresentações: 500 mg cápsula dura; 875 mg comprimido revestido; 875 mg comprimido; 50 mg/mL pó para suspensão oral; 80 mg/mL pó para suspensão oral; 400 mg/5 mL pó para suspensão oral; 250 mg/5 mL pó para suspensão oral). Amoxil cápsulas, BD 875 e suspensão (GSK); amoxicilina 400 mg/5 mL EMS. 7 dias: uso usual (bula não fixa); 10 dias: faringite (IDSA 2012); 1 g de 8/8 h por 5 dias: PAC ambulatorial (ATS/IDSA 2019), dentro do máximo da bula. Pediátrico: 50 mg/kg/dia em 3 tomadas (50 mg/mL) e 45 mg/kg/dia em 2 tomadas (80 mg/mL), faixas da bula; a dose alta de otite (80 a 90 mg/kg/dia) não está na bula e não entrou.
  - https://br.gsk.com/media/6250/amoxil-c%C3%A1psulas.pdf
  - https://doi.org/10.1093/cid/cis629
  - https://doi.org/10.1164/rccm.201908-1581ST
  - https://drogariasp.vteximg.com.br/arquivos/78000---amoxil-bd-875mg-gsk-20-comprimidos-revestidos.pdf
  - https://br.gsk.com/media/lgkkugnq/amoxil-suspens%C3%A3o-oral-10-2025.pdf
  - https://doi.org/10.1542/peds.2012-3488
  - https://img.drogasil.com.br/raiadrogasil_bula/Amoxicilina400mgEMS.pdf
- **ciprofloxacino** (3 apresentações: 500 mg comprimido revestido; 3,5 mg/mL solução oftálmica; 3 mg/mL solução oftálmica). Comprimido: Cipro (Bayer, histórico até 2019) e genérico Aché (2021); 7, 10 e 14 dias da bula. A cistite com 250 mg ficou de fora (o comprimido é de 500 mg). Colírio: Ciloxan (Novartis); conjuntivite 7 dias (a bula não fixa; AAO 2023) e úlcera de córnea 14 dias (bula, 2 frascos). Orientações do item vazias porque há via oral e ocular.
  - https://img.drogasil.com.br/raiadrogasil_bula/CIPRO.pdf
  - https://www.ache.com.br/wp-content/uploads/application/pdf/bula-paciente-cloridrato-de-ciprofloxacino.pdf
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-CILOXAN-Solucao-Oftalmica-Esteril-Medico.pdf
  - https://www.aao.org/Assets/76c4baa7-869e-42ad-9ffc-215781185a7b/638434228319430000/conjunctivitis-ppp-pdf
- **nitrofurantoina** (1 apresentação: 100 mg cápsula dura). Macrodantina (Mantecorp): 100 mg de 6/6 h por 7 a 10 dias e 100 mg ao deitar no uso prolongado. O regime de 5 dias vem da diretriz EAU (cistite não complicada), não da bula. Profilaxia: 30 dias por receita (a bula não fixa a duração).
  - https://img.drogasil.com.br/raiadrogasil_bula/Macrodantina.pdf
  - https://uroweb.org/guidelines/urological-infections/chapter/the-guideline
- **moxifloxacino+dexametasona** (1 apresentação: 5 mg/mL + 1 mg/mL solução oftálmica). Vigadexa (Novartis): infecção até 7 dias; pós-operatório de 1 dia antes até 15 dias depois (16 dias). Tudo da bula.
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-VIGADEXA-Solucao-Oftalmica-Esteril-Medico.pdf
- **ciprofloxacino+hidrocortisona** (1 apresentação: 2 mg/mL + 10 mg/mL suspensão otológica). Otociriax (Farmoquímica): 3 gotas de 12/12 h por 7 dias; descartar 7 dias após aberto. Concentração gravada como "2 mg/mL + 10 mg/mL" (o harness do SNGPC gera "2 mg + 10 mg/mL").
  - https://product-data.raiadrogasil.io/documents/16010885.pdf
- **moxifloxacino** (2 apresentações: 5 mg/mL solução oftálmica; 400 mg comprimido revestido). Colírio: Vigamox (Novartis), 7 dias (bula). Comprimido: Avalox (Bayer, bula do paciente de 2015): 5, 7, 10 e 14 dias conforme a indicação da bula. Orientações do item vazias (duas vias).
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-VIGAMOX-Solucao-Oftalmica-Esteril-Medico.pdf
  - https://img.drogasil.com.br/raiadrogasil_bula/AVALOX.pdf
- **levofloxacino** (2 apresentações: 750 mg comprimido revestido; 500 mg comprimido revestido). 750 mg: genérico Eurofarma (2023), 5 dias (bula). 500 mg: Levaquin (Janssen, 10/2025); a posologia não fixa duração, e 7, 10 e 5 dias vêm dos estudos descritos na própria bula.
  - https://bulas.eurofarma.com.br/storage/media/11195/kXFZWXpPCyLUX7mLwsuKqw1GWAuu013xlewBODEZ.pdf
  - https://assets.jnjlabels.com/innovativemedicine/latam/brasil/levaquin-bula-profissional.pdf
- **metronidazol** (6 apresentações: 250 mg comprimido; 250 mg comprimido revestido; 400 mg comprimido; 400 mg comprimido revestido; 100 mg/g gel vaginal; 500 mg/5 g gel vaginal). Flagyl comprimidos (Sanofi, 12/2021), Flagyl ginecológico (gel) e Flagyl Pediátrico/Flagimax (suspensão); Protocolo de IST do Ministério da Saúde. Gel por 5 dias (vaginose, Protocolo IST) está fora da indicação da bula do gel (10 a 20 dias, tricomoníase). Álcool: a bula atual diz até 1 dia após a última dose. A suspensão de benzoilmetronidazol ficou só na chave benzoilmetronidazol, como no catálogo.
  - https://pill-dev-site-pro-bula-pro.s3.us-east-2.amazonaws.com/7896070600799.pdf
  - http://www.scielo.br/j/ress/a/X9WkLLZRBbcW3mFwbRYBHXD/
  - http://institucional.anossadrogaria.com.br/bula/919887.pdf
- **sulfametoxazol+trimetoprima** (5 apresentações: 800 mg + 160 mg comprimido; 400 mg + 80 mg comprimido; 40 mg/mL + 8 mg/mL suspensão oral; 80 mg/mL + 16 mg/mL suspensão oral; (200 mg + 40 mg)/5 mL suspensão oral). Bactrim/Bactrim F (Farmoquímica). 7 dias: escolha usual (a bula diz pelo menos 5 dias); 3 dias: cistite (IDSA/ESCMID 2010); 3 comprimidos em dose única e profilaxia de pneumocistose 1 ao dia: bula. Pediátrico: 30 mg/kg/dia de sulfametoxazol em 2 tomadas (equivalência da tabela da bula); maxMgDia 1600 é a dose do adulto, não um teto pediátrico da bula.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Bactrim-Profissional-Consulta-Remedios.pdf
  - https://academic.oup.com/cid/article/52/5/e103/388285
- **fosfomicina** (2 apresentações: 5,631 g granulado; 5,631 g granulado para solução oral). Monuril (Zambon, 2022): dose única; 2 envelopes com 24 h de intervalo; profilaxia 3 h antes e 24 h depois de procedimento. Tudo da bula.
  - https://databaseprodotti.zambon.com/sites/default/files/product_downloads/Bula%20Profissional%20Monuril%20(2).pdf
- **ciprofloxacino+dexametasona** (7 apresentações: 3,5 mg/mL + 1 mg/mL suspensão oftálmica; 3,5 mg/mL + 1 mg/mL solução oftálmica; 3 mg/mL + 1 mg/mL solução oftálmica; 3 mg/mL + 1 mg/mL suspensão oftálmica; 3,5 mg/g + 1 mg/g pomada oftálmica; 3 mg/g + 1 mg/g pomada oftálmica; 3,5 mg + 1 mg solução oftálmica). Cilodex suspensão e pomada (Novartis); Biamotil-D solução e pomada (Allergan). Solução: cerca de 7 dias (bula); pomadas e suspensão: 7 dias pela AAO 2023, por coerência com a classe. Aviso de corticoide no item. "3,5 mg + 1 mg" repete a solução de 3,5 mg/mL + 1 mg/mL (outra grafia do SNGPC).
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-CILODEX-Suspensao-Oftalmica-Esteril-Medico.pdf
  - https://drogariasp.vteximg.com.br/arquivos/26930---biamotil-d-solucao-oftalmico-allergan-5ml.pdf
  - http://institucional.anossadrogaria.com.br/bula/927584.pdf
- **cefadroxila** (2 apresentações: 500 mg cápsula dura; 50 mg/mL pó para suspensão oral). Cefadroxila Eurofarma (cápsula e suspensão). 10 dias (estreptococo) e 1 g de 12/12 h por 7 dias (ITU complicada): bula; 1 g/dia por 7 dias: IDSA 2014 (pele). Pediátrico 30 mg/kg/dia em 2 tomadas (faixa da bula 25 a 50).
  - https://drogariasp.vteximg.com.br/arquivos/10901---cefadroxila-500mg-generico-eurofarma-8-capsulas.pdf
  - https://doi.org/10.1093/cid/cis629
  - https://doi.org/10.1093/cid/ciu444
  - https://io.convertiez.com.br/m/drogalider/uploads/bulas/7891317001421/Bula-Cefadroxila-Eurofarma-Consulta-Remedios.pdf
- **axetilcefuroxima** (5 apresentações: 500 mg comprimido revestido; 500 mg comprimido; 250 mg comprimido revestido; 50 mg/mL pó para suspensão oral; 250 mg/5 mL pó para suspensão oral). Zinnat comprimidos e suspensão (GSK; genérico Sandoz). "Duração usual 7 dias (5 a 10)": bula. Pediátrico 30 mg/kg/dia em 2 tomadas, máximo 1000 mg/dia (bula; na faringite a bula usa 20 mg/kg/dia, máximo 500). Suspensão: geladeira, 10 dias.
  - https://br.gsk.com/media/moucnngw/l1704_zinnat_com-rev_gds29_ipi09.pdf
  - https://br.gsk.com/media/oembwrcn/l1705_zinnat_po-susp_gds29_ipi09.pdf
- **doxiciclina** (2 apresentações: 100 mg comprimido revestido; 100 mg comprimido para solução). Vibramicina (Pfizer, 01/2023) e Doxiclin. 12/12 h por 7 dias (clamídia) e 14 dias (DIP, sífilis em alérgico): bula; 200 mg no 1º dia e depois 100 mg/dia por 7 dias: dose da bula, duração usual; acne 30 dias por receita. O intervalo de 2 h de antiácidos/ferro é orientação de classe (está na bula da limeciclina).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Doxiclin-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Vibramicina-Profissional-Consulta-Remedios.pdf
- **mupirocina** (1 apresentação: 20 mg/g pomada). Bactroban (GSK, 26/08/2025): até 3 vezes ao dia, no máximo 10 dias; regimes de 7, 5 e 10 dias. Mupirocina creme ficou de fora (bula não encontrada).
  - https://br.gsk.com/media/6241/bactroban-pomada-derm.pdf
  - https://www.cristalia.com.br/produto/125/bula-profissional
- **rifamicina** (2 apresentações: 10 mg/mL solução spray; 10 mg/mL solução). Rifocina spray: a cada 6 a 8 h. A bula não dá duração; 7 dias por convenção (NICE: 5 a 7 dias de antibiótico tópico).
  - https://pill-dev-site-pro-bula-pro.s3.us-east-2.amazonaws.com/7891058061562.pdf
- **clindamicina** (1 apresentação: 300 mg cápsula dura). Dalacin C (Pfizer, 10/2023). Dose da bula; 7 dias em 8/8 h e 6/6 h vem da IDSA 2014 (pele); 12/12 h por 10 dias (amigdalite): bula; 12/12 h por 7 dias (vaginose): Protocolo IST.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Dalacin-C-Profissional-Consulta-Remedios.pdf
  - https://academic.oup.com/cid/article/59/2/e10/2895845
  - http://www.scielo.br/j/ress/a/X9WkLLZRBbcW3mFwbRYBHXD/
- **tobramicina** (2 apresentações: 3 mg/mL solução oftálmica; 3 mg/g pomada oftálmica). Tobrex solução e pomada (Novartis). Solução 7 dias (bula). No regime grave, "enquanto acordado" e o fim em 7 dias são redação minha; a bula diz 2 gotas de hora em hora até melhorar, depois reduzir. Pomada 7 dias: AAO 2023.
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-TOBREX-Solucao-Oftalmica-Esteril-Medico.pdf
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-TOBREX-Pomada-Oftalmica-Esteril-Medico.pdf
- **gentamicina+betametasona** (4 apresentações: 1 mg/g + 0,64 mg/g creme; 1 mg/g + 0,5 mg/g creme; 1 mg/g + 0,64 mg/g pomada; 1 mg/g + 0,5 mg/g pomada). Diprogenta (bula do paciente de 2018 e profissional): 12/12 h, suspender quando controlado; 7 e 14 dias por convenção. Duas concentrações gravadas porque o SNGPC descreve o mesmo produto como 0,64 mg/g (dipropionato) e 0,5 mg/g (betametasona base). A solução oto/oftálmica (Garasone) ficou de fora.
  - https://img.drogasil.com.br/raiadrogasil_bula/Diprogenta.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Diprogenta-Profissional-Consulta-Remedios.pdf
- **ceftriaxona** (2 apresentações: 500 mg pó para solução injetável; 1 g pó para solução injetável). Rocefin (Roche) e PCDT IST 2022. 500 mg IM dose única: gonorreia (o PCDT associa azitromicina 1 g, outra chave); 1 g IM dose única; 1 g IM por dia por 7 dias: infecção gonocócica disseminada (PCDT). Nos kits de 1 g, o primeiro regime é o da gonorreia não complicada do PCDT IST 2022 (Quadro 31, edição vigente): 500 mg IM dose única, ou seja, metade do frasco de 1 g reconstituído com os 3,5 mL de diluente (Rocefin); o kit de 500 mg existe e evita o descarte. Só apresentações IM com diluente de lidocaína; o catálogo tem também linhas IV de 1 g e 500 mg com as mesmas strings de concentração e forma, e a UI deve mostrar estes regimes só quando a via for intramuscular.
  - https://www.gov.br/aids/pt-br/central-de-conteudo/pcdts/2022/ist/pcdt-ist-2022_isbn-1.pdf/@@display-file/file
  - https://pill-dev-site-pro-bula-pro.s3.us-east-2.amazonaws.com/7896226500584.pdf
- **claritromicina** (5 apresentações: 500 mg comprimido revestido; 500 mg comprimido de liberação prolongada; 50 mg/mL granulado para suspensão oral; 25 mg/mL granulado para suspensão oral; 125 mg/5 mL granulado para suspensão oral). Liberação imediata: genérico Medley (2014 e 2005), 7 a 14 dias. Klaricid UD (liberação prolongada): 1 ao dia com alimento, 7 a 14 dias. Klaricid suspensão (Abbott, 12/2024): 15 mg/kg/dia em 2 tomadas, máximo 1000 mg/dia, 10 dias (bula: 5 a 10); fica em temperatura ambiente por 14 dias.
  - https://img.drogasil.com.br/raiadrogasil_bula/Claritromicina500mgMedley.pdf
  - https://www.saudedireta.com.br/catinc/drugs/bulas/claritromicina.pdf
  - https://img.drogasil.com.br/raiadrogasil_bula/Klaricid.pdf
  - https://www.abbottbrasil.com.br/content/dam/corp/abbott/pt-br/documents/pdfs/nossas-bulas/k/BU-22-KLARICID-SUSP-bula-profissional.pdf
- **tobramicina+dexametasona** (2 apresentações: 3 mg/mL + 1 mg/mL suspensão oftálmica; 3 mg/g + 1 mg/g pomada oftálmica). Tobradex suspensão e pomada (Novartis, pomada de 02/2026). 7 dias pela AAO 2023 (a bula não fixa). Aviso de corticoide no item.
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-TOBRADEX-Suspensao-Oftalmica-Esteril-Medico.pdf
  - https://www.aao.org/Assets/76c4baa7-869e-42ad-9ffc-215781185a7b/638434228319430000/conjunctivitis-ppp-pdf
  - https://www.pro.novartis.com/br-pt/sites/pro_novartis_com_br/files/2026-02/Bula-TOBRADEX-Pomada-Oftalmica-Esteril-Medico.pdf
- **neomicina+polimixina b+dexametasona** (4 apresentações: 5 mg/mL + 6.000 UI/mL + 1 mg/mL suspensão oftálmica; 3,5 mg/mL + 6.000 UI/mL + 1 mg/mL suspensão oftálmica; 3,5 mg/g + 6.000 UI/g + 1 mg/g pomada oftálmica; 5 mg/g + 6.000 UI/g + 1 mg/g pomada oftálmica). Maxitrol suspensão e pomada (Novartis). 7 dias pela AAO 2023. Cada forma entra duas vezes (neomicina 5 mg de sulfato e 3,5 mg de base) porque o SNGPC usa as duas descrições.
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-MAXITROL-Suspensao-Oftalmica-Esteril-Medico.pdf
  - https://www.aao.org/Assets/76c4baa7-869e-42ad-9ffc-215781185a7b/638434228319430000/conjunctivitis-ppp-pdf
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2021/10/Bula-MAXITROL-Pomada-Oftalmica-Esteril-Medico.pdf
- **neomicina+polimixina b+fluocinolona+lidocaina** (2 apresentações: (3,5 mg+10.000 UI+0,25 mg+20 mg)/mL solução otológica; (3,85 mg+11.000 UI+0,275 mg+20 mg)/mL solução otológica). Genérico Geolab (2018) e Elotin (bula do paciente). A bula não dá duração: 7 dias pela diretriz AAO-HNSF de otite externa (2014), que aliás desaconselha gotas com anestésico na otite externa ativa; mantive porque o produto está registrado para isso.
  - https://www.geolab.com.br/wp-content/uploads/2021/05/fluocinolona-acetonida-sulf.-de-polimixina-B-sulf.-neomicina-clor.-de-lidocaina-PF.pdf
  - https://journals.sagepub.com/doi/full/10.1177/0194599813517083
  - https://bula-anvisa.s3.sa-east-1.amazonaws.com/103850016_paciente.pdf
- **cloranfenicol+aminoacidos+metionina+retinol** (1 apresentação: 5 mg/g + 25 mg/g + 5 mg/g + 10.000 UI/g pomada oftálmica). Epitezan pomada oftálmica: 1 cm 3 a 4 vezes ao dia; a bula não dá duração (7 dias por convenção). O uso principal é cicatrização da córnea, não infecção.
  - https://remediobarato.com/pdf/f6465f02d4dd2d0868e08c2af6cacdb6.pdf
- **tetraciclina+anfotericina b** (1 apresentação: 25 mg/g + 12,5 mg/g creme vaginal). Fungitrin (similar do Talsutin): 1 aplicador (4 g) por dia por 7 a 10 dias. "À noite, ao deitar" é prática comum, não da bula.
  - https://img.drogasil.com.br/raiadrogasil_bula/Fungitrin.pdf
  - https://www.bulas.med.br/p/bulas-de-medicamentos/bula/4627/talsutin-creme-vaginal.htm
- **gentamicina+betametasona+clioquinol+tolnaftato** (2 apresentações: 1 mg/g + 0,5 mg/g + 10 mg/g + 10 mg/g creme; 1 mg/g + 0,5 mg/g + 10 mg/g + 10 mg/g pomada). Quadriderm (bula antiga): 2 a 3 vezes ao dia; pé de atleta 2 a 4 semanas (bula); 7 dias por convenção nos demais usos.
  - https://www.mantecorpsaude.com.br/assets/bulas/quadriderm-bula-profissional.pdf
- **benzilpenicilina** (2 apresentações: 300.000 U/mL suspensão injetável; 1.200.000 UI pó para suspensão injetável). Benzetacil (Eurofarma), pó da FURP, PCDT IST 2022 e Diretriz SBC de febre reumática (2009). Sífilis recente 2,4 milhões UI dose única; tardia/latente 2,4 milhões UI por semana por 3 semanas; faringite 1,2 milhão dose única; profilaxia de febre reumática a cada 21 dias (SBC; a bula diz 4 semanas e aceita 3). Doses pediátricas (em UI) não entraram.
  - https://bulas.eurofarma.com.br/storage/media/12128/TVAntrstCvod4bqXlNgPUVDubWusgp4elCKJ0Luw.pdf
  - https://www.gov.br/aids/pt-br/central-de-conteudo/pcdts/2022/ist/pcdt-ist-2022_isbn-1.pdf/@@display-file/file
  - https://www.scielo.br/j/abc/a/BgMJ45rh8cKSsHpK7bTbjwM/
  - https://uploads.consultaremedios.com.br/drug_leaflet/Bula-Benzilpenicilina-Benzatina-FURP-Paciente-Consulta-Remedios.pdf
- **tetraciclina** (1 apresentação: 500 mg cápsula dura). Cloridrato de tetraciclina Prati-Donaduzzi: clamídia 6/6 h por 7 dias; acne 12/12 h por 21 dias; sífilis 6/6 h por 15 dias (alternativa à penicilina). O esquema de gonorreia da bula foi omitido por ser desatualizado.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Cloridrato-de-Tetraciclina-Prati-Donaduzzi-Profissional-Consulta-Remedios.pdf
- **cloranfenicol+colagenase** (3 apresentações: 10 mg/g + 0,6 U/g pomada; 10 mg/g + 0,6 U/g pomada vaginal; 10 mg/g + 0,6 UI/g pomada vaginal). Kollagenase com cloranfenicol (bula antiga): cerca de 2 mm 1 vez ao dia (até 2), até 14 dias. GinoKollagenase (pomada vaginal, mesma bula da Cristália): cerca de 5 g na vagina todas as noites até acabar 1 ou 2 bisnagas de 30 g (6 a 12 aplicações); se não melhorar em 14 dias, suspender.
  - https://img.drogasil.com.br/raiadrogasil_bula/GinoKollagenase-Cristalia.pdf
- **sulfadiazina** (1 apresentação: 10 mg/g creme). Genérico (bula antiga) / Dermazine: 1 vez ao dia, 2 se a ferida for muito exsudativa, até cicatrizar. dias = 14 só define quanto dispensar.
  - https://www.nativita.ind.br/wp-content/uploads/2019/08/Sulfadiazina-de-Prata-Bula-Paciente_1.pdf
  - https://www.saudedireta.com.br/catinc/drugs/bulas/dermazine.pdf
- **cefaclor** (4 apresentações: 500 mg comprimido revestido de liberação prolongada; 750 mg comprimido revestido de liberação prolongada; 50 mg/mL suspensão oral; 75 mg/mL suspensão oral). Ceclor BD e Ceclor suspensão (EMS Sigma Pharma). 12/12 h por 10 dias (estreptococo): bula; 7 dias em bronquite e sinusite: diretriz (a bula não fixa). Pediátrico 40 mg/kg/dia, máximo 1 g/dia (bula), 8/8 h (50 mg/mL) ou 12/12 h (75 mg/mL), 1 h antes ou 2 h depois das refeições.
  - https://uploads.consultaremedios.com.br/drug_leaflet/bula-ceclor-bd-paciente-consulta-remedios.pdf
  - https://doi.org/10.1093/cid/cis629
  - https://doi.org/10.1093/cid/cir1043
  - https://doi.org/10.1164/rccm.201908-1581ST
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Ceclor-Profissional-Consulta-Remedios.pdf
  - https://doi.org/10.1542/peds.2012-3488
- **ceftriaxona+lidocaina** (4 apresentações: 500 mg pó para solução injetável; 1 g pó para solução injetável; 1 g + 10 mg/mL pó para solução injetável; 500 mg + 10 mg/mL pó para solução injetável). Mesmo conteúdo da chave ceftriaxona (o SNGPC registra o kit IM com o diluente como associação). O kit "1 g + 10 mg/mL" (Rocefin, Triaxton; 35 mil embalagens), que o prescritor usa na gonorreia, tem os mesmos regimes do 1 g, com o da gonorreia primeiro; o kit de 500 mg + 10 mg/mL repete o de 500 mg.
  - https://www.gov.br/aids/pt-br/central-de-conteudo/pcdts/2022/ist/pcdt-ist-2022_isbn-1.pdf/@@display-file/file
  - https://pill-dev-site-pro-bula-pro.s3.us-east-2.amazonaws.com/7896226500584.pdf
- **neomicina+polimixina b+hidrocortisona** (1 apresentação: 5 mg/mL + 10.000 UI/mL + 10 mg/mL suspensão otológica). Otosporin (Farmoquímica, bula do paciente): 7 a 10 dias (bula), com regime para crianças de 1 a 12 anos. Contraindicado com tímpano perfurado (não impresso).
  - https://www.fqmgrupo.com.br/fqmfarma/userfiles/products/17786927886a04b2b4e8006.pdf
- **benzoilmetronidazol+benzalconio+nistatina** (1 apresentação: 62,5 mg/g + 1,25 mg/g + 25.000 UI/g creme vaginal). Colpistatin (bula antiga): 4 g à noite por 10 dias; sem álcool até 3 dias depois. Chave com "benzoilmetronidazol", como o SNGPC escreve.
  - https://img.drogasil.com.br/raiadrogasil_bula/Colpistatin.pdf
- **clorfenesina+betametasona+tetracaina** (1 apresentação: 10 mg/mL + 1 mg/mL + 5 mg/mL solução otológica). Oto Betnovate (Farmoquímica; bula do paciente aprovada em 27/10/2025 e profissional AR061120): adulto 3 a 4 gotas, criança 2 a 3 gotas, 3 a 4 vezes ao dia, por 7 a 14 dias; frasco de 10 mL = 390 gotas (1 frasco basta); aberto, vale 14 dias. Tudo da bula. A clorfenesina é o componente antimicrobiano (antifúngico e antibacteriano).
  - https://www.fqmgrupo.com.br/fqmfarma/userfiles/products/17648727256931d215ecdda.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Oto-Betnovate-Profissional-Consulta-Remedios.pdf
- **neomicina+dexametasona+nistatina** (1 apresentação: (10 mg + 0,32 mg + 100.000 UI)/5 g creme vaginal). Trivagel N (Marjan): 1 aplicador (5 g) por via vaginal 1 vez ao dia por 7 a 10 dias; bisnaga de 60 g com 10 aplicadores; uso só em adultos. A fórmula também tem tirotricina, propionato de sódio e ácido bórico (a chave segue o catálogo). "De preferência à noite, ao deitar" é prática usual, não está na bula.
  - https://marjan.com.br/wp-content/uploads/2022/11/BULA-TRIVAGEL-N-CREME-VAG_408001_A.pdf
- **norfloxacino** (2 apresentações: 400 mg comprimido revestido; 400 mg comprimido). Floxacin (MSD, antiga) e genérico Sandoz (2019): 400 mg de 12/12 h; cistite 3 a 7 dias, ITU 7 a 10 dias (bula). A EAU desaconselha fluoroquinolona em cistite.
  - https://www.saudedireta.com.br/catinc/drugs/bulas/floxacin.pdf
  - https://img.drogasil.com.br/raiadrogasil_bula/NorfloxacinoSandoz.pdf
- **neomicina+dexametasona+fenilefrina** (1 apresentação: 3,5 mg/mL + 0,5 mg/mL + 5 mg/mL solução nasal). Decadron Nasal (Aché, bula aprovada em 15/06/2023), uso adulto: 3 nebulizações em cada narina de 3 em 3 horas; com a melhora, 1 a 2 vezes ao dia e depois suspender; 3 a 5 dias em média, nunca mais de 2 semanas; a bula alerta para efeito rebote acima de 3 a 5 dias. Regimes de 5 e 3 dias, da bula.
  - https://www.ache.com.br/wp-content/uploads/application/pdf/Bula-%E2%80%93-Decadron-Solucao-Nasal.pdf
- **cefdinir** (2 apresentações: 50 mg/mL pó para suspensão oral; 25 mg/mL pó para suspensão oral). Tercen (profissional) e Terza (Eurofarma, profissional). Fora da IN 360/2025 (sem retenção), incluído a pedido do prescritor. Pediátrico: 14 mg/kg/dia em 2 tomadas (7 mg/kg de 12/12 h), máximo 600 mg/dia, 10 dias (bula; a bula aceita 14 mg/kg 1x/dia, exceto em pele). Adulto, só no frasco de 50 mg/mL: 600 mg/dia, 6 mL de 12/12 h ou 12 mL 1x/dia (item 8 das duas bulas); 10 dias vem dos estudos em adultos descritos na própria bula (a posologia não fixa); 2 frascos de 100 mL. Depois de preparada: geladeira, 14 dias. As bulas que li só listam 250 mg/5 mL; a de 25 mg/mL (Terza, 5 mil embalagens) usa a mesma dose em mg/kg (a bula diz que 125 mg/5 mL e 250 mg/5 mL são bioequivalentes).
  - https://cr-net-public-prod.s3.amazonaws.com/product_leaflet/275F3C945B26300308A702FB5DACCF99.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Terza-Profissional-Consulta-Remedios.pdf
- **acido fusidico** (1 apresentação: 20 mg/g creme). Verutex (2024): 2 a 3 vezes ao dia, em geral 7 dias (bula).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Verutex-Profissional-Consulta-Remedios.pdf
- **metronidazol+miconazol** (1 apresentação: 750 mg + 200 mg óvulo). Gynotran (bula antiga): 1 óvulo à noite por 7 dias; sem álcool até 3 dias depois; não usar preservativo nem diafragma durante o tratamento.
  - https://img.drogasil.com.br/raiadrogasil_bula/Gynotran-Exeltis.pdf
- **amoxicilina+claritromicina+esomeprazol** (1 apresentação: 500 mg + 500 mg + 20 mg kit). Genérico EMS (05/2021): tríplice por 14 dias e depois esomeprazol 20 mg por mais 14 dias (1 embalagem, 28 dias). Só 14 dias, conforme o V Consenso Brasileiro de H. pylori (2026); a bula permite 7 dias. Forma "kit" e unidade "embalagem" são propostas (gerar.mjs não lê kits).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Amoxicilina-Claritromicina-Esomeprazol-EMS-Profissional-Consulta-Remedios.pdf
  - https://www.scielo.br/j/ag/a/G9BpZdBB8tHTKdF9b5nmSbp/
- **acido fusidico+betametasona** (1 apresentação: 20 mg/g + 1 mg/g creme). Verutex B (2024): 2 a 3 vezes ao dia, no máximo 2 semanas por curso (bula); a opção de 7 dias é por convenção.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Verutex-B-Profissional-Consulta-Remedios.pdf
- **amoxicilina+claritromicina+lansoprazol** (1 apresentação: 500 mg + 500 mg + 30 mg kit). Pyloripac (bula profissional): 1 lansoprazol + 1 claritromicina + 2 amoxicilina de 12/12 h por 14 dias (1 embalagem de 14 blísteres). A bula também permite 7 e 10 dias; ficou só 14 (V Consenso Brasileiro, 2026). Forma "kit" é proposta.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Pyloripac-Profissional-Consulta-Remedios.pdf
  - https://www.scielo.br/j/ag/a/G9BpZdBB8tHTKdF9b5nmSbp/
- **limeciclina** (2 apresentações: 300 mg cápsula dura; 150 mg cápsula dura). Tetralysal (Galderma, 2022): 300 mg/dia por até 12 semanas (acne), 30 dias por receita; dias alternados na manutenção; 150 mg de 12/12 h ou 1 ao dia (bula).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Tetralysal-Profissional-Consulta-Remedios.pdf
- **benzoilmetronidazol** (1 apresentação: 40 mg/mL suspensão oral). Mesma suspensão 40 mg/mL da chave metronidazol (Flagyl Pediátrico), emitida também com esta chave. Só os regimes de giardíase por idade; sem calculadora (ver dúvidas).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Flagyl-Pediatrico-Profissional-Consulta-Remedios.pdf
  - https://cr-net-public-prod.s3.amazonaws.com/product_leaflet/A605C0946D67843027029D7C37B0072A.pdf
- **gatifloxacino+prednisolona** (1 apresentação: 3 mg/mL + 10 mg/mL suspensão oftálmica). Zypred (Allergan): infecção até 7 dias; pós-operatório até 15 dias (bula).
  - https://allergan-web-cdn-prod.azureedge.net/allerganbrazil/allerganbrazil/media/allergan-brazil/zypred-profissional.pdf
- **sulfadiazina+cerio** (2 apresentações: 1% + 0,4% creme; 1% + 0,4% gel). Dermacerium creme (Cristália, bula do paciente, histórico até 2019): 1 vez ao dia, 2 se a lesão for muito exsudativa, até a cicatrização; dias = 14 só define quanto dispensar. Dermacerium HS Gel (Cristália, profissional; indicado em lesões de herpes simples e herpes zoster): 3 vezes ao dia até a cicatrização; dias = 10 por convenção. Contraindicados em menores de 2 meses, prematuros, fim da gestação e alergia a sulfas.
  - https://img.drogasil.com.br/raiadrogasil_bula/Dermacerium.pdf
  - https://www.cristalia.com.br/produto/446/bula-profissional
- **amoxicilina+sulbactam** (2 apresentações: 875 mg + 125 mg comprimido revestido; 200 mg/mL + 50 mg/mL pó para suspensão oral). Trifamox IBL BD (Bagó): 875 mg + 125 mg de 12/12 h; 7 dias usual e 10 dias em estreptococo (bula: manter 2 a 3 dias após remissão). Pediátrico 50 mg/kg/dia em 2 tomadas (bula: 40 a 100).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Trifamox-IBL-BD-Profissional-Consulta-Remedios.pdf
  - https://doi.org/10.1093/cid/cis629
- **ofloxacino** (1 apresentação: 3 mg/mL solução oftálmica). Oflox (Allergan): 2 esquemas da bula (7 e até 10 dias).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Oflox-Profissional-Consulta-Remedios.pdf
- **ampicilina** (1 apresentação: 500 mg cápsula dura). Ampicilina Sandoz: 500 mg de 6/6 h em jejum; 10 dias (estreptococo, bula) e 7 dias (usual; a bula diz manter 48 a 72 h após os sintomas).
  - https://drogariasp.vteximg.com.br/arquivos/71870---ampicilina-500mg-generico-sandoz-12-comprimidos.pdf
  - https://doi.org/10.1093/cid/cis629
- **metronidazol+nistatina** (1 apresentação: 100 mg/g + 20.000 UI/g creme vaginal). Creme vaginal 100 mg/g + 20000 UI/g: 5 g à noite por 10 dias (bula).
  - https://www.geolab.com.br/wp-content/uploads/2021/05/TRINODAZOL-NISTATINA-Bula-Paciente.pdf
- **gatifloxacino** (2 apresentações: 3 mg/mL solução oftálmica; 5 mg/mL solução oftálmica). Zymar 0,3% (bula do paciente) e Zymar XD 0,5% (profissional), Allergan: 7 dias (bula).
  - https://img.drogasil.com.br/raiadrogasil_bula/ZYMAR.pdf
  - https://drogariasp.vteximg.com.br/arquivos/332755---zymar-xd-colirio-allergan-3ml.pdf
- **fenoximetilpenicilina** (1 apresentação: 500.000 UI comprimido). Pen-Ve-Oral (profissional): 500.000 UI de 8/8 h ou 6/6 h por 10 dias; profilaxia de febre reumática 12/12 h contínua (60 comprimidos/30 dias). A solução oral (dose em UI/kg) ficou de fora.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Pen-Ve-Oral-Profissional-Consulta-Remedios.pdf
  - https://doi.org/10.1093/cid/cis629

## Deixados de fora, e por quê

- **GLP-1 registrados, sem venda confirmada em setembro de 2026** (aguardando preço na CMED, segundo notícias até 23/09):
  - semaglutida: Owozy, Seemasun, Zempneo e Orsema (todos de 29/07/2026), o genérico da EMS (17/08), Semaclique e o genérico da Germed (ago/2026) e Yluméc (EMS, 31/08);
  - liraglutida: Liraclick (Germed, 06/2026) e os genéricos da EMS (09/2026);
  - Mounjaro KwikPen ("Mounjaro Multidose", aprovado em 18/03/2026): tem preço na CMED, mas não tem venda no SNGPC, e fontes de jul e set/2026 dizem que não chegou às farmácias.
  - Quando entrarem, é preciso ler a bula de cada um. O Ozivy, por exemplo, difere do Ozempic no armazenamento.
- **GLP-1 que não existem no Brasil:**
  - Ozempic 2 mg: o máximo na bula brasileira é 1 mg.
  - Rybelsus 1,5/4/9 mg (nova formulação): a bula de 09/2026 só traz 3, 7 e 14 mg.
  - Wegovy oral 25 mg: submetido em 01/2026, não aprovado.
  - Caneta própria de 7,2 mg: não existe.
  - Trulicity 3 e 4,5 mg: não registrados.
  - Orforglipron: sem registro na Anvisa.
  - Exenatida e lixisenatida isolada: fora da CMED.
- **Linhas do catálogo com 1.000 embalagens ou mais que estão sem posologia aqui:**
  - `amoxicilina` "400 mg" pó para suspensão oral (15,6 mil): o SNGPC não diz se é o frasco de 400 mg ou 400 mg/5 mL, então é ambíguo.
  - `mupirocina` creme (11,9 mil): a bula não foi encontrada.
  - `ciprofloxacino` 3,5 mg/g pomada oftálmica (5,8 mil): não pesquisada.
  - `acido fusidico` pomada (5 mil): não pesquisada.
  - `cefalexina` 1,5 g e 100 mg/mL, `cefaclor` 375 mg/5 mL de liberação prolongada, `ceftriaxona+lidocaina` "1 g + 10 mg/mL" e `metronidazol` "100 mg/g gel" (tópico no catálogo, provavelmente o vaginal): volume pequeno ou string ambígua.
  - Mounjaro Multidose: ver acima.
- **Antimicrobianos entre os ~50 de maior volume que ficaram fora:**
  - Dexametasona + neomicina colírio (60 mil): a bula começa de hora em hora, depois reduz, por "alguns dias a várias semanas"; não há regime seguro de um clique.
  - Garasone (gentamicina + betametasona, solução oto/oftálmica, 37 mil): só achei agregador de 2016, sem duração.
  - Adapaleno + clindamicina, clindamicina + peróxido de benzoíla, clindamicina + tretinoína (géis para acne): não pesquisados.
  - Fibrase com cloranfenicol: não pesquisada.
  - Rifampicina 300 mg (15 mil; tuberculose e profilaxia): não pesquisada.
  - Lidocaína + polimixina B otológico: não pesquisado.
  - Tetraciclina pomada oftálmica: volume pequeno.
- **Apresentações ou regimes omitidos:**
  - Formas IV e embalagens hospitalares.
  - Ciprofloxacino 500 mg na cistite: a bula dá 250 mg.
  - Azitromicina 5 dias em comprimido.
  - Kits de H. pylori por 7 e 10 dias.
  - Ceftriaxona 250 mg (bula antiga): o PCDT atual usa 500 mg.
  - Esquemas de gonorreia com tetraciclina.
  - Pen-Ve-Oral solução e benzatina em criança: a dose é em UI/kg, e o objeto pediátrico é em mg.
  - Mupirocina creme, ampicilina suspensão, cefaclor 375 mg/5 mL de liberação prolongada, nitrofurantoína suspensão: volume pequeno ou bula não achada.
  - Posologia pediátrica do Victoza e do Saxenda.

## Dúvidas gerais

- **Calculadora do metronidazol:** a do metronidazol / benzoilmetronidazol suspensão foi retirada (`pediatrico: null`).
  - A única dose por peso da bula é a da amebíase: 50 mg/kg/dia de metronidazol, 6/6 h, 5 a 7 dias.
  - O uso pediátrico mais comum é a giardíase, que a bula dosa por idade: ~15 mg/kg/dia. Sem campo de indicação, a calculadora sugeriria cerca de 3 vezes a dose da giardíase.
  - Os regimes por idade ficaram.
- **Um só `mgKgDia` por apresentação:** escolhi a dose da bula para a indicação usual. As faixas estão nos itens.
  - Não usei os 90 mg/kg/dia de amoxicilina + clavulanato do exemplo do pedido. A bula do Clavulin BD vai até 70/10 mg/kg/dia e não tem dados acima de 45/6,4 em menores de 2 anos.
  - `maxMgDia` da família da amoxicilina e do SMX-TMP é a dose do adulto, não um teto pediátrico escrito na bula.
- **Bulas antigas:** várias são anteriores a 2021 (Cipro, Avalox, Floxacin, claritromicina genérica, Diprogenta, Quadriderm, Colpistatin, Gynotran, Kollagenase). As doses raramente mudam, mas advertências novas (ex.: fluoroquinolonas) podem faltar. Vale conferir no Bulário antes de publicar.
- **Fontes que não são o PDF do próprio fabricante:**
  - Ozivy, Lirux, Olire, Otosporin, Elotin e Zymar 0,3% vêm da bula do paciente.
  - Talsutin e Garasone só em agregador.
- **Quantidades de tópicos:** 1 bisnaga ou frasco na maioria, mas depende da área tratada. O médico revisa.
- **Titulação de Xultophy e Soliqua:** as quantidades assumem a subida mais rápida.
- **Estabilidade das suspensões:** varia por fabricante (ex.: amoxicilina, 14 dias na geladeira ou em temperatura ambiente; cefalexina, 7 a 14 dias). Algumas orientações dizem "conforme o rótulo".
- **Cefaclor de liberação prolongada (Ceclor BD):** a bula se contradiz. A posologia diz 1 hora antes ou 2 horas depois das refeições, mas a farmacologia diz que o alimento aumenta a absorção. O texto segue a posologia.
