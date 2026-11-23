<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Licenças e dependências do OpenPEP-Rx

O `package-lock.json` fixa a árvore npm; instale com `npm ci`. Node.js 24 fornece
HTTP, criptografia e SQLite. O assinador usa Foundation, Security e CryptoKit do
macOS, sem biblioteca de assinatura em nuvem no servidor.

| Dependência direta | Versão | Licença declarada | Uso e motivo |
| --- | --- | --- | --- |
| pdf-lib | 1.17.1 | MIT | Compor PDFs e preparar o espaço de assinatura; Node não tem editor PDF |
| @pdf-lib/fontkit | 1.1.1 | MIT | Incorporar fontes nos modelos PDF |
| pdfjs-dist | 6.5.438 | Apache-2.0 | Renderizar todas as páginas da prévia no navegador |
| intl-tel-input | 29.5.3 | MIT | Formatação e validação de contatos internacionais |
| qrcode | 1.5.4 | MIT | Gerar o QR dentro dos bytes revisados |
| openid-client | 6.8.8 | MIT | Protocolo OIDC do adaptador institucional anterior |
| postgres | 3.4.9 | Unlicense | Adaptador PostgreSQL anterior; não é usado pelo SQLite local |
| @electric-sql/pglite | 0.5.8 | Apache-2.0 | Testar migrações e transações PostgreSQL sem servidor externo |
| esbuild | 0.28.2 | MIT | Gerar os bundles de navegador e Workers |

Os geradores dos portais fixam `drizzle-kit` 0.31.10 e `drizzle-orm` 0.45.2
(Apache-2.0), além de esbuild; o leitor de documentos inclui a mesma versão de
PDF.js. Cada portal deve versionar seu próprio lockfile e migrações. Instalar
ou construir o módulo não provisiona hospedagem nem cria contas externas.

Inter usa SIL OFL-1.1, com fontes e hashes em `assets/fonts/PROVENANCE.json`.
Os catálogos e modelos de referência têm termos separados; consulte `NOTICE`
e os arquivos `LICENSES/LicenseRef-Anvisa-*.txt`. A lista acima é um inventário para
revisão, não uma aprovação automática de todas as licenças transitivas.

Para gerar o inventário completo a partir da instalação limpa:

```sh
npm ci
npm sbom --sbom-format cyclonedx > sbom.cdx.json
npm audit
```

Guarde o SBOM como artefato da revisão/release. `npm audit` consulta o registro
npm com a lista de dependências; não deve receber arquivos de configuração ou
dados clínicos. Ele não substitui análise do código, privacidade ou licenças.

## Fontes das referências Anvisa


- [Manual da API publicado pela Anvisa](https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/controlados/sncr/documentos-do-sncr/sncr_manual_api_v5.pdf/@@download/file). Nome `v5`, texto interno 3ª edição.
- [Ocorrências e atualizações do SNCR](https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/controlados/sncr/situacao-do-sncr-ocorrencias-e-orientacoes).
- [Disponibilização da API de produção](https://www.gov.br/anvisa/pt-br/assuntos/noticias-anvisa/2026/anvisa-disponibiliza-api-do-sncr-para-integracao-de-sistemas-de-prescricao-eletronica).

Catálogos e modelos são redistribuídos conforme `LICENSES/LicenseRef-Anvisa-Catalogs.txt` e `LICENSES/LicenseRef-Anvisa-Reference.txt`. A licença do código não concede direitos sobre esses materiais.
