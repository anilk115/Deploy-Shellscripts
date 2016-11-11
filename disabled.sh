#!/bin/bash

usage() {
  echo -e "\nThis script requires path to existing prop-file"
  echo -e "Example: $0 {path-to-prop-file} {project}\n"
  exit 1
}

# check if number of parameters is 2 at least
if [ $# -lt 2 ]; then usage; fi

# check if prop-file exists and load it
if [ -f "${1}" ]; then TMP=`mktemp`; cp -f "${1}" $TMP; /usr/local/bin/enctool props $TMP; source $TMP; rm -f $TMP; else usage; fi

cd ${JENKINS_HOME}/jobs/${2}
echo "=============================================================================="
grep -r "^  <disabled>true</disabled>" --include config.xml . \
| grep -vi Archived-Jobs \
| awk -F":" '{ print $1 }' \
| sed 's/jobs/job/g' \
| sed 's#/config.xml##g' \
| eval sed 's#^\.#${JENKINS_URL}/job/${2}#g' \
| while read line; do
  echo -n "${line} - "
  wget ${line}/lastBuild/buildTimestamp --http-user=${USERNAME} --http-password=${PASSWORD} --auth-no-challenge -q --no-check-certificate -O - || echo -n "N/A"
  echo ""
done
echo "=============================================================================="
