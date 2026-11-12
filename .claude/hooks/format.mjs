#!/usr/bin/env node
/**
 * PostToolUse hook (cadenway-ops): format the file that was just written with the repository's own
 * tools, so no edit fails `pnpm format:check` for whitespace alone.
 *
 *  - Prettier (`node_modules/prettier`) for TypeScript, JavaScript, JSON, YAML, Markdown, HTML, CSS.
 *  - `terraform fmt` for `.tf` / `.tfvars` files when the terraform binary is on PATH.
 *  - Skips generated trees; degrades to a no-op when the formatter is not installed (fresh checkout).
 *  - A real formatting failure is reported (exit 2) so the agent sees it.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

const REPO_NAME = 'cadenway-ops';
const PRETTIER_EXT = new Set(['.ts', '.mts', '.cts', '.js', '.mjs', '.cjs', '.json', '.yml', '.yaml', '.md', '.html', '.css', '.scss']);
const TERRAFORM_EXT = new Set(['.tf', '.tfvars']);
const SKIP = ['/node_modules/', '/dist/', '/coverage/', '/.angular/', '/storybook-static/', '/.terraform/', '/.git/'];

function isRepoRoot(dir) {
  const marker = path.join(dir, '.claude', '.claude-plugin', 'plugin.json');
  if (!existsSync(marker)) return false;
  try {
    return JSON.parse(readFileSync(marker, 'utf8'))?.name === REPO_NAME;
  } catch {
    return false;
  }
}

function findRepoRoot(start) {
  let dir = path.resolve(start);
  for (;;) {
    if (isRepoRoot(dir)) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
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
  const normalized = absolute.replace(/\\/g, '/');
  if (SKIP.some((s) => normalized.includes(s)) || !existsSync(absolute)) return 0;
  const root = findRepoRoot(path.dirname(absolute));
  if (!root) return 0;
  const ext = path.extname(absolute).toLowerCase();

  if (PRETTIER_EXT.has(ext)) {
    const prettier = path.join(root, 'node_modules', 'prettier', 'bin', 'prettier.cjs');
    if (!existsSync(prettier)) return 0;
    const run = spawnSync(process.execPath, [prettier, '--write', '--ignore-unknown', '--log-level', 'warn', absolute], { cwd: root, encoding: 'utf8' });
    if (run.status !== 0) {
      process.stderr.write(`format hook: prettier failed for ${file}: ${(run.stderr || run.stdout || '').trim()}\n`);
      return 2;
    }
    return 0;
  }
  if (TERRAFORM_EXT.has(ext)) {
    const run = spawnSync('terraform', ['fmt', absolute], { cwd: root, encoding: 'utf8', shell: process.platform === 'win32' });
    if (run.error || run.status === null) return 0;
    if (run.status !== 0) {
      process.stderr.write(`format hook: terraform fmt failed for ${file}: ${(run.stderr || '').trim()}\n`);
      return 2;
    }
  }
  return 0;
}

process.exitCode = main();
