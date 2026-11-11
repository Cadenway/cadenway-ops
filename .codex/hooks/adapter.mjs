import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
let event;
try { event = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
const input = event.tool_input || {};
const tool = event.tool_name;
if (tool === 'Bash') {
  const result = spawnSync(process.execPath, [path.join(root, '.claude/hooks/guard-git.mjs')], {
    input: JSON.stringify({ ...event, cwd: root }), encoding: 'utf8', cwd: root,
  });
  if (result.stderr) process.stderr.write(result.stderr);
  process.exit(result.status ?? 1);
}
if (tool !== 'apply_patch' || typeof input.command !== 'string') process.exit(0);
const patch = input.command;
const files = [];
let current = null;
for (const line of patch.split(/\r?\n/)) {
  const match = /^\*\*\* (Add File|Update File|Delete File|Move to): (.+)$/.exec(line);
  if (match) {
    current = { file: match[2], body: '', deleted: match[1] === 'Delete File' };
    files.push(current);
  } else if (current && line.startsWith('+') && !line.startsWith('+++')) {
    current.body += line.slice(1) + '\n';
  }
}
if (!files.length) {
  process.stderr.write('Blocked: unable to identify files in the patch.\n');
  process.exit(2);
}
const guard = await import(pathToFileURL(path.join(root, '.claude/hooks/guard.mjs')).href);
if (event.hook_event_name === 'PreToolUse') {
  for (const f of files) {
    const absolute = path.resolve(event.cwd || root, f.file);
    const sibling = guard.evaluateSibling(root, absolute);
    const rel = path.relative(root, absolute);
    if (sibling) { process.stderr.write('Blocked: ' + sibling.message + '\n'); process.exit(2); }
    if (rel.startsWith('..') || path.isAbsolute(rel)) {
      process.stderr.write('Blocked: patch target is outside the repository.\n'); process.exit(2);
    }
    const denial = guard.evaluateWrite(rel, f.body);
    if (denial) { process.stderr.write('Blocked: ' + denial.message + '\n'); process.exit(2); }
  }
} else if (event.hook_event_name === 'PostToolUse') {
  for (const f of files.filter(f => !f.deleted)) {
    const absolute = path.resolve(event.cwd || root, f.file);
    const rel = path.relative(root, absolute);
    if (rel.startsWith('..') || path.isAbsolute(rel)) continue;
    const result = spawnSync(process.execPath, [path.join(root, '.claude/hooks/format.mjs')], {
      input: JSON.stringify({ cwd: root, tool_input: { file_path: absolute } }), encoding: 'utf8', cwd: root,
    });
    if (result.stderr) process.stderr.write(result.stderr);
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
}
