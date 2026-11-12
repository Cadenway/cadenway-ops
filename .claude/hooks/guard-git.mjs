#!/usr/bin/env node
/**
 * PreToolUse hook (cadenway-ops): refuse git, release and publishing commands that an agent must
 * never run on its own. Deny = exit 2 with the reason on stderr; everything else = exit 0.
 *
 * The same file runs for Claude Code (Bash, PowerShell) and, through the Codex adapter, for Codex
 * shell commands. It reads `tool_input.command` and denies:
 *
 *  1. Pushes that reach `main` (explicit refspec, `HEAD` or an implicit push from `main`), `--all`,
 *     `--mirror`, tag pushes (`--tags`, `--follow-tags`, `refs/tags/…`, an existing tag name).
 *  2. Force pushes: `-f`, `--force`, `--force-with-lease`, `--force-if-includes`, `+refspec`.
 *  3. Rewrites of pushed history: `commit --amend` of a commit a remote branch contains, a `rebase`
 *     whose range contains a commit reachable from a remote, `filter-branch`, `filter-repo`.
 *  4. Hook bypasses: `--no-verify` / `commit -n`, `-c core.hooksPath=…`, changing or unsetting
 *     `core.hooksPath`, `ALLOW_MAIN_PUSH=1`, `CW_SKIP_PUSH_CHECKS=1`.
 *  5. Release actions: creating or deleting a tag, `merge` while on `main`, `npm publish`,
 *     `npm unpublish`, `npm deprecate`, `npm dist-tag add|rm`, `npm version <bump>`.
 *  6. Work-tree destruction: `reset --hard`, `clean -f`, `checkout -- .`, `restore .`, deleting
 *     `main`.
 *  7. Branch names: `<type>/<kebab-description>`. Commit headers are checked by native commitlint
 *     in the commit-msg hook and CI.
 *  8. Explicit `gh api` writes to merge, Git refs and release endpoints.
 *
 * GitHub CLI PR merges, release management and repository administration are allowed by this hook
 * and follow the user's authorized task. Allowing a command does not authorize the operation. For
 * commands still denied above, stop on refusal instead of looking for another route.
 *
 * Parsing is a small shell tokenizer: quotes are honoured, heredoc bodies and the arguments of
 * `echo` / `printf` / `Write-Output` are not commands, and only a program in command position counts.
 * When a git query needed for a decision fails, the guard denies only the history-rewriting case
 * (it cannot prove the commits are local); every other unclear case passes.
 *
 * The rules mirror the other Cadenway repositories (same branch model) and the repository's own
 * `.githooks/` (pre-push refuses main, commit-msg runs commitlint). The hook only acts inside a
 * cadenway-ops checkout (marker: a package.json named cadenway-ops), so it is inert when the
 * plugin is installed elsewhere.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Constant TYPES
 *
 * @description
 * Pipe-delimited types accepted as branch prefixes. Native commitlint independently validates
 * commit messages through the repository's commit-msg hook and CI.
 *
 * @type {string}
 */
export const TYPES = 'feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert';
/**
 * Constant BRANCH_OK
 *
 * @description
 * Matches new branch names with an allowed commit type or the `hotfix` prefix and a lowercase
 * kebab-case topic.
 *
 * @type {RegExp}
 */
const BRANCH_OK = new RegExp(`^(?:${TYPES}|hotfix)/[a-z0-9]+(?:-[a-z0-9]+)*$`);
/**
 * Constant BRANCH_EXEMPT
 *
 * @description
 * Matches permanent, automation-owned, and release branches exempt from agent branch naming.
 *
 * @type {RegExp}
 */
const BRANCH_EXEMPT = /^(?:main|claude\/.+|renovate\/.+|release-please--.+|changeset-release\/.+|dependabot\/.+)$/;
/**
 * Constant PROTECTED_BRANCHES
 *
 * @description
 * Names the long-lived branches that command checks will not allow an agent to delete.
 *
 * @type {Set<string>}
 */
