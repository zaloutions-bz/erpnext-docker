#!/bin/bash
set -e

if [ -z "$RFP_DOMAIN_NAME" ]; then
    echo "ERROR: RFP_DOMAIN_NAME is not set" >&2
    exit 1
fi

SITE_DIR="/home/frappe/frappe-bench/sites/${RFP_DOMAIN_NAME}"
SETUP_MARKER="${SITE_DIR}/.railway-setup-complete"

site_has_erpnext() {
    su frappe -c "bench --site ${RFP_DOMAIN_NAME} list-apps" 2>/dev/null | grep -qw erpnext
}

if [ ! -d "$SITE_DIR" ]; then
    echo "-> Site not found, running setup"
    /home/frappe/frappe-bench/railway-setup.sh
elif [ ! -f "$SETUP_MARKER" ]; then
    if site_has_erpnext; then
        # A site set up before the marker existed.
        echo "-> Site ${RFP_DOMAIN_NAME} is installed, recording setup as complete"
        su frappe -c "touch '${SETUP_MARKER}'"
    elif [ "$RFP_RECREATE_SITE" = "$RFP_DOMAIN_NAME" ]; then
        echo "-> RFP_RECREATE_SITE names this site: dropping and recreating ${RFP_DOMAIN_NAME}"
        /home/frappe/frappe-bench/railway-setup.sh --force
    else
        echo "ERROR: site ${RFP_DOMAIN_NAME} exists but its setup never finished." >&2
        echo "       Set RFP_RECREATE_SITE=${RFP_DOMAIN_NAME} to drop and recreate it," >&2
        echo "       then remove the variable once the deploy is up." >&2
        exit 1
    fi
fi

# Re-assert the default site on every boot, so commands without --site work
# even if common_site_config.json lost it.
su frappe -c "bench use ${RFP_DOMAIN_NAME}"

# Migrate the site when the image's apps differ from the ones it was last
# migrated with. The Dockerfile pins every app's version, so this runs once per
# upgrade, not on every restart. A full backup comes first, onto the volume and,
# when the offsite job is configured, to S3. If the backup or the migrate fails,
# the boot stops: new code must not run against an old or half-migrated schema.
# Nothing is serving yet (nginx and supervisor start below), so the migrate runs
# with no traffic and no scheduler.
MIGRATED_MARKER="${SITE_DIR}/.railway-migrated-versions"
PRE_MIGRATE_DIR="/home/frappe/frappe-bench/sites/pre-migrate-backups"
IMAGE_VERSIONS="$(su frappe -c "cd /home/frappe/frappe-bench && bench version" 2>/dev/null | grep -E '^[a-z0-9_]+ ' | sort || true)"
if [ -z "$IMAGE_VERSIONS" ]; then
    echo "ERROR: could not read the image's app versions (bench version)" >&2
    exit 1
fi
if [ "$(cat "$MIGRATED_MARKER" 2>/dev/null)" != "$IMAGE_VERSIONS" ]; then
    echo "-> The image's apps differ from the site's last migrate:"
    echo "$IMAGE_VERSIONS" | sed 's/^/     /'
    BACKUP_DIR="${PRE_MIGRATE_DIR}/$(date -u +%Y%m%d_%H%M%S)"
    echo "-> Backing up to ${BACKUP_DIR}"
    su frappe -c "mkdir -p '${BACKUP_DIR}' && cd /home/frappe/frappe-bench && bench --site ${RFP_DOMAIN_NAME} backup --with-files --compress --backup-path '${BACKUP_DIR}'"
    # Keep the three newest pre-migrate backups.
    ls -1d "${PRE_MIGRATE_DIR}"/*/ 2>/dev/null | sort | head -n -3 | xargs -r rm -rf
    if [ -n "${OFFSITE_BACKUP_BUCKET:-}" ]; then
        echo "-> Offsite backup before migrating"
        su frappe -c "/home/frappe/frappe-bench/offsite-backup.sh --once"
    fi
    echo "-> Migrating ${RFP_DOMAIN_NAME}"
    su frappe -c "cd /home/frappe/frappe-bench && bench --site ${RFP_DOMAIN_NAME} migrate"
    echo "$IMAGE_VERSIONS" | su frappe -c "cat > '${MIGRATED_MARKER}'"
    echo "-> Migrated"
fi

# Install the apps built into the image on the site, once each: the Australian
# localisation and strata_guard (report Company checks). Covers new sites and ones
# created before an app was added to the image.
INSTALLED_APPS=$(su frappe -c "bench --site ${RFP_DOMAIN_NAME} list-apps" 2>/dev/null || true)
for app in erpnext_australian_localisation strata_guard; do
    if ! echo "$INSTALLED_APPS" | grep -qw "$app"; then
        echo "-> Installing ${app}"
        su frappe -c "bench --site ${RFP_DOMAIN_NAME} install-app ${app}"
    fi
done

# The site name (RFP_DOMAIN_NAME) is internal; links the site generates outside a
# request (emails, background jobs) use host_name. RFP_PUBLIC_HOST overrides the
# Railway domain, e.g. for a custom domain.
PUBLIC_HOST="${RFP_PUBLIC_HOST:-$RAILWAY_PUBLIC_DOMAIN}"
if [ -n "$PUBLIC_HOST" ]; then
    echo "-> Setting public URL to https://${PUBLIC_HOST}"
    su frappe -c "bench --site ${RFP_DOMAIN_NAME} set-config host_name 'https://${PUBLIC_HOST}'"
fi

echo "-> Clearing cache"
su frappe -c "bench --site ${RFP_DOMAIN_NAME} execute frappe.cache_manager.clear_global_cache"

echo "-> Resolving paths"
BENCH_PATH=$(su frappe -c "which bench")
NODE_PATH=$(su frappe -c "which node")
export BENCH_PATH NODE_PATH

echo "-> Bursting env into config"
envsubst '$RFP_DOMAIN_NAME' < /home/frappe/temp_nginx.conf > /etc/nginx/conf.d/default.conf
envsubst '$BENCH_PATH,$NODE_PATH' < /home/frappe/temp_supervisor.conf > /home/frappe/supervisor.conf

echo "-> Starting nginx"
nginx

echo "-> Starting supervisor"
/usr/bin/supervisord -c /home/frappe/supervisor.conf
