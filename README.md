# tools

Standalone operational scripts for a server set up with
[`grommunio-hardened-setup`](https://github.com/thctlo/grommunio-hardened-setup) —
not part of its provisioning pipeline, safe to run independently at
any time afterward.

## Platform

Built and used on Debian 13 (trixie); not tested on other
distributions or Debian releases.

## What's here

| File | Purpose |
|---|---|
| `backup-testvps.sh` + `backup-testvps.service`/`.timer` | Nightly backup via Borg: all three live MariaDB databases (proper dumps, not just file copies), plus all of `/etc`, `/var/lib`, `/var/spool` minus a short exclude list for disposable caches — not a curated path list, which has twice silently missed real state. |
| `RESTORE-testvps.md` | The restore runbook for the backup above. Deliberately **not** a script — a restore is a decision point (which server, which archive, what gets overwritten), not something to run blind. (In Dutch.) |
| `gromox-modernize.sh` | Migrates deprecated/renamed gromox config directives (e.g. the 3.13.x `listen_*` keys moving to `gromox.cfg`) to their current names and locations, self-healing either a fresh install or one that already hit the old bug. Same pre-change backup convention as `grommunio-hardened-setup`'s own `backup_file()` (`/root/backups/<run-timestamp>/<original path>` + manifest), reimplemented standalone here on purpose — this tool has no dependency on that repo. |
| `unban-fail2banIP.sh` | Removes one IP from every active fail2ban jail in one go, instead of hunting down which jail(s) banned it. |

## Status

Used on a real production deployment. Contributions, issues and
corrections welcome.

## License

MIT - see [LICENSE](LICENSE).
