// SPDX-License-Identifier: AGPL-3.0-or-later
import {spawnSync} from 'node:child_process';
const suites = 'client-syntax documento domain ledger medicamentos origin openpep-module rce receita retencao sncr-numbers sncr-producao sncr-current-format sncr termo local-signature local-prescription hosted-relay sncr-transfer documents-publication cep-contatos'.split(' ');
const result = spawnSync(process.execPath, ['--test', ...suites.map(name => `tests/${name}.test.js`)], {stdio: 'inherit'});
process.exit(result.status ?? 1);
