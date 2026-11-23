# Posologias da Receita de Controle Especial (RCE)

`posologias-rce.json` (29/09/2026) tem 47 chaves, 166 apresentações, 363 regimes e 4 calculadoras pediátricas. Ele alimenta as sugestões de posologia de um clique na RCE. Nada é preenchido sem clique, e o médico revisa. O esquema, as regras de texto e a validação são os de `posologias-retencao.json`.

## Como foi feito

- **Escopo:** 49 substâncias de `data/medicamentos-rce.json`: as 40 de maior `vendas` mais todos os itens de adendo (classe terminada em "-adendo"). Entraram 47; canabidiol e Cannabis ficaram fora (ver abaixo).
- **Junção:** `chave` e `classe` são as do catálogo, e cada apresentação usa exatamente a `concentracao` e a `forma` do catálogo.
  - As 166 apresentações daqui têm linha no catálogo tal como estava em 29/09/2026 às 22:49.
  - O script `rce/merge-rce.py` (scratchpad) refaz a junção e lista o que falta.
  - `marca` e `dose` são sempre null.
- **Fonte da posologia:** a bula brasileira vigente do medicamento de referência (ou de um genérico atual), lida em PDF.
  - O Bulário da Anvisa bloqueia acesso automatizado. Por isso a fonte é o PDF do fabricante (GSK, Pfizer, Viatris, Novartis, Abbott, Janssen, Organon, Mundipharma, Bayer e outros) ou esse mesmo PDF espelhado em drogarias e agregadores (consultaremedios, drogasil, drogariasp, bula-anvisa.s3).
  - A URL de cada bula está em `fontes`. A data de aprovação ou do histórico da bula está nas notas por item.
- **Regimes:** adulto, nas indicações principais da bula.
  - **Titulação:** quando a bula tem etapas de 1 semana ou mais, cada etapa é um regime separado (lamotrigina com e sem valproato e com indutores, topiramato, memantina, perampanel, pregabalina, duloxetina, levetiracetam, donepezila). Quando a titulação é dia a dia (quetiapina, gabapentina), há um regime "Início" que a descreve.
  - **Opioides:** o texto traz a dose máxima diária. "Se dor" só aparece onde a bula permite uso conforme a necessidade (tramadol + paracetamol, celecoxibe). As demais bulas dão intervalos fixos.
  - **Durações curtas** de analgésicos (3, 5 e 7 dias) são escolha minha dentro da orientação da bula de usar pelo menor tempo possível.
- **quantidade:** na unidade do catálogo, cobrindo `dias`.
  - Uso contínuo: 30 dias.
  - Etapas de titulação: a duração da etapa (7 ou 14 dias).
  - Esquema naturalmente mais longo, como a bupropiona de 7 semanas: até 60 dias.
  - Injetáveis de depósito: em ampolas, no máximo 5 (o Nebido cobre 84 dias com 1 ampola).
  - Líquidos: em frascos, pelo volume do frasco do catálogo.
- **pediatrico:** só onde a bula dá mg/kg/dia para aquele líquido:
  - carbamazepina suspensão;
  - levetiracetam solução;
  - valproato xarope;
  - fenobarbital gotas.
  - Faixas de idade ou peso (risperidona no autismo, valproato por faixa de peso) viraram regimes normais.
  - **Fenobarbital gotas:** a calculadora segue o padrão do arquivo (mg por mL): `mgPorMl` = 40, e o texto pede mL e diz que 1 mL corresponde a 40 gotas. Como o Gardenal é dosado em gotas (1 gota = 1 mg), um modo "gotas" na UI deixaria a receita mais natural.
- **Texto impresso:** passa na regex do PDF, com os limites de tamanho. A lacuna `__` do pediátrico precisa ser trocada pela UI antes de imprimir.

## Limites legais da RCE

Fonte: Portaria SVS/MS nº 344/1998, texto compilado.
- https://www.legisweb.com.br/legislacao/?id=317701
- https://anvisalegis.datalegis.net/action/ActionDatalegis.php?acao=abrirTextoAto&link=S&tipo=POR&numeroAto=00000344&seqAto=000&valorAno=1998&orgao=SVS%2FMS&codTipo=&desItem=&desItemFim=&cod_modulo=134&cod_menu=1696

