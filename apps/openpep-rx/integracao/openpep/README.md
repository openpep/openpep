# OpenPEP Web com OpenPEP-Rx

Esta distribuição reúne o leitor clínico local e o módulo OpenPEP-Rx. Em um computador com Node.js 24.20 ou posterior da série 24, execute na pasta que contém este README:

```sh
cd packages/protocol-schema
npm ci
npm run build
cd ../../apps/clinical-local
npm ci
npm run demo
```

Abra a URL exibida pelo leitor e digite o código de acesso mostrado no terminal. O leitor usa dados fictícios no modo demonstração.

Para o receituário integrado com armazenamento local e VIDaaS no macOS:

```sh
npm ci --prefix apps/openpep-rx
npm run build:signer --prefix apps/openpep-rx
npm run local --prefix apps/openpep-rx
```

Configure `OPENPEP_RX_ORIGIN=http://127.0.0.1:4197` no processo do leitor. O menu **OpenPEP-Rx** abrirá a página inicial com acesso a Nova receita, Assinar PDF e Configurações. Sem essa variável, a página inicial também inclui instruções para iniciar o serviço.

No macOS, após instalar as dependências, `apps/openpep-rx/Abrir-OpenPEP-Rx.command` inicia o aplicativo com dois cliques. O VIDaaS Connect continua instalado e autenticado no computador. Os números SNCR vêm de um **portal privado por provedor**: baixe a identificação do estoque local, carregue-a no portal, autentique-se no Gov.br, baixe o lote e importe-o em **Números SNCR**. O portal não precisa conectar-se ao auxiliar local. A reimportação preserva o estoque e as reservas; cada banco novo recebe lotes próprios. O [README do módulo](apps/openpep-rx/README.md) resume os requisitos e os geradores do portal.

Em **Dados locais**, cadastre o emitente e configure o SNCR. Para compartilhar a pasta com o OpenPEP, configure `OPENPEP_DATA_DIR=/caminho/para/dados-openpep` no Rx: ele usará a subpasta `prescricao/` e o banco `openpep-rx.sqlite`. A integração por navegação não transfere dados do paciente automaticamente. Para o primeiro ensaio, use dados fictícios e marque **Ensaio sem consumir numeração SNCR**.

O [README do módulo](apps/openpep-rx/README.md) descreve testes, configuração e assinatura com VIDaaS Connect local. Para executar os testes do leitor, use `npm run check --prefix apps/clinical-local`.

Código dos aplicativos sob AGPL-3.0-or-later. Os schemas do leitor usam Apache-2.0. Fixtures sintéticas do leitor usam CC0-1.0. Consulte os textos em LICENSES, as atribuições em NOTICE e as exceções de marca, fontes e catálogos em [NOTICE do módulo](apps/openpep-rx/NOTICE).