const PROTECTED_BRANCHES = new Set(['main']);
/**
 * Constant REPO_NAME
 *
 * @description
 * Identifies the package that activates this repository-specific command guard.
 *
 * @type {string}
 */
const REPO_NAME = 'cadenway-ops';

/**
 * Function parseSegments
 *
 * @description
 * Tokenizes shell text into simple-command argument arrays. Separators inside quotes remain part of
 * their token, and heredoc bodies are skipped so their content is not mistaken for a command.
 *
 * @param {string} command - Full shell command passed to the pre-tool hook.
 *
 * @returns {string[][]} Ordered simple commands, each represented by its unquoted tokens.
 */
export function parseSegments(command) {
  const segments = [];
  const heredocs = [];
  let tokens = [];
  let token = '';
  let hasToken = false;
  let quote = null;
  const pushToken = () => {
    if (hasToken) tokens.push(token);
    token = '';
    hasToken = false;
  };
  const endSegment = () => {
    pushToken();
    if (tokens.length) segments.push(tokens);
    tokens = [];
  };
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) quote = null;
      else if (quote === '"' && ch === '\\' && /["\\$`]/.test(command[i + 1] ?? ''))
        token += command[++i];
      else token += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      hasToken = true;
    } else if (ch === '\n') {
      endSegment();
      i = skipHeredocs(command, i, heredocs);
    } else if (ch === '<' && command[i + 1] === '<' && command[i + 2] !== '<') {
      pushToken();
      i += 2;
      const strip = command[i] === '-';
      if (strip) i++;
      while (command[i] === ' ' || command[i] === '\t') i++;
      let delimiter = '';
      const q = command[i];
      if (q === "'" || q === '"') {
        for (i++; i < command.length && command[i] !== q; i++) delimiter += command[i];
      } else {
        for (; i < command.length && !/[\s;&|()]/.test(command[i]); i++) delimiter += command[i];
        i--;
      }
      heredocs.push({ delimiter, strip });
    } else if (';&|()'.includes(ch)) {
      endSegment();
    } else if (/\s/.test(ch)) {
      pushToken();
    } else {
      token += ch;
      hasToken = true;
    }
  }
  endSegment();
  return segments;
}

/**
 * Function skipHeredocs
 *
 * @description
 * Advances past every heredoc body opened on the command line just processed. Each body ends at its
 * delimiter line, with leading tabs ignored only for `<<-` heredocs.
 *
 * @param {string} command - Tokenized command text containing heredoc bodies.
 * @param {number} newline - Index of the newline that ends the command line.
 * @param {{ delimiter: string, strip: boolean }[]} heredocs - Delimiters queued from that line.
 *
 * @returns {number} Index at the end of the last heredoc body, or command length when unterminated.
 */
function skipHeredocs(command, newline, heredocs) {
  let end = newline;
  while (heredocs.length) {
    const { delimiter, strip } = heredocs.shift();
    let start = end + 1;
    for (;;) {
      if (start >= command.length) return command.length;
      let lineEnd = command.indexOf('\n', start);
      if (lineEnd === -1) lineEnd = command.length;
      let line = command.slice(start, lineEnd).replace(/\r$/, '');
      if (strip) line = line.replace(/^\t+/, '');
      end = lineEnd;
      if (line === delimiter) break;
      start = lineEnd + 1;
    }
  }
  return end;
}

/**
 * Function splitCommand
 *
 * @description
 * Separates leading POSIX/PowerShell environment assignments and wrapper executables from the
 * actual program and argument vector used by policy evaluation.
 *
 * @param {string[]} tokens - Tokens for a single simple command.
 *
 * @returns {{ env: Record<string, string>, program: string, argv: string[] }} Parsed assignments,
 * normalized executable name, and remaining arguments.
 */
