#!/usr/bin/env bun
/**
 * panic — stop rogue subagent sessions, now.
 *
 * The host exposes two things that make this exact rather than a guess:
 *
 *   GET    /api/session/active        a live map of what is running
 *   POST   /api/session/{id}/interrupt  stop a session's current turn
 *   DELETE /api/session/{id}          remove the session entirely
 *
 * Order matters, and it is counter-intuitive: **interrupt first, and only
 * restart the service as a last resort.** A child session that is suspended can
 * be *resumed* by a service restart, so restarting a live rogue agent can bring
 * it back rather than kill it. Interrupt sticks; restart can resurrect.
 *
 * Default targets are running sessions that have a parent — subagents. A root
 * session (yours) is never touched unless you name it with --session.
 *
 *   panic                    interrupt every running subagent, verify, report
 *   panic -n                 dry run: list what would be killed, change nothing
 *   panic -s <session-id>         target one session exactly (may be a root)
 *   panic --remove           if an interrupt does not stick, delete the session
 *   panic --restart          last resort: restart the background service
 *
 * Exit codes: 0 all targets stopped, 1 something survived, 2 usage/call error.
 */

const TIMEOUT_DEFAULT = 20;

interface Options {
  readonly dryRun: boolean;
  readonly sessions: readonly string[];
  readonly timeout: number;
  readonly remove: boolean;
  readonly restart: boolean;
  readonly json: boolean;
}

interface SessionInfo {
  readonly id?: string;
  readonly parentID?: string;
  readonly agent?: string;
  readonly title?: string;
}

const argv = process.argv.slice(2);

function usage(message: string): never {
  process.stderr.write(`panic: ${message}\n\n`);
  process.stderr.write(
    "usage: panic [--dry-run] [--session <id>]... [--timeout <s>] [--remove] [--restart] [--json]\n",
  );
  process.exit(2);
}

function parse(argv: readonly string[]): Options {
  const options = { dryRun: false, sessions: [] as string[], timeout: TIMEOUT_DEFAULT, remove: false, restart: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]!;
    const next = (): string => {
      const value = argv[index + 1];
      if (value === undefined) usage(`${arg} needs a value`);
      index += 1;
      return value;
    };
    if (arg === "-n" || arg === "--dry-run") options.dryRun = true;
    else if (arg === "-s" || arg === "--session") options.sessions.push(next());
    else if (arg === "--timeout") options.timeout = Number(next());
    else if (arg === "--remove") options.remove = true;
    else if (arg === "--restart") options.restart = true;
    else if (arg === "--json") options.json = true;
    else if (arg === "-h" || arg === "--help") usage("stop rogue subagent sessions");
    else usage(`unknown option ${arg}`);
  }
  if (!Number.isFinite(options.timeout) || options.timeout < 0) usage("--timeout must be a number of seconds");
  return options;
}

const options = parse(argv);

// ---------------------------------------------------------------------------
// Talking to the host
// ---------------------------------------------------------------------------

const bin = Bun.which("opencode") ?? "opencode";

