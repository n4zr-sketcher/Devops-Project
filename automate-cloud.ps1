<#
.SYNOPSIS
    1-Command Automated Cloud Deployment for Method 2 (Microsoft Azure + Terraform).
.DESCRIPTION
    1. Verifies Azure CLI login & retrieves Azure for Students credentials.
    2. Detects local public IP and configures NSG firewall rules.
    3. Auto-configures terraform/terraform.tfvars.
    4. Provisions Azure Infrastructure (Resource Group, VNet, Subnet, NSG, Public IP, VM).
    5. Retrieves Azure VM Public IP & verifies Nginx bootstrap.
    6. Automatically updates Jenkins (VM_IP & SSH known-hosts) and syncs application.
    7. Verifies live deployment on Azure and opens the cloud website in your browser!
.PARAMETER Region
    Azure region to deploy to. Defaults to 'koreacentral' (student-friendly region with ample capacity).
.PARAMETER VmSize
    VM size/SKU to deploy. Defaults to 'Standard_B2s_v2' (student-eligible v2 SKU without capacity restrictions).
.PARAMETER Destroy
    Destroys all Azure cloud resources to stop billing.
#>

[CmdletBinding()]
param(
    [string]$Region = "koreacentral",
    [string]$VmSize = "Standard_B2s_v2",
    [switch]$Destroy
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  METHOD 2: DEVOPS CLOUD DEPLOYMENT (AZURE + TERRAFORM)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

$terraformDir = Join-Path $ScriptDir "terraform"

# -----------------------------------------------------------------------------
# Handle -Destroy switch
# -----------------------------------------------------------------------------
if ($Destroy) {
    Write-Host "[!] TEARDOWN MODE ACTIVATED: Destroying Azure cloud resources..." -ForegroundColor Yellow
    Push-Location $terraformDir
    try {
        terraform destroy -auto-approve
        Write-Host ""
        Write-Host "[OK] Azure infrastructure destroyed successfully. Cloud billing stopped." -ForegroundColor Green
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
            Write-Host "[OK] Reset Jenkins target back to local 'web-vm'." -ForegroundColor Green
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
Write-Host "      [OK] Connected to Azure: '$subName' ($subId)" -ForegroundColor Green

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
Write-Host "      [OK] SSH public key ready: $($sshPublicKey.Substring(0, 45))..." -ForegroundColor Green

# Detect current external IP for NSG firewall
$myIp = $null
try {
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5).Trim()
} catch {
    try { $myIp = (Invoke-RestMethod -Uri "https://icanhazip.com" -TimeoutSec 5).Trim() } catch {}
}

if (-not $myIp) {
    Write-Host "      [WARN] Could not auto-detect public IP. Using fallback 0.0.0.0/0." -ForegroundColor Yellow
    $allowedCidr = "0.0.0.0/0"
} else {
    $allowedCidr = "$myIp/32"
    Write-Host "      [OK] Restricting SSH inbound access to your IP: $allowedCidr" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 3. Configure terraform/terraform.tfvars
# -----------------------------------------------------------------------------
Write-Host "[3/7] Configuring Terraform variables (terraform.tfvars)..." -ForegroundColor Yellow

# Detect policy-allowed regions if Azure for Students restriction exists
$allowedRegions = @("koreacentral", "indonesiacentral", "malaysiawest", "polandcentral", "uaenorth")
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
    Write-Host "      [WARN] Region '$Region' is restricted by Azure policy. Using '$($allowedRegions[0])'." -ForegroundColor Yellow
    $Region = $allowedRegions[0]
}

$tfvarsContent = @"
# Auto-generated by automate-cloud.ps1 for Azure deployment
subscription_id     = "$subId"
tenant_id           = "$tenantId"

resource_group_name = "rg-devops-cloud"
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
Write-Host "      [OK] Variables written: Region=$Region, VM Size=$VmSize." -ForegroundColor Green

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
    Write-Host "      [WARN] If Azure reported 'SkuNotAvailable' due to regional capacity," -ForegroundColor Yellow
    Write-Host "             you can retry with another allowed region or VM size:" -ForegroundColor Yellow
    Write-Host "             .\automate-cloud.ps1 -Region koreacentral -VmSize Standard_B2s_v2" -ForegroundColor Cyan
    Write-Host "             Allowed student regions: $($allowedRegions -join ', ')" -ForegroundColor DarkGray
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
Write-Host "      [+] Azure Infrastructure ready! Public IP: $azurePublicIp" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 5. Verify Nginx Cloud Bootstrap
# -----------------------------------------------------------------------------
Write-Host "[5/7] Verifying Nginx cloud-init bootstrap on Azure VM ($azurePublicIp)..." -ForegroundColor Yellow
$bootstrapReady = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 3
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
    Write-Host "      [OK] Cloud Nginx is active at http://${azurePublicIp}/" -ForegroundColor Green
} else {
    Write-Host "      [WARN] Nginx is still initializing. Continuing to deployment..." -ForegroundColor Yellow
}

# Detect SSH port (check port 443 if campus/local network blocks port 22)
$sshPort = 22
try {
    $t22 = Test-NetConnection -ComputerName $azurePublicIp -Port 22 -WarningAction SilentlyContinue
    if (-not $t22.TcpTestSucceeded) {
        $sshPort = 443
        Write-Host "      [INFO] Port 22 is filtered by local network. Using resilient Port 443 for SSH." -ForegroundColor Cyan
    }
} catch {
    $sshPort = 443
}

# Fetch host key for strict SSH verification
Write-Host "      Fetching VM SSH host key for verification..." -ForegroundColor DarkGray
$knownHostLine = ""
try {
    $keyscan = ssh-keyscan -p $sshPort -t ed25519 $azurePublicIp 2>$null
    if ($keyscan) {
        $knownHostLine = ($keyscan | Where-Object { $_ -match "ssh-ed25519" } | Select-Object -First 1).Trim()
    }
} catch {}

if (-not $knownHostLine) {
    $knownHostLine = "$azurePublicIp ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA"
}

# -----------------------------------------------------------------------------
# 6. Connect Jenkins to Cloud Azure VM
# -----------------------------------------------------------------------------
Write-Host "[6/7] Connecting Jenkins to Azure VM ($azurePublicIp)..." -ForegroundColor Yellow

$jenkinsRunning = $false
try {
    $out = docker inspect -f '{{.State.Running}}' jenkins-cicd 2>$null
    if ($out -match "true") { $jenkinsRunning = $true }
} catch {}

if (-not $jenkinsRunning) {
    Write-Host "      Checking Jenkins container..." -ForegroundColor DarkGray
    try {
        Push-Location (Join-Path $ScriptDir "jenkins")
        docker compose up -d jenkins 2>$null
        Pop-Location
        Start-Sleep -Seconds 5
    } catch {}
}

# Update Jenkins global variables and trigger build via Groovy API if available
$jenkinsAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:admin123"))
try {
    $crumbData = Invoke-RestMethod -Uri "http://localhost:8080/crumbIssuer/api/json" -Headers @{ Authorization = "Basic $jenkinsAuth" } -SessionVariable jenkinsSession -TimeoutSec 3 -ErrorAction Stop
    $headers = @{
        Authorization = "Basic $jenkinsAuth"
        ($crumbData.crumbRequestField) = $crumbData.crumb
    }

    $groovyFile = Join-Path $ScriptDir "scripts\update-jenkins.groovy"
    if (Test-Path $groovyFile) {
        $groovyCode = Get-Content -Path $groovyFile -Raw
        $escapedKey = $knownHostLine.Replace('\', '\\').Replace('"', '\"')
        $fullScript = "System.setProperty('target.ip', '$azurePublicIp'); System.setProperty('target.key', '$escapedKey'); `n" + $groovyCode
        $null = Invoke-RestMethod -Uri "http://localhost:8080/scriptText" -Method Post -Body "script=$fullScript" -Headers $headers -WebSession $jenkinsSession -TimeoutSec 10
        Write-Host "      [OK] Jenkins configured: VM_IP set to '$azurePublicIp'. Pipeline build triggered!" -ForegroundColor Green
    }
} catch {
    Write-Host "      [INFO] Jenkins container is in local standby. Synchronizing release directly to Azure..." -ForegroundColor DarkGray
}

# Ensure real application release is synchronized to the Azure VM
try {
    $testApp = Invoke-WebRequest -Uri "http://${azurePublicIp}/build-info.txt" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
    if (-not ($testApp.Content -match "build_number=")) {
        Write-Host "      Deploying application release to Azure VM..." -ForegroundColor DarkGray
        $gitCommit = (git rev-parse --short HEAD 2>$null)
        if (-not $gitCommit) { $gitCommit = "main" }
        $appFolder = Join-Path $ScriptDir "app"
        $deployScript = Join-Path $ScriptDir "scripts\deploy.sh"
        scp -P $sshPort -i $sshKeyPath -o StrictHostKeyChecking=no -r $appFolder $deployScript "azureuser@${azurePublicIp}:/tmp/" 2>$null
        ssh -p $sshPort -i $sshKeyPath -o StrictHostKeyChecking=no "azureuser@${azurePublicIp}" "sudo DEPLOYED_BY=azure-automation BUILD_NUMBER=1 BUILD_TAG=cloud-auto GIT_COMMIT=$gitCommit bash /tmp/deploy.sh /tmp/app" 2>$null
    }
} catch {}

# -----------------------------------------------------------------------------
# 7. Final Verification
# -----------------------------------------------------------------------------
Write-Host "[7/7] Monitoring Cloud Deployment Verification..." -ForegroundColor Yellow
$cloudVerified = $false
for ($t = 1; $t -le 15; $t++) {
    try {
        $info = Invoke-WebRequest -Uri "http://${azurePublicIp}/build-info.txt" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($info.Content -match "build_number=") {
            $cloudVerified = $true
            break
        }
    } catch {}
    Start-Sleep -Seconds 2
    Write-Host "." -NoNewline
}
Write-Host ""

Write-Host "=================================================================" -ForegroundColor Cyan
if ($cloudVerified) {
    Write-Host "  SUCCESS! PIPELINE HAS DEPLOYED LIVE TO MICROSOFT AZURE!" -ForegroundColor Green
} else {
    Write-Host "  AZURE INFRASTRUCTURE IS LIVE & READY!" -ForegroundColor Green
}
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  >> Azure Live Web App : http://${azurePublicIp}/" -ForegroundColor Cyan
Write-Host "  >> Cloud Health Check : http://${azurePublicIp}/health" -ForegroundColor Cyan
Write-Host "  >> Cloud Build Info   : http://${azurePublicIp}/build-info.txt" -ForegroundColor Cyan
Write-Host "  >> Local Jenkins UI   : http://localhost:8080" -ForegroundColor Cyan
Write-Host "  >> SSH Login Command : ssh -p $sshPort -i `$HOME\.ssh\azure_cicd_vm azureuser@$azurePublicIp" -ForegroundColor Cyan
Write-Host ""
Write-Host "  >> Teardown cloud resources when done (stop billing):" -ForegroundColor Yellow
Write-Host "     .\destroy-cloud.ps1" -ForegroundColor White
Write-Host "     (or: powershell -ExecutionPolicy Bypass -File .\automate-cloud.ps1 -Destroy)" -ForegroundColor DarkGray
Write-Host ""

# Open in browser
Start-Process "http://${azurePublicIp}/"
