// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

struct SyntheticPatientScenario {
  let name: String
  let age: Int
  let occupation: String
  let encounters: [SyntheticPatientEncounter]
  let wiki: String
}

struct SyntheticPatientEncounter {
  let daysAgo: Int
  let body: String
}

enum SyntheticPatientScenarios {
  static let patients: [SyntheticPatientScenario] = [
    SyntheticPatientScenario(
      name: "Helena Duarte",
      age: 34,
      occupation: "arquiteta",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: cefaleias recorrentes nos dias de prazo mais apertado no escritório.

        Helena relata episódios pulsáteis, geralmente no fim da tarde, associados a náusea leve e incômodo com luz. Não descreve início súbito, febre, alteração de força ou visão persistente. Dorme pouco nas semanas de entrega e costuma pular o almoço. Exame neurológico sem achados focais; sem rigidez de nuca.

        Plano: iniciar diário de sintomas, sono e refeições; organizar pausas durante o trabalho; retornar com o registro. Pendência: caracterizar frequência e possíveis gatilhos.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno para revisão do diário de cefaleia.

        Foram anotados quatro episódios no mês, todos após noites curtas ou muitas horas diante do computador. Refere melhora ao reduzir reuniões seguidas e manter uma garrafa de água à mesa. Sem sintomas neurológicos novos. Exame clínico geral sem alterações relevantes.

        Plano: manter as medidas de rotina e acrescentar avaliação oftalmológica, pois relata que a correção dos óculos parece antiga. Pendência: trazer o resultado da avaliação e seguir registrando os episódios.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Acompanhamento breve das cefaleias.

        Relata apenas um episódio leve desde a última consulta, em semana de viagem para obra. A avaliação oftalmológica foi agendada, mas ainda não realizada. Mantém pausas e refeições mais regulares; percebeu que isso ajuda também na disposição ao fim do dia. Sem sinais de alarme relatados.

        Plano: continuar o diário e as medidas combinadas; rever após a avaliação oftalmológica. Pendência: resultado da consulta de visão.
        """),
      ],
      wiki: """
      # Helena Duarte

      Arquiteta, relata rotina de trabalho variável e sono reduzido em períodos de entrega. [F1] Cefaleias recorrentes, com características acompanhadas em diário, foram menos frequentes após pausas, hidratação e regularidade das refeições. [F2] [F3]

      ## Problemas acompanhados
      - Cefaleia recorrente, sem sinais neurológicos de alarme documentados nas consultas. [F1] [F2]

      ## Evolução e pendências
      Houve um episódio leve na última semana de acompanhamento. [F3] Aguarda avaliação oftalmológica já agendada. [F2] [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Caio Nascimento",
      age: 41,
      occupation: "cozinheiro",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: azia e sensação de queimação após o turno noturno.

        Caio trabalha em cozinha de restaurante e costuma fazer a refeição principal perto da meia-noite. Relata queimação retroesternal após comidas muito gordurosas, sem dificuldade para engolir, vômitos persistentes, perda de peso ou fezes escuras. Ao exame, está em bom estado geral; abdome flácido, sem dor localizada.

        Plano: ajustar o horário e o volume das refeições quando possível, observar alimentos associados e evitar deitar logo após comer. Pendência: acompanhar resposta e registrar qualquer sinal novo.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por desconforto digestivo.

        Relata redução da queimação ao fracionar a refeição do trabalho e diminuir frituras no fim do turno. Teve dois episódios após confraternizações mais longas. Nega dificuldade para engolir e perda de peso. Exame abdominal novamente sem alterações relevantes.

        Plano: manter as mudanças que foram viáveis na rotina do restaurante; discutir com a equipe de saúde se o quadro voltar a ser frequente. Pendência: verificar evolução durante semanas de maior movimento.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Revisão de hábitos e sintomas digestivos.

        Refere uma semana sem azia importante, mesmo em escala mais cheia. Passou a levar uma opção de lanche simples para não permanecer muitas horas sem comer. Não surgiram sintomas de alerta. Mantém preocupação de que o horário de trabalho dificulte a continuidade.

        Plano: consolidar a estratégia de refeições possíveis no turno e retorno se houver piora. Pendência: reavaliar em período de festas do restaurante.
        """),
      ],
      wiki: """
      # Caio Nascimento

      Cozinheiro em turno noturno, com refeições tardias e irregulares durante o trabalho. [F1] Relatou queimação após refeições mais gordurosas, com melhora gradual após fracionar a alimentação. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Queimação retroesternal associada a refeições tardias, sem sinais de alarme documentados. [F1] [F2]

      ## Evolução e pendências
      Na última semana não relatou azia importante. [F3] A durabilidade das mudanças precisa ser revista durante escalas mais intensas e no período de festas. [F2] [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Lívia Monteiro",
      age: 29,
      occupation: "professora de educação infantil",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: dor anterior no joelho esquerdo ao subir escadas e permanecer agachada na sala.

        Lívia relata início gradual há cerca de seis semanas, sem queda ou torção. A dor aparece principalmente depois de um dia inteiro com crianças pequenas e melhora com repouso. Nega travamento, inchaço importante, febre ou instabilidade. Exame mostra marcha preservada, sem derrame aparente, com desconforto à compressão patelofemoral e mobilidade preservada.

        Plano: adaptar temporariamente as atividades que pioram a dor, iniciar fisioterapia e retornar para avaliar função. Pendência: observar se há edema ou piora após esforço.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por dor no joelho esquerdo.

        Realizou sessões iniciais de fisioterapia e relata menor dor nas escadas. Ainda sente desconforto quando precisa ficar muito tempo agachada para atividades de roda. Não houve travamento nem edema. Exame mantém boa mobilidade e sem sinais inflamatórios locais.

        Plano: seguir com fortalecimento orientado e combinar com a escola pausas entre atividades no chão. Pendência: avaliar tolerância ao retorno gradual às caminhadas de fim de semana.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Acompanhamento funcional do joelho.

        Relata conseguir conduzir as aulas com menos interrupções e voltou a caminhar em trajeto curto no parque, sem aumento relevante da dor no dia seguinte. Continua evitando ficar agachada por tempo prolongado. Sem episódios de queda ou inchaço.

        Plano: prosseguir com fisioterapia e progressão orientada de atividades. Pendência: reavaliar se a adaptação na escola se mantém no próximo mês.
        """),
      ],
      wiki: """
      # Lívia Monteiro

      Professora de educação infantil, cuja rotina exige escadas e períodos agachada. [F1] Dor anterior no joelho esquerdo iniciou gradualmente, sem trauma relatado, e melhorou com adaptações e fisioterapia. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Dor anterior no joelho esquerdo, com impacto funcional no trabalho. [F1]

      ## Evolução e pendências
      Voltou a caminhadas curtas sem piora relevante. [F3] Acompanhar tolerância às atividades escolares e à progressão de exercícios. [F2] [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Rafael Pires",
      age: 52,
      occupation: "motorista de ônibus",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: cansaço ao final do dia e medidas de pressão elevadas em avaliação da empresa.

        Rafael trabalha em turnos alternados e relata sono fragmentado nas semanas de troca de escala. Trouxe anotações de medidas de pressão feitas no trabalho, algumas acima do habitual para ele. Refere dislipidemia identificada em exame ocupacional anterior e relata usar atorvastatina à noite, embora admita esquecer em dois ou três plantões por semana; não trouxe a caixa para conferir o esquema. Pai teve infarto aos 67 anos. Nega dor no peito, falta de ar, desmaio ou déficit neurológico. Após cinco minutos de repouso, a pressão foi 154/94 mmHg e 150/92 mmHg; frequência de 74 bpm, peso 96,4 kg e altura 1,73 m. Ausculta cardíaca e pulmonar sem achados adicionais.

        Plano: realizar registro residencial de pressão em horários combinados, rever padrão de sono e trazer exames já solicitados pelo serviço ocupacional. Pendência: diário de medidas e resultados laboratoriais.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno com registro de pressão e rotina de sono.

        O diário trouxe 18 medidas: nos dias de descanso, predominou entre 136–144/84–90 mmHg; após troca de escala, registrou valores de 150–156/92–96 mmHg. Relata ter reduzido bebidas energéticas usadas nos turnos longos, mas conta que voltou a consumi-las em dois plantões muito cheios. Trouxe exames ocupacionais de três semanas antes: glicemia de jejum 94 mg/dL, creatinina 0,88 mg/dL, potássio 4,2 mEq/L e LDL-colesterol 148 mg/dL. Diz tomar a medicação para colesterol “quase todo dia”, diferente da frequência de esquecimentos descrita na consulta anterior. Continua sem sintomas cardiovasculares ou neurológicos.

        Plano: manter o registro por mais duas semanas e organizar retorno com os exames ocupacionais. Pendência: confirmar se os valores se mantêm fora dos dias de troca de escala.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Revisão das anotações domiciliares.

        Rafael relata que as últimas seis medidas ficaram entre 134–142/82–88 mmHg após conseguir dois dias seguidos de descanso; hoje, após repouso, a pressão foi 138/86 mmHg. Ainda não recebeu o eletrocardiograma solicitado no exame ocupacional. Está tentando substituir parte das bebidas energéticas por água e lanches preparados em casa, mas relata que isso falhou no último turno extra. Não trouxe novamente a embalagem da atorvastatina para conferência.

        Plano: continuar o diário até receber os resultados e discutir a próxima etapa no retorno. Pendência: exames ocupacionais pendentes.
        """),
      ],
      wiki: """
      # Rafael Pires

      Motorista de ônibus com turnos alternados e sono fragmentado nas trocas de escala. [F1] Tem dislipidemia referida, histórico paterno de infarto e relata uso noturno de atorvastatina, sem confirmação do esquema nem adesão consistente. [F1] [F2] [F3] Medidas de pressão foram acompanhadas por diário; houve variabilidade relacionada aos dias de menor descanso. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Medidas de pressão elevadas em acompanhamento: 154/94 e 150/92 mmHg na primeira consulta; últimas seis medidas entre 134–142/82–88 mmHg. [F1] [F3]
      - Sono fragmentado associado à rotina de trabalho. [F1]
      - LDL-colesterol 148 mg/dL em exame ocupacional trazido pelo paciente. [F2]

      ## Evolução e pendências
      As últimas medidas ficaram mais próximas após dias de descanso, mas houve consumo de energético em turno extra. [F3] Falta trazer a embalagem da medicação referida e o resultado do eletrocardiograma ocupacional. [F2] [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Marta Siqueira",
      age: 63,
      occupation: "bibliotecária aposentada",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: mãos ressecadas e prurido após reorganizar livros em casa.

        Marta passou várias semanas limpando uma biblioteca particular da família e relata piora do ressecamento após contato frequente com poeira e produtos de limpeza. Há placas secas nas mãos, sem febre, secreção ou lesões em outras áreas. Exame mostra pele ressecada e fissuras superficiais em alguns dedos, sem sinais de infecção local.

        Plano: reduzir contato direto com produtos irritantes, usar proteção nas tarefas e reforçar cuidados de barreira cutânea. Pendência: observar resposta e retorno se houver dor, secreção ou expansão das lesões.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por ressecamento das mãos.

        Refere diminuição do prurido e menos fissuras desde que passou a usar luvas em parte das tarefas. Ainda tem piora depois de lavar caixas antigas. Ao exame, restam áreas discretamente secas, sem vermelhidão intensa ou secreção.

        Plano: manter proteção e cuidados de barreira; dividir a organização do acervo em períodos menores. Pendência: revisar se consegue evitar os produtos que provocam piora.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Acompanhamento dermatológico das mãos.

        Marta relata pele praticamente íntegra e voltou a preparar conservas com a irmã, usando luvas nas etapas de limpeza. Não há dor, secreção ou novas fissuras. Diz que o incômodo diminuiu quando deixou de concentrar toda a organização em um único dia.

        Plano: manter as medidas preventivas e procurar reavaliação se as lesões retornarem. Pendência: nenhuma consulta programada; acompanhar conforme sintomas.
        """),
      ],
      wiki: """
      # Marta Siqueira

      Bibliotecária aposentada, reorganizava um acervo familiar com contato frequente com poeira e produtos de limpeza. [F1] Ressecamento e prurido das mãos melhoraram com proteção durante as tarefas e cuidados de barreira. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Ressecamento e fissuras superficiais nas mãos, sem sinais de infecção documentados. [F1] [F2]

      ## Evolução e pendências
      Na última consulta, a pele estava praticamente íntegra e sem novos sintomas. [F3] Manter medidas preventivas e reavaliar se houver retorno das lesões. [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Otávio Lemos",
      age: 47,
      occupation: "fotógrafo",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: dificuldade para manter o sono desde o início de uma exposição importante.

        Otávio relata despertar de madrugada pensando em prazos e edição de imagens. Durante o dia, sente cansaço e se apoia em café até o fim da tarde. Nega uso de outras substâncias para dormir, humor persistentemente deprimido ou pensamentos de autoagressão. Exame clínico geral sem alterações agudas.

        Plano: estabelecer horário de desligamento do trabalho, reduzir cafeína no fim do dia e registrar horários de sono. Pendência: avaliar impacto das mudanças após o período de montagem da exposição.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno sobre sono e sobrecarga de trabalho.

        Conseguiu deixar o computador fora do quarto na maior parte dos dias e reduziu o café após o almoço. Ainda desperta em duas noites por semana, principalmente quando recebe mensagens de clientes à noite. Mantém apetite e atividades habituais; sem queixas de humor persistente.

        Plano: manter rotina de desaceleração e silenciar notificações profissionais após o horário combinado. Pendência: observar o sono depois da abertura da exposição.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Revisão após a abertura da exposição.

        Relata alívio da pressão de prazo e sono mais contínuo em cinco das últimas sete noites. Voltou a caminhar pela manhã com o vizinho, atividade que havia interrompido. Ainda teme retomar o padrão de mensagens noturnas quando aceitar novos trabalhos.

        Plano: preservar limites de horário e caminhar quando a agenda permitir. Pendência: revisar manutenção da rotina em retorno de acompanhamento.
        """),
      ],
      wiki: """
      # Otávio Lemos

      Fotógrafo com sobrecarga temporária relacionada à montagem de uma exposição. [F1] Dificuldade de manutenção do sono melhorou depois de separar o trabalho do período noturno e reduzir cafeína tarde. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Sono fragmentado associado a prazos e mensagens de trabalho. [F1] [F2]

      ## Evolução e pendências
      Relatou sono mais contínuo após a abertura da exposição e retomou caminhadas matinais. [F3] Acompanhar a manutenção dos limites de horário em novos projetos. [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Beatriz Campos",
      age: 38,
      occupation: "engenheira ambiental",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: congestão nasal e espirros em visitas a uma estação de tratamento.

        Beatriz relata nariz entupido, espirros e coceira ocular ao acompanhar vistorias em área com muito pó. Os sintomas melhoram nos fins de semana em casa. Nega falta de ar, chiado, febre ou dor facial intensa. Exame mostra mucosa nasal irritada, sem secreção purulenta; ausculta pulmonar sem ruídos adicionais.

        Plano: registrar exposição e sintomas, revisar o uso de equipamentos de proteção no trabalho e manter reavaliação se houver sintomas respiratórios baixos. Pendência: verificar se os equipamentos disponíveis se ajustam adequadamente.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por sintomas nasais relacionados ao trabalho.

        Passou a usar proteção respiratória durante toda a vistoria e refere redução clara dos espirros. Teve uma crise mais intensa em dia de vento forte, quando o equipamento não foi usado desde o início. Sem falta de ar ou chiado. Exame sem alterações pulmonares.

        Plano: manter o equipamento desde a chegada ao local e discutir com a empresa uma opção de melhor ajuste. Pendência: acompanhar sintomas na próxima sequência de vistorias.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Revisão após nova rodada de campo.

        Refere apenas coceira ocular leve em uma vistoria longa; não teve congestão importante nem episódios fora do trabalho. A empresa forneceu um modelo de proteção que se adapta melhor ao rosto. Sem sintomas respiratórios baixos relatados.

        Plano: continuar as medidas no campo e registrar possíveis recorrências. Pendência: retorno conforme necessidade após período mais seco.
        """),
      ],
      wiki: """
      # Beatriz Campos

      Engenheira ambiental, com sintomas nasais e oculares durante vistorias em ambiente com poeira. [F1] Houve melhora após uso mais consistente de proteção respiratória. [F2] [F3]

      ## Problemas acompanhados
      - Congestão nasal, espirros e coceira ocular associados à exposição ocupacional. [F1]

      ## Evolução e pendências
      Restou coceira ocular leve em uma vistoria longa, sem sintomas respiratórios baixos. [F3] Acompanhar recorrências no período mais seco e a adaptação do equipamento fornecido. [F2] [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Samuel Freitas",
      age: 56,
      occupation: "marceneiro",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: dor lombar após encomenda com muitas peças grandes.

        Samuel relata dor lombar de início após vários dias carregando placas de madeira, sem queda ou trauma direto. Teve episódio semelhante há quatro anos, que melhorou após reduzir a carga por algumas semanas. Usa paracetamol apenas em dias de maior incômodo, sem frequência fixa, e nega outros medicamentos contínuos. A dor piora ao final da jornada e melhora ao descansar. Nega febre, perda de força, dormência em sela, alteração urinária ou dor irradiada persistente. Exame mostra sensibilidade muscular lombar, flexão limitada pela dor a cerca de 60 graus e marcha preservada, sem déficit neurológico observado.

        Plano: adaptar temporariamente o transporte de peças, iniciar fisioterapia e manter-se ativo dentro do tolerado. Pendência: rever evolução funcional e sinais de alarme.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por dor lombar.

        Refere melhora parcial com seis sessões de fisioterapia e uso de carrinho para movimentar parte das peças. Diz ter faltado a duas sessões por precisar entregar uma encomenda. Ainda piora quando trabalha sozinho em encomendas pesadas e usou paracetamol em quatro dias nas últimas duas semanas. Não houve irradiação, fraqueza ou alteração urinária. Exame mantém marcha e força preservadas; flexão alcança aproximadamente 75 graus, ainda com desconforto ao final do movimento.

        Plano: continuar fisioterapia e planejar ajuda para cargas maiores. Pendência: avaliar se a dor interfere no sono ou retorna nos dias sem oficina.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Acompanhamento da lombalgia.

        Samuel relata que conseguiu concluir uma encomenda menor sem crise forte ao dividir a carga com um ajudante. Dorme melhor e não refere irradiação ou perda de força. Na última semana não usou analgésico. Pretende reorganizar a oficina para deixar materiais pesados mais acessíveis, mas ainda não comprou o segundo carrinho que havia considerado necessário.

        Plano: manter exercícios orientados e as adaptações de trabalho. Pendência: reavaliar após a reorganização da oficina.
        """),
      ],
      wiki: """
      # Samuel Freitas

      Marceneiro, com esforço físico repetido para movimentação de peças grandes e episódio semelhante há quatro anos. [F1] Dor lombar iniciou após período de sobrecarga e melhorou parcialmente com fisioterapia e adaptação do transporte de materiais. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Dor lombar mecânica em acompanhamento, com flexão aproximada de 60 graus inicialmente e 75 graus no retorno, sem sinais neurológicos de alarme documentados. [F1] [F2]
      - Relata uso eventual de paracetamol para dor, sem medicamento contínuo informado. [F1] [F2] [F3]

      ## Evolução e pendências
      Faltou a duas sessões de fisioterapia por demanda de trabalho, mas concluiu uma encomenda menor sem crise forte ao dividir a carga. [F2] [F3] Ainda pretende reorganizar a oficina e não adquiriu o segundo carrinho. [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Nina Azevedo",
      age: 26,
      occupation: "designer de interiores",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: lesões de pele na face antes de apresentações para clientes.

        Nina relata aparecimento de pápulas e inflamação na região do queixo e mandíbula, percebidas sobretudo em semanas de maior ansiedade e quando dorme com maquiagem após visitas externas. Usa um gel de limpeza e um hidratante sem fragrância que comprou por conta própria; diz ter suspendido um produto com ácidos após ardor e descamação, sem lesões em outras áreas. Nega reação medicamentosa conhecida. Exame mostra 11 pápulas e três pústulas pequenas na região mandibular, sem nódulos profundos ou sinais de infecção extensa.

        Plano: simplificar a rotina de limpeza, evitar manipular as lesões e registrar produtos usados. Pendência: observar resposta antes de introduzir novos cosméticos.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por lesões faciais.

        Refere menos inflamação depois de retirar a maquiagem ao chegar em casa e parar de alternar muitos produtos. Teve piora pontual antes de uma apresentação importante, quando voltou a usar a base antiga por dois dias; depois suspendeu novamente. Mantém o gel e o hidratante na maior parte dos dias, mas esqueceu ambos em uma viagem de trabalho. Ao exame, há cinco pápulas ativas, uma pústula pequena e marcas residuais discretas, sem lesões profundas.

        Plano: manter rotina simples e discutir fatores de estresse que coincidem com as crises. Pendência: acompanhar marcas residuais e frequência das novas lesões.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Acompanhamento da pele facial.

        Nina relata duas pequenas lesões novas no período, sem piora disseminada. Diz que deixou lenços e itens de limpeza na mochila para os dias de visita e manteve a rotina em todos os dias, exceto em uma noite de evento. Ao exame, há duas pápulas pequenas e marcas residuais; não há pústulas ou nódulos. Está satisfeita com a melhora e prefere não testar produtos adicionais por enquanto.

        Plano: manter a rotina atual e reavaliar se houver nova piora. Pendência: acompanhar impacto de períodos de apresentação na pele.
        """),
      ],
      wiki: """
      # Nina Azevedo

      Designer de interiores, com semanas de trabalho externo e apresentações para clientes. [F1] Relata uso de gel de limpeza e hidratante sem fragrância; suspendeu um produto com ácidos após ardor e descamação. [F1] Lesões inflamatórias leves na face melhoraram após simplificar a rotina e retirar maquiagem ao chegar em casa. [F1] [F2] [F3]

      ## Problemas acompanhados
      - Lesões inflamatórias leves na face, com piora percebida em semanas de maior estresse: 11 pápulas e três pústulas inicialmente; duas pápulas e nenhuma pústula no último atendimento. [F1] [F3]

      ## Evolução e pendências
      A adesão à rotina foi incompleta em viagem e noite de evento; houve uso pontual da base antiga antes da melhora continuar. [F2] [F3] Prefere manter a rotina atual e acompanhar recorrência em períodos de apresentações. [F3]
      """
    ),
    SyntheticPatientScenario(
      name: "Dora Valença",
      age: 71,
      occupation: "florista",
      encounters: [
        SyntheticPatientEncounter(daysAgo: 90, body: """
        Motivo: inchaço leve nos tornozelos no fim de dias de feira.

        Dora trabalha em pé preparando arranjos e relata edema discreto ao final de feiras longas, que melhora pela manhã. Tem hipertensão acompanhada em outro serviço e diz usar losartana pela manhã; não soube informar a dose nem levou a lista, pois separa os comprimidos em uma caixa sem rótulo. Nega falta de ar, dor no peito, dor unilateral intensa ou feridas nas pernas. Pressão de 132/78 mmHg, frequência de 68 bpm e peso de 62,1 kg. Exame mostra edema maleolar discreto bilateral ao fim da tarde, pele íntegra e pulsos presentes.

        Plano: alternar períodos em pé e sentada, fazer pausas com elevação das pernas quando possível e trazer a lista dos medicamentos que usa em casa. Pendência: confirmar medicações de uso contínuo e acompanhar a variação do edema.
        """),
        SyntheticPatientEncounter(daysAgo: 30, body: """
        Retorno por edema em tornozelos.

        Relata menor inchaço ao usar um banco alto entre os atendimentos e ao terminar a feira mais cedo duas vezes por semana. Trouxe uma lista antiga com losartana e um segundo comprimido “para circulação”, mas diz que o segundo pode ter sido suspenso há meses; a filha acredita que ela ainda o toma. Exames trazidos do outro serviço, datados de dois meses antes, registram creatinina 0,79 mg/dL, sódio 140 mEq/L e potássio 4,4 mEq/L. Pressão de 128/76 mmHg e peso de 61,8 kg. Não houve falta de ar, dor torácica ou assimetria importante.

        Plano: manter as pausas e combinar revisão da lista de medicamentos com o serviço que acompanha a pressão. Pendência: registrar dias de maior edema e levar lista atualizada ao próximo retorno.
        """),
        SyntheticPatientEncounter(daysAgo: 7, body: """
        Acompanhamento breve do edema.

        Dora relata que o inchaço ficou restrito a um dia de feira prolongada e cedeu após repouso. A filha encontrou foto de uma receita recente apenas com losartana, mas Dora afirma que ainda tem uma cartela do outro comprimido em casa; a conciliação segue incompleta. Pressão de 130/78 mmHg, peso de 61,9 kg e edema maleolar mínimo bilateral no fim do dia. Exame sem feridas ou assimetria importante; mantém ausência de sintomas respiratórios relatados.

        Plano: continuar as adaptações no trabalho e trazer a lista atualizada quando disponível. Pendência: conciliação da medicação referida com o serviço de acompanhamento.
        """),
      ],
      wiki: """
      # Dora Valença

      Florista, permanece em pé por períodos prolongados durante feiras. [F1] Tem hipertensão acompanhada em outro serviço e relata uso de losartana, sem dose documentada nesta série. [F1] [F2] [F3] Edema leve bilateral nos tornozelos melhora com repouso e foi menos frequente após pausas no trabalho. [F1] [F2] [F3]

      ## Problemas e medicamentos
      - Edema maleolar leve bilateral no fim do dia, sem sintomas respiratórios ou dor torácica relatados; mínimo no último exame. [F1] [F2] [F3]
      - Hipertensão acompanhada em outro serviço. Medicação relatada: losartana; possível segundo comprimido não identificado, com uso atual contraditório. [F1] [F2] [F3]
      - Creatinina 0,79 mg/dL, sódio 140 mEq/L e potássio 4,4 mEq/L em exames de outro serviço. [F2]

      ## Evolução e pendências
      Teve um único dia de edema recente após feira prolongada. [F3] A lista e a foto da receita divergem sobre um possível segundo comprimido; a conciliação permanece pendente com o serviço de acompanhamento. [F2] [F3]
      """
    ),
  ]
}