- **Art. 52:** a Receita de Controle Especial vai em **2 vias** e vale **30 dias** a partir da emissão, em todo o país (listas C1 e C5).
- **Art. 57:** no máximo **3 substâncias da lista C1** por receita.
- **Art. 59, caput:** a quantidade de cada substância C1 ou C5 é "limitada a **5 (cinco) ampolas** e para as demais formas farmacêuticas, a quantidade para o tratamento correspondente a no máximo **60 (sessenta) dias**".
- **Art. 59, parágrafo único:** **antiparkinsonianos e anticonvulsivantes**, até **6 meses** de tratamento.
- **Art. 60:** o prescritor pode passar desses limites com justificativa (CID ou diagnóstico e posologia), datada e assinada nas 2 vias.
- **Itens de adendo prescritos em RCE:**
  - São eles: tramadol e codeína até 100 mg (A2); oxicodona LP até 40 mg e buprenorfina em adesivo (A1); fenobarbital e perampanel (B1); Cannabis (A3).
  - Os adendos dizem "Receita de Controle Especial, em 2 vias", mas não repetem o limite de quantidade, e o art. 59 cita só C1 e C5.
  - Os manuais aplicam o mesmo limite pelo tipo de receituário: CRF-SP, 04/10/2023 (https://portal.crfsp.org.br/orienta%C3%A7%C3%A3o-farmac%C3%AAutica/641-fiscaliza%C3%A7%C3%A3o-orientativa/farm%C3%A1cia/12608-confira-as-orienta%C3%A7%C3%B5es-sobre-per%C3%ADodos-de-tratamento-da-portaria-svs-ms-n%C2%BA-344-98.html), e CRF-PR, Manual de Dispensação, 9ª ed., 2025, Quadro 4 (https://www.crmv-pr.org.br/uploads/pagina/arquivos/Manual_dispensacao_controle_especial_9_ed_2025.pdf).
  - Assim, fenobarbital e perampanel, que são anticonvulsivantes, cabem em até 6 meses.
  - O CRF-SP registra que os limites voltaram ao padrão em 22/09/2023, com o fim da RDC 357/2020 da pandemia.
- **Receita eletrônica:**
  - A **RDC 1.000, de 11/12/2025** (em vigor desde 13/02/2026), alterou a Portaria 344. O novo art. 55, § 3º diz que a RCE eletrônica deve atender integralmente à RDC 1.000.
  - A RCE eletrônica exige assinatura qualificada ICP-Brasil (Lei 5.991/1973, art. 35, § 3º, segundo o CRF-PR).
  - Li só as notas de redação do texto compilado, não a RDC 1.000.
  - A RDC 873/2024 mudou as notificações, não a RCE.
- **Neste arquivo:**
  - Nos injetáveis, no máximo 5 ampolas.
  - Nas demais formas, no máximo 60 dias; o padrão é 30.
  - Nos injetáveis de depósito, `dias` é o intervalo da bula e passa de 60 (Nebido 70, 84 e 98; Durateston 84), o que é legal porque o limite do art. 59 para ampolas é em número de ampolas. Se a UI travar `dias` em 60 na RCE, precisa abrir exceção para injetáveis.
- **Cannabis e canabidiol:** o Manual do CRF-PR (2025) cita a RDC 327/2019, art. 51 e 52: Notificação B até 60 dias para THC até 0,2%; Notificação A até 30 dias para THC acima de 0,2%. O catálogo (RDC 1.036/2026) os põe em RCE. Conferir antes de emitir.

## Fontes e notas por item

Na ordem de volume do catálogo.

- **quetiapina** (C1; 4 apresentações: 25 mg comprimido revestido; 100 mg comprimido revestido; 200 mg comprimido revestido; 50 mg comprimido revestido de liberação prolongada). Seroquel e Seroquel XRO. No 25 mg, o "Início" cobre só os dias 1 e 2 (esquizofrenia e depressão bipolar), porque a bula não permite partir o comprimido e a titulação segue com concentrações maiores. Manutenção de 200 a 800 mg/dia (máximo) no 100 e no 200 mg; 300 mg à noite na depressão bipolar. XR 50 mg: adjuvante na depressão (50 e depois 150 mg) e titulação do idoso.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Seroquel-Profissional-Consulta-Remedios.pdf
- **pregabalina** (C1; 6 apresentações: 75 mg cápsula dura; 150 mg cápsula dura; 50 mg cápsula dura; 25 mg cápsula dura; 75 mg comprimido; 25 mg/mL solução oral). Lyrica (22/01/2026), Dorene Tabs e Dorene líquido. Início com 75 mg de 12/12 h por 7 dias; manutenção de 150 a 600 mg/dia, com o máximo no texto. Cápsula de 25 mg: 50 e 25 mg/dia, doses da tabela de função renal. Solução: 3 mL = 75 mg.
  - https://www.viatris.com.br/-/media/project/common/viatriscombr/pdf/leaflets_legacy_myl_brazil/bula_lyrica_profissional_1.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Dorene-Tabs-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Dorene-Profissional-Consulta-Remedios.pdf
- **sertralina** (C1; 4 apresentações: 50 mg comprimido revestido; 100 mg comprimido revestido; 25 mg comprimido revestido; 75 mg comprimido revestido). Zoloft (histórico até 15/12/2025) e Tolrest. 50 a 200 mg/dia em dose única; 25 mg por 7 dias e depois 50 mg em pânico, estresse pós-traumático e fobia social; aumentos com pelo menos 1 semana de intervalo. O Zoloft 100 mg não deve ser partido.
  - https://www.viatris.com.br/-/media/project/common/viatriscombr/pdf/leaflets_legacy_myl_brazil/zoloft_bula_profissional.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Tolrest-Profissional-Consulta-Remedios.pdf
- **escitalopram** (C1; 6 apresentações: 10 mg comprimido revestido; 15 mg comprimido revestido; 20 mg comprimido revestido; 20 mg/mL solução oral; 5 mg comprimido orodispersível; 10 mg comprimido orodispersível). Lexapro (profissional e paciente), Lexapro Gotas e Esc ODT (09/03/2023). 10 mg/dia, máximo 20 mg; meio comprimido de 10 mg por 7 dias no início (o Lexapro permite partir; nem todo genérico é sulcado). Gotas: 1 gota = 1 mg, 300 gotas por frasco, válido 8 semanas após aberto. Orodispersível: dissolver na língua, sem partir.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Lexapro-Profissional-Consulta-Remedios.pdf
  - https://img.drogasil.com.br/raiadrogasil_bula/Lexapro.pdf
  - https://drogariasp.vteximg.com.br/arquivos/269557---lexapro-20mg-lundbeck-15ml-conta-gotas.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Esc-ODT-Profissional-Consulta-Remedios.pdf
- **venlafaxina** (C1; 6 apresentações: 75 mg cápsula dura; 75 mg cápsula dura de liberação prolongada; 150 mg cápsula dura de liberação prolongada; 37,5 mg cápsula dura de liberação prolongada; 150 mg cápsula dura; 37,5 mg cápsula dura). Efexor XR (12/11/2025) e Venlift OD (14/04/2023). As linhas "cápsula dura" do catálogo são o Venlift OD, que a própria bula descreve como de liberação prolongada, 1 vez ao dia, com a mesma posologia. 75 mg/dia até 225 mg; no 37,5 mg, o início do pânico (37,5 mg por 7 dias e depois 75 mg).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Venlift-OD-Profissional-Consulta-Remedios.pdf
  - https://www.viatris.com.br/-/media/project/common/viatriscombr/pdf/leaflets_legacy_myl_brazil/efexor-xr_bula_profissional.pdf
- **tramadol** (A2-adendo; 4 apresentações: 50 mg cápsula dura; 100 mg comprimido revestido de liberação prolongada; 50 mg comprimido revestido de liberação prolongada; 100 mg/mL solução oral). Tramal e Tramal Retard (04/08/2023). Cápsula de 50 mg de 6/6 h ou 8/8 h por 3 ou 5 dias; liberação prolongada de 12/12 h; gotas (1 gota = 2,5 mg). Todo texto traz o máximo de 400 mg/dia. A bula dá intervalos fixos; "se dor" não entrou. As durações de 3 e 5 dias são escolha minha (a bula diz usar pelo menor tempo possível).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Tramal-Profissional-Consulta-Remedios.pdf
- **fluoxetina** (C1; 4 apresentações: 20 mg cápsula dura; 20 mg comprimido revestido; 10 mg cápsula dura; 20 mg/mL solução oral). Prozac e Daforin (07/08/2023). 20 a 60 mg/dia, máximo 80 mg. Gotas: 1 gota = 1 mg, 400 gotas por frasco de 20 mL; quantidade em frascos para 30 dias. A bula não fixa horário.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Prozac-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Daforin-Profissional-Consulta-Remedios.pdf
- **trazodona** (C1; 6 apresentações: 50 mg comprimido revestido; 100 mg comprimido revestido; 150 mg comprimido de liberação prolongada; 50 mg comprimido; 100 mg comprimido; 150 mg comprimido revestido de liberação prolongada). Donaren, Loredon, Donaren Retard (2019) e Inseris XR. Doses fixas (à noite ou de 12/12 h, após refeição), máximo ambulatorial 400 mg/dia; liberação prolongada de 150 mg à noite ou 300 mg. A titulação de 50 mg em 50 mg da bula depende da resposta, por isso não virou regime. Aviso de priapismo no item.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Donaren-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Donaren-Retard-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Loredon-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Inseris-XR-Profissional-Consulta-Remedios.pdf
- **desvenlafaxina** (C1; 2 apresentações: 50 mg comprimido revestido de liberação prolongada; 100 mg comprimido revestido de liberação prolongada). Pristiq (12/12/2025). 50 mg/dia; em dias alternados no 50 mg para insuficiência renal grave; máximo 200 mg/dia.
  - https://www.pfizer.com.br/files/Pristiq_Profissional_de_Saude_30.pdf
- **risperidona** (C1; 5 apresentações: 1 mg/mL solução oral; 1 mg comprimido revestido; 2 mg comprimido revestido; 3 mg comprimido revestido; 500 mcg comprimido revestido). Risperdal (24/10/2025). Solução 1 mg/mL: início no autismo por faixa de peso (menos de 20 kg e 20 kg ou mais) como regimes normais, e 0,25 mg de 12/12 h na agitação da demência. Comprimidos: esquizofrenia (2 e depois 4 mg), mania, idoso e início do adolescente.
  - https://assets.jnjlabels.com/innovativemedicine/latam/brasil/risperdal-pub-vps-comp.pdf
- **duloxetina** (C1; 2 apresentações: 30 mg cápsula dura de liberação retardada; 60 mg cápsula dura de liberação retardada). Cymbalta (20/12/2021, a mais recente encontrada). 30 mg por 7 dias e depois 60 mg; 60 mg/dia ou 60 mg de 12/12 h (120 mg, máximo).
  - https://assets.ctfassets.net/fhvti7ztpwfk/41aaoR1JNorFF3y3itvZ0T/b8829b8d254856ac03b8a446de19c1a6/CYMBALTA_30_60_LIT_HCP_V03_20DEC21_MTC_clean.pdf
- **lamotrigina** (C1; 6 apresentações: 100 mg comprimido; 100 mg comprimido para suspensão; 50 mg comprimido; 25 mg comprimido; 50 mg comprimido para suspensão; 25 mg comprimido para suspensão). Lamictal comprimidos e dispersíveis (08/05/2026). A bula do comprimido simples só cobre epilepsia; o transtorno bipolar está na do dispersível. Etapas de 14 dias como regimes separados: sem valproato (semanas 1 e 2, 3 e 4), com valproato (dias alternados, depois diário) e com indutores enzimáticos; semana 5 do bipolar no dispersível de 100 mg; manutenção de 100 a 400 mg/dia. Aviso de reação de pele no item.
  - https://br.gsk.com/media/od0j15hy/lamictal.pdf
  - https://br.gsk.com/media/3vzebm45/lamictal-comprimidos-dispers%C3%ADveis.pdf
- **amitriptilina** (C1; 4 apresentações: 25 mg comprimido revestido; 10 mg comprimido revestido; 25 mg comprimido; 75 mg comprimido revestido). Amytril e genérico (16/12/2021). Regimes de depressão da bula (ao deitar e de 8/8 h), máximo ambulatorial 150 mg/dia. Usos fora da bula (dor, enxaqueca) não entraram.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Cloridrato-de-Amitriptilina-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Amytril-Profissional-Consulta-Remedios.pdf
- **etoricoxibe** (C1; 2 apresentações: 90 mg comprimido revestido; 60 mg comprimido revestido). Arcoxia. 90 mg por 3, 5 ou 7 dias (dor aguda, no máximo 8 dias) ou 30 dias (artrite reumatoide, espondilite); 60 mg por 14 ou 30 dias (osteoartrite). Sempre no máximo 1 comprimido por dia. O 120 mg (2 embalagens) não está na bula atual.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Arcoxia-Profissional-Consulta-Remedios.pdf
- **codeina+paracetamol** (A2-adendo; 2 apresentações: 30 mg + 500 mg comprimido; 7,5 mg + 500 mg comprimido). Tylex. 1 comprimido de 4/4 h ou 6/6 h, ou 2 de 6/6 h, por 3 ou 5 dias; máximo 8 comprimidos por dia e aviso do limite de 4 g/dia de paracetamol de todas as fontes. As durações curtas são escolha minha.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Tylex-Profissional-Consulta-Remedios.pdf
- **paroxetina** (C1; 5 apresentações: 20 mg comprimido revestido; 10 mg comprimido revestido; 25 mg comprimido de liberação modificada; 25 mg comprimido revestido de liberação modificada; 12,5 mg comprimido de liberação modificada). Aropax, Pondera, Paxil CR (19/01/2024) e Pondera XR. Liberação imediata de 20 mg pela manhã com alimento (a bula do Pondera 20 não permite partir); 10 mg com etapa de 7 dias; liberação modificada de 12,5 e 25 mg pela manhã. O 15 mg ficou de fora (as bulas sobem de 10 em 10 mg).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Aropax-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Pondera-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Paxil-CR-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Pondera-XR-Profissional-Consulta-Remedios.pdf
- **bupropiona** (C1; 2 apresentações: 150 mg comprimido revestido de liberação prolongada; 300 mg comprimido revestido de liberação prolongada). Wellbutrin XL (04/09/2026, máximo 300 mg/dia), Zyban e genéricos. 150 mg: 1 pela manhã; 1 de manhã e 1 no fim da tarde (8 h de intervalo); esquema de 3 dias 1 vez ao dia e depois 2 vezes ao dia por 7 semanas (95 comprimidos, 49 dias). 300 mg XL: 1 pela manhã. Atenção: a linha de 150 mg do catálogo mistura comprimidos de 12 h e de 24 h; os regimes de 2 vezes ao dia e de 7 semanas são dos de 12 h.
  - https://br.gsk.com/media/onxkmcmu/l1701_wellbutrin-sr_com_rev_lib_lenta_gds32_ipi19.pdf
  - https://br.gsk.com/media/jdyhpw5h/l1703_zyban_com_rev_lib_lenta_gds32_ipi19.pdf
  - https://cr-net-public-prod.s3.amazonaws.com/product_leaflet/CDA4E7E470B8EFFFD3B2C5C9426819F7.pdf
  - https://br.gsk.com/media/m42jfmk2/wellbutrin-xl.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Eutymia-XL-Profissional-Consulta-Remedios.pdf
- **buspirona** (C1; 2 apresentações: 5 mg comprimido; 10 mg comprimido). Ansitec (2020). 5 mg de 8/8 h (15 mg/dia, início), 10 mg de 12/12 h, até 60 mg/dia; evitar álcool e grande quantidade de suco de toranja.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Ansitec-Profissional-Consulta-Remedios.pdf
- **mirtazapina** (C1; 5 apresentações: 15 mg comprimido orodispersível; 30 mg comprimido revestido; 30 mg comprimido orodispersível; 45 mg comprimido revestido; 45 mg comprimido orodispersível). Remeron SolTab e Razapina (23/11/2020). 1 comprimido ao deitar (15, 30 ou 45 mg); aviso de fenilalanina nos orodispersíveis.
  - https://www.organon.com/brazil/wp-content/uploads/sites/33/2023/06/remeron_soltab_bula_profissional.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Razapina-Profissional-Consulta-Remedios.pdf
- **fenobarbital** (B1-adendo; 1 apresentação: 40 mg/mL solução oral). Gardenal (04/11/2021). Só as gotas 40 mg/mL, com calculadora pediátrica de 3 mg/kg/dia em dose única, em mL (mgPorMl 40; o texto diz que 1 mL corresponde a 40 gotas, e 1 gota = 1 mg). Os comprimidos de 50 e 100 mg ficaram de fora (ver abaixo).
  - https://bula-anvisa.s3.sa-east-1.amazonaws.com/1832603230037_paciente.pdf
- **undecilato de testosterona** (C5; 1 apresentação: 250 mg/mL solução injetável). Nebido (Bayer, bula de 24/04/2023). 1 ampola (4 mL, 1000 mg) IM muito lentamente; a 2ª após 6 semanas; depois a cada 10 a 14 semanas (o regime de 12 semanas é o meio da faixa). Quantidade em ampolas, dentro do limite de 5.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Nebido-Profissional-Consulta-Remedios.pdf
- **atomoxetina** (C1; 6 apresentações: 25 mg cápsula dura; 40 mg cápsula dura; 10 mg cápsula dura; 18 mg cápsula dura; 60 mg cápsula dura; 80 mg cápsula dura). Atentah (2023). A dose infantil é em mg/kg e a cápsula não pode ser aberta, então cada concentração tem "1 pela manhã" e "1 de manhã e 1 no fim da tarde". No 40 mg, início do adulto por 7 dias e depois 80 mg (7 dias é escolha dentro do "pelo menos 3 dias" da bula).
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Atentah-Profissional-Consulta-Remedios.pdf
- **carbamazepina** (C1; 5 apresentações: 200 mg comprimido; 20 mg/mL suspensão oral; 400 mg comprimido; 200 mg comprimido de liberação prolongada; 400 mg comprimido de liberação prolongada). Tegretol, Tegretol CR e suspensão (08/01/2026). Doses fixas de 400 a 1200 mg/dia; CR de 12/12 h, meio comprimido permitido. Suspensão 20 mg/mL: calculadora de 10 mg/kg/dia em 3 tomadas, máximo 1000 mg/dia, e 600 mg/dia do adulto (9 frascos para 30 dias). Sem regime de titulação do adulto, porque a bula não fixa a duração das etapas.
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2025/11/Bula-TEGRETOL-Comprimido-Comprimido-de-Liberacao-Prolongada-Medico.pdf
  - https://portal.novartis.com.br/medicamentos/wp-content/uploads/2025/11/Bula-TEGRETOL-Suspensao-Medico.pdf
- **Durateston (decanoato + fempropionato + isocaproato + propionato de testosterona)** (C5; 1 apresentação: 100 mg + 60 mg + 60 mg + 30 mg solução injetável). Durateston (Aspen, bula de 06/02/2023). 1 ampola IM a cada 3 semanas, como 2 ampolas (6 semanas) ou 4 ampolas (12 semanas). A bula atual não traz o esquema a cada 2 semanas. Contraindicado em alergia a amendoim ou soja.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Durateston-Profissional-Consulta-Remedios.pdf
- **gabapentina** (C1; 3 apresentações: 300 mg cápsula dura; 400 mg cápsula dura; 600 mg comprimido revestido). Neurontin (05/01/2022) e Gabaneurin 600 mg (12/07/2023). 300 mg: "Início" dos dias 1 a 3 e depois 300 mg de 8/8 h (87 cápsulas); 400 e 600 mg: 900 a 3600 mg/dia em 3 tomadas; o comprimido de 600 mg pode ser partido.
  - https://www.viatris.com/-/media/project/common/viatris/pdf/brazil/leaflets_legacy_myl_brazil/neurontin_bula_profissional.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/Bula-Gabaneurin-Paciente-Consulta-Remedios.pdf
- **olanzapina** (C1; 4 apresentações: 10 mg comprimido revestido; 5 mg comprimido revestido; 10 mg comprimido; 5 mg comprimido). Zyprexa (2021). 5 e 10 mg (revestido e simples) nas doses da bula. O 2,5 mg ficou de fora: a bula não tem regime próprio para ele e o comprimido não deve ser partido.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Olanzapina-Eurofarma-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Zyprexa-Profissional-Consulta-Remedios.pdf
- **levetiracetam** (C1; 6 apresentações: 250 mg comprimido revestido; 500 mg comprimido revestido; 750 mg comprimido revestido; 1 g comprimido revestido; 500 mg comprimido revestido de liberação prolongada; 100 mg/mL solução oral). Keppra (paciente, 12/2019) e Keppra XR (03/2021). Início com 250 mg de 12/12 h por 2 semanas e depois 500 mg de 12/12 h; manutenção até 1500 mg de 12/12 h; XR 500 mg 1 vez ao dia por 2 semanas e depois 1000 ou 1500 mg. Solução: regimes do adulto em mL e calculadora de 20 mg/kg/dia em 2 tomadas (dose a partir de 6 meses), máximo 3000 mg/dia; frasco válido 7 meses após aberto.
  - https://product-data.raiadrogasil.io/documents/3824803.pdf
  - https://img.drogasil.com.br/raiadrogasil_bula/KeppraXr.pdf
- **topiramato** (C1; 3 apresentações: 50 mg comprimido revestido; 25 mg comprimido revestido; 100 mg comprimido revestido). Topamax (15/10/2025). 25 mg: etapas semanais (semanas 1, 2 e 3) e depois 50 mg/dia; 50 mg: 100 mg/dia e início da epilepsia; 100 mg: 200 e 400 mg/dia. A solução Toduze ficou de fora (bula não encontrada).
  - https://assets.jnjlabels.com/innovativemedicine/latam/brasil/topamax-pub-vps.pdf
- **donepezila** (C1; 2 apresentações: 10 mg comprimido revestido; 5 mg comprimido revestido). Eranz. 5 mg por 4 a 6 semanas e depois contínuo; 10 mg contínuo.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Eranz-Profissional-Consulta-Remedios.pdf
- **celecoxibe** (C1; 2 apresentações: 200 mg cápsula dura; 100 mg cápsula dura). Celebra (20/12/2023). 200 mg: esquema da dor aguda da bula, 3 dias na cólica menstrual, 1 ao dia ou de 12/12 h por 30 dias; 100 mg: 1 ou 2 de 12/12 h. "Se dor" só onde a bula permite.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Celebra-Profissional-Consulta-Remedios.pdf
- **citalopram** (C1; 2 apresentações: 20 mg comprimido revestido; 40 mg comprimido revestido). Cipramil e Procimax (30/01/2023). 20 mg/dia e 40 mg/dia (máximo). O início com 10 mg no pânico (meio comprimido) não entrou.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Cipramil-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Procimax-Profissional-Consulta-Remedios.pdf
- **divalproato de sodio** (C1; 4 apresentações: 500 mg comprimido revestido de liberação prolongada; 250 mg comprimido revestido de liberação prolongada; 250 mg comprimido revestido de liberação retardada; 500 mg comprimido revestido de liberação retardada). Depakote ER e Depakote (liberação retardada), ambas de 05/03/2026. Só os esquemas com dose fixa na bula: ER 500 mg na enxaqueca (500 mg por 1 semana e depois 1000 mg), ER 250 mg (2 comprimidos por 1 semana), liberação retardada de 250 mg de 12/12 h (enxaqueca) ou 8/8 h (início da mania, 750 mg/dia) e de 500 mg de 12/12 h. Mania e epilepsia no ER, epilepsia na liberação retardada (dose por peso) e o Sprinkle de 125 mg ficaram de fora.
  - https://www.abbottbrasil.com.br/content/dam/corp/abbott/pt-br/documents/pdfs/nossas-bulas/D/BU-37-Depakote-ER-Bula-Profissional-FINAL.pdf
  - https://www.abbottbrasil.com.br/content/dam/corp/abbott/pt-br/documents/pdfs/nossas-bulas/D/BU-32-Depakote-DR-Bula-Profissional-FINAL.pdf
- **litio** (C1; 3 apresentações: 300 mg comprimido revestido; 450 mg comprimido de liberação prolongada; 300 mg comprimido). Carbolitium (2019) e Carbolitium CR (bula antiga, sem data). Manutenção de 900 e 1200 mg/dia, mania aguda de 1800 mg/dia com litemia 2 vezes por semana, potencializador de 600 mg/dia. Orientações sobre litemia (8 a 12 h após a dose), líquidos e sal, sinais de toxicidade e dose esquecida.
  - https://img.drogasil.com.br/raiadrogasil_bula/CARBOLITIUM.pdf
  - https://www.saudedireta.com.br/catinc/drugs/bulas/carbolitiumcr.pdf
- **memantina** (C1; 6 apresentações: 10 mg comprimido revestido; 20 mg comprimido revestido; 10 mg/mL solução oral; 20 mg/mL solução oral; 5 mg comprimido orodispersível; 10 mg comprimido orodispersível). Ebix, Zider, Alois e Moriale ODT. 10 mg: uma etapa por semana (5, 10, 15 mg) e manutenção de 20 mg; 20 mg: manutenção; gotas: manutenção e início de 21 dias (1 frasco cobre as semanas 1 a 3); orodispersíveis de 5 e 10 mg: etapas das semanas 1 e 2.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Ebix-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Zider-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Alois-Solucao-Oral-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Zider-Gotas-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Moriale-ODT-Profissional-Consulta-Remedios.pdf
- **aripiprazol** (C1; 6 apresentações: 10 mg comprimido; 15 mg comprimido; 20 mg comprimido; 30 mg comprimido; 1 mg/mL suspensão oral; 20 mg/mL suspensão oral). Aristab (comprimidos; suspensão 1 mg/mL, bula do paciente de 2019) e Arpejo gotas 20 mg/mL (2022). Doses de 10 a 30 mg/dia conforme a indicação da bula.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Aristab-Profissional-Consulta-Remedios.pdf
  - https://drogariasp.vteximg.com.br/arquivos/711160---aristab-1mgml-ache-suspensao-oral-150ml.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Arpejo-Profissional-Consulta-Remedios.pdf
- **valproato de sodio** (C1; 1 apresentação: 50 mg/mL xarope). Depakene (29/10/2025). Só o xarope 50 mg/mL: 4 regimes por faixa de peso copiados da tabela de dose inicial da bula (25 a 89,9 kg) e calculadora de 15 mg/kg/dia em 2 tomadas (limite da bula: 60 mg/kg/dia). São doses iniciais que a bula manda ajustar.
  - https://www.abbottbrasil.com.br/content/dam/corp/abbott/pt-br/documents/pdfs/nossas-bulas/D/BU-31-Depakene-Bula-Profissional-Xpe-FINAL.pdf
- **vortioxetina** (C1; 4 apresentações: 10 mg comprimido revestido; 5 mg comprimido revestido; 15 mg comprimido revestido; 20 mg comprimido revestido). Brintellix. 5, 10, 15 e 20 mg 1 vez ao dia. A bula brasileira não exige redução no idoso e permite parar sem retirada gradual; dose esquecida é pulada.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Brintellix-Profissional-Consulta-Remedios.pdf
- **nortriptilina** (C1; 4 apresentações: 25 mg cápsula dura; 10 mg cápsula dura; 50 mg cápsula dura; 75 mg cápsula dura). Pamelor (27/09/2023). 10 a 75 mg à noite, até 150 mg/dia; acima de 100 mg/dia a bula pede dosagem no sangue.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Pamelor-Profissional-Consulta-Remedios.pdf
- **tramadol+paracetamol** (A2-adendo; 2 apresentações: 37,5 mg + 325 mg comprimido revestido; 37,5 mg + 325 mg comprimido). Ultracet (18/03/2024), Paratram e Gésico Duo. 1 a 2 de 6/6 h "se dor" por 5 dias (a bula permite uso conforme a necessidade); início da dor crônica (1 ao dia, mais 1 a cada 3 dias até 4 ao dia); 1 de 6/6 h contínuo por 30 dias; máximo 8 por dia.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Ultracet-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Paratram-Profissional-Consulta-Remedios.pdf
- **levomepromazina** (C1; 3 apresentações: 25 mg comprimido revestido; 100 mg comprimido revestido; 40 mg/mL solução oral). Neozine (2022). Comprimidos de 25 e 100 mg e gotas 40 mg/mL: início de 50 mg/dia, 200 mg/dia e a dose da dor terminal. A bula chama a posologia de "individual", então esses regimes são escolhas dentro das faixas dela. Doses infantis em mg/kg (frações de gota) não entraram.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Neozine-Profissional-Consulta-Remedios.pdf
- **codeina** (A2-adendo; 3 apresentações: 30 mg comprimido; 60 mg comprimido; 3 mg/mL solução oral). Codein. 30 e 60 mg e solução 3 mg/mL (10 mL = 30 mg), de 4/4 h ou 6/6 h por 3 dias, máximo 360 mg/dia; a bula diz que a dor aguda dura até cerca de 4 dias. Uso restrito abaixo de 18 anos.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Codein-Comprimido-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Codein-Profissional-Consulta-Remedios.pdf
- **tramadol+diclofenaco** (A2-adendo; 2 apresentações: 25 mg + 25 mg comprimido; 50 mg + 50 mg comprimido). Adorlan e Nusira (21/02/2024). 1 de 8/8 h por 3 ou 5 dias, máximo 3 por dia.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Adorlan-Profissional-Consulta-Remedios.pdf
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Nusira-Profissional-Consulta-Remedios.pdf
- **buprenorfina** (A1-adendo; 5 apresentações: 10 mg adesivo transdérmico; 5 mg adesivo transdérmico; 5 mcg/h adesivo transdérmico; 10 mcg/h adesivo transdérmico; 20 mcg/h adesivo transdérmico). Restiva 5 e 10 mg (Mundipharma) e Lusanda/genérico Adium 5, 10 e 20 mcg/h: adesivo de 7 dias, 4 adesivos por 28 dias; não aumentar antes de 3 dias; no máximo 2 adesivos ao mesmo tempo. A linha "20 mg" do catálogo ficou de fora: junta o Restiva 20 mg (7 dias) com o Transtec 20 mg (troca 2 vezes por semana).
  - https://br.mundipharma.com/sites/mundi-pharma-brazil/files/products/bula_do%20profissional_Restiva.pdf
  - https://cr-net-public-prod.s3.amazonaws.com/product_leaflet/F98E5D146A7EBFD16C59097B80CAB8CB.pdf
  - https://adium.com.br/wp-content/uploads/sites/3/2026/01/02_Bula-Profissional_BUPRENORFINA_0050-04-1.pdf
- **oxicodona** (A1-adendo; 2 apresentações: 10 mg comprimido revestido de liberação prolongada; 20 mg comprimido revestido de liberação prolongada). OxyContin (04/07/2023). 10 e 20 mg de 12/12 h, contínuo. A bula não tem máximo fixo.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Oxycontin-Profissional-Consulta-Remedios.pdf
- **oxicodona+naloxona** (A1-adendo; 3 apresentações: 5 mg + 2,5 mg comprimido revestido de liberação prolongada; 10 mg + 5 mg comprimido revestido de liberação prolongada; 20 mg + 10 mg comprimido revestido de liberação prolongada). Targin (21/03/2023). 1 de 12/12 h, máximo 80 mg de oxicodona por dia; 10 + 5 mg é o início do paciente sem uso prévio de opioide.
  - https://br.mundipharma.com/sites/mundi-pharma-brazil/files/products/bula_do%20profissional%20Targin.pdf
- **perampanel** (B1-adendo; 4 apresentações: 2 mg comprimido revestido; 4 mg comprimido revestido; 6 mg comprimido revestido; 8 mg comprimido revestido). Fycompa (30/11/2023). 2 mg ao deitar por 2 semanas (1 semana com indutores enzimáticos), cada aumento de 2 mg como regime separado, e manutenção de 4, 6 e 8 mg.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Fycompa-Profissional-Consulta-Remedios.pdf
- **codeina+diclofenaco** (A2-adendo; 1 apresentação: 50 mg + 50 mg comprimido revestido). Codaten (histórico da bula até 2016). 1 de 8/8 h ou 12/12 h por 5 dias, antes das refeições, máximo 3 por dia.
  - https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Codaten-Profissional-Consulta-Remedios.pdf

## Deixados de fora, e por quê

- **canabidiol** (6 apresentações) e **cannabis sativa** (6): produtos da RDC 327/2019 sem marca no catálogo. Várias empresas vendem cada concentração, e o folheto de cada uma traz titulação própria. Dá para incluir produto a produto se o catálogo passar a trazer a marca.
- **fenobarbital 100 mg e 50 mg comprimidos** (818 mil e 137 mil embalagens): a bula do Gardenal só dá "Adultos: 2 a 3 mg/kg/dia em dose única ou fracionada", sem dose fixa por comprimido. Um regime como "100 mg à noite" ficaria abaixo da faixa num adulto de 70 kg. Se o prescritor quiser, dá para montar faixas de peso a partir de 2 a 3 mg/kg/dia, com a aprovação dele.
- **valproato de sódio 500 e 300 mg comprimidos** (231 mil e 6 mil): a dose é por peso, e a tabela de dose inicial da bula para o 300 mg não fecha a conta.
- **divalproato de sódio:**
  - mania e epilepsia no ER e epilepsia na liberação retardada: a dose é por peso;
  - Sprinkle 125 mg (30 mil): só epilepsia;
  - "500 mg comprimido revestido" genérico (22 mil): a descrição não diz se é de liberação retardada ou prolongada, que têm posologias diferentes.
- **quetiapina pó para suspensão oral 12,5 e 25 mg/mL** (35 mil): a bula própria não foi encontrada.
- **olanzapina 2,5 mg** (220 mil): a bula dá doses de 5 a 20 mg, não tem regime para o 2,5 mg e o comprimido não deve ser partido.
- **paroxetina 15 mg** (32 mil): as bulas sobem de 10 em 10 mg; sem base para um regime de 15 mg.
- **bupropiona 150 mg "comprimido revestido"** (3,8 mil): não há bupropiona de liberação imediata no Brasil; não dá para saber se é de 12 h ou 24 h.
- **buprenorfina "20 mg"** (6,6 mil): a linha junta Restiva 20 mg (troca a cada 7 dias) e Transtec 20 mg (troca 2 vezes por semana).
- **topiramato solução 100 mg/mL** (Toduze, 3,4 mil): a bula não foi encontrada.
- **Volume desprezível ou uso hospitalar:**
  - tramadol injetável e 100 mg "liberação retardada";
  - fenobarbital injetável e levomepromazina injetável;
  - fluoxetina 5 mg/mL e 20 mg comprimido simples;
  - citalopram 20 mg simples;
  - risperidona 2 mg simples;
  - nortriptilina solução;
  - levomepromazina 10 mg/mL;
  - etoricoxibe 120 mg;
  - valproato 500 mg de liberação retardada.
- **Regimes omitidos:**
  - titulação passo a passo da trazodona (depende da resposta);
  - início de 10 mg de citalopram (meio comprimido);
  - 225 mg de pregabalina de 12/12 h (exige duas concentrações por dose);
  - titulação da carbamazepina no adulto (a bula não fixa a duração das etapas);
  - usos fora da bula (amitriptilina na dor e na enxaqueca, trazodona na insônia);
  - doses infantis de levomepromazina em frações de gota.

## Dúvidas

- **Bupropiona 150 mg:** a linha do catálogo mistura comprimidos de 12 h e de 24 h. "1 pela manhã" serve para os dois. Os regimes de 2 vezes ao dia e de 7 semanas (cessação do tabagismo) são dos de 12 h. Se o catálogo separar por marca, esses dois ficam só nos de 12 h.
- **Durações curtas dos analgésicos** (3, 5 e 7 dias): são escolha minha.
- **Nebido:** o regime de "12 semanas" é o meio da faixa de 10 a 14 da bula.
- **Neozine:** a bula chama a posologia de "individual"; os regimes são escolhas dentro das faixas dela.
- **Atomoxetina:** o início do adulto por 7 dias é escolha dentro do "pelo menos 3 dias" da bula.
- **Escitalopram:** o meio comprimido de 10 mg segue o Lexapro, que é sulcado; nem todo genérico é.
- **Bulas antigas:** as mais antigas que achei foram Cymbalta (2021), Donaren Retard (2019), Carbolitium CR (sem data), Ansitec (2020), Keppra (2019 e 2021), Gardenal (2021) e Codaten (2016). Vale conferir no Bulário antes de publicar.
- **Doses feitas de vários comprimidos** (2 de sertralina 50 mg para 100 mg, 3 cápsulas de fluoxetina para 60 mg): são a dose da bula montada com a concentração escolhida. O médico pode preferir a concentração maior.
- **Valproato xarope, divalproato na mania e quetiapina 25 mg:** os regimes são doses iniciais que a bula manda ajustar.
- **Levetiracetam solução:** a calculadora usa a dose a partir de 6 meses de idade; de 1 a 6 meses, a bula dá 7 mg/kg de 12/12 h.
- **Frascos no limite exato:** escitalopram 10 gotas por dia (300 gotas = 1 frasco de 15 mL), tramadol 20 gotas de 6/6 h por 5 dias (400 gotas = 1 frasco de 10 mL), memantina 20 mg/mL (600 gotas = 1 frasco de 30 mL) e codeína 10 mL de 6/6 h por 3 dias (120 mL = 1 frasco). Qualquer perda no gotejamento deixa faltar a última dose; o médico pode pedir 1 frasco a mais.


## Fenobarbital em comprimido (30/09/2026)

A bula do Gardenal dá, para adultos, 2 a 3 mg/kg/dia em dose única ou fracionada, sem dose fixa por comprimido. A pedido do prescritor, as doses diárias mais frequentes foram montadas com a faixa de peso que cada uma cobre, a 2 a 3 mg/kg/dia:
- **50 mg:** 1 (50 mg/dia, 17 a 25 kg), 2 (100 mg/dia, 33 a 50 kg) ou 3 comprimidos à noite (150 mg/dia, 50 a 75 kg).
- **100 mg:** 1 (100 mg/dia, 33 a 50 kg) ou 2 comprimidos à noite (200 mg/dia, 67 a 100 kg).

Não há meio comprimido, porque nem todo genérico é sulcado; 150 mg sai do comprimido de 50 mg. A quantidade é para 30 dias. Anticonvulsivantes podem ir a 6 meses (Portaria 344, art. 59, parágrafo único).
