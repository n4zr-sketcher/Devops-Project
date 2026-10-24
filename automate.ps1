<#
.SYNOPSIS
    Zero-touch end-to-end automation script for the DevOps CI/CD Project.
.DESCRIPTION
    1. Checks & starts Docker Desktop if needed.
    2. Syncs SSH keys to jenkins/secrets_auto.
    3. Builds and starts Jenkins & Web VM containers via Docker Compose.
    4. Waits for Jenkins auto-configuration to complete.
    5. Monitors Build #1 of the CI/CD pipeline.
    6. Verifies http://localhost:8000 and opens it in your default browser.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  🚀 DEVOPS CI/CD PROJECT - FULL AUTOMATION SETUP" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------------------
# 1. Check Docker Desktop
# -----------------------------------------------------------------------------
Write-Host "[1/6] Checking Docker status..." -ForegroundColor Yellow
$dockerOk = $false
try {
    $null = docker ps 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
} catch {}

if (-not $dockerOk) {
    Write-Host "      Docker is not running. Launching Docker Desktop..." -ForegroundColor Yellow
    $dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerPath) {
        Start-Process $dockerPath
    } else {
        Write-Error "Docker Desktop not found at $dockerPath. Please install/start Docker Desktop."
        exit 1
    }

    Write-Host "      Waiting for Docker engine to start..." -NoNewline
    $timeoutSeconds = 120
    $elapsed = 0
    while ($elapsed -lt $timeoutSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        try {
            $null = docker ps 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dockerOk = $true
                break
            }
        } catch {}
        Write-Host "." -NoNewline
    }
    Write-Host ""
    if (-not $dockerOk) {
        Write-Error "Docker engine failed to become ready within $timeoutSeconds seconds. Please verify Docker Desktop."
        exit 1
    }
}
Write-Host "      ✅ Docker Engine is active and ready." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Sync SSH Key and Known Hosts
# -----------------------------------------------------------------------------
Write-Host "[2/6] Preparing SSH keys for automated deployment..." -ForegroundColor Yellow
$secretsDir = Join-Path $ScriptDir "jenkins\secrets_auto"
if (-not (Test-Path $secretsDir)) {
    New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
}

$userSshKey = Join-Path $env:USERPROFILE ".ssh\azure_cicd_vm"
if (Test-Path $userSshKey) {
    Copy-Item $userSshKey (Join-Path $secretsDir "azure_cicd_vm") -Force
    Write-Host "      ✅ Deployment SSH key synced to jenkins/secrets_auto." -ForegroundColor Green
} else {
    Write-Host "      ⚠️ SSH key $userSshKey not found. Pipeline will look for fallback." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 3. Build & Launch Docker Compose
# -----------------------------------------------------------------------------
Write-Host "[3/6] Building and launching CI/CD containers (Jenkins + Web VM)..." -ForegroundColor Yellow
Push-Location (Join-Path $ScriptDir "jenkins")
try {
    docker compose up -d --build
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker compose up failed with exit code $LASTEXITCODE."
        exit 1
    }
} finally {
    Pop-Location
}
Write-Host "      ✅ Containers built and started in background." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 4. Wait for Jenkins Auto-Configuration
# -----------------------------------------------------------------------------
Write-Host "[4/6] Waiting for Jenkins auto-configuration to complete..." -ForegroundColor Yellow
Write-Host "      Jenkins is applying Groovy init (admin user, env vars, credentials, job)..." -ForegroundColor DarkGray

$jenkinsReady = $false
$maxRetries = 40
for ($i = 1; $i -le $maxRetries; $i++) {
    Start-Sleep -Seconds 3
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:8080/login" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            $jenkinsReady = $true
            break
        }
    } catch {}
    Write-Host "." -NoNewline
}
Write-Host ""

if (-not $jenkinsReady) {
    Write-Host "      ⚠️ Jenkins UI is still initializing. Check logs with 'docker logs -f jenkins-cicd'." -ForegroundColor Yellow
} else {
    Write-Host "      ✅ Jenkins is online at http://localhost:8080" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 5. Monitor Pipeline Execution
# -----------------------------------------------------------------------------
Write-Host "[5/6] Monitoring automated Pipeline Build #1..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Follow Jenkins logs briefly to show progress
$timeout = 90
$timer = 0
$buildSuccess = $false
while ($timer -lt $timeout) {
    Start-Sleep -Seconds 5
    $timer += 5
    try {
        $health = Invoke-WebRequest -Uri "http://localhost:8000/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($health.Content -match "ok") {
            try {
                $buildInfo = Invoke-WebRequest -Uri "http://localhost:8000/build-info.txt" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
                if ($buildInfo.Content -match "build_number=") {
                    $buildSuccess = $true
                    break
                }
            } catch {}
        }
    } catch {}
    Write-Host "      Waiting for pipeline deployment to verify on localhost:8000 ($timer s)..." -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# 6. Final Status & Verification
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
if ($buildSuccess) {
    Write-Host "  🎉 SUCCESS! PIPELINE HAS AUTOMATICALLY DEPLOYED THE APP!" -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  🌐 Web Application : http://localhost:8000" -ForegroundColor Cyan
    Write-Host "  🛠️  Jenkins UI      : http://localhost:8080  (User: admin / admin123)" -ForegroundColor Cyan
    Write-Host "  🩺 Health Check    : http://localhost:8000/health" -ForegroundColor Cyan
    Write-Host "  📄 Build Info      : http://localhost:8000/build-info.txt" -ForegroundColor Cyan
    Write-Host ""
    
    # Auto open in browser
    Start-Process "http://localhost:8000"
} else {
    Write-Host "  ⚠️ Containers are running! Build is currently executing in Jenkins." -ForegroundColor Yellow
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "  Check live progress at: http://localhost:8080/job/devops-project-pipeline/1/console" -ForegroundColor Cyan
    Write-Host "  Once finished, your app will be at: http://localhost:8000" -ForegroundColor Cyan
}
Write-Host ""
