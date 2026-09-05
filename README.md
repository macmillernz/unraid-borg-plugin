# Borg Backup for Unraid

An Unraid plugin that backs up your Docker containers with
[BorgBackup](https://www.borgbackup.org/) — deduplicated, compressed and
encrypted, on a schedule.

You choose **all containers or specific ones**, and for each container you choose
**exactly which of its mounts** get archived.

---

## What it does

- **Repository** — a local path or a remote `ssh://` repository, with an optional SSH key.
- **Passphrase** — stored on the flash drive, or read from a file you keep on the array.
- **Archive naming** — a template with `{container}` plus borg's own `{now}`,
  `{hostname}`, `{user}` placeholders, with a live preview of the resulting name.
- **Container selection** — all containers, or only the ones you tick.
- **Per-container mount selection** — every bind mount is listed with its host path
  and where it appears inside the container; tick the ones worth archiving.
- **Per-container overrides** — stop/start the container around its archive, and
  extra exclude patterns.
- **Retention** — keep N daily/weekly/monthly/yearly, applied *per container*.
- **Schedule** — hourly, daily, weekly, monthly, or a custom cron expression.
- **Notifications** — through Unraid's own notification system.

Each container gets its own archive, so you can restore one container without
touching the others.

## Requirements

- Unraid **6.12.0** or newer (the plugin needs PHP 8).
- The Docker service running, for containers to be listed.
- Somewhere to put the repository. **A repository on the same array as the data
  it protects is not a backup** — it does not survive losing the array. Use a
  separate disk, an unassigned device, or a remote host over SSH.

## Install

1. In Unraid, go to **Plugins → Install Plugin**.
2. Paste:
   ```
   https://raw.githubusercontent.com/macmillernz/unraid-borg-plugin/main/borgbackup.plg
   ```
3. Open **Settings → Utilities → Borg Backup**.
4. Press **Install / update borg** — the plugin downloads the official
   standalone borg binary to the flash drive and installs it. This is a separate
   step because borg is not part of Unraid.
5. Set the repository location and passphrase, press **Apply**, then
   **Initialise repository** to create a new one.
6. Press **Test repository**, then **Dry run**, before trusting a real schedule.

## Tabs

**Settings** — repository, encryption, archive naming, compression, global
excludes, retention, schedule, notifications.

**Containers** — the container and mount picker. Each container expands to show
its bind mounts, with the host path (what actually gets archived) alongside the
path it is mounted at inside the container. **Preview what will be backed up**
resolves your settings and selections into the exact list of paths, without
touching the repository.

The Settings tab also carries the archive list, the repository's real on-disk
size, and `/var/log/borgbackup.log` with auto-refresh while a backup runs — they
sit below the action buttons, so pressing **Run backup now** and watching the log
happen in one place.

## How selection works

- **Every container is backed up unless you untick it** on the Containers tab, and
  a container you add later is included automatically. For a backup tool, quietly
  missing a new container is worse than archiving one you did not need.
- A container marked `auto` has all its mounts selected, and will pick up mounts
  you add to it later. Untick even one mount and the selection becomes fixed — so
  revisit the Containers tab after changing a container's volume mappings.
- Only **bind mounts** are listed. Named Docker volumes and passthrough paths like
  `/dev` and `/var/run` are excluded because they are not useful to archive.
- Nested paths are collapsed, so a parent and its child are not both archived.

## Archive naming

The default is:

```
{container}-{now:%Y-%m-%d_%H%M%S}
```

`{container}` is substituted by the plugin; everything else is handled by borg
itself (`{now}`, `{utcnow}`, `{hostname}`, `{fqdn}`, `{user}`, `{pid}`, with
strftime formats after a colon).

**Keep `{container}` and a timestamp in the format.** Retention prunes each
container independently by turning this template into a match pattern, so if two
containers can produce the same name, pruning one can delete the other's
archives. The settings page flags a format that would do this.

## Restoring

Restoring is deliberately not a button in the web UI — overwriting live data
should be a considered act. From the Unraid terminal:

```bash
export BORG_REPO=/mnt/user/backups/borg
export BORG_PASSPHRASE='your passphrase'

borg list                                  # what archives exist
borg list ::plex-2026-09-05_030000         # what is in one
cd /mnt/user/restore
borg extract ::plex-2026-09-05_030000      # extract into the current directory
```

`borg extract` writes relative to the **current working directory**, so `cd`
somewhere safe first rather than restoring over the original path by accident.

## Where things live

| Path | What |
|---|---|
| `/boot/config/plugins/borgbackup/borgbackup.cfg` | settings |
| `/boot/config/plugins/borgbackup/containers.json` | container and mount selections |
| `/boot/config/plugins/borgbackup/excludes.txt` | global exclude patterns |
| `/boot/config/plugins/borgbackup/passphrase` | passphrase, when stored on flash |
| `/boot/config/plugins/borgbackup/borg` | the borg binary, restored to `/usr/local/bin` at boot |
| `/var/log/borgbackup.log` | run log |
| `/etc/cron.d/borgbackup` | generated schedule |

Uninstalling leaves `/boot/config/plugins/borgbackup` in place so a reinstall
keeps your settings. Delete that directory yourself if you want them gone. **Your
repository is never touched by uninstalling.**

## A note on the passphrase

The Unraid flash drive is `vfat`, which cannot enforce file permissions. A
passphrase stored there is readable by anything that can read the flash, and it
is included in flash backups. If that matters, set **Passphrase source** to
*Read from a file I specify*, put the file on the array, and `chmod 600` it.

Whichever you choose: **keep a copy of the passphrase somewhere else.** Without
it the archives are unreadable, and there is no recovery path. If you use a
`keyfile` encryption mode, also back up `/root/.config/borg/keys` — the
passphrase alone is not enough to restore.

## Layout

```
borgbackup.plg          the plugin descriptor Unraid reads
package.sh              builds the .txz and stamps version + MD5 into the .plg
deploy.sh               rsync source/ straight to a test box (dev only)
source/borgbackup/      everything that ships, rooted at the plugin dir
```

## Building

```bash
make lint               # PHP (via Docker), shell, JS and XML checks
make build              # build at the version currently in borgbackup.plg
make bump               # advance to today's next version, then build
make tree               # list what ships in the package
```

Versions are `year.month.day.n` — bump `n` for each same-day release, reset to
`1` on a new day. The version lives in exactly one place, `borgbackup.plg`'s
`<!ENTITY version …>`; `package.sh` reads it rather than inventing its own, so
the package and the descriptor cannot drift apart. `make bump` advances it for
you and refuses to reuse a version you may already have released.

`package.sh` writes the MD5 of the package it just built back into the `.plg`.
A stale MD5 makes Unraid's plugin manager reject the download as corrupt.

## Releasing

The `.txz` is **not** committed — it is `.gitignore`d and distributed as a
GitHub release asset, so the repo doesn't accumulate binaries.

```bash
make bump                                   # new version + build
make release                                # upload the .txz to a release
git add -A && git commit -m "Release ..." && git push
```

The repository must be **public** — Unraid fetches the `.plg` and `.txz` over
plain HTTPS with no credentials, so a private repo cannot be installed from.

If you fork this, change the `pluginURL` and `SRC` entities in the manifest and
the homepage line in `package.sh`'s `slack-desc`, or the plugin will look for
its updates in the wrong place.

### Testing on a real box

`deploy.sh` rsyncs `source/borgbackup/` straight into a test server's plugin
directory, skipping packaging entirely:

```bash
BORG_UI_HOST=root@tower ./deploy.sh
```

This does not survive a reboot — `/usr/local/emhttp` is rebuilt from OS packages
every boot — so it is for the edit/reload cycle, not for a real install. Your
settings under `/boot/config/plugins/borgbackup` are left alone.

## Licence

MIT.
