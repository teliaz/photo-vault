# Private photo vault plan

This guide describes a self-hosted photo service for iOS and Android, with an always-on copy on this computer and a second copy on a removable USB disk. The repository does not install Immich or change this computer's storage. The included script creates a USB backup only when you run it.

## How the pieces fit

1. Run [Immich](https://docs.immich.app/overview/quick-start/) with Docker Compose on this computer. Keep `UPLOAD_LOCATION` and the PostgreSQL data on persistent internal storage, not in the container filesystem or on the removable disk. Immich recommends at least 6 GB RAM and 2 CPU cores.
2. Use the Immich iOS and Android apps for camera roll backup. Select albums, enable backup, and restrict uploads to Wi-Fi. Immich skips matching files and uploads new media when the app opens or when the phone grants it background time. On iOS, enable Background App Refresh; arrival-time uploads cannot be guaranteed. [Mobile backup behavior](https://docs.immich.app/features/mobile-backup/)
3. At home, point the phone app at the computer's **home-network** Immich address. That makes uploads possible when the phone rejoins home Wi-Fi. Use a DHCP reservation or a stable local DNS name so the address does not change. If you want uploads away from home too, point the app at the private remote address instead; Wi-Fi-only then means *any* Wi-Fi.
4. For browsing away from home, put [Tailscale Serve](https://tailscale.com/docs/solutions/host-private-server-docker) in front of Immich. It provides a private HTTPS `*.ts.net` address without a static home IP or router port forwarding. Install Tailscale on approved phones. Open the web address in Safari or Chrome and add it to the home screen. A home-screen web app works for browsing and manual uploads; phone background camera roll access still needs the native Immich app. [PWA background limitations](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Offline_and_background_operation)
5. Run [`scripts/backup-to-usb.sh`](scripts/backup-to-usb.sh) manually whenever the USB disk is connected. It creates a new versioned Borg archive containing the Immich media, a PostgreSQL dump, and the Compose configuration. It never prunes, deletes, or overwrites an earlier archive.

Do the first Immich admin registration from the computer or trusted home network **before** allowing other devices to reach the service. The first registered user becomes the admin. [Immich user management](https://docs.immich.app/administration/user-management/)

## Two accounts and access permissions

Two accounts are supported. Create one admin account for yourself and a second ordinary account through **Administration → Users → Create user**. Each account has its own library and may sign in from multiple phones or browsers. The admin can create users, reset passwords, set per-user storage quotas, and disable accounts. Do not share one login between people if you want separate libraries and accountable devices. [Immich user management](https://docs.immich.app/administration/user-management/)

| Access | What it allows | Suggested setting |
| --- | --- | --- |
| Own library | Upload, browse, and manage the account's own media | One account per person |
| Shared album | Selected users can view it; choose viewer or editor permissions | Use for selected family photos |
| Partner sharing | Gives another account broad access to the library, including GPS metadata; sharing is one-way | Enable only if both people want this |
| Public share link | Anyone with a reachable link may access the shared items | Avoid for a private-only deployment |
| Immich admin | Manages users and server settings | Keep to one trusted account |
| Tailscale device | Controls whether a phone/computer can reach the private service | Enable device approval; revoke lost devices |

Shared album permissions and partner sharing are documented in [Immich sharing](https://docs.immich.app/features/sharing/) and [partner sharing](https://docs.immich.app/features/partner-sharing/). Users can review their signed-in devices under [Account Settings](https://docs.immich.app/features/user-settings/). Immich login and network device approval are separate checks: a device needs network access **and** an Immich account to use the service.

Tailscale's [device approval](https://tailscale.com/docs/features/access-control/device-management/device-approval) is managed in Tailscale's hosted admin console, even though the photo service has no public signup endpoint. If approval must be wholly self-hosted, replace Tailscale with administrator-provisioned WireGuard peers and dynamic DNS. That requires a reachable VPN port on the home connection; check for carrier-grade NAT before choosing it. In either case, do not expose Immich's port or the backup trigger directly to the public internet.

## Location and automatic arrival uploads

Start without GPS tracking: home Wi-Fi plus a home-only server address is enough to make uploads possible at home. Phone operating systems decide when background jobs actually run, especially on iOS. If you want arrival events or a private location history, [OwnTracks](https://owntracks.org/booklet/features/location/) is a free iOS/Android option with geofences and a self-hosted endpoint. An OwnTracks event cannot force a PWA or the Immich app to upload immediately.

## Manual USB backup setup

The script assumes the [official Immich Docker Compose layout](https://docs.immich.app/overview/quick-start/), with services named `immich-server` and `database`, and [Borg 1.x](https://borgbackup.readthedocs.io/en/stable/usage/init.html). Adjust the service names in the config if your Compose file differs. Install Borg and the Docker Compose plugin on the host. Initialized as shown below, the backup is an encrypted, versioned archive, not a folder of directly browsable JPEGs.

1. Mount the USB disk at a fixed path, for example `/mnt/photo-backup`. Find its filesystem UUID with `lsblk -f` or `findmnt --mountpoint /mnt/photo-backup -o UUID`. Use a native filesystem such as ext4 for the Borg repository.
2. Initialize the repository **once**, while that disk is mounted. Borg will ask for an encryption passphrase:

   ```bash
   borg init --encryption=repokey --append-only /mnt/photo-backup/immich-borg
   borg key export /mnt/photo-backup/immich-borg /path/on/another/device/immich-borg.key
   ```

   Keep the exported key and passphrase somewhere safe outside this computer and USB disk. Borg's append-only setting protects committed backup data from Borg compaction, but it does not protect against physical deletion or a full disk. [Borg encryption and append-only notes](https://borgbackup.readthedocs.io/en/stable/usage/init.html)
3. Copy [`backup.example.env`](backup.example.env) to `backup.env` and edit the absolute paths and UUID. `backup.env` is ignored by Git. Keep it readable only by the backup operator because it identifies private storage paths. The script does **not** put a Borg passphrase in this file; it prompts when run.
4. Connect the USB disk and trigger the backup from this repository:

   ```bash
   ./scripts/backup-to-usb.sh ./backup.env
   ```

The script checks that the configured UUID is mounted at the configured path and that the Borg repository already exists. It stops `immich-server`, dumps PostgreSQL, writes one Borg archive, then restarts the server even if the backup fails. The temporary database dump is removed after the run. Uploads and browsing pause while the server is stopped. An interrupted run may leave a Borg checkpoint, but previous completed archives remain available. The script does not initialize repositories, format disks, run `rsync --delete`, prune, or compact.

To inspect backup history and verify integrity:

```bash
borg list /mnt/photo-backup/immich-borg
borg check /mnt/photo-backup/immich-borg
```

Practice restoring one photo and the database dump into a **separate test directory** before relying on this backup. Immich needs both its database and original media for a full restore; a database dump alone does not contain photos. [Immich backup and restore](https://docs.immich.app/administration/backup-and-restore/)

The internal disk plus one USB disk are two physical copies in the same location. If “two backup locations” means two backups **in addition to** the internal copy, add another disk or an off-site destination. Also plan capacity: keeping every version means the USB repository grows indefinitely, and this script intentionally has no automatic retention.

## Non-destructive behavior

Immich mobile backup uploads new media and skips duplicates; it does not mirror phone deletions. This USB command only creates new archives. However, a person can still delete media through Immich, and the server itself can fail. Older USB archives retain earlier versions until someone deliberately removes them. Do not use Immich's file directories as a manually maintained mirror: its database records file paths, so direct moves or deletions can break the library. [Immich backup guidance](https://docs.immich.app/administration/backup-and-restore/)
