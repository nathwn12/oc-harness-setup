# Session scope

One live session owns one task domain. Before dispatching into another repository or shared harness surface, check active sessions through the OpenCode service API when collision is plausible.

Read the service registration in-process from `$XDG_STATE_HOME/opencode/service.json`, defaulting to `~/.local/state/opencode/service.json`, with `~/.config/opencode/service.json` as fallback. Keep the password inside the process and Authorization header; never print or log it.

If another live session clearly owns the target, do not edit that surface. Report the collision and hand over the finding. If overlap is discovered after dispatch, stop the overlapping worker and preserve the last verified state; do not destructively revert shared work.

The user may intentionally combine domains in one session. That explicit request defines the broader scope.
