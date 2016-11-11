#!/bin/bash

# This is set for tags and release/hotfix branch
# the job has to be a fresh checkout of the repo

set -e

func-update-master-from-tag() {
  git fetch --tags origin
  git checkout master
  git merge -m "${PARAM_GIT_TAG} merge" --no-ff ${PARAM_GIT_TAG}
  git push origin master && echo "master branch updated."
  if [ ! "$(git diff ${PARAM_GIT_BRANCH} origin/master)" = "" ]; then echo "Differences exist between ${PARAM_GIT_BRANCH} and master" && exit 101; fi
}

# This assumes that the checkout:
#   - is new
#   - on origin/release (for releases) -or- origin/hotfix (for hotfixes)
func-update-master-from-branch() {
  git merge origin/master
  git checkout master
  git merge -m "${PARAM_GIT_BRANCH}-branch merge" --no-ff origin/${PARAM_GIT_BRANCH}
  git push origin master
  if [ "$(git diff origin/${PARAM_GIT_BRANCH} origin/master)" = "" ]; then git push origin :${PARAM_GIT_BRANCH}; fi
}


if [ ! -z "$PARAM_GIT_TAG" ]; then
  func-update-master-from-tag
else
  func-update-master-from-branch
fi
