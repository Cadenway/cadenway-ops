#!/usr/bin/env node
/**
 * PreToolUse hook (cadenway-ops): refuse writes that are never right in this repository.
 * Deny = exit 2 with the reason on stderr; everything else = exit 0.
 *
 * Reads `tool_input.file_path` and the written text (`content`, `new_string`, or the
 * `edits[].new_string` of a MultiEdit) and denies, in this order:
 *
 *  1. Sibling checkouts (`../cadenway-*`): read-only from a cadenway-ops session.
 *  2. Generated trees and build outputs. Edit the source and rebuild.
 *  3. Lockfiles edited by hand (`pnpm-lock.yaml`, `package-lock.json`). Use the package manager.
 *  4. Git internals (`.git/`).
 *  5. Secrets: `.env*` files other than `.env.example`, token-shaped text, private keys, an
 *     `_authToken` other than the `${NODE_AUTH_TOKEN}` placeholder.
 *  6. Repository-specific rules (see REPO_RULES).
 *
 * Deliberately conservative: ordinary sources, specs, docs and configuration stay writable. The hook
 * only acts inside a cadenway-ops checkout (marker: `.claude/.claude-plugin/plugin.json` named
 * cadenway-ops), so it is inert elsewhere.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_NAME = 'cadenway-ops';

const GENERATED = [
  [/^(?:.*\/)?node_modules\//, 'an installed dependency'],
  [/^(?:.*\/)?dist\//, 'a build output'],
  [/^(?:.*\/)?coverage\//, 'a coverage report'],
  [/^(?:.*\/)?\.angular\//, 'the Angular build cache'],
  [/^(?:.*\/)?test-results(?:-[^/]*)?\//, 'a test run artifact'],
  [/^(?:.*\/)?playwright-report\//, 'a Playwright report'],
  [/^(?:.*\/)?storybook-static\//, 'a Storybook build'],
  [/^(?:.*\/)?\.turbo\//, 'a build cache'],
  [/(^|\/)\.terraform\//, 'the Terraform plugin cache'],
  [/\.tfstate(\.|$)/, 'a Terraform state file'],
];

const TOKEN_PATTERNS = [
  new RegExp(['gh', '[pousr]_', '[A-Za-z0-9]{36,}'].join('')),
  new RegExp(['github', '_pat_', '[A-Za-z0-9_]{22,}'].join('')),
  new RegExp(['npm', '_', '[A-Za-z0-9]{36}'].join('')),
  new RegExp(['-----BEGIN ', '[A-Z ]*', 'PRIVATE KEY-----'].join('')),
  new RegExp(['AGE-SECRET-KEY-', '1[0-9A-Z]{20,}'].join('')),
];

/** Repository-specific rules: [test(rel, body) => boolean, message]. */
const REPO_RULES = [
  [(rel) => /^environments\/.+\.env$/.test(rel) && !/\.sops\.env$/.test(rel) && !/versions\.env$/.test(rel), 'decrypted environment files never live in the repository; edit secrets with sops on environments/<env>/secrets.sops.env.'],
  [(rel, body) => /\.sops\.(env|ya?ml|json)$/.test(rel) && !/sops_|"sops"|sops:/.test(body), 'a .sops file must be written encrypted by the sops CLI, never as plaintext.'],
  [(rel) => /(^|\/)(age|.*\.agekey|.*\.key|id_(rsa|ed25519))$/.test(rel), 'private keys never live in the repository.'],
  [(rel, body) => /^\.github\/workflows\/.+\.ya?ml$/.test(rel) && /uses:\s*(?!\.\/|docker:\/\/)[^@\s]+@(?![0-9a-f]{40}\b)/.test(body), 'pin third-party actions to a full commit SHA, with the version in a comment.'],
  [(rel, body) => /^\.github\/workflows\/.+\.ya?ml$/.test(rel) && /pull_request_target/.test(body), 'pull_request_target runs with secrets on untrusted code; use pull_request, or ask the user.'],
];

const deny = (message) => ({ message });