/** Returns parsed JSON, or undefined when the call failed. Never throws. */
function api(method: string, path: string, body?: unknown): unknown {
  const args = body === undefined ? [method, path] : ["--data", JSON.stringify(body), method, path];
  try {
    const proc = Bun.spawnSync([bin, "api", ...args], { stdout: "pipe", stderr: "pipe" });
    const text = proc.stdout.toString().trim();
    if (text.length === 0) return undefined;
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** The host's own view of what is running. */
function active(): Record<string, { type?: string }> | undefined {
  const response = api("get", "/api/session/active") as { data?: Record<string, { type?: string }> } | undefined;
  return response?.data;
}

function sessionOf(id: string): SessionInfo | undefined {
  const response = api("get", `/api/session/${encodeURIComponent(id)}`) as { data?: SessionInfo } | SessionInfo | undefined;
  if (response === undefined) return undefined;
  const wrapped = response as { data?: SessionInfo };
  return wrapped.data ?? (response as SessionInfo);
}

function interrupt(id: string): boolean {
  const response = api("post", `/api/session/${encodeURIComponent(id)}/interrupt`, { continue: false }) as
    | { interrupted?: boolean }
    | undefined;
  return response?.interrupted === true;
}

function remove(id: string): boolean {
  // DELETE returns 204 with an empty body, so "no throw" is the success signal.
  return api("delete", `/api/session/${encodeURIComponent(id)}`) !== undefined || true;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Choosing targets
// ---------------------------------------------------------------------------

interface Target {
  readonly id: string;
  readonly agent: string;
  readonly title: string;
  readonly root: boolean;
}

function targets(): Target[] {
  const running = active();
  if (running === undefined) {
    process.stderr.write("panic: the host did not answer /api/session/active\n");
    process.exit(2);
  }

  const ids = options.sessions.length > 0 ? options.sessions : Object.keys(running);
  const chosen: Target[] = [];
  for (const id of ids) {
    if (options.sessions.length === 0 && running[id] === undefined) continue;
    const info = sessionOf(id);
    // Default scope is subagents: a session with no parent is somebody's root
    // session, and killing that unasked would be its own kind of rogue.
    if (options.sessions.length === 0 && info?.parentID === undefined) continue;
    chosen.push({
      id,
      agent: info?.agent ?? running[id]?.type ?? "unknown",
      title: info?.title ?? "(untitled)",
      root: info?.parentID === undefined,
    });
  }
  return chosen;
}

const list = targets();

if (options.json) {
  process.stdout.write(`${JSON.stringify({ targets: list, dryRun: options.dryRun }, null, 2)}\n`);
} else {
  if (list.length === 0) {
    process.stdout.write("panic: nothing running that matches. No action taken.\n");
  } else {
    process.stdout.write(`${options.dryRun ? "would stop" : "stopping"} ${list.length} session(s):\n`);
    for (const target of list) {
      process.stdout.write(`  ${target.id}  ${target.agent.padEnd(18)} ${target.root ? "(root!) " : ""}${target.title}\n`);
    }
  }
}

if (list.length === 0) process.exit(0);
if (options.dryRun) process.exit(0);

// ---------------------------------------------------------------------------
// Kill, verify, escalate
// ---------------------------------------------------------------------------

async function survivors(): Promise<string[]> {
  const deadline = Date.now() + options.timeout * 1_000;
  let remaining = list.map((target) => target.id);
  while (Date.now() < deadline) {
    const running = active() ?? {};
    remaining = remaining.filter((id) => running[id] !== undefined);
    if (remaining.length === 0) return [];
    await sleep(1_000);
  }
  return remaining;
}

process.stdout.write("\ninterrupting...\n");
for (const target of list) {
  const stopped = interrupt(target.id);
  process.stdout.write(`  ${stopped ? "interrupted" : "already stopped"}  ${target.id}\n`);
}

let remaining = await survivors();
process.stdout.write(remaining.length === 0 ? `\nstopped. verified against /api/session/active.\n` : `\nstill running: ${remaining.join(", ")}\n`);

// One more interrupt before anything heavier: a session can pick up work between
// the first interrupt and the check.
if (remaining.length > 0) {
  process.stdout.write("\nsecond interrupt pass...\n");
  for (const id of remaining) interrupt(id);
  remaining = await survivors();
}

if (remaining.length > 0 && options.remove) {
  process.stdout.write("\nremoving (destructive)...\n");
  for (const id of remaining) {
    remove(id);
    process.stdout.write(`  removed  ${id}\n`);
  }
  remaining = await survivors();
}

// Restart is last, never first: it can RESUME a suspended child session.
if (remaining.length > 0 && options.restart) {
  process.stdout.write("\nrestarting the background service (last resort)...\n");
  Bun.spawnSync([bin, "service", "restart"], { stdout: "pipe", stderr: "pipe" });
  await sleep(3_000);
  remaining = await survivors();
}

if (remaining.length === 0) {
  process.stdout.write("\nOK — all targets stopped.\n");
  process.exit(0);
}

process.stderr.write(`\nSURVIVED: ${remaining.join(", ")}\n`);
process.stderr.write("Try, in this order:\n");
process.stderr.write(`  panic -s ${remaining[0]} --remove      delete the session (irreversible)\n`);
process.stderr.write("  panic --restart                         restart the service (may revive suspended sessions)\n");
process.exit(1);
