#!/usr/bin/env node
/**
 * Points Git at the repository's own hooks (`.githooks/`): commit-msg runs commitlint, pre-push
 * refuses `main` and runs the format and lint checks.
 *
 * Runs from the `prepare` script after every install. Outside a Git checkout (Docker build,
 * extracted tarball) there is nothing to configure, so the failure is ignored.
 */
import { execFileSync } from 'node:child_process';

try {
  execFileSync('git', ['config', 'core.hooksPath', '.githooks'], { stdio: 'ignore' });
} catch {
  process.exitCode = 0;
}
