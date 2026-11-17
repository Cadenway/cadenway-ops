import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export const repositoryName = 'cadenway-ops';

export function hasRepoMarker(dir, name = repositoryName) {
  const marker = path.join(dir, '.claude', '.claude-plugin', 'plugin.json');
  if (!existsSync(marker)) return false;
  try {
    return JSON.parse(readFileSync(marker, 'utf8'))?.name === name;
  } catch {
    return false;
  }
}

export function findCheckoutRoot(start, matches = hasRepoMarker) {
  let dir = path.resolve(start);
  for (;;) {
    if (matches(dir)) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

export function readHookPayload() {
  try {
    return JSON.parse(readFileSync(0, 'utf8') || '{}');
  } catch {
    return undefined;
  }
}
