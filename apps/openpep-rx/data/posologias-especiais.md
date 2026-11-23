# Posologias das notificações especiais: retinoides (NRR) e talidomida (NRT)

`posologias-especiais.json` (30/09/2026) tem 3 chaves, 5 apresentações, 20 regimes e 2 calculadoras. As strings `chave`, `classe`, `concentracao` e `forma` são as de `data/medicamentos-especiais.json` (versão de 30/09/2026 às 00:07), e todas as apresentações casam com o catálogo. O esquema e as regras de texto são os de `posologias-rce.json`, com os acréscimos abaixo. As bulas foram lidas em PDF; o Bulário da Anvisa bloqueia acesso automatizado, e as URLs estão em `fontes`.

## Acréscimos ao esquema

- **`tempo` nos regimes da talidomida:** é o campo "TEMPO DE TRATAMENTO" do modelo da NRT. O modelo tem QUANTIDADE DE COMPRIMIDOS (em algarismos e por extenso), DOSE POR UNIDADE POSOLÓGICA, POSOLOGIA, TEMPO DE TRATAMENTO e OUTRAS ORIENTAÇÕES.
  - `quantidade` é a quantidade de comprimidos; a dose por unidade é a `concentracao` (100 mg); `texto` é a posologia.
  - As `orientacoes` da talidomida são as sugestões para OUTRAS ORIENTAÇÕES.
  - A talidomida tem 6 regimes, acima do limite usual de 4, para cobrir as indicações da bula.
- **Calculadora da isotretinoína** (objeto `pediatrico`, também usado no adulto):
  - Campos: `mgKgDia` 0,5 (dose inicial), `mgKgDiaMax` 1, `dosesDia` 1, `mgPorUnidade` (mg por cápsula: 10 ou 20), `maxMgDia` null e `doseAcumuladaMgKg` [120, 150].
  - O `texto` tem a lacuna `__` para o número de cápsulas ("2 cápsulas").
  - Diferente das calculadoras em mL da RET e da RCE, esta pede um modo "cápsulas" na UI: número de cápsulas = dose diária ÷ `mgPorUnidade`, arredondado para a cápsula.
  - Duração do curso = dose acumulada × peso ÷ dose diária. Exemplo: 60 kg a 0,5 mg/kg = 30 mg/dia; 120 a 150 mg/kg = 7.200 a 9.000 mg, ou seja, 240 a 300 dias. A 1 mg/kg, 60 mg/dia dá 120 a 150 dias.
  - A bula admite até 2 mg/kg/dia em doença muito grave ou acne no tronco; por isso `maxMgDia` é null.

## Isotretinoína (NRR, lista C2)

Apresentações do catálogo: cápsula mole de 20 mg e de 10 mg. A de 40 mg não está no catálogo (sem vendas no SNGPC).

**Fontes:**
- Roacutan, bula profissional aprovada pela Anvisa em 24/10/2022 (versão da Roche; o registro passou à Farmoquímica em 2024): https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Roacutan-Profissional-Consulta-Remedios.pdf
- Isotretinoína 20 mg da Colbrás, bula padrão aprovada em 19/03/2025: https://bula-anvisa.s3.sa-east-1.amazonaws.com/132650030_paciente.pdf
- Isotretinoína 10 mg da Germed, bula aprovada em 01/08/2025: https://bula-anvisa.s3.sa-east-1.amazonaws.com/105830755_paciente.pdf

**Posologia da bula (item 8):**
- Durante as refeições, 1 ou 2 vezes ao dia.
- Início com 0,5 mg/kg/dia; na maioria dos pacientes, 0,5 a 1,0 mg/kg/dia.
- Até 2,0 mg/kg/dia em doença muito grave ou acne no tronco.
- Dose cumulativa de 120 a 150 mg/kg por tratamento; remissão em geral entre 16 e 24 semanas.
- Na intolerância, doses menores por mais tempo.

**Regimes fixos, por peso** (30 dias, o máximo da NRR). Doses acima de 20 mg foram divididas entre almoço e jantar, o que a bula permite.

