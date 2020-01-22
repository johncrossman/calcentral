#!/bin/bash

######################################################
#
# Download and deploy the "calcentral.knob"
#
######################################################

LOG=$(date +"${PWD}/log/update-build_%Y-%m-%d.log")
LOGIT="tee -a ${LOG}"

function log_error {
  echo | ${LOGIT}
  echo "$(date): [ERROR] ${1}" | ${LOGIT}
  echo | ${LOGIT}
}

function log_info {
  echo "$(date): [INFO] ${1}" | ${LOGIT}
}

echo | ${LOGIT}

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Enable rvm and use the correct Ruby version and gem set.
[[ -s "${HOME}/.rvm/scripts/rvm" ]] && . "${HOME}/.rvm/scripts/rvm"
source .rvmrc

# Update source tree (from which these scripts run)
log_info "========================================="
log_info "Updating Junction source code from: ${REMOTE}, branch: ${BRANCH}"

git fetch "${REMOTE}" 2>&1 | ${LOGIT}
git fetch -t "${REMOTE}" 2>&1 | ${LOGIT}
git reset --hard HEAD 2>&1 | ${LOGIT}
git checkout -qf "${BRANCH}" 2>&1 | ${LOGIT}

log_info "Last commit in source tree:"
git log -1 | ${LOGIT}

echo | ${LOGIT}
echo "------------------------------------------" | ${LOGIT}
log_info "Stopping Junction..."

./script/stop-torquebox.sh

rm -rf deploy
mkdir deploy
cd deploy || exit 1

echo | ${LOGIT}
echo "------------------------------------------" | ${LOGIT}

log_info "Fetching new calcentral.knob from ${WAR_URL}"

# Get calcentral.knob file from Bamboo (deprecated deployment strategy)
WAR_URL=${WAR_URL:="https://bamboo.media.berkeley.edu/bamboo/browse/MYB-MVPWAR/latest/artifact/JOB1/warfile/calcentral.knob"}
curl -k -s ${WAR_URL} > calcentral.knob

log_info "Unzipping knob..."

jar xf calcentral.knob

if [ ! -d "versions" ]; then
  log_error "Missing or malformed calcentral.knob file!"
  exit 1
fi
log_info "Last commit in calcentral.knob:"
cat versions/git.txt | ${LOGIT}

# Fix permissions on files that need to be executable
chmod u+x ./script/*
chmod u+x ./vendor/bundle/jruby/2.3.0/bin/*
find ./vendor/bundle -name standalone.sh | xargs chmod u+x

echo | ${LOGIT}
echo "------------------------------------------" | ${LOGIT}
log_info "Deploying new Junction knob..."

bundle exec torquebox deploy calcentral.knob --env=production | ${LOGIT}

MAX_ASSET_AGE_IN_DAYS=${MAX_ASSET_AGE_IN_DAYS:="45"}
DOC_ROOT="/var/www/html/junction"

log_info "Copying assets into ${DOC_ROOT}"
cp -Rvf public/assets ${DOC_ROOT} | ${LOGIT}

log_info "Deleting old assets from ${DOC_ROOT}/assets"
find ${DOC_ROOT}/assets -type f -mtime +${MAX_ASSET_AGE_IN_DAYS} -delete | ${LOGIT}

log_info "Copying bCourses static files into ${DOC_ROOT}"
cp -Rvf public/canvas ${DOC_ROOT} | ${LOGIT}

log_info "Copying OAuth static files into ${DOC_ROOT}"
cp -Rvf public/oauth ${DOC_ROOT} | ${LOGIT}

log_info "Congratulations, deployment complete."

echo | ${LOGIT}

exit 0
