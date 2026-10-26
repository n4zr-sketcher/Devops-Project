<#
.SYNOPSIS
    1-Command Teardown for Azure Cloud Resources to stop billing.
.DESCRIPTION
    Runs terraform destroy -auto-approve and resets Jenkins to local mode.
#>

[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

& (Join-Path $ScriptDir "automate-cloud.ps1") -Destroy
