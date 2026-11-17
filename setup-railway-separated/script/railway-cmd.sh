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

# Install the Australian localisation (built into the image) on the site, once.
# Covers new sites and ones created before the app was added to the image.
if ! su frappe -c "bench --site ${RFP_DOMAIN_NAME} list-apps" 2>/dev/null | grep -qw erpnext_australian_localisation; then
    echo "-> Installing Australian localisation"
    su frappe -c "bench --site ${RFP_DOMAIN_NAME} install-app erpnext_australian_localisation"
fi

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
