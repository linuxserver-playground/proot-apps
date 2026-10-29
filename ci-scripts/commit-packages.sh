#! /bin/bash
set -e

# Commit the package_versions.txt files the app jobs uploaded (artifacts/<app>/package_versions.txt) to master.
# The push uses GITHUB_TOKEN, so it starts no workflow: the images are already published. Someone may have pushed
# meanwhile, so rebase onto it; when both touched one app's list, this run's newer scan wins.

# shellcheck source=ci-scripts/lib.sh
source "$(dirname "$0")/lib.sh"

if [[ -d artifacts ]]; then
  rsync -a artifacts/ apps/
fi
git config user.name 'Package Bot'
git config user.email 'package-bot@users.noreply.github.com'
git add apps
if git diff --cached --quiet; then
  echo "No package changes"
  exit 0
fi
git diff --cached --stat
git commit -q -m "Bot Updating Package Versions"
retry 5 10 bash -c 'git pull --rebase -X theirs -q origin master && git push origin HEAD:master'
