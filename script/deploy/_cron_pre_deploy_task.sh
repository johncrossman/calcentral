#!/bin/bash

##################################################################
#
# In dev/qa environments, a deploy-junction cron job will run
# every N minutes. Before deploying the requested WAR file we
# must checkout the latest deploy scripts, in case the scripts
# in the environment are buggy.
#
##################################################################

# Abort immediately if a command fails
set -e

# Local properties file
deploy_properties="${HOME}/.calcentral_config/junction-deploy.properties"

function getDeployProperty {
  grep "^${1}=" "${deploy_properties}" | cut -d'=' -f2
}

git_branch=$(getDeployProperty 'junction.git.branch')

tmp_dir=$(date +"/var/tmp/junction-git-checkout_%Y-%m-%d_%H%M%S")

mkdir -p "${tmp_dir}"
cd "${tmp_dir}"

git clone https://github.com/ets-berkeley-edu/junction.git
cd junction
git checkout "${git_branch}"

cp -R "${tmp_dir}/junction/script" "${HOME}/calcentral/"
cp "${tmp_dir}/junction/config/deploy.rb" "${HOME}/calcentral/config/"

rm -Rf "${tmp_dir}"

exit 0