| Peso e dose | mg/dia | 20 mg | 10 mg |
|---|---|---|---|
| 40 kg a 0,5 mg/kg | 20 | 1 ao dia (30) | 1 no almoço e 1 no jantar (60) |
| 60 kg a 0,5 mg/kg | 30 | não | 1 no almoço e 2 no jantar (90) |
| 80 kg a 0,5 mg/kg, ou 40 kg a 1 mg/kg | 40 | 1 no almoço e 1 no jantar (60) | não |
| 60 kg a 1 mg/kg | 60 | 1 no almoço e 2 no jantar (90) | não |
| 80 kg a 1 mg/kg | 80 | 2 no almoço e 2 no jantar (120) | não |
| dose reduzida (intolerância) | 10 | não | 1 ao dia (30) |

**Orientações:**
- Tomar com a refeição e engolir inteiro.
- Contracepção de 1 mês antes a 1 mês depois do tratamento, com teste de gravidez mensal (a bula pede teste antes, mensal e 5 semanas após).
- Parar e procurar o médico se houver suspeita de gravidez.
- Não doar sangue durante o tratamento e até 1 mês após.
- Não tomar vitamina A nem tetraciclinas (risco de pseudotumor cerebral).
- Evitar cera, laser e peelings durante e até 6 meses após.
- Sinais de alerta: humor e depressão, cefaleia forte com visão turva, dor abdominal forte (pancreatite).
- Remédio pessoal e intransferível; devolver as sobras.

## Acitretina (NRR, lista C2)

Apresentações do catálogo: cápsula dura de 25 mg e de 10 mg.

**Fontes:**
- Neotigason, bula profissional aprovada pela Anvisa em 28/07/2022: https://uploads.consultaremedios.com.br/drug_leaflet/pro/Bula-Neotigason-Profissional-Consulta-Remedios.pdf
- Acitretina Glenmark, bula padrão de 19/08/2022: https://bula-anvisa.s3.sa-east-1.amazonaws.com/110130288_paciente.pdf

**Posologia da bula:**
- Uma vez ao dia, com alimento ou um pouco de leite.
- Início com 25 mg (ou 30 mg, 3 × 10 mg) por 2 a 4 semanas.
- Manutenção de 25 a 50 mg/dia por mais 6 a 8 semanas; máximo de 75 mg/dia.
- Nos distúrbios de ceratinização, a menor dose possível (pode ser menor que 20 mg/dia), até 50 mg/dia.

**Regimes:**
- 25 mg: início por 4 semanas; manutenção de 25, 50 e 75 mg (máximo), por 30 dias.
- 10 mg: início de 30 mg por 4 semanas; 10 mg (ceratinização) e 20 mg por 30 dias.

**Orientações:**
- Contracepção de 30 dias antes a 3 anos depois, com testes de gravidez.
- Não doar sangue durante o tratamento e por 3 anos após.
- Sem álcool durante o tratamento e por 2 meses após (forma etretinato).
- Contraindicado com vitamina A, outros retinoides, tetraciclinas e metotrexato.
- Evitar sol em excesso; pode ressecar lábios e olhos e reduzir a visão noturna.
- A minipílula de progesterona não é contracepção adequada. Isto está só aqui, porque não coube nas orientações.

## Talidomida (NRT, lista C3)

Apresentação do catálogo: comprimido de 100 mg (FUNED).

**Fonte:** FUNED Talidomida 100 mg, bula do paciente aprovada pela Anvisa em 17/11/2023, com indicações nos termos da RDC nº 11/2011: https://bula-anvisa.s3.sa-east-1.amazonaws.com/112090031_paciente.pdf

Não achei a bula profissional em PDF. A posologia é a do item 6 da bula do paciente.

**Modo de usar da bula:** ao deitar, pelo menos 1 hora após a última refeição, com um copo cheio de água. O comprimido pode ser partido; a metade que sobra fica na embalagem até a próxima dose.

**Regimes, com `tempo`.** Todos cobrem no máximo 30 dias, o limite da NRT.
- **Eritema nodoso hansênico (ENH) ou reação tipo II:** a bula dá 100 a 400 mg/dia conforme a intensidade. Regimes de 100, 200 e 300 mg ao deitar.
- **Úlceras aftoides no HIV:** 200 mg/dia por 4 semanas (56 comprimidos).
- **Mieloma múltiplo:** 100 mg/dia nos primeiros 14 dias e, sem intolerância, 200 mg/dia contínuo (46 comprimidos para 30 dias). A bula também traz um esquema de 200 mg com aumentos de 200 mg a cada 2 semanas até 400 mg, que não entrou.
- **Lúpus eritematoso:** 50 a 100 mg/dia em 2 doses por pelo menos 6 meses. Regime de 50 mg de 12/12 h (meio comprimido).
- **Doença do enxerto contra hospedeiro e síndrome mielodisplásica:** não viraram regimes. A titulação é mensal e especializada: DECH começa com 50 a 100 mg até o alvo de 400 mg/dia; SMD vai de 100 a 200 mg por 4 semanas, com aumentos mensais. Acima de 200 mg/dia, a bula manda dividir em 2 a 4 tomadas, 1 hora após as refeições.

