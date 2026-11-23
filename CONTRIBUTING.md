<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Contribuindo

Use somente dados sintéticos. Nunca inclua prontuários reais, chaves de API,
senhas ou certificados em código, testes, imagens, logs ou relatos.

- Faça uma mudança coerente por PR e explique o problema, a solução e como foi
  verificada. Registre limitações e decisões de arquitetura no próprio PR.
- Preserve os arquivos locais como fonte dos registros, a revisão profissional
  das propostas de IA e a correção de notas finais somente por adendo.
- Execute os testes relacionados à mudança e, antes do merge, `make check` e
  `make mac-check`. Mudanças de formato precisam de testes de compatibilidade.
- Prefira APIs nativas. Uma dependência nova precisa de versão fixada, licença,
  justificativa e avisos preservados.
- Use português brasileiro na interface e inglês nos identificadores de código.
  Escreva textos diretos e não prometa garantias além do que os testes sustentam.
- Cada commit deve ter `Signed-off-by`, com `git commit -s`, conforme o [DCO](DCO).
  Não há CLA nem cessão de copyright. Preserve as licenças e os avisos SPDX.

O GitHub executa automaticamente os testes Linux nos PRs. O job macOS é manual
para controlar o consumo; não o configure como check obrigatório da branch.
A validação macOS local continua necessária antes do merge.

Até a primeira release pública, Carlos Pedrotti pode revisar as próprias
mudanças. Depois dela, alterações de criptografia, autenticação e finalização
clínica exigem dois revisores, incluindo alguém responsável pela segurança.

A distribuição pública depende de revisão do mantenedor, inclusive das licenças
dos catálogos. Aprovar um PR ou publicar o site não libera uso clínico.
