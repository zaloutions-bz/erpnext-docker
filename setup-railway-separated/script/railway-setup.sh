#!/bin/bash
set -e

require_var() {
    if [ -z "${!1}" ]; then
        echo "ERROR: $1 is not set" >&2
        exit 1
    fi
}

require_var RFP_DOMAIN_NAME
require_var RFP_SITE_ADMIN_PASSWORD
require_var FRAPPE_DB_PASSWORD

SITES_DIR="/home/frappe/frappe-bench/sites"
SETUP_MARKER="${SITES_DIR}/${RFP_DOMAIN_NAME}/.railway-setup-complete"

# --force drops and recreates a site that an interrupted setup left behind.
# railway-cmd.sh passes it only when RFP_RECREATE_SITE names this site.
FORCE_FLAG=""
if [ "$1" = "--force" ]; then
    FORCE_FLAG="--force"
elif [ -d "${SITES_DIR}/${RFP_DOMAIN_NAME}" ]; then
    echo "-> Site ${RFP_DOMAIN_NAME} already exists, skipping setup"
    exit 0
fi

# Never overwrite an existing common_site_config.json: it holds default_site,
# and wiping it leaves every later `bench execute` without a site.
if [ ! -f "${SITES_DIR}/common_site_config.json" ]; then
    echo "-> Create empty common site config"
    su frappe -c "echo '{}' > '${SITES_DIR}/common_site_config.json'"
fi

# The Australian localisation app is built into the image (Dockerfile) and
# installed on the site by railway-cmd.sh after this script.

echo "-> Create new site with ERPNext"
su frappe -c "bench new-site ${RFP_DOMAIN_NAME} ${FORCE_FLAG} \
    --admin-password ${RFP_SITE_ADMIN_PASSWORD} \
    --no-mariadb-socket \
    --db-root-password ${FRAPPE_DB_PASSWORD} \
    --install-app erpnext"

echo "-> Run migrations"
su frappe -c "cd /home/frappe/frappe-bench && bench --site ${RFP_DOMAIN_NAME} migrate"

su frappe -c "bench use ${RFP_DOMAIN_NAME}"

echo "-> Enable scheduler"
su frappe -c "bench --site ${RFP_DOMAIN_NAME} enable-scheduler"

su frappe -c "touch '${SETUP_MARKER}'"
echo "-> Setup complete"