export function splitCommand(tokens) {
  const env = {};
  let i = 0;
  for (; i < tokens.length; i++) {
    const t = tokens[i];
    const posix = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s.exec(t);
    if (posix) {
      env[posix[1]] = posix[2];
      continue;
    }
    const ps = /^\$env:([A-Za-z_][A-Za-z0-9_]*)(?:=(.*))?$/is.exec(t);
    if (ps) {
      if (ps[2] !== undefined) env[ps[1]] = ps[2];
      else if (tokens[i + 1] === '=') {
        env[ps[1]] = tokens[i + 2] ?? '';
        i += 2;
      }
      continue;
    }
    if (['sudo', 'env', 'command', 'exec', 'nohup', 'time', 'export', '&'].includes(t)) continue;
    break;
  }
  const argv = tokens.slice(i);
  const program = (argv[0] ?? '')
    .split(/[\\/]/)
    .pop()
    .toLowerCase()
    .replace(/\.(exe|cmd|bat)$/, '');
  return { env, program, argv };
}

/**
 * Function realGit
 *
 * @description
 * Binds Git queries to the requested working directory. Decision helpers receive this function as
 * a dependency so tests can substitute deterministic responses.
 *
 * @param {string} cwd - Repository directory in which each Git command runs.
 *
 * @returns {Function} A query function returning `{ ok, out }` for the supplied arguments.
 */
export function realGit(cwd) {
  return (args) => {
    const result = spawnSync('git', args, { cwd, encoding: 'utf8', windowsHide: true });
    return { ok: result.status === 0, out: (result.stdout ?? '').trim() };
  };
}

/**
 * Function currentBranch
 *
 * @description
 * Reads the checked-out branch name and maps an unsuccessful Git query to `null`.
 *
 * @param {Function} git - Injected Git query function.
 *
 * @returns {string | null} Current branch name when the query succeeds; otherwise null.
 */
function currentBranch(git) {
  const r = git(['rev-parse', '--abbrev-ref', 'HEAD']);
  return r.ok ? r.out : null;
}

/**
 * Function isTag
 *
 * @description
 * Checks whether the supplied name resolves to a local Git tag reference.
 *
 * @param {Function} git - Injected Git query function.
 * @param {string} name - Candidate tag name to resolve.
 *
 * @returns {boolean} True when Git confirms that the tag exists.
 */
function isTag(git, name) {
  return git(['show-ref', '--verify', '--quiet', `refs/tags/${name}`]).ok;
}

/**
 * Function deny
 *
 * @description
 * Creates the structured refusal returned by an individual command-policy check.
 *
 * @param {string} what - Action or target that triggered the refusal.
 * @param {string} why - Explanation reported with the refusal.
 *
 * @returns {{ what: string, why: string }} Denial data consumed by the hook entry point.
 */
const deny = (what, why) => ({ what, why });

/**
 * Function stripHeads
 *
 * @description
 * Removes the local-head namespace prefix so ref comparisons use a branch's visible name.
 *
 * @param {string} ref - Git ref that may start with `refs/heads/`.
 *
 * @returns {string} Ref with the local-head namespace removed when present.
 */
