"""Build a source release without local deployment files or repository history."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
# Keep the source distribution independent of ignored/untracked workspace files.
MODULE = """
.env.example LICENSING.md sbom.cdx.json data/PROVENANCE.md .gitignore .vercelignore LICENSE NOTICE README.md
LICENSES/CC-BY-4.0.txt LICENSES/LicenseRef-OpenPEP-Brand.txt LICENSES/Apache-2.0.txt
LICENSES/LicenseRef-Anvisa-Reference.txt LICENSES/LicenseRef-Anvisa-Catalogs.txt
package.json package-lock.json vercel.json build.mjs openpep-module.mjs Abrir-OpenPEP-Rx.command
cep.js contato.js compartilhar-documento.js compartilhar-documento.css local-client.js conectar.html conectar.js index.html inicio.css inicio.js app.js domain.js styles.css openpep.css assinatura.html assinatura.js assinatura.css pdf-preview.js
dados-locais.html dados-locais.css dados-locais.js portal-sncr.html portal-sncr.css portal-sncr.js
numeros.html numeros.css numeros.js receita.html receita.css receita.js
sncr.html sncr.css sncr.js verificar.html verificar.css verificar.js acesso.css
transicao.css transicao.js medicamentos.js telefone.mjs
assets/openpep-mark.png assets/fonts/PROVENANCE.json assets/fonts/OFL.txt
assets/fonts/inter-400.ttf assets/fonts/inter-500.ttf assets/fonts/inter-600.ttf assets/fonts/inter-700.ttf
assets/fonts/pdf/README.md assets/fonts/pdf/inter-400-latin.ttf assets/fonts/pdf/inter-500-latin.ttf
assets/fonts/pdf/inter-600-latin.ttf assets/fonts/pdf/inter-700-latin.ttf
fixtures/assinatura-local.pdf fixtures/documento.pdf
scripts/demo.mjs scripts/preview.mjs scripts/empacotar.py scripts/gerar-amostras.mjs
scripts/build-signer.mjs scripts/test-public.mjs scripts/preparar-documentos.mjs scripts/configurar-documentos.mjs scripts/preparar-portal.mjs scripts/gerar-chave-portal.mjs
integracao/openpep/clinical-web.patch integracao/openpep/README.md
qa/receita-local-server.mjs qa/sncr-local-server.mjs
local/VIDaaSSigner.swift local/appearance.mjs local/prepare-pdf.mjs local/native.mjs local/server.mjs
hosted/relay.mjs hosted/exports.mjs hosted/worker.mjs hosted/schema.sql hosted/build-site.mjs hosted/db-schema.ts
local/lots.mjs integracao/sncr-lote.mjs integracao/sncr-portal-keys.json tests/d1-fixture.mjs
documentos/worker.mjs documentos/schema.sql documentos/db-schema.ts documentos/build-site.mjs documentos/index.html documentos/documentos.js documentos/documentos.css hosted/documents.mjs local/publications.mjs local/backup.mjs
local/web-bridge.mjs local/database.mjs local/runtime-lock.mjs local/schema.sql local/prescriptions.mjs local/catalog.mjs local/sncr.mjs
""".split()

# Explicit list: the publication contains only the local signing runtime,
# synthetic prescription demo, and the SNCR adapter and its migrations.
PUBLIC_TESTS = 'client-syntax documento domain ledger medicamentos origin openpep-module rce receita retencao sncr-numbers sncr-producao sncr-current-format sncr termo local-signature local-prescription hosted-relay sncr-transfer documents-publication cep-contatos'.split()
GROUPS = {
    'references/anvisa-modelos': 'notificacao-de-receita-a-eletronica.pdf notificacao-de-receita-b-eletronica.pdf notificacao-de-receita-b2-eletronica.pdf notificacao-de-receita-retinoides-eletronica.pdf notificacao-de-receita-talidomida-eletronica.pdf receita-de-controle-especial-eletronica.pdf',
    'api': 'cep.mjs http-utils.mjs db.mjs documento.mjs entry-oidc.mjs entry-proof.mjs ledger.mjs origin.mjs receita-doc.mjs receita.mjs sncr-callback-edge.mjs sncr-numbers.mjs sncr-probe-edge.mjs sncr-probe.mjs sncr-return.mjs sncr.mjs store.mjs termo-doc.mjs',
    'db/migrations': '0001_cockpit_rx_ledger.sql 0002_cockpit_rx_search_path.sql 0003_cockpit_rx_painel.sql 0004_cockpit_rx_receita.sql 0005_cockpit_rx_acesso.sql 0006_cockpit_rx_codigo_impresso.sql 0007_cockpit_rx_varios_medicamentos.sql 0008_cockpit_rx_producao.sql 0009_cockpit_rx_producao_mes_brasilia.sql 0010_openpep_rx_sncr_producao.sql',
    'data': 'medicamentos-controlados.json medicamentos-especiais.json medicamentos-rce.json medicamentos-retencao.json posologias-especiais.json posologias-rce.json posologias-retencao.json posologias-especiais.md posologias-rce.md posologias-retencao.md termos.json',
    'scripts/medicamentos': 'gerar.mjs gerar-especiais.mjs gerar-rce.mjs gerar-retencao.mjs',
    'tests': ' '.join(t + '.test.js' for t in PUBLIC_TESTS),
}

def copy_files(source, dest, names):
    for name in names:
        target = dest / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
        if name.endswith('.command'):
            target.chmod(0o755)

def add_reader(source, dest):
    # The clinical-web worktree can contain unpublished reader code. Include
    # those specific sources; copy schema/fixture files only from Git's index.
    files = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z', '--',
                                     'packages/protocol-schema', 'fixtures']).decode().split('\0')
    copy_files(source, dest, [f for f in files if f])
    copy_files(source, dest, [
        'LICENSE', 'NOTICE', '.node-version', 'LICENSES/AGPL-3.0-or-later.txt',
        'LICENSES/Apache-2.0.txt', 'LICENSES/CC0-1.0.txt', 'LICENSES/CC-BY-4.0.txt',
        'apps/clinical-web/index.html', 'apps/clinical-web/style.css', 'apps/clinical-web/app.js',
        'apps/clinical-web/README.md', 'apps/clinical-local/package.json',
        'apps/clinical-local/package-lock.json', 'apps/clinical-local/tsconfig.json',
        'apps/clinical-local/src/server.ts', 'apps/clinical-local/src/cli.ts',
        'apps/clinical-local/src/demo.ts', 'apps/clinical-local/src/reader.ts',
        'apps/clinical-local/test/local.test.ts', 'apps/clinical-local/README.md',
    ])
    patch = ROOT / 'integracao/openpep/clinical-web.patch'
    # A source tree may already contain the integration.
    command = ['git', 'apply']
    if subprocess.run(command + ['--reverse', '--check', str(patch)], cwd=dest,
                      capture_output=True).returncode:
        subprocess.run(command + ['--check', str(patch)], cwd=dest, check=True)
        subprocess.run(command + [str(patch)], cwd=dest, check=True)
    # The kit can become a fresh repository. Ignore build products and local credentials
    # at its root, but keep the module's distributable medication catalogs under data/.
    (dest / '.gitignore').write_text('node_modules/\ndist/\n.vercel/\n.env*\n!.env.example\n*.log\n.DS_Store\n', encoding='utf-8')
    shutil.copyfile(ROOT / 'integracao/openpep/README.md', dest / 'README.md')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openpep', type=Path, help='Checkout containing the local clinical web reader')
    args = parser.parse_args()
    name = 'openpep-web-rx' if args.openpep else 'openpep-rx'
    out = ROOT / 'dist'
    out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp) / name
        module = stage / 'apps/openpep-rx' if args.openpep else stage
        copy_files(ROOT, module, MODULE)
        for folder, files in GROUPS.items():
            copy_files(ROOT / folder, module / folder, files.split())
        if args.openpep:
            add_reader(args.openpep.resolve(), stage)
        archive = Path(temp) / (name + '.zip')
        with ZipFile(archive, 'w', ZIP_DEFLATED) as bundle:
            for file in sorted(stage.rglob('*')):
                if file.is_file():
                    bundle.write(file, file.relative_to(temp))
        shutil.copyfile(archive, out / archive.name)
    print(out / archive.name)

if __name__ == '__main__':
    main()
