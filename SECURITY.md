<!-- SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep> -->
<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Política de segurança

## Versões suportadas

Somente a linha mais recente do projeto recebe correções de segurança. Versões anteriores não são mantidas.

## Como relatar uma vulnerabilidade

Relate de forma privada, pelo recurso **Report a vulnerability** da aba **Security** do repositório [`openpep/openpep`](https://github.com/openpep/openpep/security) no GitHub. Não abra issue pública, discussão nem pull request para descrever uma falha ainda não corrigida.

Inclua no relato:

- a versão ou o commit examinado e, quando aplicável, a versão do macOS, do navegador ou do Node.js;
- o componente afetado;
- os passos para reproduzir, com um prontuário sintético;
- o efeito observado e o efeito que você esperava;
- a avaliação do impacto, se houver, e qualquer mitigação conhecida.

## O que nunca enviar

Nunca anexe dados reais de pacientes: prontuários, documentos, transcrições, capturas de tela, registros de execução ou backups. Reproduza o problema com dados sintéticos, como os de `fixtures/` ou do ensaio sintético do aplicativo.

Nunca envie credenciais: chaves de API, tokens, senhas, certificados, chaves privadas ou arquivos de configuração local. Se uma credencial foi exposta por engano, revogue-a antes de relatar.

## Escopo

- o aplicativo macOS em `apps/macos`;
- o módulo de prescrição OpenPEP-Rx em `apps/openpep-rx`, incluindo o serviço local, o relay hospedado e a integração com o SNCR;
- o formato do cofre e os schemas em `packages/protocol-schema`;
- o site em `website/`;
- as ferramentas em `tools/` e os scripts em `scripts/`.

Serviços de terceiros usados pelo aplicativo, como provedores de IA, o SNCR e o provedor do certificado digital, ficam fora do escopo. Falhas neles devem ser relatadas aos respectivos responsáveis. A forma como o OpenPEP usa esses serviços está no escopo.

## Limites conhecidos

Os limites já declarados do software não são vulnerabilidades novas. Eles estão descritos no [README](README.md#limites) e no [aviso de saúde](DISCLAIMER-SAUDE.md). Um relato é bem-vindo quando mostra que o aplicativo faz menos do que esses documentos afirmam.
