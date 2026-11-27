# Pinned to the base image staging and production were last built on (17-18 Nov
# 2026). The tag version-16-latest moves every week, and the start script never
# runs `bench migrate`, so a rebuild on a newer base would run newer Frappe and
# ERPNext code against the old schema. To upgrade: move the digest (and the
# localisation commit below), redeploy staging, run `bench migrate` there, then
# production.
FROM thspacecode/erpnext-docker:version-16-latest@sha256:57b51b7543c08c5caef6d1fe4081e5eaa82182a502fb5266dab3acf5ba817386

USER root

RUN apt-get update \
    && apt-get install -y -q \
    # [fix] "debconf: delaying package configuration, since apt-utils is not installed"
    apt-utils \
    # [fix] "debconf: unable to initialize frontend: Dialog"
    # https://github.com/moby/moby/issues/27988
    && echo "debconf debconf/frontend select Noninteractive" | debconf-set-selections \
    ###############################################
    # add sudo
    ###############################################
    && apt-get install -y -q sudo \
    && echo "frappe ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    ###############################################
    # add supervisor
    ###############################################
    && apt-get install -y -q \
    supervisor \
    nginx \
    ###############################################
    # clean-up
    ###############################################
    && apt-get autoremove --purge -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/*

# AWS CLI v2, for the offsite backup job (script/offsite-backup.sh). Pinned to
# 2.40.0 (built 2026-11-10) and checked against its zip's SHA-256. When the pin
# was set (2026-11-27) the zip's signature was verified against AWS's published
# key, fingerprint FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C
# (docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html):
# verify the new zip's signature the same way before moving the pin. x86_64 only,
# which is what Railway builds.
ARG AWSCLI_VERSION=2.40.0
ARG AWSCLI_SHA256=4a6d34150060a6bc30160ef1f66e536db64674797bbb582044f93bb9c6e299e7
RUN apt-get update \
    && apt-get install -y -q --no-install-recommends unzip curl ca-certificates \
    && curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
    && echo "${AWSCLI_SHA256}  /tmp/awscliv2.zip" | sha256sum -c - \
    && unzip -q /tmp/awscliv2.zip -d /tmp/awscli \
    && /tmp/awscli/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/awscli /var/lib/apt/lists/* \
    && aws --version

# nginx workers run as www-data and must traverse /home/frappe to serve
# /assets and site public files. The base image published 2026-11-15 makes
# /home/frappe 0770, which turns every static file into a 404.
RUN chmod o+x /home/frappe

# Our server block (conf.d/default.conf) is the default for every hostname;
# Debian's stock default site would otherwise answer unknown hosts.
RUN rm -f /etc/nginx/sites-enabled/default

# Australian localisation: the app's code lives in the image (apps/ is not on
# the volume). get-app adds it to apps.txt and builds its assets, so it must run
# before built_sites is copied. railway-cmd.sh installs it on the site.
# Pinned to the commit its version-16 branch was at when production was built
# (922dfd86, 2026-10-20), for the same reason as the base image's digest.
ARG AU_LOCALISATION_COMMIT=922dfd861fe48d03af19293ceea5277f68d7cb03
RUN su frappe -c "cd /home/frappe/frappe-bench && bench get-app --branch=version-16 https://github.com/Arus-Info/ERPNext-Australian-Localisation.git \
        && cd apps/erpnext_australian_localisation \
        && git fetch --quiet --depth 1 https://github.com/Arus-Info/ERPNext-Australian-Localisation.git ${AU_LOCALISATION_COMMIT} \
        && git checkout --quiet ${AU_LOCALISATION_COMMIT} \
        && cd /home/frappe/frappe-bench && bench build --app erpnext_australian_localisation" \
    && grep -qxF "erpnext_australian_localisation" /home/frappe/frappe-bench/sites/apps.txt

# strata_guard: refuses report requests for a Company the caller may not read
# (apps/strata_guard/README.md). Like the localisation, its code lives in the
# image and railway-cmd.sh installs it on the site.
COPY --chown=frappe ./apps/strata_guard /home/frappe/frappe-bench/apps/strata_guard
RUN su frappe -c "cd /home/frappe/frappe-bench && ./env/bin/python -m pip install --quiet --no-deps -e apps/strata_guard" \
    && (grep -qxF "strata_guard" /home/frappe/frappe-bench/sites/apps.txt \
        || { [ -z "$(tail -c1 /home/frappe/frappe-bench/sites/apps.txt)" ] || echo >> /home/frappe/frappe-bench/sites/apps.txt; \
             echo "strata_guard" >> /home/frappe/frappe-bench/sites/apps.txt; })

# copy built_sites from sites
RUN mkdir -p /home/frappe/frappe-bench/built_sites \
    && cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/built_sites/assets \
    && cp /home/frappe/frappe-bench/sites/apps.json /home/frappe/frappe-bench/built_sites/apps.json \
    && cp /home/frappe/frappe-bench/sites/apps.txt /home/frappe/frappe-bench/built_sites/apps.txt \
    && chown -R frappe:frappe /home/frappe/frappe-bench/built_sites

# copy template
COPY ./template/temp_nginx.conf /home/frappe/temp_nginx.conf
COPY ./template/temp_supervisor.conf /home/frappe/temp_supervisor.conf

# copy script
COPY --chown=frappe --chmod=0755 ./script/railway-setup.sh /home/frappe/frappe-bench/railway-setup.sh
COPY --chown=frappe --chmod=0755 ./script/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY --chown=frappe --chmod=0755 ./script/railway-cmd.sh /usr/local/bin/railway-cmd.sh
COPY --chown=frappe --chmod=0755 ./script/offsite-backup.sh /home/frappe/frappe-bench/offsite-backup.sh

USER root

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/usr/local/bin/railway-cmd.sh"]

EXPOSE 80
