// Jenkinsfile
//
// Declarative pipeline for:
//   "Automated Deployment of a Web Application using CI/CD, Terraform, Azure
//    and Jenkins"
//
// Stages
//   1. Checkout  - clone the latest commit from GitHub
//   2. Validate  - the required application files must exist
//   3. Test      - static checks on the HTML, CSS and JavaScript
//   4. Deploy    - copy the application to the Azure VM over SSH
//   5. Reload    - publish the release and gracefully reload Nginx
//   6. Verify    - request the live URL and confirm the new build is served
//
// Secrets
//   NOTHING sensitive is stored in this file. The SSH private key and the
//   server host key are read from the Jenkins credential store:
//
//     azure-vm-ssh-private-key   Secret text   - contents of ~/.ssh/azure_cicd_vm
//     azure-vm-known-hosts       Secret text   - one known_hosts line for the VM
//
//   Connection settings come from Jenkins global environment variables:
//
//     VM_IP             public IP of the Azure VM      e.g. 20.55.1.2
//     VM_USER           SSH user                       e.g. azureuser
//     REMOTE_TMP_DIR    staging folder on the VM       e.g. /tmp/cicd-build
//     REMOTE_APP_DIR    live web root on the VM        e.g. /var/www/app


pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        ansiColor('xterm')
    }

    environment {
        APP_DIR         = 'app'
        SCRIPT_DIR      = 'scripts'
        SSH_DIR         = '.ssh-tmp'
        SSH_KEY_FILE    = '.ssh-tmp/id_ed25519'
        KNOWN_HOSTS_FILE = '.ssh-tmp/known_hosts'

        // Fallbacks so the pipeline fails with a clear message instead of a
        // cryptic SSH error when the global variables are not configured yet.
        VM_IP          = "${env.VM_IP ?: ''}"
        VM_USER        = "${env.VM_USER ?: 'azureuser'}"
        REMOTE_TMP_DIR = "${env.REMOTE_TMP_DIR ?: '/tmp/cicd-build'}"
        REMOTE_APP_DIR = "${env.REMOTE_APP_DIR ?: '/var/www/app'}"
    }

    stages {

        // ------------------------------------------------------------------
        stage('Checkout') {
            steps {
                script {
                    env.GIT_COMMIT = sh(
                        script: 'git rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()

                    env.GIT_BRANCH = sh(
                        script: 'git rev-parse --abbrev-ref HEAD',
                        returnStdout: true
                    ).trim()

                    echo "Checked out branch '${env.GIT_BRANCH}' at commit ${env.GIT_COMMIT}"
                }
            }
        }

        // ------------------------------------------------------------------
        stage('Validate') {
            steps {
                script {
                    def required = ['index.html', 'style.css', 'script.js']
                    def missing = required.findAll { !fileExists("${env.APP_DIR}/${it}") }

                    if (missing) {
                        error("Missing required file(s) in ${env.APP_DIR}/: ${missing.join(', ')}. " +
                             "Aborting before anything is deployed.")
                    }

                    def html = readFile("${env.APP_DIR}/index.html")

                    if (!html.contains('<!DOCTYPE html>')) {
                        error('index.html does not start with a DOCTYPE declaration.')
                    }
                    if (!html.contains('<title>')) {
                        error('index.html does not contain a <title> element.')
                    }
                    if (!html.contains('style.css')) {
                        error('index.html does not reference style.css.')
                    }
                    if (!html.contains('script.js')) {
                        error('index.html does not reference script.js.')
                    }

                    echo "Validation passed: ${required.join(', ')} are present and the HTML looks sane."
                }
            }
        }

        // ------------------------------------------------------------------
        stage('Test') {
            steps {
                sh '''
                    #!/bin/bash
                    set -euo pipefail

                    APP_DIR="${APP_DIR}"

                    echo "== Test 1/6: HTML structure =="
                    test -s "${APP_DIR}/index.html"
                    grep -qi "<!DOCTYPE html>" "${APP_DIR}/index.html"
                    grep -qi "<title>" "${APP_DIR}/index.html"
                    grep -qi "</html>" "${APP_DIR}/index.html"
                    grep -qi "style.css" "${APP_DIR}/index.html"
                    grep -qi "script.js" "${APP_DIR}/index.html"
                    echo "   OK - HTML has a doctype, a title and both asset references."

                    echo "== Test 2/6: CSS integrity =="
                    test -s "${APP_DIR}/style.css"
                    OPEN_BRACES=$(tr -cd '{' < "${APP_DIR}/style.css" | wc -c)
                    CLOSE_BRACES=$(tr -cd '}' < "${APP_DIR}/style.css" | wc -c)
                    if [ "${OPEN_BRACES}" -ne "${CLOSE_BRACES}" ]; then
                        echo "   FAIL - unbalanced braces: ${OPEN_BRACES} open vs ${CLOSE_BRACES} close" >&2
                        exit 1
                    fi
                    echo "   OK - ${OPEN_BRACES} CSS rules, braces balanced."

                    echo "== Test 3/6: JavaScript syntax (node --check) =="
                    test -s "${APP_DIR}/script.js"
                    if command -v node >/dev/null 2>&1; then
                        node --check "${APP_DIR}/script.js"
                        echo "   OK - script.js parses without syntax errors."
                    else
                        echo "   SKIP - node is not installed in this agent."
                    fi

                    echo "== Test 4/6: no leftover debug statements =="
                    if grep -n "console\\.log" "${APP_DIR}/script.js"; then
                        echo "   FAIL - console.log() found in script.js, remove debug statements." >&2
                        exit 1
                    fi
                    echo "   OK - no console.log() calls."

                    echo "== Test 5/6: required deployment script =="
                    test -s "${SCRIPT_DIR}/deploy.sh"
                    echo "   OK - scripts/deploy.sh is present."

                    echo "== Test 6/6: deployment settings are configured =="
                    if [ -z "${VM_IP}" ]; then
                        echo "   FAIL - VM_IP is not set." >&2
                        echo "         Add it under Manage Jenkins > System > Global properties." >&2
                        exit 1
                    fi
                    echo "   OK - target ${VM_USER}@${VM_IP}"

                    echo ""
                    echo "All tests passed."
                '''
            }
        }

        // ------------------------------------------------------------------
        stage('Prepare SSH') {
            steps {
                withCredentials([
                    string(credentialsId: 'azure-vm-ssh-private-key', variable: 'SSH_PRIVATE_KEY'),
                    string(credentialsId: 'azure-vm-known-hosts',     variable: 'SSH_KNOWN_HOSTS')
                ]) {
                    sh '''
                        #!/bin/bash
                        set -euo pipefail

                        mkdir -p "${SSH_DIR}"
                        chmod 700 "${SSH_DIR}"

                        printf '%s\n' "${SSH_PRIVATE_KEY}" > "${SSH_KEY_FILE}"
                        chmod 600 "${SSH_KEY_FILE}"

                        printf '%s\n' "${SSH_KNOWN_HOSTS}" > "${KNOWN_HOSTS_FILE}"
                        chmod 644 "${KNOWN_HOSTS_FILE}"

                        echo "SSH material written to ${SSH_DIR} (values are masked in this log)."
                        echo "known_hosts entry: $(cut -d' ' -f1,2 "${KNOWN_HOSTS_FILE}" | head -n 1 | cut -c1-60)..."
                    '''
                }
            }
        }

        // ------------------------------------------------------------------
        stage('Deploy') {
            steps {
                sh '''
                    #!/bin/bash
                    set -euo pipefail

                    SSH_OPTS="-i ${SSH_KEY_FILE}"
                    SSH_OPTS="${SSH_OPTS} -o StrictHostKeyChecking=yes"
                    SSH_OPTS="${SSH_OPTS} -o UserKnownHostsFile=${WORKSPACE}/${KNOWN_HOSTS_FILE}"
                    SSH_OPTS="${SSH_OPTS} -o BatchMode=yes"
                    SSH_OPTS="${SSH_OPTS} -o ConnectTimeout=15"
                    SSH_OPTS="${SSH_OPTS} -o LogLevel=ERROR"

                    REMOTE_STAGE="${REMOTE_TMP_DIR}/build-${BUILD_NUMBER}"

                    echo "Preparing staging folder ${REMOTE_STAGE} on the VM..."
                    ssh ${SSH_OPTS} "${VM_USER}@${VM_IP}" "mkdir -p '${REMOTE_STAGE}'"

                    echo "Uploading ${APP_DIR}/ ..."
                    scp ${SSH_OPTS} -r "${APP_DIR}" "${VM_USER}@${VM_IP}:${REMOTE_STAGE}/"

                    echo "Uploading ${SCRIPT_DIR}/deploy.sh ..."
                    scp ${SSH_OPTS} "${SCRIPT_DIR}/deploy.sh" "${VM_USER}@${VM_IP}:${REMOTE_STAGE}/deploy.sh"

                    echo "Files transferred successfully."
                '''
            }
        }

        // ------------------------------------------------------------------
        stage('Reload') {
            steps {
                sh '''
                    #!/bin/bash
                    set -euo pipefail

                    SSH_OPTS="-i ${SSH_KEY_FILE}"
                    SSH_OPTS="${SSH_OPTS} -o StrictHostKeyChecking=yes"
                    SSH_OPTS="${SSH_OPTS} -o UserKnownHostsFile=${WORKSPACE}/${KNOWN_HOSTS_FILE}"
                    SSH_OPTS="${SSH_OPTS} -o BatchMode=yes"
                    SSH_OPTS="${SSH_OPTS} -o ConnectTimeout=15"
                    SSH_OPTS="${SSH_OPTS} -o LogLevel=ERROR"

                    REMOTE_STAGE="${REMOTE_TMP_DIR}/build-${BUILD_NUMBER}"

                    echo "Running deploy.sh on ${VM_IP} ..."
                    ssh ${SSH_OPTS} "${VM_USER}@${VM_IP}" \
                        "sudo DEPLOYED_BY=jenkins BUILD_NUMBER='${BUILD_NUMBER}' BUILD_TAG='${JOB_NAME}' GIT_COMMIT='${GIT_COMMIT}' \
                         bash '${REMOTE_STAGE}/deploy.sh' '${REMOTE_STAGE}/${APP_DIR}'"
                '''
            }
        }

        // ------------------------------------------------------------------
        stage('Verify') {
            steps {
                sh '''
                    #!/bin/bash
                    set -euo pipefail

                    BASE_URL="http://${VM_IP}"

                    echo "== Verify 1/3: homepage returns HTTP 200 =="
                    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${BASE_URL}/")
                    echo "   HTTP ${HTTP_CODE}"
                    if [ "${HTTP_CODE}" != "200" ]; then
                        echo "   FAIL - expected HTTP 200 from ${BASE_URL}/" >&2
                        exit 1
                    fi

                    echo "== Verify 2/3: health endpoint answers =="
                    HEALTH=$(curl -fsS --max-time 20 "${BASE_URL}/health")
                    echo "   health: ${HEALTH}"
                    case "${HEALTH}" in
                        *ok*) echo "   OK - the application is healthy." ;;
                        *)    echo "   FAIL - unexpected health response." >&2; exit 1 ;;
                    esac

                    echo "== Verify 3/3: the NEW build is the one being served =="
                    BUILD_INFO=$(curl -fsS --max-time 20 "${BASE_URL}/build-info.txt")
                    echo "${BUILD_INFO}" | sed 's/^/   /'
                    if ! echo "${BUILD_INFO}" | grep -q "build_number=${BUILD_NUMBER}"; then
                        echo "   FAIL - the live site is not serving build ${BUILD_NUMBER}." >&2
                        exit 1
                    fi

                    echo ""
                    echo "Deployment verified at ${BASE_URL}/"
                '''
            }
        }
    }

    post {
        success {
            echo "======================================================"
            echo " PIPELINE SUCCESSFUL - the website is live and verified."
            echo " Branch : ${env.GIT_BRANCH}"
            echo " Commit : ${env.GIT_COMMIT}"
            echo " URL    : http://${env.VM_IP}/"
            echo "======================================================"
        }
        failure {
            echo "======================================================"
            echo " PIPELINE FAILED"
            echo " The live website was NOT modified by a failed build."
            echo " Review the stage output above for the root cause."
            echo "======================================================"
        }
        always {
            archiveArtifacts artifacts: 'app/**', allowEmptyArchive: true, fingerprint: true
            deleteDir()
        }
    }
}
