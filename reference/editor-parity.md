# Editor parity

Use this only when a dependency, compiler, language-server, project, or toolchain configuration change could make the user's editor disagree with the proving command.

Verify the editor can resolve the project from committed metadata and the documented install/restore step. Check the relevant manifest, lockfile, compiler config, interpreter/SDK pin, and project files. Add editor-specific settings only when the repository genuinely requires them; do not install extensions or rewrite unrelated configuration.

Report whether the editor should be green immediately, after dependency restore, or after restart. Ordinary source-only changes do not require this ceremony.
