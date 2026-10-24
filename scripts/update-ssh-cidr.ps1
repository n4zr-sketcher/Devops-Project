<#
.SYNOPSIS
    Updates the `allowed_ssh_cidr` value inside terraform/terraform.tfvars with
    your CURRENT public IP address.

.DESCRIPTION
    Home broadband connections usually get a new public IP every time the
    router reconnects. If your IP changes, the Azure Network Security Group
    still allows the OLD address, and Jenkins will fail to SSH into the VM
    with a "Connection timed out" error.

    Run this script before `terraform apply` and whenever the IP changes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/update-ssh-cidr.ps1
#>

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$tfvarsPath = Join-Path $repoRoot 'terraform\terraform.tfvars'

if (-not (Test-Path -LiteralPath $tfvarsPath)) {
    Write-Host "ERROR: $tfvarsPath not found. Create it from terraform.tfvars.example first." -ForegroundColor Red
    exit 1
}

Write-Host 'Detecting your current public IP address...' -ForegroundColor Cyan
$ip = Invoke-RestMethod -Uri 'https://api.ipify.org'
Write-Host "  detected: $ip" -ForegroundColor Green

$content = Get-Content -LiteralPath $tfvarsPath -Raw

if ($content -match 'allowed_ssh_cidr\s*=\s*"([^"]*)"') {
    $old = $Matches[1]
    $new = "$ip/32"
    $content = $content -replace 'allowed_ssh_cidr\s*=\s*"[^"]*"', "allowed_ssh_cidr = `"$new`""
    Set-Content -LiteralPath $tfvarsPath -Value $content -Encoding UTF8
    Write-Host "  updated : allowed_ssh_cidr  `"$old`"  ->  `"$new`"" -ForegroundColor Green
} else {
    Write-Host '  WARNING: no allowed_ssh_cidr entry found - add the line manually:' -ForegroundColor Yellow
    Write-Host "    allowed_ssh_cidr = `"$ip/32`"" -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  cd terraform'
Write-Host '  terraform plan      # review the change (one rule is updated)'
Write-Host '  terraform apply     # push the new rule to Azure'
Write-Host ''
Write-Host 'NOTE: this only updates the Azure rule for SSH.' -ForegroundColor DarkGray
Write-Host '      Your Jenkins VM_IP variable must be updated separately in Jenkins.' -ForegroundColor DarkGray
