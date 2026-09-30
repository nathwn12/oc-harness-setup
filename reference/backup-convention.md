# Backup Convention

When any agent must back up a config file before editing it, run:

    scripts\backup-config.ps1 -Path <file>

- Backups land in `%USERPROFILE%\.opencode\config-backups\`.
- The script enforces keep-last-5 retention per file name.
- Never write `.bak` files inside `~\.config\opencode`.