const stripHeads = (ref) => ref.replace(/^refs\/heads\//, '');

/**
 * Function hasShort
 *
 * @description
 * Detects a single-letter option inside a short-flag cluster such as `-uf`.
 *
 * @param {string} arg - Argument token to inspect.
 * @param {string} letter - Short option letter whose presence is being tested.
 *
 * @returns {boolean} True when `arg` is a short-option cluster containing `letter`.
 */
const hasShort = (arg, letter) => /^-[A-Za-z]+$/.test(arg) && arg.slice(1).includes(letter);

/**
 * Function checkPush
 *
 * @description
 * Evaluates push options and refspecs for force updates, hook bypasses, bulk/tag pushes, writes to
 * `main`, and release tags. It consults the current branch and local tag references only when a
 * push's target cannot be resolved from its arguments.
 *
 * @param {string[]} args - Arguments following the `git push` subcommand.
 * @param {Function} git - Injected Git query function used for branch and tag resolution.
 *
 * @returns {{ what: string, why: string } | null} First refusal found, or null when the push is allowed.
 */
function checkPush(args, git) {
  const valueOptions = new Set(['-o', '--push-option', '--repo', '--receive-pack', '--exec']);
  const positional = [];
  let dryRun = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (valueOptions.has(a)) {
      i++;
      continue;
    }
    if (a === '--dry-run' || hasShort(a, 'n')) dryRun = true;
    if (/^--force(?:-with-lease|-if-includes)?(?:=.*)?$/.test(a) || hasShort(a, 'f')) {
      return deny(
        'force push',
        'Force pushes rewrite published history. Push new commits instead, or ask the user.',
      );
    }
    if (a === '--no-verify') {
      return deny('git push --no-verify', 'The pre-push hook guards main; do not bypass it.');
    }
    if (['--all', '--mirror', '--tags', '--follow-tags'].includes(a)) {
      return deny(
        `git push ${a}`,
        'It pushes tags or every branch, main included. Push your work branch by name.',
      );
    }
    if (!a.startsWith('-')) positional.push(a);
  }
  if (dryRun) return null;
  const refspecs = positional.slice(1);
  if (refspecs.length === 0) {
    if (currentBranch(git) === 'main') {
      return deny('git push from main', 'Only merged pull requests reach main (AGENTS.md, Git and branch flow).');
    }
    return null;
  }
  for (const spec of refspecs) {
    if (spec.startsWith('+')) {
      return deny(`force refspec ${spec}`, 'A "+" refspec is a force push.');
    }
    const [src, dst] = spec.includes(':') ? spec.split(':') : [spec, spec];
    const target = stripHeads(dst === 'HEAD' || dst === '@' ? (currentBranch(git) ?? dst) : dst);
    if (target === 'main') {
      return deny(
        `push to main (${spec})`,
        'main only receives squash-merged pull requests (AGENTS.md, Git and branch flow).',
      );
    }
    const names = [src, dst].filter(Boolean);
    if (
      names.some((n) => n.startsWith('refs/tags/') || /^v\d+(?:\.\d+)*(?:[-+].*)?$/.test(n)) ||
      (src && !src.startsWith('refs/') && src !== 'HEAD' && isTag(git, src))
    ) {
      return deny(
        `tag push (${spec})`,
        'Tags mark releases; the release workflow creates them after the release pull request is merged.',
      );
    }
  }
  return null;
}

/**
 * Function checkCommit
 *
 * @description
 * Prevents commit-hook bypasses and amendments to remotely reachable commits. The native
 * commit-msg hook validates the message itself.
 *
 * @param {string[]} args - Arguments following the `git commit` subcommand.
 * @param {Function} git - Injected Git query function for remote reachability checks.
 *
 * @returns {{ what: string, why: string } | null} First refusal found, or null when allowed.
 */
function checkCommit(args, git) {
  if (args.includes('--no-verify') || args.some((a) => hasShort(a, 'n'))) {
    return deny('git commit --no-verify', 'The commit-msg hook runs commitlint; do not bypass it.');
  }
  if (args.includes('--amend')) {
    const r = git(['branch', '-r', '--contains', 'HEAD']);
    if (r.ok && r.out) {
      return deny(
        'git commit --amend of a pushed commit',
        `HEAD is already on ${r.out.split('\n')[0].trim()}. Add a new commit instead.`,
      );
    }
  }
  return null;
}

/**
 * Function checkRebase
 *
 * @description
 * Allows interactive rebase control actions and rebases whose complete target range is local. It
 * refuses when Git cannot verify reachability or when the range includes remotely reachable commits.
 *
 * @param {string[]} args - Arguments following the `git rebase` subcommand.
 * @param {Function} git - Injected Git query function used to compare total and unpublished commits.
 *
 * @returns {{ what: string, why: string } | null} Refusal for unverifiable or published history, otherwise null.
 */
