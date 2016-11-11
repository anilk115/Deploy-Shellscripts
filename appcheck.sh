#!/bin/bash

usage() {
	echo -e "\nThis script requires path to existing prop-file and uses a second argument to define an environment variable"
	echo -e "Example: $0 {path-to-prop-file} {DEV} {restart}"
	exit 1
}

if [ $# -lt 3 ]; then usage; fi

func-test-exit-status() {
if [ "$?" -ne "0" ]; then
	echo -e "\t[echo] Command did not complete cleanly.  Exiting."
	exit 101
fi
}

func-startappserver() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Starting the Service for ${APP_CANONICAL_NAME}"
	echo -e "\t*************************************************************************************"
	if [ ${REMOTE_APP_SCRIPT_SUDO} == "true" ]; then
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "sudo ${APPSERVER_APPLICATION_EXEC_DIR}/${REMOTE_APP_SCRIPT} start"
	else
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "${APPSERVER_APPLICATION_EXEC_DIR}/${REMOTE_APP_SCRIPT} start"
	fi
        func-test-exit-status
}

func-stopappserver() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Stopping the Service for ${APP_CANONICAL_NAME}"
	echo -e "\t*************************************************************************************"
	if [ ${REMOTE_APP_SCRIPT_SUDO} == "true" ]; then
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "sudo ${APPSERVER_APPLICATION_EXEC_DIR}/${REMOTE_APP_SCRIPT} stop"
	else
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "${APPSERVER_APPLICATION_EXEC_DIR}/${REMOTE_APP_SCRIPT} stop"
	fi

}

func-testhttpresponse() {
	echo -e "\t[echo] Waiting for App Server to start. Waiting up to ${APPSERVER_STARTUP_TIMEOUT} seconds..."
	http_response=`curl -s --max-time 1 --connect-timeout 1 \
		-H "Cache-Control: no-cache, max-age=0" \
		-H "Pragma: no-cache" -w "%{http_code}\\n" "http://${i}${APP_URL}" -o /dev/null`
	echo -e "\t[echo] Trying url -> http://${i}${APP_URL}"
	echo -e "\t[echo] Initial HTTP Response Code: ${http_response}"
	ctr=0

	while [ ! ${http_response} -eq 200 ]; do
		http_response=`curl -s --max-time 1 --connect-timeout 1 \
		-H "Cache-Control: no-cache, max-age=0" \
		-H "Pragma: no-cache" -w "%{http_code}\\n" "http://${i}${APP_URL}" -o /dev/null`
		sleep 1
		let ctr=ctr+1

		if [ $ctr = ${APPSERVER_STARTUP_TIMEOUT} ]
			then
			echo -e "\t[echo] App Server (http://${i}${APP_URL}) not yet started after ${APPSERVER_STARTUP_TIMEOUT} seconds."
			echo -e "\t[ERROR] Marking Job as Failed."
			echo ""
			exit 1
		fi
	done

	if [ ${http_response} -eq 200 ]
		then
		echo -e "\t[echo] App Server was successfully started after ${ctr} seconds."
		echo -e "\t[echo] Application can be accessed via http://${i}${APP_URL}"
		echo ""
	fi
}

# check if prop-file exists and load it
if [ -f "$1" ]; then TMP=`mktemp`; cp -f "$1" $TMP; /usr/local/bin/enctool props $TMP; source $TMP; rm -f $TMP; else usage; fi

ENV=$(eval echo \$${2}_ENV)
JENKINS_ARTIFACT_SRC_DIR=$(eval echo \$${2}_JENKINS_ARTIFACT_SRC_DIR)
if [ -z "$REMOTE_APP_SCRIPT_SUDO" ]; then REMOTE_APP_SCRIPT_SUDO="false"; fi
eval APP_SERVERS=( \${${2}"_APP_SERVERS"[@]} )
APP_URL=$(eval echo \$${2}_APP_URL)

for i in "${APP_SERVERS[@]}"; do
 if [ $3 == "start" ];then
   func-startappserver
   func-testhttpresponse
 elif [ $3 == "stop" ];then
   func-stopappserver
 elif [ $3 == "restart" ];then
   func-stopappserver
   func-startappserver
   func-testhttpresponse
 fi
done