**Sugestões para OUTRAS ORIENTAÇÕES** (as `orientacoes` do item):
- tomar ao deitar;
- proibida na gravidez;
- mulheres em idade fértil: 2 métodos contraceptivos (1 de barreira) de 1 mês antes a 1 mês após, e teste de gravidez semanal no 1º mês e depois a cada 2 a 4 semanas;
- homens: preservativo durante o tratamento e até 30 dias após, mesmo vasectomizados;
- não doar sangue nem esperma durante o tratamento e até 4 semanas após;
- sonolência: não dirigir, sem álcool nem calmantes;
- avisar se houver formigamento (neuropatia);
- remédio pessoal e intransferível; devolver as sobras à unidade de saúde.

## Deixados de fora

- **Tretinoína 10 mg** (Vesanoid, 7 embalagens): usada na indução da leucemia promielocítica aguda, na dose de 45 mg/m²/dia (25 mg/m²/dia em alguns casos), por superfície corporal, sob equipe especializada. O esquema não tem calculadora por superfície corporal.
- **Isotretinoína 40 mg:** fora do catálogo. Também ficaram de fora doses acima de 1 mg/kg/dia, que a bula reserva para doença muito grave.
- **Acitretina em crianças:** cerca de 0,5 mg/kg/dia, até 1 mg/kg/dia por período limitado, máximo 35 mg/dia. As cápsulas não permitem calculadora por peso.
- **Talidomida:** DECH e SMD (acima) e o esquema de mieloma de 200 + 200 mg a cada 2 semanas.

## Limites legais

### NRR (retinoides sistêmicos, lista C2)

Portaria SVS/MS nº 344/1998, texto compilado (legisweb, com as RDC 873/2024 e 1.000/2025): https://www.legisweb.com.br/legislacao/?id=317701

- **Art. 50, caput** (redação da RDC 873/2024): Notificação de Receita Especial, de cor branca, impressa às expensas do prescritor ou da instituição. Validade de **30 dias** a partir da emissão, **em todo o território nacional**.
- **Art. 50, § 1º:** no máximo **5 ampolas**; nas demais formas, a quantidade para **30 dias** de tratamento.
- **Art. 50, § 2º:** a NRR deve vir acompanhada do **"Termo de Consentimento Pós-Informação"** (Anexos XV e XVI), fornecido pelo prescritor, alertando que o medicamento é pessoal e intransferível e sobre reações e restrições.
  - A bula do Roacutan fala em "Termo de Consentimento Informado" e cita os critérios de contracepção para mulheres com potencial de engravidar.
  - No legisweb, os Anexos XV e XVI são imagens, e não confirmei o título exato de cada um. O nome "Termo de Conhecimento de Risco e Consentimento Pós-Informação" para mulheres em idade fértil não foi conferido no texto.
- **Art. 50, § 3º** (RDC 1.000/2025, em vigor desde 13/02/2026): o Termo pode ser emitido e assinado eletronicamente, com assinatura eletrônica válida do prescritor e do paciente (Lei 14.063/2020).
- **Art. 35, caput** (redação da RDC 1.000/2025): a Notificação de Receita, **acompanhada de receita**, autoriza a dispensação. A farmácia retém a notificação e devolve a receita carimbada (§ 5º).
- **Art. 35, § 3º:** a quantidade vai **em algarismos arábicos e por extenso**, sem emenda ou rasura.
- **Art. 35, § 7º:** a notificação é personalizada e intransferível, com uma só substância.
- **Art. 36, f:** o modelo traz o símbolo da mulher grávida cortada ao meio e a advertência "Risco de graves defeitos na face, nas orelhas, no coração e no sistema nervoso do feto".
- **Definição de Notificação de Receita:** a de retinoides é firmada **exclusivamente por médico** (CRM).
- **Art. 28:** a dispensação só ocorre em farmácias e drogarias **credenciadas pela Autoridade Sanitária Estadual**.
- **Art. 36, § 1º e art. 37** (redação da RDC 1.000/2025): numeração e controle da sequência pela Instrução Normativa. Hoje a numeração vem do SNCR, como mostra o modelo eletrônico da Anvisa.

