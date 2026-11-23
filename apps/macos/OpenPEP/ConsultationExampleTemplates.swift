// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Illustrative document layouts, never patient-specific treatment recommendations.
enum ConsultationExampleTemplates {
    struct Example: Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }

    static func examples(for section: ConsultationTextSection) -> [Example] {
        switch section {
        case .prescription:
            return [
                Example(name: "Uso contínuo — exemplo", text: """
                EXEMPLO PARA EDIÇÃO — individualizar antes de usar

                USO ORAL

                1. Losartana potássica
                Apresentação e concentração: [preencher]
                Tomar [dose] por via oral, [frequência].
                Duração: [preencher]. Quantidade a dispensar: [preencher].

                2. Metformina
                Apresentação e concentração: [preencher]
                Tomar [dose] por via oral, [frequência].
                Duração: [preencher]. Quantidade a dispensar: [preencher].

                Orientações específicas: [preencher].
                """),
                Example(name: "Medicamento se necessário — exemplo", text: """
                EXEMPLO PARA EDIÇÃO — individualizar antes de usar

                USO ORAL

                1. Paracetamol
                Apresentação e concentração: [preencher]
                Tomar [dose] por via oral se [condição de uso].
                Intervalo mínimo entre doses: [preencher].
                Limite diário e duração máxima: [preencher].
                Quantidade a dispensar: [preencher].

                Orientações e critérios para reavaliação: [preencher].
                """)
            ]
        case .exams:
            return [
                Example(name: "Pedido laboratorial — exemplo", text: """
                EXEMPLO PARA EDIÇÃO — selecionar os exames pertinentes

                Solicito:

                - Hemograma completo
                - Glicemia de jejum
                - Hemoglobina glicada (HbA1c)
                - Creatinina
                - Colesterol total, HDL, LDL e triglicerídeos

                Justificativa clínica: [preencher].
                Informações ao laboratório: [preencher, se necessário].
                """),
                Example(name: "Ultrassonografia — exemplo", text: """
                EXEMPLO PARA EDIÇÃO — individualizar antes de usar

                Solicito:

                Ultrassonografia de abdome total.

                Indicação clínica: [preencher].
                Questão a esclarecer: [preencher].
                Informações clínicas relevantes: [preencher].
                """)
            ]
        default: return []
        }
    }
}
