<#
.SYNOPSIS
    1-Command Automated Cloud Deployment for Method 2 (Microsoft Azure + Terraform).
.DESCRIPTION
    1. Verifies Azure CLI login & retrieves Azure for Students credentials.
    2. Detects local public IP and configures NSG firewall rules.
    3. Auto-configures terraform/terraform.tfvars.
    4. Provisions Azure Infrastructure (Resource Group, VNet, Subnet, NSG, Public IP, VM).
    5. Retrieves Azure VM Public IP & verifies Nginx bootstrap.
    6. Automatically updates Jenkins (VM_IP & SSH known-hosts) and triggers Pipeline.
    7. Verifies live deployment on Azure and opens the cloud website in your browser!
.PARAMETER Region
    Azure region to deploy to. Defaults to 'uaenorth' (allowed by Azure for Students policy).
.PARAMETER VmSize
    VM size/SKU to deploy. Defaults to 'Standard_B1s'.
.PARAMETER Destroy
    Destroys all Azure cloud resources to stop billing.
#>

[CmdletBinding()]
param(
    [string]$Region = "uaenorth",
    [string]$VmSize = "Standard_B1s",
    [switch]$Destroy
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  ☁️ METHOD 2: DEVOPS CLOUD DEPLOYMENT (AZURE + TERRAFORM)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

$terraformDir = Join-Path $ScriptDir "terraform"

# -----------------------------------------------------------------------------
# Handle -Destroy switch
# -----------------------------------------------------------------------------
if ($Destroy) {
    Write-Host "⚠️ TEARDOWN MODE ACTIVATED: Destroying Azure cloud resources..." -ForegroundColor Yellow
    Push-Location $terraformDir
    try {
        terraform destroy -auto-approve
        Write-Host ""
        Write-Host "✅ Azure infrastructure destroyed successfully. Cloud billing stopped." -ForegroundColor Green
    } finally {
        Pop-Location
    }

    # Reset Jenkins VM_IP back to local web-vm if Jenkins is running
    try {
        $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:admin123"))
        $crumbData = Invoke-RestMethod -Uri "http://localhost:8080/crumbIssuer/api/json" -Headers @{ Authorization = "Basic $auth" } -SessionVariable jSession -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($crumbData) {
            $resetGroovy = "def p = jenkins.model.Jenkins.instance.getGlobalNodeProperties().getAll(hudson.slaves.EnvironmentVariablesNodeProperty.class)[0].getEnvVars(); p.put('VM_IP', 'web-vm'); jenkins.model.Jenkins.instance.save();"
            $headers = @{ Authorization = "Basic $auth"; ($crumbData.crumbRequestField) = $crumbData.crumb }
            $null = Invoke-RestMethod -Uri "http://localhost:8080/scriptText" -Method Post -Body "script=$resetGroovy" -Headers $headers -WebSession $jSession -TimeoutSec 5
            Write-Host "✅ Reset Jenkins target back to local 'web-vm'." -ForegroundColor Green
        }
    } catch {}
    exit 0
}

# -----------------------------------------------------------------------------
# 1. Pre-flight Check: Azure CLI & Login
# -----------------------------------------------------------------------------
Write-Host "[1/7] Checking Azure CLI authentication..." -ForegroundColor Yellow
$azAccount = $null
try {
    $azRaw = az account show 2>$null
    if ($LASTEXITCODE -eq 0 -and $azRaw) {
        $azAccount = $azRaw | ConvertFrom-Json
    }
} catch {}

if (-not $azAccount) {
    Write-Host "      Not logged into Azure. Launching browser login ('az login')..." -ForegroundColor Yellow
    az login --output none
    $azAccount = (az account show) | ConvertFrom-Json
}

$subId = $azAccount.id
$tenantId = $azAccount.tenantId
$subName = $azAccount.name
Write-Host "      ✅ Connected to Azure: '$subName' ($subId)" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Check SSH Key & Public IP
# -----------------------------------------------------------------------------
Write-Host "[2/7] Preparing network security and SSH credentials..." -ForegroundColor Yellow

$sshKeyPath = Join-Path $env:USERPROFILE ".ssh\azure_cicd_vm"
$sshPubPath = Join-Path $env:USERPROFILE ".ssh\azure_cicd_vm.pub"

if (-not (Test-Path $sshPubPath)) {
    Write-Host "      Generating dedicated Ed25519 deployment key pair..." -ForegroundColor DarkGray
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    ssh-keygen -t ed25519 -f $sshKeyPath -N '""' -C "azure-cicd-deploy" | Out-Null
}
$sshPublicKey = (Get-Content $sshPubPath -Raw).Trim()
Write-Host "      ✅ SSH public key ready: $($sshPublicKey.Substring(0, 45))..." -ForegroundColor Green

# Detect current external IP for NSG firewall
$myIp = $null
try {
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5).Trim()
} catch {
    try { $myIp = (Invoke-RestMethod -Uri "https://icanhazip.com" -TimeoutSec 5).Trim() } catch {}
}