### NRT (talidomida, lista C3)

RDC Anvisa nº 11, de 22/03/2011 (texto em bvsms): https://bvsms.saude.gov.br/bvs/saudelegis/anvisa/2011/res0011_21_03_2011.html

- **Art. 21, § 2º:** validade de **20 dias** a partir da emissão, **só dentro da unidade federativa onde foi emitida**. O pedido falava em "20 dias?"; confirmado.
- **Art. 21, § 3º:** no máximo a quantidade para **30 dias** de tratamento por notificação.
- **Art. 21, § 1º:** individual e intransferível; contém só talidomida.
- **Arts. 11, 13, 17 e 22, V, e:** prescrição só por médico com CRM **cadastrado na autoridade sanitária competente** (Anexo II). O **número do cadastro** é campo obrigatório da notificação.
  - Os talonários são distribuídos gratuitamente aos cadastrados (arts. 23 e 24).
  - No modelo eletrônico, a numeração vem do SNCR.
- **Art. 22:** campos obrigatórios:
  - CID;
  - as frases "Proibida para mulheres grávidas ou com chance de engravidar" e "Talidomida causa o nascimento de crianças sem braços e sem pernas";
  - especialidade e CPF do prescritor;
  - dados do paciente e do responsável;
  - **quantidade de comprimidos em algarismos e por extenso**, dose por unidade posológica, posologia, **tempo de tratamento** e demais orientações.
- **Arts. 18 e 20:** a notificação vai acompanhada do **Termo de Responsabilidade/Esclarecimento** (Anexos V-A ou V-B, conforme o caso). O Termo é preenchido e assinado pelo prescritor e pelo paciente em **3 vias**: prontuário, unidade dispensadora e paciente.
- **Art. 19:**
  - Mulheres em idade fértil (da menarca à menopausa, exceto as esterilizadas) só após exclusão de gravidez por método sensível e com **2 métodos contraceptivos, sendo 1 de barreira**.
  - O SUS fornece os métodos até 30 dias após o término.
  - Homens: preservativo durante o tratamento e por 30 dias após.
- **Art. 2º, XXXVI; art. 3º, § 3º; arts. 11, 30 a 33:**
  - Dispensação só por farmacêutico, em **unidade pública dispensadora do SUS credenciada**, com retenção da 2ª via.
  - É vedada a comercialização.
  - A 1ª via volta carimbada ao paciente.
- **Art. 27:** paciente internado dispensa a NRT e usa receita do hospital com o Termo.
- **Art. 16:** as indicações são as do Anexo III e da bula.
- **Art. 28:** fora delas, como última alternativa, só com **autorização prévia da Anvisa**.
- **Portaria 344, art. 49:** a notificação da lista C3 é impressa às expensas dos serviços públicos de saúde cadastrados na Vigilância Sanitária Estadual.

## Dúvidas

- **Roacutan:** a bula lida é a versão Roche de 2022. O registro está com a Farmoquímica desde 2024 e não achei a bula dela. A posologia confere com as bulas padrão de 2025 dos genéricos.
- **Talidomida:** só a bula do paciente (FUNED, 2023).
  - A bula não diz que a dose de 300 mg no ENH deve ser dividida; a divisão acima de 200 mg/dia aparece só em DECH e SMD. O regime de 300 mg é em dose única ao deitar.
- **Rótulos com indicação:** os rótulos da talidomida citam a indicação ("ENH", "Mieloma", "Lúpus"). A NRT já traz o CID, mas vale confirmar se o rótulo é impresso.
- **Orientações da NRR:** o modelo da NRR tem só o campo POSOLOGIA, sem campo de orientações. As `orientacoes` da isotretinoína e da acitretina ficam para a tela e para o Termo, a critério da UI.
- **Calculadora da isotretinoína:** os campos `mgPorUnidade`, `mgKgDiaMax` e `doseAcumuladaMgKg` são novos. A UI atual calcula em mL e precisa de um modo para cápsulas.
