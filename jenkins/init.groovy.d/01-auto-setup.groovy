import jenkins.model.*
import hudson.security.*
import jenkins.install.*
import hudson.slaves.EnvironmentVariablesNodeProperty

import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret

import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import hudson.plugins.git.GitSCM
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.UserRemoteConfig

println "--> [Auto-Setup] =================================================="
println "--> [Auto-Setup] Starting Jenkins automated configuration..."
println "--> [Auto-Setup] =================================================="

def instance = Jenkins.getInstance()

// 1. Mark initial setup completed (disable unlock wizard)
if (!instance.getInstallState().isSetupComplete()) {
    instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
    println "--> [Auto-Setup] Setup wizard marked as complete."
}

// 2. Create default Admin user if not exists
def realm = instance.getSecurityRealm()
if (!(realm instanceof HudsonPrivateSecurityRealm)) {
    realm = new HudsonPrivateSecurityRealm(false)
    instance.setSecurityRealm(realm)
}
if (realm.getUser("admin") == null) {
    realm.createAccount("admin", "admin123")
    println "--> [Auto-Setup] Admin user 'admin' created with password 'admin123'."
}

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// 3. Configure Global Environment Variables
def props = instance.getGlobalNodeProperties()
def envVarsNodePropertyList = props.getAll(EnvironmentVariablesNodeProperty.class)
def newEnvVarsNodeProperty = null
def envVars = null

if (envVarsNodePropertyList == null || envVarsNodePropertyList.isEmpty()) {
    newEnvVarsNodeProperty = new EnvironmentVariablesNodeProperty()
    props.add(newEnvVarsNodeProperty)
    envVars = newEnvVarsNodeProperty.getEnvVars()
} else {
    envVars = envVarsNodePropertyList.get(0).getEnvVars()
}

envVars.put("VM_IP", "web-vm")
envVars.put("VM_USER", "azureuser")
envVars.put("REMOTE_TMP_DIR", "/tmp/cicd-build")
envVars.put("REMOTE_APP_DIR", "/var/www/app")
println "--> [Auto-Setup] Global environment variables configured: VM_IP=web-vm, VM_USER=azureuser."

// 4. Configure Credentials
try {
    def domain = Domain.global()
    def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()

    // SSH Private Key
    def sshKeyFile = new File("/var/jenkins_home/secrets_auto/azure_cicd_vm")
    if (sshKeyFile.exists() && sshKeyFile.length() > 0) {
        def sshKeyContent = sshKeyFile.text.trim()
        def existingKey = store.getCredentials(domain).find { it.id == 'azure-vm-ssh-private-key' }
        if (existingKey != null) {
            store.removeCredentials(domain, existingKey)
        }
        def sshKeyCred = new StringCredentialsImpl(
            CredentialsScope.GLOBAL,
            'azure-vm-ssh-private-key',
            'SSH Private Key for deployment',
            Secret.fromString(sshKeyContent)
        )
        store.addCredentials(domain, sshKeyCred)
        println "--> [Auto-Setup] Credential 'azure-vm-ssh-private-key' successfully configured."
    } else {
        println "--> [Auto-Setup] WARNING: /var/jenkins_home/secrets_auto/azure_cicd_vm not found or empty."
    }

    // SSH Known Hosts
    def knownHostsFile = new File("/var/jenkins_home/secrets_auto/known_hosts")
    def knownHostsContent = ""
    if (knownHostsFile.exists() && knownHostsFile.length() > 0) {
        knownHostsContent = knownHostsFile.text.trim()
    } else {
        // Fallback to pre-generated known host key
        knownHostsContent = "web-vm ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINKJ/lDieReG9ybT//OurATt9KjvZtbXk4NX63jBeMCX"
    }

    def existingKnownHosts = store.getCredentials(domain).find { it.id == 'azure-vm-known-hosts' }
    if (existingKnownHosts != null) {
        store.removeCredentials(domain, existingKnownHosts)
    }
    def knownHostsCred = new StringCredentialsImpl(
        CredentialsScope.GLOBAL,
        'azure-vm-known-hosts',
        'SSH Known Hosts for web-vm',
        Secret.fromString(knownHostsContent)
    )
    store.addCredentials(domain, knownHostsCred)
    println "--> [Auto-Setup] Credential 'azure-vm-known-hosts' successfully configured."
} catch (Exception e) {
    println "--> [Auto-Setup] Error configuring credentials: " + e.getMessage()
}

// 5. Create Pipeline Job
try {
    def jobName = "devops-project-pipeline"
    def job = instance.getItem(jobName)
    if (job == null) {
        job = instance.createProject(WorkflowJob.class, jobName)
        println "--> [Auto-Setup] Created pipeline job '${jobName}'."
    }

    def remoteConfig = new UserRemoteConfig("https://github.com/n4zr-sketcher/Devops-Project.git", null, null, null)
    def scm = new GitSCM([remoteConfig], [new BranchSpec("*/main")], false, [], null, null, [])
    job.setDefinition(new CpsScmFlowDefinition(scm, "Jenkinsfile"))

    instance.save()
    job.save()

    // 6. Schedule initial build
    println "--> [Auto-Setup] Automatically scheduling Build #1..."
    job.scheduleBuild2(0)
    println "--> [Auto-Setup] Build #1 scheduled successfully!"
} catch (Exception e) {
    println "--> [Auto-Setup] Error configuring pipeline job: " + e.getMessage()
}

println "--> [Auto-Setup] =================================================="
println "--> [Auto-Setup] Automated Jenkins setup finished successfully!"
println "--> [Auto-Setup] =================================================="