function checkRebase(args, git) {
  const control = new Set([
    '--abort',
    '--continue',
    '--skip',
    '--quit',
    '--edit-todo',
    '--show-current-patch',
  ]);
  if (args.some((a) => control.has(a))) return null;
  const valueOptions = new Set([
    '--onto',
    '-x',
    '--exec',
    '-s',
    '--strategy',
    '-X',
    '--strategy-option',
  ]);
  const positional = [];
  let root = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (valueOptions.has(a)) i++;
    else if (a === '--root') root = true;
    else if (!a.startsWith('-')) positional.push(a);
  }
  const tip = positional[1] ?? 'HEAD';
  const range = root ? [tip] : [`${positional[0] ?? '@{upstream}'}..${tip}`];
  const total = git(['rev-list', '--count', ...range]);
  const local = git(['rev-list', '--count', ...range, '--not', '--remotes']);
  if (!total.ok || !local.ok) {
    return deny(
      'git rebase (range not verifiable)',
      'The guard could not prove that the rebased commits are unpublished. Ask the user.',
    );
  }
  if (total.out !== local.out) {
    return deny(
      'git rebase of pushed commits',
      'The range contains commits a remote branch already has. Merge or add commits instead.',
    );
  }
  return null;
}

/**
 * Function checkBranchName
 *
 * @description
 * Applies the branch naming policy to a new or renamed ref, allowing configured permanent and
 * automation-managed exceptions.
 *
 * @param {string} name - Branch name created or renamed by Git.
 *
 * @returns {{ what: string, why: string } | null} Naming refusal, or null when the name is accepted.
 */
function checkBranchName(name) {
  if (!name || BRANCH_EXEMPT.test(name) || BRANCH_OK.test(name)) return null;
  return deny(
    `branch name "${name}"`,
    `Branches are <type>/<lowercase-kebab-description> with a type among ${TYPES.split('|').join(', ')}, ` +
      'or hotfix/<topic>; no agent-name prefix.',
  );
}

/**
 * Function checkGit
 *
 * @description
 * Dispatches Git subcommands to their policy checks and handles direct safety rules for history
 * rewrites, tags, merges, working-tree resets, branch operations, and hook configuration.
 *
 * @param {string[]} argv - Git executable and command arguments after wrapper parsing.
 * @param {Function} git - Injected Git query function for state-dependent decisions.
 *
 * @returns {{ what: string, why: string } | null} First applicable refusal, or null when permitted.
 */
