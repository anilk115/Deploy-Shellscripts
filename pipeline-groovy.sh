@Library('pipeline-library') _

//checking parameters and define defaults
def failed
def environment
def branch = null
def tag = null
def project_name = "idx2"
def project_repo = "git@github.com:NBCUOTS/IDX2.git"
def performance_node = "Perf-Test-IDX2"
def slackChannel = "#ci_bots"
def mailRecipients = "dzmitry.zmitrachonak@nbcuni.com,gerald.fontejon@nbcuni.com,gleb.samsonov@nbcuni.com"

def deploy_script = "${env.JENKINS_HOME}/workspace/all-projects-property-files/com/nbcuni/common/deploy_jar.sh"
def prop_file = "${env.JENKINS_HOME}/workspace/all-projects-property-files/com/nbcuni/idx2/env.properties"

//default env
if (params.ENVIRONMENT == null) {
    environment = "DEV"
} else {
    environment = params.ENVIRONMENT.toUpperCase()
}

//branch or tag
if (params.BRANCH == null && params.TAG != null) {
    tag = params.TAG
} else if  (params.BRANCH != null && params.TAG == null) {
    branch = params.BRANCH
} else {
    branch = "develop"
}

def runRegression(environment,project_name) {
    def failed = false
    def mvn_options
    if (params.WITH_SEALIGHTS == true) {
        mvn_options = "-Drally.userid=${params.RALLY_USER} -Drally.password=${params.RALLY_PASSWORD} -Dtest.scope=Regression -Denv=${environment} -Psealights-${environment.toLowerCase()}"
    } else {
        mvn_options = "-Drally.userid=${params.RALLY_USER} -Drally.password=${params.RALLY_PASSWORD} -Dtest.scope=Regression -Denv=${environment}"
    }
    failed = runTests {
        env = environment
        projectName = project_name
        scope = "Regression"
        mvnPom = "test/pom.xml "
        mvnGoals = "clean test -U"
        mvnOptions = mvn_options
    }
    return failed
}

def runIntegration(environment,project_name) {
    def failed = false
    def mvn_options
    if (params.WITH_SEALIGHTS == true) {
        mvn_options = "-Drally.userid=${params.RALLY_USER} -Drally.password=${params.RALLY_PASSWORD} -Dtest.scope=Integration -Denv=${environment} -Psealights-${environment.toLowerCase()}"
    } else {
        mvn_options = "-Drally.userid=${params.RALLY_USER} -Drally.password=${params.RALLY_PASSWORD} -Dtest.scope=Integration -Denv=${environment}"
    }
    failed = runTests {
        env = environment
        projectName = project_name
        scope = "Mailman Integration"
        mvnPom = "test/pom.xml "
        mvnGoals = "clean test -U"
        mvnOptions = mvn_options
    }
    return failed
}

def runPerformance(environment,project_name,performance_node) {
    def failed = false
        def mvn_options
    if (params.WITH_SEALIGHTS == true) {
        mvn_options = "-Dtotal.executions=15 -Dramp.up=1 -Dhostname=${environment.toLowerCase()}.idx2.nbcuext.com -Dpeak=3.0 -Dprotocol=http -Psealights"
    } else {
        mvn_options = "-Dtotal.executions=15 -Dramp.up=1 -Dhostname=${environment.toLowerCase()}-idx2.apps.nbcuni.com -Dpeak=3.0 -Dprotocol=https -Pbuild"
    }
    failed = runPerformance{
        env = environment
        projectName = project_name
        node = performance_node
        mvnPom = "performance/pom.xml "
        mvnGoals = "clean verify -U"
        mvnOptions = mvn_options
    }
    return failed
}

//we're starting here
println "starting pipeline with params: env=${params.ENVIRONMENT} do_deploy=${params.DO_DEPLOY} regression=${params.RUN_REGRESSION} integration=${params.RUN_INTEGRATION} perf=${params.RUN_PERFORMANCE}"

if (params.DISABLE_ALERT == true) {
    alertPolicyControl {
        alertScript = deploy_script
        env = environment
        properties = prop_file
        enabled = "false"
    }
}

node {
    sendSlackNotification {
        channel = slackChannel
        type = 'start'
    }
}

def with_sealights = false
if (params.WITH_SEALIGHTS == true) {
    with_sealights = params.WITH_SEALIGHTS
}
//create archive
stashSource {
    env = environment
    projectName = project_name
    branch = branch
    tag = tag
    repo = project_repo
    withSealights = with_sealights
}

if (params.DO_DEPLOY == true) {
    //we don't need build if we're using tag
    if (tag == null) {
        basicBuild {
            env = environment
            projectName = project_name
            withSealights = with_sealights
            mvnPom = 'project/pom.xml'
            mvnGoals = 'clean package'
            mvnOptions = '-Dmaven.test.skip=true'
        }
    }
    def within_elb = false
    if (environment == "STAGE") {
        within_elb = true
    }
    basicDeploy {
        env = environment
        projectName = project_name
        version = tag
        withinElb = within_elb
        deployScript = deploy_script
        properties = prop_file
    }
}

if (params.RUN_REGRESSION == true) {
    failed = runRegression(environment,project_name)
}
if (failed == false && params.RUN_PERFORMANCE == true) {
    failed = runPerformance(environment,project_name,performance_node)
}

if (failed == false && environment == "DEV") { 
    publishArtifact{
        env = environment
        projectName = project_name
    }
}

if (failed == false && params.RUN_INTEGRATION == true && environment != "DEV") {
    failed = runIntegration(environment,project_name)
}

if (failed == false && environment == "DEV") {
    //starting dev to qa
    environment = "QA"
    if (params.DO_DEPLOY == true) {
        basicDeploy {
            env = environment
            projectName = project_name
            version = tag
            withinElb = "false"
            deployScript = deploy_script
            properties = prop_file
        }
    }
    if (params.RUN_REGRESSION == true) {
        failed = runRegression(environment,project_name)
    }
    if (failed == false && params.RUN_INTEGRATION == true) {
        failed = runIntegration(environment,project_name)
    }
}

if (params.DISABLE_ALERT == true) {
    alertPolicyControl {
        env = environment
        alertScript = deploy_script
        properties = prop_file
        enabled = "true"
    }
}
if (failed == false && environment == "STAGE") {
    def release_script = "${env.JENKINS_HOME}/workspace/all-projects-property-files/com/nbcuni/common/create_release_branch_from_dev.sh"
    def release_prop = "${env.JENKINS_HOME}/workspace/all-projects-property-files/com/nbcuni/idx2/scripts/idx2-create-release-branch.properties"
    createReleaseBranch {
        env = environment
        projectName = project_name
        releaseScript = release_script
        properties = release_prop
    }
}
node {
    stage 'Send Notifications'
    if(failed) {
        sendEmailNotification {
            result = 'failed'
            attachments = 'test/target/surefire-reports/test-idx-2.0-1.0.0-SNAPSHOT/emailable-report.html'
            recipients = mailRecipients
        }
        sendSlackNotification {
            channel = slackChannel
            type = 'failed'
        }
    } else {
        sendEmailNotification {
            result = 'success'
            attachments = 'test/target/surefire-reports/test-idx-2.0-1.0.0-SNAPSHOT/emailable-report.html'
            recipients = mailRecipients
        }
        sendSlackNotification {
            channel = slackChannel
            type = 'success'
        }
    }
}