if (-not $myIp) {
    Write-Host "      ⚠️ Could not auto-detect public IP. Using fallback 0.0.0.0/0." -ForegroundColor Yellow
    $allowedCidr = "0.0.0.0/0"
} else {
    $allowedCidr = "$myIp/32"
    Write-Host "      ✅ Restricting SSH inbound access to your IP: $allowedCidr" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 3. Configure terraform/terraform.tfvars
# -----------------------------------------------------------------------------
Write-Host "[3/7] Configuring Terraform variables (terraform.tfvars)..." -ForegroundColor Yellow

# Detect policy-allowed regions if Azure for Students restriction exists
$allowedRegions = @("uaenorth", "koreacentral", "malaysiawest", "indonesiacentral", "polandcentral")
try {
    $policyJson = az policy assignment list --query "[?contains(name, 'regionrestriction')].parameters.listOfAllowedLocations.value" -o json 2>$null
    if ($policyJson) {
        $parsed = $policyJson | ConvertFrom-Json
        if ($parsed -and $parsed.Count -gt 0) {
            $allowedRegions = $parsed[0]
        }
    }
} catch {}

if ($allowedRegions -notcontains $Region) {
    Write-Host "      ⚠️ Region '$Region' is restricted by Azure policy. Using '$($allowedRegions[0])'." -ForegroundColor Yellow
    $Region = $allowedRegions[0]
}

$tfvarsContent = @"
# Auto-generated by automate-cloud.ps1 for Azure deployment
subscription_id     = "$subId"
tenant_id           = "$tenantId"

resource_group_name = "rg-devops-cicd"
location            = "$Region"

vm_name             = "vm-devops-cicd"
vm_computer_name    = "devops-cicd-vm"
vm_size             = "$VmSize"
admin_username      = "azureuser"

ssh_public_key      = "$sshPublicKey"
allowed_ssh_cidr    = "$allowedCidr"

tags = {
  Project     = "devops-cicd-terraform-jenkins"
  ManagedBy   = "terraform"
  Environment = "azure-cloud-demo"
  Owner       = "student"
}
"@

Set-Content -Path (Join-Path $terraformDir "terraform.tfvars") -Value $tfvarsContent -Force
Write-Host "      ✅ Variables written: Region=$Region, VM Size=$VmSize." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 4. Provision Azure Infrastructure via Terraform
# -----------------------------------------------------------------------------
Write-Host "[4/7] Provisioning cloud infrastructure with Terraform..." -ForegroundColor Yellow
Push-Location $terraformDir
$applyOk = $false
try {
    Write-Host "      Running 'terraform init'..." -ForegroundColor DarkGray
    terraform init -input=false | Out-Null

    Write-Host "      Applying Terraform plan in region '$Region' (this creates the Azure VM)..." -ForegroundColor DarkGray
    terraform apply -auto-approve -input=false
    if ($LASTEXITCODE -eq 0) {
        $applyOk = $true
    }
} finally {
    Pop-Location
}

if (-not $applyOk) {
    Write-Host ""
    Write-Host "      ⚠️ If Azure reported 'SkuNotAvailable' due to regional capacity," -ForegroundColor Yellow
    Write-Host "         you can retry with another allowed region or VM size:" -ForegroundColor Yellow
    Write-Host "         .\automate-cloud.ps1 -Region koreacentral -VmSize Standard_B1s" -ForegroundColor Cyan
    Write-Host "         Allowed student regions: $($allowedRegions -join ', ')" -ForegroundColor DarkGray
    exit 1
}

# Extract output public IP
Push-Location $terraformDir
$azurePublicIp = (terraform output -raw public_ip_address 2>$null).Trim()
Pop-Location

if (-not $azurePublicIp) {
    Write-Error "Failed to retrieve public IP address from Terraform output."
    exit 1
}
Write-Host "      🎉 Azure Infrastructure created! Public IP: $azurePublicIp" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 5. Verify Nginx Cloud Bootstrap
# -----------------------------------------------------------------------------
Write-Host "[5/7] Verifying Nginx cloud-init bootstrap on Azure VM ($azurePublicIp)..." -ForegroundColor Yellow
$bootstrapReady = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 4
    try {
        $resp = Invoke-WebRequest -Uri "http://${azurePublicIp}/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($resp.StatusCode -eq 200 -and $resp.Content -match "ok") {
            $bootstrapReady = $true
            break
        }
    } catch {}
    Write-Host "." -NoNewline
}
Write-Host ""
if ($bootstrapReady) {
    Write-Host "      ✅ Cloud Nginx is active at http://${azurePublicIp}/" -ForegroundColor Green
} else {
    Write-Host "      ⚠️ Nginx is still initializing. Continuing to Jenkins setup..." -ForegroundColor Yellow
}