function checkGit(argv, git) {
  let i = 1;
  for (; i < argv.length && argv[i].startsWith('-'); i++) {
    const a = argv[i];
    const config = a === '-c' ? argv[++i] : a.startsWith('-c') ? a.slice(2) : null;
    if (a === '-C' || a === '--git-dir' || a === '--work-tree') i++;
    if (config && /^core\.hookspath\s*=/i.test(config)) {
      return deny('git -c core.hooksPath=…', 'It disables the repository hooks (.githooks).');
    }
  }
  const sub = argv[i];
  const args = argv.slice(i + 1);
  switch (sub) {
    case 'push':
      return checkPush(args, git);
    case 'commit':
      return checkCommit(args, git);
    case 'rebase':
      return checkRebase(args, git);
    case 'filter-branch':
    case 'filter-repo':
      return deny(`git ${sub}`, 'It rewrites history.');
    case 'tag': {
      const listing = args.length === 0 || args.some((a) => ['-l', '--list'].includes(a));
      if (listing && !args.some((a) => ['-d', '--delete'].includes(a))) return null;
      return deny('git tag', 'Creating or deleting tags is a release step done by the maintainer.');
    }
    case 'merge':
      if (args.includes('--abort') || args.includes('--continue')) return null;
      if (currentBranch(git) === 'main') {
        return deny('git merge on main', 'main only receives merged pull requests.');
      }
      return null;
    case 'reset':
      return args.includes('--hard')
        ? deny('git reset --hard', 'It discards uncommitted work with no recovery path.')
        : null;
    case 'clean':
      return args.some((a) => a === '--force' || hasShort(a, 'f'))
        ? deny('git clean -f', 'It deletes untracked files permanently.')
        : null;
    case 'checkout':
    case 'restore': {
      const paths = args.includes('--') ? args.slice(args.indexOf('--') + 1) : args;
      const stagedOnly =
        sub === 'restore' &&
        args.some((a) => a === '--staged' || a === '-S') &&
        !args.some((a) => a === '--worktree' || a === '-W');
      if (!stagedOnly && (paths.includes('.') || paths.includes(':/'))) {
        return deny(`git ${sub} .`, 'It reverts every uncommitted change at once.');
      }
      if (sub === 'checkout') {
        const at = args.findIndex((a) => a === '-b' || a === '-B');
        if (at !== -1) return checkBranchName(args[at + 1]);
      }
      return null;
    }
    case 'switch': {
      const at = args.findIndex((a) => ['-c', '-C', '--create', '--force-create'].includes(a));
      return at === -1 ? null : checkBranchName(args[at + 1]);
    }
    case 'branch': {
      const del = args.some(
        (a) => ['-d', '-D', '--delete'].includes(a) || /^-[a-zA-Z]*[dD]$/.test(a),
      );
      const names = args.filter((a) => !a.startsWith('-'));
      if (del) {
        const hit = names.find((n) => PROTECTED_BRANCHES.has(n.replace(/^origin\//, '')));
        return hit
          ? deny(`delete branch ${hit}`, 'main is the long-lived branch.')
          : null;
      }
      if (args.some((a) => ['-m', '-M', '--move'].includes(a)))
        return checkBranchName(names.at(-1));
      if (args.some((a) => a.startsWith('-'))) return null;
      return checkBranchName(names[0]);
    }
    case 'worktree': {
      if (args[0] !== 'add') return null;
      const at = args.findIndex((a) => a === '-b' || a === '-B');
      return at === -1 ? null : checkBranchName(args[at + 1]);
    }
    case 'config': {
      const key = args.find((a) => /^core\.hookspath$/i.test(a));
      if (!key) return null;
      const value = args[args.indexOf(key) + 1];
      if (
        args.includes('--unset') ||
        args.includes('--unset-all') ||
        (value && value !== '.githooks')
      ) {
        return deny(
          'git config core.hooksPath',
          'The repository hooks live in .githooks; keep them.',
        );
      }
      return null;
    }
    default:
      return null;
  }
}

/**
 * Function checkPackageManager
 *
 * @description
 * Rejects package-registry publication, registry-tag mutation, and version-bump commands that
 * perform release actions from an agent shell.
 *
 * @param {string} program - Normalized package-manager executable name.
 * @param {string[]} argv - Full argument vector for the package-manager command.
 *
 * @returns {{ what: string, why: string } | null} Release refusal, or null for other commands.
 */
function checkPackageManager(program, argv) {
  const sub = argv[1];
  if (sub === 'publish' && argv.includes('--dry-run')) return null;
  if (['publish', 'unpublish', 'deprecate'].includes(sub)) {
    return deny(
      `${program} ${sub}`,
      'cadenway-ops is never published to a registry: it ships as a Docker image built by CI.',
    );
  }
  if (sub === 'dist-tag' && ['add', 'rm'].includes(argv[2])) {
    return deny(`${program} dist-tag ${argv[2]}`, 'Registry tags are a release action.');
  }
  if (program === 'npm' && sub === 'version' && argv.slice(2).some((a) => !a.startsWith('-'))) {
    return deny(
      'npm version <bump>',
      'It bumps and tags. Versions come from release-please and its release pull request.',
    );
  }
  return null;
}

/**
 * Function checkGh
 *
 * @description
 * Detects explicit GitHub CLI API writes to merge, Git ref, or release endpoints while leaving
 * ordinary read operations to the user's authorization boundary.
 *
 * @param {string[]} argv - Full argument vector for the `gh` command.
 *
 * @returns {{ what: string, why: string } | null} API-write refusal, or null for other commands.
 */
function checkGh(argv) {
  const [, group] = argv;
  if (group === 'api') {
    const text = argv.join(' ');
    if (
      /\/merge\b|\/git\/refs|\/releases\b/.test(text) &&
      /(-X|--method)[ =]?(PUT|POST|PATCH|DELETE)/i.test(text)
    ) {
      return deny(
        'gh api write to merges, refs or releases',
        'Same limits as git push, tags and merges.',
      );
    }
  }
  return null;
}

/**
 * Function evaluateCommand
 *
 * @description
 * Splits a shell command into simple commands, ignores output-only commands, and dispatches Git,
 * package-manager, and GitHub CLI operations to their safety checks. Environment overrides that
 * bypass repository push checks are denied before command dispatch.
 *
 * @param {string} command - Complete shell command text to evaluate.
 * @param {{ git: Function }} dependencies - Git query dependency used by stateful command rules.
 *
 * @returns {{ what: string, why: string } | null} First refusal in command order, or null when allowed.
 */
export function evaluateCommand(command, { git }) {
  if (typeof command !== 'string' || !command.trim()) return null;
  for (const tokens of parseSegments(command)) {
    const { env, program, argv } = splitCommand(tokens);
    if (env.ALLOW_MAIN_PUSH !== undefined) {
      return deny(
        'ALLOW_MAIN_PUSH',
        'This override of the pre-push hook is for a human repairing main.',
      );
    }
    if (env.CW_SKIP_PUSH_CHECKS !== undefined) {
      return deny(
        'CW_SKIP_PUSH_CHECKS',
        'The pre-push format and lint checks complement pull-request CI: fix what they report.',
      );
    }
    if (['echo', 'printf', 'write-output', 'write-host'].includes(program)) continue;
    let denial = null;
    if (program === 'git') denial = checkGit(argv, git);
    else if (['npm', 'pnpm', 'yarn'].includes(program)) denial = checkPackageManager(program, argv);
    else if (program === 'gh') denial = checkGh(argv);
    if (denial) return denial;
  }
  return null;
}

/**
 * Function isRepoRoot
 *
 * @description
 * Checks whether a directory contains a readable package manifest whose package name identifies
 * the cadenway-ops checkout.
 *
 * @param {string} dir - Directory that may be the repository root.
 *
 * @returns {boolean} True when the manifest exists and names this repository.
 */
function isRepoRoot(dir) {
  const manifest = path.join(dir, '.claude', '.claude-plugin', 'plugin.json');
  if (!existsSync(manifest)) return false;
  try {
    return JSON.parse(readFileSync(manifest, 'utf8'))?.name === REPO_NAME;
  } catch {
    return false;
  }
}

/**
 * Function findRepoRoot
 *
 * @description
 * Walks from the supplied path toward the filesystem root and returns the nearest ancestor whose
 * package manifest identifies this repository.
 *
 * @param {string} start - File or directory from which the ancestor search begins.
 *
 * @returns {string | null} Matching checkout root, or null when no ancestor is the Web repository.
 */
export function findRepoRoot(start) {
  let dir = path.resolve(start);
  for (;;) {
    if (isRepoRoot(dir)) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/**
 * Function main
 *
 * @description
 * Reads the pre-tool payload, locates the active Web checkout, evaluates the requested shell
 * command, and writes a denial reason when a repository rule blocks it.
 *
 * @returns {number} Exit status 2 for a denied command and 0 when the hook has nothing to block.
 */
function main() {
  let payload;
  try {
    payload = JSON.parse(readFileSync(0, 'utf8') || '{}');
  } catch {
    return 0;
  }
  const command = payload?.tool_input?.command ?? payload?.tool_input?.cmd;
  const cwd = payload?.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  if (typeof command !== 'string' || !findRepoRoot(cwd)) return 0;
  const denial = evaluateCommand(command, { git: realGit(cwd) });
  if (!denial) return 0;
  process.stderr.write(
    `Blocked: ${denial.what}\n${denial.why}\n` +
      'If the user explicitly asked for this, stop and let them run it themselves (AGENTS.md, hard limits).\n',
  );
  return 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main();
}
