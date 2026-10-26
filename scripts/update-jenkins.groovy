import jenkins.model.*
import hudson.slaves.EnvironmentVariablesNodeProperty
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret

def ip = System.getProperty("target.ip")
def key = System.getProperty("target.key")

if (ip != null && !ip.isEmpty()) {
    def instance = Jenkins.getInstance()
    def props = instance.getGlobalNodeProperties()
    def envProps = props.getAll(EnvironmentVariablesNodeProperty.class)
    if (envProps != null && envProps.size() > 0) {
        envProps[0].getEnvVars().put("VM_IP", ip)
    }

    if (key != null && !key.isEmpty()) {
        def domain = Domain.global()
        def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()
        def old = store.getCredentials(domain).find { it.id == 'azure-vm-known-hosts' }
        if (old != null) { store.removeCredentials(domain, old) }
        def cred = new StringCredentialsImpl(CredentialsScope.GLOBAL, 'azure-vm-known-hosts', 'Azure Cloud VM Host Key', Secret.fromString(key))
        store.addCredentials(domain, cred)
    }

    instance.save()

    def job = instance.getItem('devops-project-pipeline')
    if (job != null) {
        job.scheduleBuild2(0)
    }
}
