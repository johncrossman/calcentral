#!/bin/bash
# Script to create user CSV file in "tmp/canvas" and upload it to Canvas.

# Make sure the normal shell environment is in place, since it may not be
# when running as a cron job.
source "$HOME/.bash_profile"

cd $( dirname "${BASH_SOURCE[0]}" )/..

LOG=`date +"$PWD/log/canvas_refresh_users_%Y-%m-%d.log"`
LOGIT="tee -a $LOG"

# Enable rvm and use the correct Ruby version and gem set.
[[ -s "$HOME/.rvm/scripts/rvm" ]] && . "$HOME/.rvm/scripts/rvm"
source .rvmrc

export RAILS_ENV=${RAILS_ENV:-production}
export LOGGER_STDOUT=only
export LOGGER_LEVEL=INFO
export JRUBY_OPTS="-Xcompile.invokedynamic=false -J-XX:+UseConcMarkSweepGC -J-XX:+CMSPermGenSweepingEnabled -J-XX:+CMSClassUnloadingEnabled -J-Xmx1024m"

echo | $LOGIT
echo "------------------------------------------" | $LOGIT
echo "`date`: About to run the refresh script..." | $LOGIT

set -o pipefail
/usr/bin/flock -n /tmp/canvas-refresh.lock bundle exec rake canvas:user_accounts_refresh |& $LOGIT
if [[ $? != 0 ]]; then
  echo "Found a /tmp/canvas-refresh.lock file from another refresh in progress; will not run." |& $LOGIT
fi
