#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

mode="${1:-phase0}"
failures=0
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "$script_dir/.." && pwd)"

ok() {
  printf 'ok: %s\n' "$1"
}

missing() {
  printf 'erro: %s\n' "$1" >&2
  failures=$((failures + 1))
}

warning() {
  printf 'aviso: %s\n' "$1" >&2
}

require_command() {
  local command_name="$1"
  local purpose="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    ok "$command_name disponível para $purpose"
  else
    missing "$command_name ausente; necessário para $purpose"
  fi
}

case "$mode" in
  phase0|mac) ;;
  *)
    printf 'uso: %s [phase0|mac]\n' "$0" >&2
    exit 2
    ;;
esac

if [[ "$(uname -s)" == "Darwin" ]]; then
  macos_version="$(sw_vers -productVersion)"
  macos_major="$(printf '%s' "$macos_version" | cut -d. -f1)"
  if (( macos_major >= 26 )); then
    ok "macOS $macos_version"
  else
    missing "macOS 26 ou mais recente é necessário"
  fi
else
  missing "a fase Apple exige macOS"
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  ok "Apple Silicon arm64"
else
  missing "o MVP exige Apple Silicon arm64"
fi

require_command git "controle de versão"
require_command swift "protocolo e testes Swift"
require_command node "ferramentas TypeScript"
require_command npm "dependências TypeScript"
require_command reuse "verificação de licenças"

if command -v node >/dev/null 2>&1; then
  expected_node="$(tr -d '[:space:]' < "$repository_dir/.node-version")"
  actual_node="$(node --version | sed 's/^v//')"
  if [[ "$actual_node" == "$expected_node" ]]; then
    ok "Node v$actual_node"
  else
    missing "Node v$expected_node é necessário; encontrado v$actual_node"
  fi
fi

if command -v swift >/dev/null 2>&1; then
  expected_swift="$(tr -d '[:space:]' < "$repository_dir/.swift-version")"
  actual_swift="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [[ "$actual_swift" == "$expected_swift" || "$actual_swift" == "$expected_swift".* ]]; then
    ok "Swift $actual_swift"
  else
    missing "Swift $expected_swift.x é necessário; encontrado ${actual_swift:-desconhecido}"
  fi

  swift_cache_dir="${TMPDIR:-/tmp}/openpep-swift-module-cache"
  mkdir -p "$swift_cache_dir"
  if swift -module-cache-path "$swift_cache_dir" -e 'print("ok")' >/dev/null 2>&1; then
    ok "compilação Swift mínima"
  else
    missing "o compilador Swift não consegue usar o SDK selecionado"
  fi
fi

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -n "$developer_dir" && "$developer_dir" != *CommandLineTools* ]]; then
  ok "Xcode completo selecionado em $developer_dir"
elif [[ "$mode" == "mac" ]]; then
  missing "Xcode completo não está instalado ou selecionado"
else
  warning "Xcode completo é necessário para compilar o aplicativo"
fi

if (( failures > 0 )); then
  printf 'ambiente incompleto: %d requisito(s) ausente(s)\n' "$failures" >&2
  exit 1
fi

printf 'ambiente pronto para %s\n' "$mode"
