// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: Apache-2.0

export interface ProtocolValidationIssue {
  readonly source: string;
  readonly path: string;
  readonly rule: string;
  readonly message: string;
}

export class ProtocolValidationError extends Error {
  override readonly name = "ProtocolValidationError";
  readonly issues: readonly ProtocolValidationIssue[];

  constructor(issues: readonly ProtocolValidationIssue[]) {
    super(
      issues
        .map(
          (issue) =>
            `${issue.source}:${issue.path}: ${issue.message} [${issue.rule}]`,
        )
        .join("\n"),
    );
    this.issues = issues;
  }
}

export function validationError(
  source: string,
  path: string,
  rule: string,
  message: string,
): ProtocolValidationError {
  return new ProtocolValidationError([{ source, path, rule, message }]);
}
