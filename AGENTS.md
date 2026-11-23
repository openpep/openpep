<!-- SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep> -->
<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Instruções para agentes

Escolha a menor solução que preserve as fronteiras do aplicativo e possa ser
verificada agora. Siga [CONTRIBUTING.md](CONTRIBUTING.md).

- Não antecipe funcionalidades, abstrações, migrações ou dependências.
- Preserve arquivos fora do escopo. Não crie documentos de planejamento,
  roadmaps ou relatórios históricos; registre escopo, decisões, critérios de
  aceite e pendências no PR. Mantenha o README conciso e fiel ao código atual.
- Preserve os avisos de licença, procedência e atribuição. Dependências novas
  precisam de versão, licença e justificativa antes da adoção.
- Use somente dados e identificadores sintéticos. Nunca exponha credenciais.
- O filesystem clínico local é a fonte soberana. Uma projeção operacional deve
  ser reconstruível; a recepção web não pode acessar conteúdo clínico.
- IA produz propostas até validação profissional. Corrija nota final somente
  por adendo. Não altere silenciosamente permissões de acesso ou envio de dados.
- Não declare segurança, integridade, interoperabilidade ou imutabilidade sem
  testes que sustentem exatamente a garantia.
- Execute os testes relacionados e os gates obrigatórios antes do merge.
  Prefira um PR por incremento e commits pequenos com `git commit -s`.
- Não crie outro AGENTS.md em subdiretórios sem necessidade concreta.
