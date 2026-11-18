# Photo vault — as-built setup log

This file records what was actually built on this machine and how the second
(backup) storage location is wired. The [README](README.md) describes the
original plan; where the two differ, this file wins. Latest update:
2026-11-18.

## Hardware map

| Device | Model | Filesystem | Mounted at | Role |
| --- | --- | --- | --- | --- |
| `/dev/sda2` | WDC WD40EFRX (USB, 3.6T) | ntfs3 | `/mnt/4T_RED` | Primary — Immich upload library (`UPLOAD_LOCATION`) |
| `/dev/sdb1` | Toshiba MQ04ABD200 in Verbatim enclosure (USB, 1.8T) | exFAT | `/mnt/2TB_TOSHIBA` | Backup — DB dumps + nightly library mirror |
| `nvme0n1p2` | Samsung 990 PRO 1TB | btrfs | `/` | OS, Docker, Immich PostgreSQL data (`immich-app/postgres`) |

Both USB disks are in `/etc/fstab` (entries below) with `nofail`, so boot
does not hang when a disk is absent — but Immich needs both disks present.

```fstab
UUID=BC96D53096D4EBC0 /mnt/4T_RED      ntfs3  defaults,nofail,uid=1000,gid=1000,iocharset=utf8,windows_names 0 0
UUID=7EFD-F24D         /mnt/2TB_TOSHIBA exfat defaults,nofail,uid=1000,gid=1000 0 0
```

Backups of `/etc/fstab` from before these lines: `/etc/fstab.bak-immich`,
`/etc/fstab.bak-immich2`.

## What was set up, in order

1. **Immich via Docker Compose** in [`immich-app/`](immich-app/) — stock
   upstream compose, `IMMICH_VERSION=v3`, web UI on port **2283**.
   `UPLOAD_LOCATION=/mnt/4T_RED/immich/library`, PostgreSQL data in
   `immich-app/postgres` (local SSD, not USB — never put the DB on USB/NTFS).
2. **4T_RED fstab entry.** The disk was being automounted by the desktop at
   `/run/media/teliaz/4T_RED` while the containers bind-mount `/mnt/4T_RED`,
   which left an *empty* directory at the container path. Symptom:
   `immich_server` crash-looping on `Failed to read /data/encoded-video/.immich`
   (folder-integrity check). Fix: fstab mount at `/mnt/4T_RED`; desktop
   automount no longer grabs it after a normal boot.
3. **2TB Verbatim disk wiped and formatted exFAT** (2026-11-18). Was factory
   FAT32 with Verbatim bloatware (~444 MB, nothing user-created). MBR label,
   single type-`0x07` partition spanning the disk, `mkfs.exfat -n 2TB_TOSHIBA`,
   cluster size 128 KB. exFAT chosen for maximum cross-OS compatibility
   (Windows/macOS/Linux/TVs/cameras); trade-off: no journaling and no POSIX
   permissions — always eject/sync before unplugging.
4. **Backup location wired into Immich** — see next section.
5. **Nightly library mirror** via systemd timer — see next section.

## The extra backup location (`/mnt/2TB_TOSHIBA`)

**This drive is detachable by design.** It is not always attached, and nothing
on the always-on path depends on it:

- The systemd timer fires nightly regardless; when the drive is absent the
  script exits early with `backup drive not mounted, aborting` and the unit
  reports failed. That is expected and harmless — the next run with the drive
  attached mirrors everything that changed in the meantime.
- `Persistent=true` only re-fires runs missed while the machine was off. A
  run missed because the drive was unplugged simply re-runs at the next 02:00
  with the drive present (or immediately via `systemctl start
  immich-library-backup.service`).
- The immich-server container does **not** mount anything from this drive.
  (A bind mount from a detachable disk is dangerous: Docker silently
  re-creates the missing host path as an empty directory, so backups would
  "succeed" onto the SSD, and Immich's folder checks can crash-loop the
  server. Tried and reverted on 2026-11-18.)

Layout on the backup disk:

```
/mnt/2TB_TOSHIBA/immich-backup/
└── library/    # rsync mirror of the whole upload library, incl. database dumps
```

### Immich database backups (in-app setting)

Immich writes PostgreSQL dumps to its default location `/data/backups` —
i.e. `/mnt/4T_RED/immich/library/backups`, inside the always-attached
library tree. The nightly mirror therefore carries them to the backup disk
automatically whenever it is attached; no separate wiring.

**Pending manual step (needs the web UI):** in Immich, *Administration →
Settings → Backup*, enable scheduled database backup (e.g. daily) and leave
the path at its default (`/data/backups`). Do **not** point it at a custom
path on the removable drive.

Files on the host (installed 2026-11-18):

- `/usr/local/bin/immich-library-backup.sh` — checks both disks are mounted,
  then `rsync -rlt --modify-window=1 --delete` the library to the backup disk.
  Source copy of the script: [`scripts/immich-library-backup.sh`](scripts/immich-library-backup.sh).
- `/etc/systemd/system/immich-library-backup.service` — oneshot, idle I/O
  priority so it stays out of the way.
- `/etc/systemd/system/immich-library-backup.timer` — **daily at 02:00**,
  `Persistent=true` (a missed run fires after boot).

```sh
systemctl list-timers immich-library-backup.timer   # next run
systemctl start immich-library-backup.service       # run now (foreground)
journalctl -u immich-library-backup.service -f      # watch a run
```

The mirror is **not** versioned: `--delete` means a photo deleted in Immich
disappears from the backup on the next run. It also copies Immich's live
folder layout, which is only meaningful together with a database backup.
For versioned, encrypted, append-only backups use the pre-existing
[`scripts/backup-to-usb.sh`](scripts/backup-to-usb.sh) (Borg) from the
original README plan — it can target the same disk.

## Restore quick reference

1. `docker compose down` in `immich-app/`.
2. Restore the library tree: rsync/copy `immich-backup/library/` back to
   `/mnt/4T_RED/immich/library/` (database dumps are in
   `immich-backup/library/backups/`).
3. Restore the DB: `docker compose up -d database redis`, then restore the
   latest dump per
   [Immich backup and restore](https://docs.immich.app/administration/backup-and-restore/).
4. `docker compose up -d`.

Practice this once before trusting it.

## Operational gotchas learned on 2026-11-18

- If disks end up mounted under `/run/media/...` after a replug, the
  containers see empty dirs and `immich_server` crash-loops on the `.immich`
  folder check. Fix: `sudo mount /mnt/4T_RED /mnt/2TB_TOSHIBA` (fstab entries
  handle normal boots) or replug and remount.
- The immich containers hold bind-mount references; remounting the disks
  underneath them is safe, but recreating containers while a disk is missing
  silently re-binds to empty host dirs — check `docker inspect immich_server`
  mounts after any disk event. (This is why nothing bind-mounts the
  detachable 2TB drive.)
- After unplugging the 2TB drive and plugging it back in, the desktop may
  automount it at `/run/media/teliaz/2TB_TOSHIBA`. The backup script only
  accepts `/mnt/2TB_TOSHIBA`; remount it with
  `sudo mount /mnt/2TB_TOSHIBA` (fstab entry) or `sudo umount
  /run/media/teliaz/2TB_TOSHIBA` first.
