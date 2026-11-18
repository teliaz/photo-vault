#!/bin/sh
# Mirror the Immich library (4T_RED) to the 2TB_TOSHIBA backup drive.
# ponytail: mirror with --delete — photos deleted in Immich also vanish from the
# backup on the next run; switch to restic if you ever need point-in-time history.
set -e
mountpoint -q /mnt/4T_RED || { echo "source drive not mounted, aborting"; exit 1; }
mountpoint -q /mnt/2TB_TOSHIBA || { echo "backup drive not mounted, aborting"; exit 1; }
rsync -rlt --modify-window=1 --delete --info=stats1 \
  /mnt/4T_RED/immich/library/ /mnt/2TB_TOSHIBA/immich-backup/library/
