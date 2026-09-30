# testflight

**Check the artifact you are about to publish — not the checkout you built it in.**

Your working copy lies to you. It has `node_modules` full of packages that a
consumer's install will never produce, it has files that `.gitignore` or `files`
will quietly drop, and it has paths that only exist on your machine.

`npm pack --dry-run` will not catch any of it. It lists files. It does not
install them and it does not resolve them.

Test Flight packs the real tarball, installs it into an empty project, and loads
it. Then it tells you, in plain language, what a user would have hit.

```bash
testflight .                 # pack, inspect, install, resolve
testflight . --no-install    # static checks only — fast, no network
testflight . --import        # also load the declared entry points
testflight ./pkg-1.0.0.tgz   # check a tarball you already have
testflight . --json
```

Exit codes: `0` clean (warnings allowed) · `1` findings · `2` could not run.

## The two bugs this exists for

Both shipped in a real package. Both passed `npm pack --dry-run` with a clean
file list. Both worked perfectly on the machine they were built on.

**The optional peer.** A package declared `@opentui/solid` in
`peerDependencies`, then listed it in `peerDependenciesMeta` as `optional: true`
so local development would stop complaining. npm believes you: it skips optional
peers at install time. The package installed cleanly and died on first import
with `Cannot find package '@opentui/solid'`. The fix is one `npm deprecate`, and
the only reliable way to have caught it was to install the thing.

**The duplicated peer.** A plugin bundled its own copy of a module the host also
provides. Two instances load, module identity differs, and state shared across
that boundary silently stops working — no error, no warning, just a component
that renders fine and never updates. The checkout cannot show you this, because
the checkout only has one copy.

Neither is exotic. Both are one line of manifest.

## What it actually does

1. **Packs the real tarball.** `npm pack`, not the working directory.
2. **Extracts it and reads the published `package.json`.** `files`, `main`,
   `exports`, and `peerDependencies` as npm rewrote them — including anything a
   `prepack` script generated.
3. **Verifies every declared entry point is inside the tarball.** The most
   common release bug there is: a `files` whitelist that forgot the build
   directory. The package installs, and importing it throws.
4. **Checks the peer relationships.** A peer that is also a runtime
   dependency is a second copy waiting to happen. A peer marked optional that
   shipped code statically imports is a guaranteed install-time crash.
5. **Greps the packed bytes for machine-specific paths.** `file:///C:/...`,
   `/Users/<name>/`, `C:/Users/<name>/`. A path that names one machine is a package
   that works on one machine.
6. **Installs into a throwaway project and confirms every peer resolved.** The
   step that `--dry-run` cannot do, and the step that catches the first bug
   above.

## What it checks

| Code | Severity | Meaning |
|---|---|---|
| `TF001` | fail | A declared entry point is not in the tarball (usually a missing `files` entry) |
| `TF002` | fail / warn | A required peer marked optional that shipped code imports |
| `TF003` | fail | A peer that is also a runtime dependency — two copies at runtime |
| `TF004` | fail | A declared `bin` that is not packed |
| `TF005` | warn | A peer bundled inside the tarball |
| `TF010`–`TF014` | fail / warn | Packed files reference a machine-specific path |
| `TF020` | fail | `npm install` of the tarball failed in a clean project |
| `TF021` | info | An optional peer was skipped — correct, if nothing imports it |
| `TF022` | fail | A required peer did not resolve after a clean install |
| `TF023` | fail | The package itself is absent after install |
| `TF030` | fail / warn | A declared entry point threw when imported |

## What it cannot check

This matters more than the list above, so it is not buried.

- **Modules the host injects.** A plugin can load perfectly here and still fail
  inside a bundled host binary that carries its own copy of a shared library.
  Test Flight cannot reproduce that runtime; it can only tell you that the
  packaging is not the cause. A green run is not "it works in the host".
- **Behaviour.** It proves the package loads. It does not prove it does anything
  correct.
- **Dependency security.** That is a different tool's job.

Every run prints the first of these as a reminder. A check that overstates what
it proved is worse than no check.

## Wiring

- **CLI**, run through `bun`. No daemon, no server, no MCP.
- **Trigger:** the `test-flight` skill tells the agent to run this before any
  publish.
- **Shim:** `~/.local/bin/testflight`.
- **Sandbox:** a fresh directory under the system temp dir, deleted afterwards
  unless `--keep` is passed.

## Tests

```bash
cd scripts/testflight && bun test
```

38 tests. The manifest analyser and path scanner are tested as pure functions;
the end-to-end tests build real fixture packages, pack them, and assert that the
optional-peer release and the missing-`files` release are both caught.
