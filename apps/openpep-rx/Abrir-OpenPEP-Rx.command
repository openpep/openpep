#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Starts the existing foreground helper; no background installation or auto-pairing.
cd -- "${0:A:h}" || exit 1

fail() {
  print -r -- "$1"
  read -r "?Pressione Enter para fechar. "
  exit 1
}

command -v node >/dev/null 2>&1 || fail 'Instale Node.js 24.20 ou posterior da série 24 antes de abrir o OpenPEP-Rx.'
command -v npm >/dev/null 2>&1 || fail 'npm não encontrado. Confira a instalação do Node.js.'
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major === 24 && minor >= 20 ? 0 : 1)' || fail 'Use Node.js 24.20 ou posterior da série 24.'
[[ -d node_modules/pdf-lib && -d node_modules/esbuild ]] || fail 'Na pasta do OpenPEP-Rx, execute npm ci uma vez. Depois abra este arquivo novamente.'

if [[ ! -x local/bin/vidaas-signer || local/VIDaaSSigner.swift -nt local/bin/vidaas-signer ]]; then
  print 'Preparando o assinador VIDaaS do OpenPEP-Rx…'
  npm run build:signer || fail 'Não foi possível compilar o assinador. Confira a instalação do Xcode Command Line Tools.'
fi

print 'Quando o auxiliar iniciar, abra uma vez o endereço de abertura exibido abaixo no navegador que vai usar.'
print 'Depois abra https://rx.openpep.com.br e conecte este computador quando solicitado.'
print 'Mantenha esta janela aberta. Para encerrar o auxiliar, pressione Control+C.'
print 'Se ele já estiver aberto em outra janela, use a instância existente.'
npm run local
result=$?
(( result == 0 || result == 130 )) || fail 'O auxiliar não iniciou ou foi interrompido. Confira a mensagem acima; não abra duas instâncias para o mesmo banco.'
exit "$result"
