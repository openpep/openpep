<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# OpenPEP-Rx

Módulo independente de prescrição: interface no navegador, SQLite local,
modelos PDF, estoque SNCR e assinatura por VIDaaS Connect no Mac.
**Alfa para testes sintéticos, sem liberação clínica.**

## Executar

Requer Node.js 24.20 ou posterior da série 24. Para assinatura: macOS, Xcode
Command Line Tools e VIDaaS Connect instalado e autenticado.

```sh
npm ci
npm run build:signer
npm run local
```

Abra o endereço de abertura exibido no terminal
(`http://127.0.0.1:4197/abrir?chave=…`). Ele vale uma vez por execução e entrega
ao navegador que o abrir o cookie da sessão local; sem esse cookie ou um
pareamento web, o serviço não entrega o token da sessão. Para usar outro
navegador, reinicie o serviço. O cookie não isola portas em `127.0.0.1`, e quem
lê o terminal ou os cookies do navegador obtém a sessão. No macOS, depois da
instalação, também é possível usar `Abrir-OpenPEP-Rx.command`. Mantenha o
serviço local aberto durante o uso.

Para começar, escolha **Nova receita**, cadastre emitente e paciente sintéticos
e marque **Ensaio sem consumir numeração SNCR**. Revise o PDF antes de qualquer
assinatura. O certificado do VIDaaS está em nuvem e exige conexão.

O banco fica em `.local-data/prescricao/`. Para escolher outra pasta, copie
`.env.example` para `.env` e configure `OPENPEP_DATA_DIR` com um caminho absoluto.
Credenciais e bancos locais não devem entrar no Git. Não use cópias simultâneas
do mesmo estoque: o controle offline não impede duplicação entre clones.

O portal SNCR por provedor é opcional e separado: recebe a identificação do
estoque, autentica o prescritor e entrega um lote para importação local. O portal
de documentos só recebe PDFs após confirmação individual. Instalar o módulo
não provisiona esses serviços. O portal SNCR identifica a conta pelo cabeçalho
`oai-authenticated-user-id`, que a hospedagem precisa definir e não pode aceitar
do cliente, e permite no máximo 10 logins SNCR por conta a cada hora. O ambiente web pareado não grava números diretamente: o pedido passa pelo portal, e o resultado só entra no estoque local como lote assinado, conferido pelo auxiliar com a chave pública configurada. Seus
geradores estão em `scripts/preparar-portal.mjs` e
`scripts/preparar-documentos.mjs`, com configuração em `.env.example`.

## Verificar

`npm test` executa os testes sintéticos; `npm run release` gera o ZIP de
código-fonte. Compilar ou testar não solicita numeração de produção nem libera
uso clínico. A integridade CMS verificada não comprova conformidade ICP-Brasil,
revogação ou perfil PAdES.

Código sob AGPL-3.0-or-later. Preserve [NOTICE](NOTICE), [licenças](LICENSING.md)
e [procedência dos catálogos](data/PROVENANCE.md). Os materiais da Anvisa
seguem os termos descritos em [licenças](LICENSING.md).