function isRepoRoot(dir) {
  const marker = path.join(dir, '.claude', '.claude-plugin', 'plugin.json');
  if (!existsSync(marker)) return false;
  try {
    return JSON.parse(readFileSync(marker, 'utf8'))?.name === REPO_NAME;
  } catch {
    return false;
  }
}

/** Walks upward from a path and returns the nearest cadenway-ops checkout root, or null. */
export function findRepoRoot(start) {
  let dir = path.resolve(start);
  for (;;) {
    if (isRepoRoot(dir)) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/** Extracts the text a tool intends to write (Write, Edit or MultiEdit payloads). */
export function writtenText(input) {
  if (!input) return '';
  if (Array.isArray(input.edits)) return input.edits.map((e) => e?.new_string ?? '').join('\n');
  return String(input.content ?? input.new_string ?? '');
}

/** Refuses writes into a sibling Cadenway checkout. */
export function evaluateSibling(root, absolute) {
  const relative = path.relative(path.dirname(root), path.resolve(absolute));
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) return null;
  const [folder] = relative.split(/[\\/]/);
  if (folder === path.basename(root)) return null;
  if (!/^cadenway-[a-z0-9-]+$/i.test(folder)) return null;
  return deny(
    `${relative.replace(/\\/g, '/')} belongs to the sibling checkout ${folder}, which is read-only from a ` +
      'cadenway-ops session. Write the need down for its owner (its cw-* agents) and change it in its own session and pull request.',
  );
}

/** Applies the write policy to a repository-relative path and the proposed text. */
export function evaluateWrite(relative, text) {
  const rel = relative.replace(/\\/g, '/').replace(/^\.\//, '');
  const base = rel.split('/').pop() ?? '';
  const body = String(text ?? '');

  for (const [pattern, what] of GENERATED) {
    if (pattern.test(rel)) return deny(`${rel} is ${what}. Edit the source and regenerate it instead.`);
  }
  if (base === 'pnpm-lock.yaml' || base === 'package-lock.json') {
    return deny(`${rel} is a lockfile. Change dependencies with pnpm, never by hand.`);
  }
  if (rel === '.git' || /^(?:.*\/)?\.git\//.test(rel)) {
    return deny(`${rel} is inside .git/. Git internals and hooks are not edited by agents.`);
  }
  if (/(^|\/)\.env(\.|$)/.test(rel) && base !== '.env.example') {
    return deny(`${rel} looks like a secret environment file. Do not write secrets; document the variable in .env.example.`);
  }
  if (TOKEN_PATTERNS.some((p) => p.test(body))) {
    return deny(`${rel}: the text contains what looks like a token or a private key. Never write secrets.`);
  }
  if (/_authToken\s*=\s*(?!\$\{[A-Z_]+\})\S/.test(body)) {
    return deny(`${rel}: an _authToken must stay the \${NODE_AUTH_TOKEN} placeholder.`);
  }
  for (const [test, message] of REPO_RULES) {
    if (test(rel, body)) return deny(`${rel}: ${message}`);
  }
  return null;
}

function main() {
  let payload;
  try {
    payload = JSON.parse(readFileSync(0, 'utf8') || '{}');
  } catch {
    return 0;
  }
  const input = payload?.tool_input;
  const file = input?.file_path ?? input?.filePath;
  if (!file) return 0;
  const cwd = payload?.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const absolute = path.resolve(cwd, file);
  const session = findRepoRoot(cwd);
  if (session) {
    const sibling = evaluateSibling(session, absolute);
    if (sibling) {
      process.stderr.write(`Blocked: ${sibling.message}\n`);
      return 2;
    }
  }
  const root = findRepoRoot(path.dirname(absolute));
  if (!root) return 0;
  const relative = path.relative(root, absolute);
  if (relative.startsWith('..') || path.isAbsolute(relative)) return 0;
  const denial = evaluateWrite(relative, writtenText(input));
  if (!denial) return 0;
  process.stderr.write(`Blocked: ${denial.message}\n`);
  return 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main();
}
