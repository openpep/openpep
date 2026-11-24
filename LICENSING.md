<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Licenças do OpenPEP

O repositório usa licenças diferentes conforme a função de cada arquivo. O mapa legível por máquina está em [`REUSE.toml`](REUSE.toml). Os textos integrais ficam em `LICENSES/`.

| Conteúdo | Licença |
|---|---|
| Aplicativo em `apps/` e site em `website/` | `AGPL-3.0-or-later` |
| Schemas e ferramentas em `packages/`, `tools/` e `scripts/` | `Apache-2.0` |
| Documentação | `CC-BY-4.0` |
| Fixtures sintéticas | `CC0-1.0` |
| Logotipo | `LicenseRef-OpenPEP-Brand` |

O arquivo `LICENSE` contém a AGPL usada pelo núcleo. Ele não substitui o mapa acima.

## Dados criados pelo usuário

As licenças do repositório não concedem ao projeto direitos sobre prontuários, anexos, agendas, exportações ou backups criados por quem usa o software. Fixtures publicadas pelo projeto são a exceção expressa e usam CC0-1.0.

## Contribuições

Cada contribuição entra sob a licença do diretório de destino. O contribuidor mantém o copyright sobre o que escreveu e certifica a origem pelo DCO 1.1. O projeto não exige CLA.

## Avisos e marca

O [aviso de saúde](DISCLAIMER-SAUDE.md) informa o estado e os limites do software. Ele não acrescenta restrições às licenças.

O nome e o logotipo são tratados separadamente. O arquivo do bem-te-vi não pode ser usado para sugerir certificação, endosso ou vínculo oficial com o OpenPEP.

## Catálogo CID-10 de terceiros

O recurso `apps/macos/OpenPEP/Resources/cid10-br-2008.tsv` é uma exceção ao mapa
padrão de `apps/`: usa `LicenseRef-CID10-DATASUS`, que documenta os titulares e
a oferta oficial para uso em aplicações. O arquivo foi baixado diretamente do
DATASUS e reproduzido pelo conversor versionado. Não é relançado sob AGPL.
Fonte: [ZIP DATASUS V2008](http://www2.datasus.gov.br/cid10/V2008/downloads/CID10CSV.zip),
obtido em 22/11/2026; a [página de distribuição](http://www2.datasus.gov.br/cid10/V2008/download.htm)
oferece uso em aplicações sem esclarecer integralmente a redistribuição da
tradução CBCD/FSP-USP/OMS/OPAS. O recurso contém 14.233 códigos; não é a edição
atual, não inclui códigos posteriores como os de COVID-19 e não é ICD-10-CM.

O conversor `scripts/build-cid10.py` preserva códigos e descrições, fixa os hashes
de entrada e saída e não cria traduções. SHA-256 do ZIP:
`84f23809275575f751255048064bbb244b0de33fd5987ab98df0f98e5f5d2c95`;
do TSV: `a5a8ae4dfd02186e90bebb1387bab5bff9f6209b37c111e8a69a866fa7b924f1`.
O download histórico usou HTTP: os hashes identificam os bytes recebidos, mas
não autenticam o transporte. O catálogo é distribuído sem alteração, com
atribuição aos titulares, como base de dados para uso no aplicativo, conforme a
oferta do DATASUS. Titulares podem pedir a remoção pelos canais do repositório.

## Terminologia e dependências

O catálogo SNOMED CT IPS usa o snapshot inglês de 01/07/2024, distribuído em
16/12/2024, sob CC BY 4.0. Atribuição: International Health Terminology Standards
Development Organisation, 2002–2024, operando como SNOMED International.
O OpenPEP extrai um TSV para consulta local; não fornece tradução oficial.
O aviso original permanece em
`apps/macos/OpenPEP/Resources/snomed-ips-NOTICE.txt` e o conversor em
`scripts/build-snomed-ips.py`. Atribuições LOINC e UCUM estão em [NOTICE](NOTICE).

| Componente | Versão | Licença | Uso |
|---|---|---|---|
| Yams | 6.2.2 | MIT | Leitura YAML no aplicativo; Foundation não possui parser YAML |
| pdf-lib | 1.17.1 | MIT | Modelos PDF e campos de assinatura não oferecidos pelo PDFKit |
| @pdf-lib/fontkit | 1.1.1 | MIT | Fonte Inter nos modelos PDF |
| qrcode | 1.5.4 | MIT | QR de consulta SNCR |
| esbuild | 0.28.2 | MIT | Geração do renderizador offline durante o desenvolvimento |
| Tailwind CSS e CLI | 4.3.5 | MIT | Compilação dos estilos estáticos do site |
| Inter | Subconjuntos incluídos | OFL-1.1 | Tipografia dos documentos e do site |

As resoluções exatas estão em `Package.resolved` e nos arquivos `package-lock.json`.
Os avisos das bibliotecas do renderizador instaladas pelo npm acompanham
`apps/macos/OpenPEP/Resources/CockpitPDF/THIRD-PARTY-NOTICES.txt`. O pacote
`@pdf-lib/fontkit` já é distribuído com código de terceiros embutido, como
`iconv-lite`; os avisos desse código ainda precisam ser levantados; a licença das
fontes acompanha os arquivos. O site preserva seus avisos de fontes, Tailwind
e [mídia](website/ASSETS.md).


## OpenPEP-Rx

O módulo independente conserva seus [avisos](apps/openpep-rx/NOTICE),
[inventário de dependências](apps/openpep-rx/LICENSING.md) e
[SBOM](apps/openpep-rx/sbom.cdx.json). Os catálogos, modelos Anvisa e textos de
posologias têm termos próprios, com pendências de redistribuição registradas
nos arquivos `LicenseRef-Anvisa-*`; a AGPL do código não cobre esses materiais.
