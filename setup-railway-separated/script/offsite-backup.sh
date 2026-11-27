#!/bin/bash
# Daily offsite backup of the ERPNext site, for Strata (zaloutions/strata-app,
# openspec/changes/erpnext-ledger-backup, design D1). Frappe v16 has no offsite
# backup of its own, so supervisor runs this beside the workers.
#
# Once a day, at OFFSITE_BACKUP_HOUR_UTC (default 13, which is 00:00 Sydney
# summer time), it:
#   1. runs `bench backup --with-files --compress` into a fresh directory
#      outside sites/, so Frappe's hourly clean-up can't delete it mid-upload
#      and a backup never lands on the volume it protects;
#   2. uploads the four files (database, site config, public and private files)
#      to s3://$OFFSITE_BACKUP_BUCKET/<YYYYMMDD_HHMMSS>/ with AWS CLI v2, which
#      sends the checksum S3 Object Lock requires;
#   3. lists the uploaded prefix and checks each file's size;
#   4. deletes the local copy, and logs one line: no file contents, no key.
#
# With OFFSITE_BACKUP_BUCKET, OFFSITE_BACKUP_REGION, AWS_ACCESS_KEY_ID or
# AWS_SECRET_ACCESS_KEY unset it does nothing and logs "not configured" once a
# day: the job stays dormant in an environment until its variables are set.
# A failed run logs "failed <step> <code>"; Strata's nightly freshness check is
# the alert. The credential can only add objects: it never deletes.
#
#   offsite-backup.sh          loop forever (supervisor)
#   offsite-backup.sh --once   one run now, exit 0 on success or when not
#                              configured, non-zero on failure
#
# OFFSITE_BACKUP_ENDPOINT (optional) points the AWS CLI at an S3 stand-in, for
# local tests only.

set -uo pipefail

BENCH_DIR="${OFFSITE_BACKUP_BENCH_DIR:-/home/frappe/frappe-bench}"
WORK_ROOT="${OFFSITE_BACKUP_WORK_DIR:-/home/frappe/offsite-backup}"
BENCH="${BENCH_PATH:-bench}"
HOUR_UTC="${OFFSITE_BACKUP_HOUR_UTC:-13}"

log() { echo "offsite-backup: $*"; }

missing_config() {
  local name missing=()
  for name in RFP_DOMAIN_NAME OFFSITE_BACKUP_BUCKET OFFSITE_BACKUP_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  echo "${missing[*]}"
}

aws_s3() {
  local endpoint=()
  [ -n "${OFFSITE_BACKUP_ENDPOINT:-}" ] && endpoint=(--endpoint-url "$OFFSITE_BACKUP_ENDPOINT")
  aws "${endpoint[@]}" --region "$OFFSITE_BACKUP_REGION" s3 "$@"
}

# One run. Returns 0 on success or when not configured.
run_once() {
  local missing dir rc ts db count file listed local_size remote_size
  missing="$(missing_config)"
  if [ -n "$missing" ]; then
    log "not configured ($missing)"
    return 0
  fi

  mkdir -p "$WORK_ROOT" || { log "failed workdir $?"; return 1; }
  dir="$(mktemp -d "$WORK_ROOT/run.XXXXXX")" || { log "failed workdir $?"; return 1; }
  # shellcheck disable=SC2064 # expand $dir now: it is this run's directory.
  trap "rm -rf '$dir'" RETURN

  cd "$BENCH_DIR" || { log "failed bench-dir $?"; return 1; }
  log "versions $("$BENCH" version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"

  "$BENCH" --site "$RFP_DOMAIN_NAME" backup --with-files --compress --backup-path "$dir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { log "failed backup $rc"; return 1; }

  db="$(find "$dir" -maxdepth 1 -name '*-database.sql.gz' ! -name '*-partial-database*' -printf '%f\n' | head -n1)"
  count="$(find "$dir" -maxdepth 1 -type f \( -name '*-database.sql.gz' -o -name '*-site_config_backup.json' -o -name '*-files.tgz' -o -name '*-files.tar' \) | wc -l)"
  if [ -z "$db" ] || [ "$count" -lt 4 ]; then
    log "failed backup-parts $count"
    return 1
  fi
  ts="${db:0:15}"

  aws_s3 cp "$dir" "s3://$OFFSITE_BACKUP_BUCKET/$ts/" --recursive --only-show-errors >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { log "failed upload $rc"; return 1; }

  listed="$(aws_s3 ls "s3://$OFFSITE_BACKUP_BUCKET/$ts/" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || { log "failed verify-list $rc"; return 1; }
  for file in "$dir"/*; do
    local_size="$(stat -c %s "$file")"
    remote_size="$(awk -v name="$(basename "$file")" '$4 == name { print $3 }' <<<"$listed")"
    if [ "$remote_size" != "$local_size" ]; then
      log "failed verify-size $(basename "$file")"
      return 1
    fi
  done

  log "ok $ts $(du -sb "$dir" | cut -f1)"
  return 0
}

seconds_until_next_run() {
  local now target
  now="$(date -u +%s)"
  target="$(date -u -d "today ${HOUR_UTC}:00" +%s)"
  [ "$target" -gt "$now" ] || target="$(date -u -d "tomorrow ${HOUR_UTC}:00" +%s)"
  echo $((target - now))
}

if [ "${1:-}" = "--once" ]; then
  run_once
  exit $?
fi

while true; do
  sleep "$(seconds_until_next_run)"
  run_once || true
done
