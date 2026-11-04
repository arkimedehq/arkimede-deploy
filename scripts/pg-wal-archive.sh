#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright © 2026 Andrea Genovese

# pg-wal-archive.sh — Postgres archive_command for Arkimede's continuous WAL archiving.
#
#   archive_command = 'sh /wal-spool/.archive.sh "%p" "%f" <spool cap in MB>'
#
# Runs INSIDE the postgres container (scripts/backup.sh copies it into the wal_spool
# volume). It only compresses the finished segment into the local spool; the host job
# (`backup.sh wal-ship`, every minute) moves the spool to the backup destination. So
# archiving never waits on the network or on the destination's permissions.
#
# Bounded disk use: when the spool reaches its cap (destination unreachable for a long
# time) the segment is DROPPED and its name written to GAP, instead of failing — a failing
# archive_command makes Postgres keep every WAL segment in pg_wal and can fill the disk.
# The host job alerts on GAP and takes a fresh base backup once the destination is back
# (point-in-time recovery resumes from there).
set -eu
src="$1"; name="$2"; cap_mb="${3:-1024}"
spool="$(dirname "$0")"

# A previous attempt already spooled it (crash between the rename and the return).
[ -f "$spool/$name.gz" ] && exit 0

used_kb=$(du -sk "$spool" | cut -f1)
if [ "$used_kb" -ge $((cap_mb * 1024)) ]; then
  [ -f "$spool/GAP" ] || echo "$name" > "$spool/GAP"
  echo "pg-wal-archive: spool full (${used_kb} KB >= ${cap_mb} MB), dropped $name" >&2
  exit 0
fi

tmp="$spool/.$name.gz.tmp"
gzip -c "$src" > "$tmp"
sync "$tmp"
mv "$tmp" "$spool/$name.gz"