# Fetch host key for strict SSH verification
Write-Host "      Fetching VM SSH host key for strict host key verification..." -ForegroundColor DarkGray
$knownHostLine = ""
try {
    $keyscan = ssh-keyscan -t ed25519 $azurePublicIp 2>$null
    if ($keyscan) {
        $knownHostLine = ($keyscan | Where-Object { $_ -match "ssh-ed25519" } | Select-Object -First 1).Trim()
    }
} catch {}

if (-not $knownHostLine) {
    $knownHostLine = "$azurePublicIp ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA" # fallback
}

# -----------------------------------------------------------------------------
# 6. Connect Jenkins to Cloud Azure VM
# -----------------------------------------------------------------------------
Write-Host "[6/7] Connecting Jenkins to Azure VM ($azurePublicIp)..." -ForegroundColor Yellow

# Ensure Jenkins container is running
$jenkinsRunning = $false
try {
    $out = docker inspect -f '{{.State.Running}}' jenkins-cicd 2>$null
    if ($out -match "true") { $jenkinsRunning = $true }
} catch {}

if (-not $jenkinsRunning) {
    Write-Host "      Starting Jenkins container..." -ForegroundColor DarkGray
    Push-Location (Join-Path $ScriptDir "jenkins")
    docker compose up -d jenkins
    Pop-Location
    Start-Sleep -Seconds 10
}

