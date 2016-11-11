#!/bin/bash

################################################################################
#
# script use - $0 {path-to-prop-file} {dev|qa}
# script use - $0 {path-to-prop-file} {dev}
# script use - $0 {path-to-prop-file} {qa} {MVN_STRT_VER} {MVN_END_VER}
#
################################################################################

usage() {
	echo -e "\nThis script requires path to existing prop-file and uses a second argument to define an environment variable"
	echo -e "Example: $0 {path-to-prop-file} {DEV}"
	echo -e "Example: $0 {path-to-prop-file} {QA} {MVN_STRT_VER} {MVN_END_VER} {release|snapshot}\n"
	echo -e "Example: $0 {path-to-prop-file} {STAGE} {MVN_STRT_VER} {MVN_END_VER} {release|snapshot}\n"
	exit 1
}

# check if number of parameters is 2 at least
if [ $# -lt 2 ]; then usage; fi

if [ "$2" != "DEV" ] && [ "$2" != "RB" ]; then
	if [ "$3" == "alert_policy_enabled" ]; then ALERT_POLICY_ENABLED="$4"; elif [ "$3" == "from_build" ]; then FROM_BUILD="true"; elif [ "$3" == "" ]; then usage; elif [ "$4" == ""  ]; then usage; elif [ "$5" == ""  ]; then usage; fi
fi

# check if prop-file exists and load it
if [ -f "$1" ]; then TMP=`mktemp`; cp -f "$1" $TMP; /usr/local/bin/enctool props $TMP; source $TMP; rm -f $TMP; else usage; fi
# uppercase dev-env name
# NAME=`echo $2 | tr '[:lower:]' '[:upper:]'`

# set environment specific variables
ENV=$(eval echo \$${2}_ENV)
JENKINS_ARTIFACT_SRC_DIR=$(eval echo \$${2}_JENKINS_ARTIFACT_SRC_DIR)

#APP_SERVERS=$(eval echo \$${2}_APP_SERVERS)
eval APP_SERVERS=( \${${2}"_APP_SERVERS"[@]} )

APP_URL=$(eval echo \$${2}_APP_URL)
NEWRELIC_APPNAME=$(eval echo \$${2}_NEWRELIC_DEPLOYMENT_APPNAME)
NEWRELIC_ALERT_POLICY_URL=$(eval echo \$${2}_NEWRELIC_ALERT_POLICY_URL)
NEWRELIC_APP_ID=$(eval echo \$${2}_NEWRELIC_APP_ID)
ELB_NAME=$(eval echo \$${2}_ELB_NAME)

# set common script values
MVN_STRT_VER=$3
MVN_END_VER=$4
MVN_PROFILE=$5
MVN_EXEC="/var/lib/jenkins/tools/hudson.tasks.Maven_MavenInstallation/Maven_-_303/bin/mvn"

if [ "${DEPLOY_RELEASE_ARTIFACT_RANGE}" = "true" ]; then
  MVN_GETARTIFACT_POM="/var/lib/jenkins/workspace/all-projects-property-files/com/nbcuni/maven-common/get-artifact/standard_pom-release-v-range.xml"
else
  MVN_GETARTIFACT_POM="/var/lib/jenkins/workspace/all-projects-property-files/com/nbcuni/maven-common/get-artifact/standard_pom.xml"
fi

if [ "$2" == "STAGE" ]
	then
	APPSERVER_STARTUP_TIMEOUT=1200
else
	APPSERVER_STARTUP_TIMEOUT=360
fi
APPSERVER_DRAINAGE_TIMEOUT=300

NEWRELIC_AGENT="newrelic.jar"
NEWRELIC_AGENT_SRC="/opt/newrelic"

APP_VERSION_REGEX='s/^[a-z\-]*-\([0-9\.]*[0-9]\)\(-[A-Z]\+\)\?.*$/\1\2/p'

echo ""
echo ""
echo -e "*************************************************************************************"
echo -e "***"
echo -e "***	Starting Deployment for the ${APP_NAME} on the ${ENV} environment"
echo -e "***"
echo -e "*************************************************************************************"
echo ""
echo ""

################################################################################
#
# func-getartifactfromnexus()
#
# This function call is used to retrieve the latest artifact from Nexus based
# on the version ranges specified within the Jenkins command.  This is only used
# for QA and Up environments.  The purpose of this is to ensure integrity of the
# artifact tested by the SQE team and no longer require rebuilding the artifact
# after their validation.
#
################################################################################
func-getartifactfromnexus() {
echo -e "*************************************************************************************"
echo -e "***	Getting the latest artifact from the Maven Respository (Nexus)"
echo -e "*************************************************************************************"

	cp "${MVN_GETARTIFACT_POM}" "${WORKSPACE}/pom.xml"

	echo -e "\t[echo] Getting latest WAR from Nexus (${MVN_STRT_VER} - ${MVN_END_VER})"
	${MVN_EXEC} clean -q ${MVN_GOAL} -Dgroupid=${MVN_GRP_ID} \
		-Dartifactid=${MVN_ARTFCT_ID} -Dartifacttype=${MVN_PKG_TYPE} \
		-P${MVN_PROFILE} -Dstartversion=${MVN_STRT_VER} -Dendversion=${MVN_END_VER} -Dartifactversion=${MVN_END_VER}

	if [ ! -f "${JENKINS_ARTIFACT_SRC_DIR}/dependency/"*.war ]
		then
		echo -e "\t[ERROR] Exiting Deployment - no WAR File"
		exit 2
	fi


	WAR_FILE=`ls "${JENKINS_ARTIFACT_SRC_DIR}"/dependency/*.war`
	echo -e "\t[echo] Latest Artifact that will be deployed to the App Servers"
	echo -e "\t[echo] ${WAR_FILE}"

	echo -e "\t[echo] Copying ${WAR_FILE} to ${WORKSPACE}/target/"
	cp "${WAR_FILE}" ${JENKINS_ARTIFACT_SRC_DIR}

	APP_VERSION="`cd ${JENKINS_ARTIFACT_SRC_DIR} ; echo *.war | sed -n ${APP_VERSION_REGEX}`"

	JENKINS_TEMP_ARTIFACT="`cd ${JENKINS_ARTIFACT_SRC_DIR} ; ls -1 *.war`"
}


################################################################################
#
# func-getartifactfrombuild()
#
# This function call is used to check whether the artifact was successfully built
# during the build process. This is only used the DEV environment only.  This will
# always deploy the latest artifact built every Git Commit/Push.
#
################################################################################
func-getartifactfrombuild() {
	echo -e "*************************************************************************************"
	echo -e "***	Getting the latest artifact from most recent build"
	echo -e "*************************************************************************************"

	if [ ! -f "${JENKINS_ARTIFACT_SRC_DIR}"/*.war ]
		then
		echo -e "\t[echo] Exiting Deployment - no file for deployment exists."
		echo -e "\t[echo] Here is the listing of the workspace:"
    		ls -1 ${JENKINS_ARTIFACT_SRC_DIR}
		exit 2
	fi

	JENKINS_TEMP_ARTIFACT="`cd ${JENKINS_ARTIFACT_SRC_DIR} ; ls -1 *.war`"

	APP_VERSION="`cd ${JENKINS_ARTIFACT_SRC_DIR} ; echo *.war | sed -n ${APP_VERSION_REGEX}`"
}


################################################################################
#
# func-stateserver() {
#
# Just displays informational stuff on the console.
#
################################################################################
func-stateserver() {

	echo -e "*************************************************************************************"
	echo -e "***	Deployment / Environment Information"
	echo -e "*************************************************************************************"

	echo -e "\t[echo] Server: ${i}"
	echo -e "\t[echo] Application: ${APP_NAME}"
	echo -e "\t[echo] Application Version: ${APP_VERSION}"
	echo -e "\t[echo] Environment: ${ENV}"
	echo ""
}


################################################################################
#
# func-stageserver() {
#
# Performs the copying of artifacts and configurations if any to the target
# server.
#
################################################################################
func-stageserver() {

	echo -e "\t*************************************************************************************"
	echo -e "\t***	Staging the artifacts onto the App Server ${i}"
	echo -e "\t*************************************************************************************"

	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "rm -rf ${APPSERVER_DEPLOY_DIR}/*"

	echo -e "\t\t[echo] Creating ${APPSERVER_DEPLOY_DIR} folder if the folder doesn't exist"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ ! -d ${APPSERVER_DEPLOY_DIR} ]; then mkdir -p ${APPSERVER_DEPLOY_DIR}; fi"

	echo -e "\t\t[echo] Sending  ${JENKINS_TEMP_ARTIFACT} to ${i}:${APPSERVER_DEPLOY_DIR} folder"
	scp -i  ${JENKINS_PEM_FILE} "${JENKINS_ARTIFACT_SRC_DIR}/${JENKINS_TEMP_ARTIFACT}" ${JENKINS_REMOTE_USER}@${i}:${APPSERVER_DEPLOY_DIR}


	echo -e "\t\t[echo] Renaming ${JENKINS_TEMP_ARTIFACT} to ${ARTIFACT}"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "mv ${APPSERVER_DEPLOY_DIR}/*.war ${APPSERVER_DEPLOY_DIR}/${ARTIFACT}"


	echo -e "\t\t[echo] Chmod ${JENKINS_TEMP_ARTIFACT} to the correct permissions"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "chmod 744 ${APPSERVER_DEPLOY_DIR}/${ARTIFACT}"

 	echo -e "\t\t[echo] Sending property files to ${i}:${APPSERVER_DEPLOY_DIR} folder"
  	eval $(ssh-agent) ; ssh-add ${JENKINS_PEM_FILE} &> ${ARTIFACT}.out ; rsync -rltvzq --exclude deploy*.* \
    		-e ssh ${JENKINS_CI_CONFIGS}/  ${JENKINS_REMOTE_USER}@${i}:${APPSERVER_DEPLOY_DIR}
}


################################################################################
#
# func-stageapp() {
#
# Performs the copying of artifacts and configurations from the staged location
# /deployments_<artifact> of the appserver to the correct location of the home
# directory of the application on the same server.
#
################################################################################
func-stageapp() {


	echo -e "\t*************************************************************************************"
	echo -e "\t***	Moving the artifacts onto the App Home Directory (${APP_HOME_DIR})"
	echo -e "\t*************************************************************************************"

	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "rm -rf ${APP_HOME_DIR}"

	echo -e "\t\t[echo] Remove old Artifacts from tomcat/webapps/ directory"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "rm -rf ${CATALINA_HOME}/webapps/${APP_CANONICAL_NAME}.war"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "rm -rf ${CATALINA_HOME}/webapps/${APP_CANONICAL_NAME}"

	#also remove just in case old artifact alias still exists.
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "rm -rf ${CATALINA_HOME}/webapps/${APP_DOCBASE_NAME}.war"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "rm -rf ${CATALINA_HOME}/webapps/${APP_DOCBASE_NAME}"

	echo -e "\t\t[echo] Copy war file from ${APPSERVER_DEPLOY_DIR} to ${CATALINA_HOME}/webapps"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "cp ${APPSERVER_DEPLOY_DIR}/${ARTIFACT} ${CATALINA_HOME}/webapps/"


	echo -e "\t\t[echo] Cleaning catalina.out log file"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "cat /dev/null > ${CATALINA_HOME}/logs/catalina.out"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ ! -d ${APP_HOME_DIR}/log} ]; then mkdir -p ${APP_HOME_DIR}/log; fi"

	echo -e "\t\t[echo] Copying the property files onto the application directory (${APP_HOME_DIR}/conf)"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ ! -d ${APP_HOME_DIR}/conf} ]; then mkdir -p ${APP_HOME_DIR}/conf; fi"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "cp -f ${APPSERVER_DEPLOY_DIR}/*.properties ${APP_HOME_DIR}/conf"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "chmod go-rwx -R ${APP_HOME_DIR}/conf"

	echo -e "\t\t[echo] Copying the New Relic Config File onto the application directory (${APP_HOME_DIR}/agent)"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ ! -d ${APP_HOME_DIR}/agent} ]; then mkdir -p ${APP_HOME_DIR}/agent; fi"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "cp -f ${APPSERVER_DEPLOY_DIR}/*.yml ${APP_HOME_DIR}/agent"

	echo -e "\t\t[echo] Copying Setenv.sh onto the tomcat bin directory"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ -f ${APPSERVER_DEPLOY_DIR}/setenv.sh ]; then cp ${APPSERVER_DEPLOY_DIR}/setenv.sh ${CATALINA_HOME}/bin/; fi"
# 	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "cp ${APPSERVER_DEPLOY_DIR}/setenv.sh ${CATALINA_HOME}/bin/"

  echo -e "\t\t[echo] Copying server.xml onto the tomcat conf directory"
  ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ -f ${APPSERVER_DEPLOY_DIR}/server.xml ]; then cp ${APPSERVER_DEPLOY_DIR}/server.xml ${CATALINA_HOME}/conf/; fi"
  echo -e "\t\t[echo] Copying tomcat-users.xml onto the tomcat conf directory"
  ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ -f ${APPSERVER_DEPLOY_DIR}/tomcat-users.xml ]; then cp ${APPSERVER_DEPLOY_DIR}/tomcat-users.xml ${CATALINA_HOME}/conf/; fi"

	echo -e "\t\t[echo] Setting Up New Relic Agent for Tomcat"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ ! -d ${APP_HOME_DIR}/agent ]; then mkdir -p ${APP_HOME_DIR}/agent; fi"
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "cp ${NEWRELIC_AGENT_SRC}/${NEWRELIC_AGENT} ${APP_HOME_DIR}/agent"
}


################################################################################
#
# func-startappserver() {
#
# Starting the application
#
################################################################################
func-startappserver() {

	echo -e "\t*************************************************************************************"
	echo -e "\t***	Starting Tomcat for ${APP_CANONICAL_NAME}"
	echo -e "\t*************************************************************************************"

	if [ ${ENV} == "STAGE" ] || [ ${ENV} == "PROD" ] || [ ${REMOTE_APP_SCRIPT_SUDO} == "true" ]; then
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "sudo /etc/init.d/${REMOTE_APP_SCRIPT} start"
	else
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "/etc/init.d/${REMOTE_APP_SCRIPT} start"
	fi
}


################################################################################
#
# func-stopappserver() {
#
# Stopping the application
#
################################################################################
func-stopappserver() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Stopping Tomcat for ${APP_CANONICAL_NAME}"
	echo -e "\t*************************************************************************************"

	if [ ${ENV} == "STAGE" ] || [ ${ENV} == "PROD" ] || [ ${REMOTE_APP_SCRIPT_SUDO} == "true" ]; then
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "sudo /etc/init.d/${REMOTE_APP_SCRIPT} stop"
	else
		ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "/etc/init.d/${REMOTE_APP_SCRIPT} stop"
	fi

	sleep 15

	#Validate if the tomcat instance has been killed.  If not, kill it.
	func-killprocess
}


################################################################################
#
# func-killprocess() {
#
# Validating that the tomcat process has been killed already and if not, forcefully
# kill the session.
#
################################################################################
func-killprocess() {
	echo -e "\t\t[echo] Auditing Java Processes"
# 	for pid in `ps -ef | tomcat | awk '{print $2}'` ; do kill $pid ; done
	pidarray="`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} ps x | grep tomcat | grep -v grep | awk -F ' ' '{print $1}' | tr '\n' ' '`"
		for pid in "${pidarray[@]}"
		do
			if [ -n "${pid}" ]
				then
				echo -e "\t\t[echo] Found Process PID: ${pid}"
				echo -e "\t\t[echo] Tomcat was not killed by the 'STOP' command.  Killing Tomcat process...."
				echo ""
				ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "kill -9 ${pid}"
				echo -e "\t\t[echo] Tomcat PID ${pid} killed.... "
				echo ""
			fi
		done

}


################################################################################
#
# func-testhttpresponse() {
#
# Validation that the application is started within the given timeout period.
# Fails the build when the script does not get an HTTP 200.
#
################################################################################
func-testhttpresponse() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Deployment Verification for ${i} - Get Basic Response"
	echo -e "\t*************************************************************************************"

	echo -e "\t\t[echo] Waiting for App Server to start. Waiting up to ${APPSERVER_STARTUP_TIMEOUT} seconds...  Waiting response from (http://${i}${APP_URL})"
	http_response=`curl -s --max-time 1 --connect-timeout 1 \
		-H "Cache-Control: no-cache, max-age=0" \
		-H "Pragma: no-cache" -w "%{http_code}\\n" "http://${i}${APP_URL}" -o /dev/null`
	echo -e "\t\t[echo]Initial HTTP Response Code:  ${http_response}"
	ctr=0

	while [ ! ${http_response} -eq 200 ]; do
		http_response=`curl -s --max-time 1 --connect-timeout 1 \
		-H "Cache-Control: no-cache, max-age=0" \
		-H "Pragma: no-cache" -w "%{http_code}\\n" "http://${i}${APP_URL}" -o /dev/null`
		sleep 1
		let ctr=ctr+1

		if [ $ctr = ${APPSERVER_STARTUP_TIMEOUT} ]
			then
			echo -e "\t\t[echo] App Server (http://${i}${APP_URL}) not yet started after ${APPSERVER_STARTUP_TIMEOUT} seconds."
			echo -e "\t\t[ERROR] Marking Deployment as Failed."
			echo ""
			exit 1
		fi
	done

	if [ ${http_response} -eq 200 ]
		then
		echo -e "\t\t[echo] App Server was successfully started after ${ctr} seconds."
		echo -e "\t\t[echo] Application can be accessed via http://${i}${APP_URL}"
		echo -e "\t\t[echo] Deployment complete."
		echo ""
	fi
}

################################################################################
#
# func-updatenewrelic() {
#
# Updating the deployment information on New Relic
#
################################################################################

func-updatenewrelic(){


	if [ "${NEWRELIC_DEPLOYMENT_APIKEY}" != "" ] && [ "${NEWRELIC_APPNAME}" != "$2" ] ; then
		echo -e "\t*************************************************************************************"
		echo -e "\t***	Updating New Relic Deployment Information"
		echo -e "\t*************************************************************************************"

		curl -H "x-api-key:${NEWRELIC_DEPLOYMENT_APIKEY}" \
			-d "deployment[app_name]=${NEWRELIC_APPNAME}" \
			-d "deployment[description]=Deployed App Version: ${APP_VERSION}" \
			-d "deployment[revision]=${APP_VERSION}" \
			-d "deployment[changelog]=Deployed App Version: ${APP_VERSION}" \
			https://api.newrelic.com/deployments.xml

		echo -e "\t[echo] Deployment Information sent to New Relic."
	else
		echo -e "\t[echo] This application is not configured for New Relic Deployment Update.  Skipping."
	fi
}

################################################################################
#
# func-deploy-enctool
#
# Send over encryption tool to stage or prod enviornment
#
################################################################################

function func-deploy-enctool {
	echo -e "\t[echo] Updating enctool."
	ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "if [ ! -d "tools" ]; then mkdir tools; fi"
	scp -i ${JENKINS_PEM_FILE} ${JENKINS_HOME}/tools/encrypt/enctool ${JENKINS_REMOTE_USER}@${i}:tools/
}

################################################################################
#
# func-newrelic-alert-control
#
################################################################################

function func-newrelic-alert-control {
	if [ ! -z "$NEWRELIC_ALERT_APIKEY" ]; then
	    for POLICY_URL in ${NEWRELIC_ALERT_POLICY_URL}; do
		curl -X PUT "${POLICY_URL}" \
		     -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" -i \
		     -H 'Content-Type: application/json' \
		     -d \
		'{
		  "alert_policy": {
		     "enabled": '"${1}"'
		   }
		}'
	    done
	fi
}

################################################################################
#
# AMAZON INTEGRATION: Deregister node from ELB
#
################################################################################
function func-deregister-node() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Deregistering ${i} node from ${ELB_NAME} load balancer"
	echo -e "\t*************************************************************************************"
	INSTANCE=`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "wget -q -O- http://169.254.169.254/latest/meta-data/instance-id"`
	echo "Instance ID detected: ${INSTANCE}"
	REGION=`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g'"`
	echo "Region detected: ${REGION}"
	aws elb deregister-instances-from-load-balancer --load-balancer-name ${ELB_NAME} --instances ${INSTANCE} --region ${REGION}
}

################################################################################
#
# AMAZON INTEGRATION: Register node with ELB
#
################################################################################
function func-register-node() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Registering ${i} node with ${ELB_NAME} load balancer"
	echo -e "\t*************************************************************************************"
	INSTANCE=`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "wget -q -O- http://169.254.169.254/latest/meta-data/instance-id"`
	echo "Instance ID detected: ${INSTANCE}"
	REGION=`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} "wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g'"`
	echo "Region detected: ${REGION}"
	aws elb register-instances-with-load-balancer --load-balancer-name ${ELB_NAME} --instances ${INSTANCE} --region ${REGION}
}

################################################################################
#
# NEWRELIC INTEGRATION: Connection drainage per node
#
################################################################################
function func-connection-drainage() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Connection drainage per ${i} node"
	echo -e "\t*************************************************************************************"
	HOSTNAME=`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} hostname`
	echo "Node hostname detected: ${HOSTNAME}"
	INSTANCE=`curl -X GET https://api.newrelic.com/v2/applications/${NEWRELIC_APP_ID}/instances.json -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" | json application_instances | json -a id host | grep ${HOSTNAME} | awk '{ print $1 }'`
	echo "NewRelic instance ID detected: ${INSTANCE}"
	CALL_COUNT=`curl -s --max-time 1 --connect-timeout 1 -X GET https://api.newrelic.com/v2/applications/${NEWRELIC_APP_ID}/instances/${INSTANCE}/metrics/data.json -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" -i -d 'names[]=HttpDispatcher&values[]=call_count&period=60' | json metric_data.metrics[0].timeslices[29].values.call_count | tail -n 1`
	ctr=0
	while [ "${CALL_COUNT}" == "" ] || [ ${CALL_COUNT} -gt 0 ]; do
		CALL_COUNT=`curl -s --max-time 1 --connect-timeout 1 -X GET https://api.newrelic.com/v2/applications/${NEWRELIC_APP_ID}/instances/${INSTANCE}/metrics/data.json -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" -i -d 'names[]=HttpDispatcher&values[]=call_count&period=60' | json metric_data.metrics[0].timeslices[29].values.call_count | tail -n 1`
		sleep 1
		let ctr=ctr+1
		if [ $ctr = ${APPSERVER_DRAINAGE_TIMEOUT} ]; then echo "[WARN] Exiting by connection drainage timeout after ${APPSERVER_DRAINAGE_TIMEOUT} seconds"; break; fi
	done
	echo "Connection drainage completed with ${CALL_COUNT} calls during last 60 seconds"
}

################################################################################
#
# NEWRELIC INTEGRATION: Service is processing requests verification per node
#
################################################################################
function func-connection-verification() {
	echo -e "\t*************************************************************************************"
	echo -e "\t***	Verify that ${i} node is processing requests"
	echo -e "\t*************************************************************************************"
	HOSTNAME=`ssh -i ${JENKINS_PEM_FILE} ${JENKINS_REMOTE_USER}@${i} hostname`
	echo "Node hostname detected: ${HOSTNAME}"
	INSTANCE=`curl -X GET https://api.newrelic.com/v2/applications/${NEWRELIC_APP_ID}/instances.json -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" | json application_instances | json -a id host | grep ${HOSTNAME} | awk '{ print $1 }'`
	echo "NewRelic instance ID detected: ${INSTANCE}"
	CALL_COUNT=`curl -s --max-time 1 --connect-timeout 1 -X GET https://api.newrelic.com/v2/applications/${NEWRELIC_APP_ID}/instances/${INSTANCE}/metrics/data.json -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" -i -d 'names[]=HttpDispatcher&values[]=call_count&period=60' | json metric_data.metrics[0].timeslices[29].values.call_count | tail -n 1`
	ctr=0
	while [ "${CALL_COUNT}" == "" ] || [ ${CALL_COUNT} -eq 0 ]; do
		CALL_COUNT=`curl -s --max-time 1 --connect-timeout 1 -X GET https://api.newrelic.com/v2/applications/${NEWRELIC_APP_ID}/instances/${INSTANCE}/metrics/data.json -H "X-Api-Key:${NEWRELIC_ALERT_APIKEY}" -i -d 'names[]=HttpDispatcher&values[]=call_count&period=60' | json metric_data.metrics[0].timeslices[29].values.call_count | tail -n 1`
		sleep 1
		let ctr=ctr+1
		if [ $ctr = ${APPSERVER_DRAINAGE_TIMEOUT} ]; then echo "[WARN] We don't see new connections happens to the node after ${APPSERVER_DRAINAGE_TIMEOUT} seconds. Probably there is no new requests"; break; fi
	done
	echo "Verification completed with ${CALL_COUNT} calls during last 60 seconds"
}

################################################################################
#
# WIKI INTEGRATION: Post comment to release page
#
################################################################################
function func-update-wiki-page() {
	if [ "${WIKI_USERNAME}" != "" ] && [ "${WIKI_PASSWORD}" != "" ] ; then
		PAGE=$(date +%D" Release")
		echo -e "\t*************************************************************************************"
		echo -e "\t***	Post comment about ${NEWRELIC_APPNAME} v${APP_VERSION} deployment to \"${PAGE}\" page"
		echo -e "\t*************************************************************************************"
		${JENKINS_HOME}/workspace/all-projects-property-files/com/nbcuni/common/add_comment.py ${WIKI_USERNAME} ${WIKI_PASSWORD} "${PAGE}" "${NEWRELIC_APPNAME} v${APP_VERSION} deployed"
	fi
}

################################################################################
#
# THIS IS WHERE IT STARTS
#
#
################################################################################
if [ "${ALERT_POLICY_ENABLED}" != "" ]; then
	func-newrelic-alert-control ${ALERT_POLICY_ENABLED}
	exit 0
fi

if [ "${ENV}" == "DEV" ] || [ "${ENV}" == "RB" ] || [ "${FROM_BUILD}" == "true" ]; then
	func-getartifactfrombuild
else
	func-getartifactfromnexus
fi

for i in "${APP_SERVERS[@]}"
	do
		func-deploy-enctool

		func-stateserver
		func-stageserver

		func-newrelic-alert-control false
		if [ "${DEPLOY_WITHIN_ELB}" == "true" ]; then
			func-deregister-node
			func-connection-drainage
		fi

		func-stopappserver
		func-stageapp
		func-startappserver
		func-testhttpresponse

		if [ "${DEPLOY_WITHIN_ELB}" == "true" ]; then
			func-register-node
			func-connection-verification
		fi
		func-newrelic-alert-control true
	done

func-updatenewrelic
#if [[ ${ENV} == PROD* ]] ; then
#	func-update-wiki-page
#fi
