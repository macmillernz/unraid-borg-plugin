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
2. Paste the raw URL of `plugin/borgbackup.plg` from your fork of this repo.
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

**Archives & Log** — list the archives in the repository, check its real on-disk
size, and read `/var/log/borgbackup.log`, with auto-refresh while a backup runs.

## How selection works

- **All containers** mode backs up every container, except ones you untick.
- **Only selected** mode backs up nothing until you tick containers.
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

## Building

```bash
./build.sh              # package archive/*.txz and update plugin/*.plg
make lint               # PHP (via Docker), shell, JS and XML checks
make tree               # list what ships in the package
```

`build.sh` rewrites the `version` and `md5` entities in `plugin/borgbackup.plg`
to match the package it just built.

Both the manifest and the packaged `slack-desc` point at
`macmillernz/unraid-borg-plugin`. If you fork this, change the `gitURL` entity in
the manifest and build with `GHUSER=youraccount ./build.sh`, or the plugin will
look for its updates in the wrong place.

The repository must be **public** — Unraid fetches the `.plg` and `.txz` over
plain HTTPS with no credentials, so a private repo cannot be installed from.

## Licence

MIT.
