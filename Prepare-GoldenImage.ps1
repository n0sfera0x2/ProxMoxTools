#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepares a Windows 11 Proxmox VM for conversion into a golden-image template.

.DESCRIPTION
    This script:
      - Verifies administrative privileges
      - Creates a transcript log
      - Configures power settings
      - Installs common tools through WinGet
      - Installs available Windows updates
      - Enables OpenSSH and Remote Desktop
      - Verifies the QEMU Guest Agent
      - Clears temporary data and event logs
      - Runs DISM component cleanup
      - Runs Sysprep with /generalize /oobe /shutdown

.NOTES
    Review the software list before running.
    The VM will shut down when Sysprep completes.
#>

[CmdletBinding()]
param(
    [switch]$SkipApplications,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipOpenSSH,
    [switch]$SkipEventLogCleanup
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$WorkingDirectory = "C:\GoldenImage"
$LogDirectory = Join-Path $WorkingDirectory "Logs"
$LogFile = Join-Path $LogDirectory "GoldenImage-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
Start-Transcript -Path $LogFile -Append

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Message
    Write-Host "============================================================"
}

function Test-PendingReboot {
    $locations = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )

    foreach ($location in $locations) {
        if (Test-Path $location) {
            if ($location -like "*Session Manager") {
                $value = Get-ItemProperty `
                    -Path $location `
                    -Name PendingFileRenameOperations `
                    -ErrorAction SilentlyContinue

                if ($null -ne $value) {
                    return $true
                }
            }
            else {
                return $true
            }
        }
    }

    return $false
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name
    )

    Write-Host "Installing $Name..."

    $arguments = @(
        "install",
        "--id", $Id,
        "--exact",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    $process = Start-Process `
        -FilePath "winget.exe" `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($process.ExitCode -notin @(0, -1978335189)) {
        Write-Warning "$Name returned exit code $($process.ExitCode)."
    }
}

function Install-WindowsUpdates {
    Write-Step "Installing Windows updates"

    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

        Install-PackageProvider `
            -Name NuGet `
            -MinimumVersion 2.8.5.201 `
            -Force

        Install-Module `
            -Name PSWindowsUpdate `
            -Scope AllUsers `
            -Force `
            -Confirm:$false
    }

    Import-Module PSWindowsUpdate

    Get-WindowsUpdate `
        -MicrosoftUpdate `
        -AcceptAll `
        -Install `
        -IgnoreReboot
}

try {
    Write-Step "Starting Windows 11 golden-image preparation"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        throw "This script must be run as Administrator."
    }

    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Windows version: $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Host "Build: $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"

    Write-Step "Disabling sleep and hibernation"

    powercfg.exe /hibernate off
    powercfg.exe /change monitor-timeout-ac 0
    powercfg.exe /change standby-timeout-ac 0
    powercfg.exe /change disk-timeout-ac 0

    Write-Step "Configuring Remote Desktop"

    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

    if (-not $SkipOpenSSH) {
        Write-Step "Installing and configuring OpenSSH Server"

        $sshCapability = Get-WindowsCapability -Online |
            Where-Object Name -Like "OpenSSH.Server*"

        if ($sshCapability.State -ne "Installed") {
            Add-WindowsCapability `
                -Online `
                -Name $sshCapability.Name |
                Out-Null
        }

        Set-Service sshd -StartupType Automatic
        Start-Service sshd

        if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -Name "OpenSSH-Server-In-TCP" `
                -DisplayName "OpenSSH Server (sshd)" `
                -Enabled True `
                -Direction Inbound `
                -Protocol TCP `
                -Action Allow `
                -LocalPort 22
        }
    }

    Write-Step "Checking QEMU Guest Agent"

    $qemuService = Get-Service `
        -Name "QEMU-GA" `
        -ErrorAction SilentlyContinue

    if ($qemuService) {
        Set-Service -Name $qemuService.Name -StartupType Automatic

        if ($qemuService.Status -ne "Running") {
            Start-Service -Name $qemuService.Name
        }

        Write-Host "QEMU Guest Agent is installed and running."
    }
    else {
        Write-Warning @"
QEMU Guest Agent was not detected.

Mount the VirtIO ISO and run:
    virtio-win-guest-tools.exe

Then rerun this script before creating the template.
"@
    }

    if (-not $SkipApplications) {
        Write-Step "Installing applications"

        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue

        if (-not $winget) {
            Write-Warning "WinGet is unavailable. Skipping application installation."
        }
        else {
            $packages = @(
                @{
                    Id   = "7zip.7zip"
                    Name = "7-Zip"
                },
                @{
                    Id   = "Git.Git"
                    Name = "Git"
                },
                @{
                    Id   = "Microsoft.PowerShell"
                    Name = "PowerShell 7"
                },
                @{
                    Id   = "Microsoft.Sysinternals"
                    Name = "Sysinternals Suite"
                },
                @{
                    Id   = "Microsoft.VisualStudioCode"
                    Name = "Visual Studio Code"
                },
                @{
                    Id   = "Mozilla.Firefox"
                    Name = "Firefox"
                },
                @{
                    Id   = "Python.Python.3.13"
                    Name = "Python"
                }
            )

            foreach ($package in $packages) {
                try {
                    Install-WingetPackage `
                        -Id $package.Id `
                        -Name $package.Name
                }
                catch {
                    Write-Warning "Could not install $($package.Name): $($_.Exception.Message)"
                }
            }

            Write-Host "Applying available WinGet upgrades..."

            winget.exe upgrade `
                --all `
                --silent `
                --accept-package-agreements `
                --accept-source-agreements `
                --disable-interactivity
        }
    }

    if (-not $SkipWindowsUpdate) {
        try {
            Install-WindowsUpdates
        }
        catch {
            Write-Warning "Windows Update encountered an error: $($_.Exception.Message)"
        }
    }

    if (Test-PendingReboot) {
        Write-Warning @"
A reboot is pending.

For the cleanest image, reboot Windows, sign back in, and run this script again.
Use -SkipApplications on the second run to avoid reinstalling applications.
"@

        $response = Read-Host "Continue to Sysprep despite the pending reboot? Type YES to continue"

        if ($response -ne "YES") {
            throw "Stopped because Windows requires a reboot."
        }
    }

    Write-Step "Cleaning temporary data"

    $temporaryLocations = @(
        "$env:TEMP\*",
        "C:\Windows\Temp\*",
        "C:\Windows\SoftwareDistribution\Download\*"
    )

    foreach ($location in $temporaryLocations) {
        Remove-Item `
            -Path $location `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    Write-Step "Cleaning Windows component store"

    $dism = Start-Process `
        -FilePath "dism.exe" `
        -ArgumentList @(
            "/Online",
            "/Cleanup-Image",
            "/StartComponentCleanup"
        ) `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($dism.ExitCode -ne 0) {
        Write-Warning "DISM returned exit code $($dism.ExitCode)."
    }

    if (-not $SkipEventLogCleanup) {
        Write-Step "Clearing Windows event logs"

        wevtutil.exe el |
            ForEach-Object {
                wevtutil.exe cl $_ 2>$null
            }
    }

    Write-Step "Removing shell and PowerShell history"

    Remove-Item `
        -Path (Get-PSReadLineOption).HistorySavePath `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -Path "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Step "Running Sysprep"

    Write-Host "The VM will shut down when Sysprep finishes."
    Write-Host "Do not start this source VM again before converting it to a template."

    Stop-Transcript

    $sysprep = "$env:WINDIR\System32\Sysprep\Sysprep.exe"

    Start-Process `
        -FilePath $sysprep `
        -ArgumentList @(
            "/generalize",
            "/oobe",
            "/shutdown",
            "/mode:vm"
        ) `
        -Wait

    exit 0
}
catch {
    Write-Error $_
    Stop-Transcript -ErrorAction SilentlyContinue
    exit 1
}
