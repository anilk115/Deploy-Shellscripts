#!/bin/bash

usage() {
  echo -e "\nThis script requires path to existing prop-file"
  echo -e "Example: $0 {path-to-prop-file}\n"
  exit 1
}

function last_stable_build() {
  wget ${JENKINS_URL}/job/$1/lastStableBuild/api/json?tree=actions%5bbuildsByBranchName%5brevision%5bSHA1%5d%5d%5d --http-user=${USERNAME} --http-password=${PASSWORD} --auth-no-challenge -q --no-check-certificate -O - | \
    python -c 'import sys, json; print json.load(sys.stdin)["actions"][3]["buildsByBranchName"]["refs/remotes/origin/develop"]["revision"]["SHA1"]'
}

# check if number of parameters is 2 at least
if [ $# -lt 1 ]; then usage; fi

# check if prop-file exists and load it
if [ -f "$1" ]; then TMP=`mktemp`; cp -f "$1" $TMP; /usr/local/bin/enctool props $TMP; source $TMP; rm -f $TMP; else usage; fi


echo ""
echo "---------------------------"
echo ""

for i in ${!JOBS[@]}; do
  JOB=${JOBS[$i]}
  REPO=${REPOS[$i]}

  SHA1=$(last_stable_build ${JOB})

  if [ "${SHA1}" != "" ]; then
    echo "Create release branch from ${SHA1} for ${REPO}"

    git clone -q git@github.com:NBCUOTS/${REPO}.git ./${REPO} 2>/dev/null
    cd ./${REPO}
    git push -f origin :release
    git branch release ${SHA1}
    git push origin release
    cd ..
    rm -rf ./${REPO}
  fi
done

echo ""
echo "---------------------------"
echo ""