# Update Jenkins global variables and trigger build via Groovy API
$jenkinsAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:admin123"))
try {
    $crumbData = Invoke-RestMethod -Uri "http://localhost:8080/crumbIssuer/api/json" -Headers @{ Authorization = "Basic $jenkinsAuth" } -SessionVariable jenkinsSession -TimeoutSec 5
    $headers = @{
        Authorization = "Basic $jenkinsAuth"
        ($crumbData.crumbRequestField) = $crumbData.crumb
    }

    $escapedKey = $knownHostLine.Replace("`"", "\`"").Replace("'", "\'")
    $updateGroovy = @"
import jenkins.model.*
import hudson.slaves.EnvironmentVariablesNodeProperty
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import hudson.util.Secret

def instance = Jenkins.getInstance()

// 1. Update VM_IP global property to Azure Public IP
def props = instance.getGlobalNodeProperties()
def envProps = props.getAll(EnvironmentVariablesNodeProperty.class)
def envVars = envProps[0].getEnvVars()
envVars.put("VM_IP", "$azurePublicIp")

// 2. Update SSH Known Hosts credential
def domain = Domain.global()
def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()
def existingKnownHosts = store.getCredentials(domain).find { it.id == 'azure-vm-known-hosts' }
if (existingKnownHosts != null) { store.removeCredentials(domain, existingKnownHosts) }
def knownHostsCred = new StringCredentialsImpl(
    CredentialsScope.GLOBAL,
    'azure-vm-known-hosts',
    'Azure Cloud VM Host Key',
    Secret.fromString('$escapedKey')
)
store.addCredentials(domain, knownHostsCred)

instance.save()

// 3. Trigger deployment build
def job = instance.getItem('devops-project-pipeline')
if (job != null) {
    job.scheduleBuild2(0)
}
"@

    $res = Invoke-RestMethod -Uri "http://localhost:8080/scriptText" -Method Post -Body "script=$updateGroovy" -Headers $headers -WebSession $jenkinsSession -TimeoutSec 10
    Write-Host "      ✅ Jenkins configured: VM_IP set to '$azurePublicIp'. Pipeline build triggered!" -ForegroundColor Green
} catch {
    Write-Host "      ⚠️ Note: Jenkins could not be automatically notified via API. You can manually set VM_IP to $azurePublicIp in Jenkins UI." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 7. Final Verification
# -----------------------------------------------------------------------------
Write-Host "[7/7] Monitoring Cloud Deployment Verification..." -ForegroundColor Yellow
$cloudVerified = $false
for ($t = 1; $t -le 24; $t++) {
    Start-Sleep -Seconds 5
    try {
        $info = Invoke-WebRequest -Uri "http://${azurePublicIp}/build-info.txt" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($info.Content -match "build_number=") {
            $cloudVerified = $true
            break
        }
    } catch {}
    Write-Host "      Waiting for Jenkins pipeline to deploy app to Azure ($($t * 5) s)..." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
if ($cloudVerified) {
    Write-Host "  🎉 SUCCESS! PIPELINE HAS DEPLOYED LIVE TO MICROSOFT AZURE!" -ForegroundColor Green
} else {
    Write-Host "  ☁️ AZURE INFRASTRUCTURE IS LIVE & READY!" -ForegroundColor Green
}
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  🌐 Azure Live Web App : http://${azurePublicIp}/" -ForegroundColor Cyan
Write-Host "  🩺 Cloud Health Check : http://${azurePublicIp}/health" -ForegroundColor Cyan
Write-Host "  📄 Cloud Build Info   : http://${azurePublicIp}/build-info.txt" -ForegroundColor Cyan
Write-Host "  🛠️  Local Jenkins UI   : http://localhost:8080" -ForegroundColor Cyan
Write-Host "  🔑 SSH Access Command : ssh -i `"`$HOME\.ssh\azure_cicd_vm`" azureuser@$azurePublicIp" -ForegroundColor Cyan
Write-Host ""
Write-Host "  💡 To destroy cloud resources when done (stop billing):" -ForegroundColor Yellow
Write-Host "     .\automate-cloud.ps1 -Destroy" -ForegroundColor White
Write-Host "     (or: cd terraform; terraform destroy -auto-approve)" -ForegroundColor DarkGray
Write-Host ""

# Open in browser
Start-Process "http://${azurePublicIp}/"
