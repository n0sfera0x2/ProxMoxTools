#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepares a Windows 11 Proxmox VM for conversion into a golden-image
    template.

.DESCRIPTION
    This script:

      - Verifies administrative privileges
      - Creates a transcript log
      - Configures power settings
      - Enables Remote Desktop
      - Optionally configures OpenSSH Server when already installed
      - Verifies and configures the QEMU Guest Agent
      - Installs applications through WinGet
      - Installs Windows updates
      - Detects pending reboot conditions
      - Cleans temporary files
      - Cleans the Windows component store
      - Optionally clears Windows event logs
      - Removes PowerShell history
      - Runs Sysprep with /generalize /oobe /shutdown /mode:vm

.PARAMETER SkipApplications
    Skips installation and updating of applications through WinGet.

.PARAMETER SkipWindowsUpdate
    Skips installation of Windows updates.

.PARAMETER SkipOpenSSH
    Skips all OpenSSH checks and configuration.

.PARAMETER SkipEventLogCleanup
    Preserves existing Windows event logs.

.PARAMETER ForceSysprep
    Continues to Sysprep even when Windows reports a pending reboot.

.PARAMETER SkipSysprep
    Performs image preparation but does not run Sysprep or shut down the VM.

.EXAMPLE
    .\Prepare-GoldenImage.ps1

.EXAMPLE
    .\Prepare-GoldenImage.ps1 -SkipOpenSSH

.EXAMPLE
    .\Prepare-GoldenImage.ps1 -SkipOpenSSH -SkipApplications

.EXAMPLE
    .\Prepare-GoldenImage.ps1 -SkipSysprep

.NOTES
    Run from an elevated PowerShell session.

    When Sysprep completes, the VM will shut down. Do not boot the source VM
    again before converting it into a Proxmox template.
#>

[CmdletBinding()]
param(
    [switch]$SkipApplications,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipOpenSSH,
    [switch]$SkipEventLogCleanup,
    [switch]$ForceSysprep,
    [switch]$SkipSysprep
)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$WorkingDirectory = "C:\GoldenImage"
$LogDirectory = Join-Path $WorkingDirectory "Logs"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDirectory "GoldenImage-$Timestamp.log"

$TranscriptStarted = $false


function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Message
    Write-Host "============================================================"
}


function Write-Info {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[INFO] $Message"
}


function Write-Success {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[SUCCESS] $Message"
}


function Stop-GoldenImageTranscript {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Ignore transcript shutdown errors.
        }

        $script:TranscriptStarted = $false
    }
}


function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Test-PendingReboot {
    $rebootRequiredPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile"
    )

    foreach ($path in $rebootRequiredPaths) {
        if (Test-Path $path) {
            return $true
        }
    }

    $sessionManagerPath =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"

    $pendingFileRename = Get-ItemProperty `
        -Path $sessionManagerPath `
        -Name "PendingFileRenameOperations" `
        -ErrorAction SilentlyContinue

    if ($null -ne $pendingFileRename) {
        return $true
    }

    try {
        $computerSystem = Invoke-CimMethod `
            -Namespace "root\ccm\ClientSDK" `
            -ClassName "CCM_ClientUtilities" `
            -MethodName "DetermineIfRebootPending" `
            -ErrorAction Stop

        if (
            $computerSystem.RebootPending -or
            $computerSystem.IsHardRebootPending
        ) {
            return $true
        }
    }
    catch {
        # SCCM client namespace is normally not present on unmanaged systems.
    }

    return $false
}


function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-Info "Installing $Name..."

    $arguments = @(
        "install"
        "--id"
        $Id
        "--exact"
        "--silent"
        "--accept-package-agreements"
        "--accept-source-agreements"
        "--disable-interactivity"
    )

    $process = Start-Process `
        -FilePath "winget.exe" `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    $acceptedExitCodes = @(
        0,
        -1978335189
    )

    if ($process.ExitCode -in $acceptedExitCodes) {
        Write-Success "$Name installation completed."
    }
    else {
        Write-Warning (
            "$Name returned WinGet exit code " +
            "$($process.ExitCode)."
        )
    }
}


function Install-GoldenImageWindowsUpdates {
    Write-Step "Installing Windows updates"

    try {
        $nugetProvider = Get-PackageProvider `
            -Name NuGet `
            -ErrorAction SilentlyContinue

        if (-not $nugetProvider) {
            Write-Info "Installing the NuGet package provider."

            Install-PackageProvider `
                -Name NuGet `
                -MinimumVersion "2.8.5.201" `
                -Force `
                -Confirm:$false |
                Out-Null
        }

        $repository = Get-PSRepository `
            -Name PSGallery `
            -ErrorAction SilentlyContinue

        if ($repository) {
            Set-PSRepository `
                -Name PSGallery `
                -InstallationPolicy Trusted
        }

        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Info "Installing the PSWindowsUpdate module."

            Install-Module `
                -Name PSWindowsUpdate `
                -Scope AllUsers `
                -Force `
                -AllowClobber `
                -Confirm:$false
        }

        Import-Module PSWindowsUpdate -Force

        Write-Info "Checking Microsoft Update for available updates."

        Get-WindowsUpdate `
            -MicrosoftUpdate `
            -AcceptAll `
            -Install `
            -IgnoreReboot `
            -Verbose
    }
    catch {
        Write-Warning (
            "Windows Update encountered an error: " +
            $_.Exception.Message
        )
    }
}


function Configure-OpenSSH {
    Write-Step "Checking OpenSSH Server"

    $capabilityName = "OpenSSH.Server~~~~0.0.1.0"

    try {
        $capability = Get-WindowsCapability `
            -Online `
            -Name $capabilityName `
            -ErrorAction Stop
    }
    catch {
        Write-Warning (
            "Unable to query the OpenSSH capability: " +
            $_.Exception.Message
        )

        return
    }

    if ($capability.State -ne "Installed") {
        Write-Warning @"
OpenSSH Server is not currently installed.

The script will not automatically install it because
Add-WindowsCapability can stall while waiting for Windows Update.

To install it later, use:

    Settings
    > System
    > Optional features
    > View features
    > OpenSSH Server

Or run this command manually after Windows Update is healthy:

    Add-WindowsCapability -Online `
        -Name OpenSSH.Server~~~~0.0.1.0

To skip this check entirely, run the script with:

    -SkipOpenSSH
"@

        return
    }

    $sshService = Get-Service `
        -Name "sshd" `
        -ErrorAction SilentlyContinue

    if (-not $sshService) {
        Write-Warning (
            "OpenSSH is marked as installed, but the sshd service " +
            "was not found."
        )

        return
    }

    Set-Service `
        -Name "sshd" `
        -StartupType Automatic

    if ($sshService.Status -ne "Running") {
        try {
            Start-Service -Name "sshd" -ErrorAction Stop
        }
        catch {
            Write-Warning (
                "The sshd service could not be started: " +
                $_.Exception.Message
            )
        }
    }

    $firewallRule = Get-NetFirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -ErrorAction SilentlyContinue

    if (-not $firewallRule) {
        New-NetFirewallRule `
            -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort 22 |
            Out-Null
    }
    else {
        Enable-NetFirewallRule `
            -Name "OpenSSH-Server-In-TCP" `
            -ErrorAction SilentlyContinue
    }

    Write-Success "OpenSSH Server is configured."
}


function Configure-QemuGuestAgent {
    Write-Step "Checking QEMU Guest Agent"

    $possibleServiceNames = @(
        "QEMU-GA",
        "qemu-ga"
    )

    $qemuService = $null

    foreach ($serviceName in $possibleServiceNames) {
        $qemuService = Get-Service `
            -Name $serviceName `
            -ErrorAction SilentlyContinue

        if ($qemuService) {
            break
        }
    }

    if (-not $qemuService) {
        Write-Warning @"
QEMU Guest Agent was not detected.

Mount the VirtIO ISO and run:

    virtio-win-guest-tools.exe

Then rerun this script before converting the VM into a template.
"@

        return
    }

    Set-Service `
        -Name $qemuService.Name `
        -StartupType Automatic

    if ($qemuService.Status -ne "Running") {
        try {
            Start-Service `
                -Name $qemuService.Name `
                -ErrorAction Stop
        }
        catch {
            Write-Warning (
                "The QEMU Guest Agent could not be started: " +
                $_.Exception.Message
            )
        }
    }

    $qemuService = Get-Service -Name $qemuService.Name

    Write-Info "QEMU Guest Agent service: $($qemuService.Name)"
    Write-Info "QEMU Guest Agent state: $($qemuService.Status)"
    Write-Success "QEMU Guest Agent configuration completed."
}


function Install-GoldenImageApplications {
    Write-Step "Installing applications"

    $wingetCommand = Get-Command `
        "winget.exe" `
        -ErrorAction SilentlyContinue

    if (-not $wingetCommand) {
        Write-Warning @"
WinGet is not available.

Application installation will be skipped. WinGet is normally installed
through the Microsoft App Installer package.
"@

        return
    }

    try {
        winget.exe source update `
            --disable-interactivity |
            Out-Host
    }
    catch {
        Write-Warning (
            "WinGet source update failed: " +
            $_.Exception.Message
        )
    }

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
            Name = "Python 3.13"
        }
    )

    foreach ($package in $packages) {
        try {
            Install-WingetPackage `
                -Id $package.Id `
                -Name $package.Name
        }
        catch {
            Write-Warning (
                "Could not install $($package.Name): " +
                $_.Exception.Message
            )
        }
    }

    Write-Step "Applying available WinGet application upgrades"

    try {
        $upgradeArguments = @(
            "upgrade"
            "--all"
            "--silent"
            "--accept-package-agreements"
            "--accept-source-agreements"
            "--disable-interactivity"
        )

        $upgradeProcess = Start-Process `
            -FilePath "winget.exe" `
            -ArgumentList $upgradeArguments `
            -Wait `
            -PassThru `
            -NoNewWindow

        if ($upgradeProcess.ExitCode -ne 0) {
            Write-Warning (
                "WinGet upgrade returned exit code " +
                "$($upgradeProcess.ExitCode)."
            )
        }
    }
    catch {
        Write-Warning (
            "WinGet upgrade encountered an error: " +
            $_.Exception.Message
        )
    }
}


function Remove-TemporaryData {
    Write-Step "Cleaning temporary data"

    $temporaryLocations = @(
        "$env:TEMP\*",
        "$env:LOCALAPPDATA\Temp\*",
        "C:\Windows\Temp\*",
        "C:\Windows\SoftwareDistribution\Download\*"
    )

    foreach ($location in $temporaryLocations) {
        Write-Info "Cleaning $location"

        Remove-Item `
            -Path $location `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    try {
        Clear-RecycleBin `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {
        # Recycle Bin may not be initialized for every profile.
    }

    Write-Success "Temporary file cleanup completed."
}


function Clear-GoldenImageEventLogs {
    Write-Step "Clearing Windows event logs"

    $eventLogs = wevtutil.exe el

    foreach ($eventLog in $eventLogs) {
        try {
            wevtutil.exe cl "$eventLog" 2>$null
        }
        catch {
            # Some protected or active logs may not allow clearing.
        }
    }

    Write-Success "Event log cleanup completed."
}


function Remove-ShellHistory {
    Write-Step "Removing PowerShell and shell history"

    try {
        $historyPath = (Get-PSReadLineOption).HistorySavePath

        if ($historyPath) {
            Remove-Item `
                -Path $historyPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
        # PSReadLine may not be loaded.
    }

    $historyLocations = @(
        "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
        "$env:APPDATA\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt"
    )

    foreach ($historyLocation in $historyLocations) {
        Remove-Item `
            -Path $historyLocation `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Clear-History -ErrorAction SilentlyContinue

    Write-Success "Shell history cleanup completed."
}


function Invoke-ComponentCleanup {
    Write-Step "Cleaning the Windows component store"

    $dismArguments = @(
        "/Online"
        "/Cleanup-Image"
        "/StartComponentCleanup"
    )

    $dismProcess = Start-Process `
        -FilePath "dism.exe" `
        -ArgumentList $dismArguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($dismProcess.ExitCode -eq 0) {
        Write-Success "DISM component cleanup completed."
    }
    else {
        Write-Warning (
            "DISM returned exit code " +
            "$($dismProcess.ExitCode)."
        )
    }
}


function Invoke-GoldenImageSysprep {
    Write-Step "Running Sysprep"

    $sysprepPath = Join-Path `
        $env:WINDIR `
        "System32\Sysprep\Sysprep.exe"

    if (-not (Test-Path $sysprepPath)) {
        throw "Sysprep was not found at $sysprepPath."
    }

    Write-Warning @"
Sysprep is about to generalize and shut down this VM.

After the VM powers off:

  1. Do not start the source VM again.
  2. Detach the Windows and VirtIO installation ISOs.
  3. Convert the VM into a Proxmox template.
"@

    $confirmation = Read-Host `
        "Type SYSPREP to continue"

    if ($confirmation -cne "SYSPREP") {
        throw "Sysprep was cancelled by the user."
    }

    Stop-GoldenImageTranscript

    $sysprepArguments = @(
        "/generalize"
        "/oobe"
        "/shutdown"
        "/mode:vm"
    )

    $sysprepProcess = Start-Process `
        -FilePath $sysprepPath `
        -ArgumentList $sysprepArguments `
        -Wait `
        -PassThru

    if ($sysprepProcess.ExitCode -ne 0) {
        throw (
            "Sysprep returned exit code " +
            "$($sysprepProcess.ExitCode). Review " +
            "C:\Windows\System32\Sysprep\Panther\setuperr.log."
        )
    }
}


try {
    if (-not (Test-IsAdministrator)) {
        throw "This script must be run from an elevated PowerShell session."
    }

    New-Item `
        -Path $LogDirectory `
        -ItemType Directory `
        -Force |
        Out-Null

    Start-Transcript `
        -Path $LogFile `
        -Append |
        Out-Null

    $TranscriptStarted = $true

    Write-Step "Starting Windows 11 golden-image preparation"

    $operatingSystem = Get-CimInstance `
        -ClassName Win32_OperatingSystem

    Write-Info "Computer name: $env:COMPUTERNAME"
    Write-Info "Windows edition: $($operatingSystem.Caption)"
    Write-Info "Windows version: $($operatingSystem.Version)"
    Write-Info "Windows build: $($operatingSystem.BuildNumber)"
    Write-Info "Log file: $LogFile"

    Write-Step "Configuring power settings"

    powercfg.exe /hibernate off | Out-Null
    powercfg.exe /change monitor-timeout-ac 0 | Out-Null
    powercfg.exe /change standby-timeout-ac 0 | Out-Null
    powercfg.exe /change disk-timeout-ac 0 | Out-Null

    Write-Success "Sleep and hibernation are disabled."

    Write-Step "Configuring Remote Desktop"

    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0

    Enable-NetFirewallRule `
        -DisplayGroup "Remote Desktop" `
        -ErrorAction SilentlyContinue

    Write-Success "Remote Desktop is enabled."

    if ($SkipOpenSSH) {
        Write-Step "Skipping OpenSSH configuration"
        Write-Info "OpenSSH was skipped because -SkipOpenSSH was specified."
    }
    else {
        Configure-OpenSSH
    }

    Configure-QemuGuestAgent

    if ($SkipApplications) {
        Write-Step "Skipping application installation"
        Write-Info (
            "Application installation was skipped because " +
            "-SkipApplications was specified."
        )
    }
    else {
        Install-GoldenImageApplications
    }

    if ($SkipWindowsUpdate) {
        Write-Step "Skipping Windows Update"
        Write-Info (
            "Windows Update was skipped because " +
            "-SkipWindowsUpdate was specified."
        )
    }
    else {
        Install-GoldenImageWindowsUpdates
    }

    $pendingReboot = Test-PendingReboot

    if ($pendingReboot) {
        Write-Warning @"
Windows reports that a reboot is pending.

The recommended process is:

  1. Stop this run.
  2. Restart Windows.
  3. Sign back in.
  4. Run this script again with:

     -SkipOpenSSH -SkipApplications

This allows pending servicing operations to finish before Sysprep.
"@

        if (-not $ForceSysprep) {
            throw @"
A pending reboot was detected. The script stopped before cleanup and Sysprep.

Restart Windows and rerun the script, or use -ForceSysprep to override this
safety check.
"@
        }

        Write-Warning (
            "Continuing despite a pending reboot because " +
            "-ForceSysprep was specified."
        )
    }

    Remove-TemporaryData

    Invoke-ComponentCleanup

    if ($SkipEventLogCleanup) {
        Write-Step "Skipping event log cleanup"
        Write-Info (
            "Windows event logs were preserved because " +
            "-SkipEventLogCleanup was specified."
        )
    }
    else {
        Clear-GoldenImageEventLogs
    }

    Remove-ShellHistory

    if ($SkipSysprep) {
        Write-Step "Skipping Sysprep"

        Write-Success @"
Golden-image preparation completed without Sysprep.

Review the system, then rerun this script when ready to generalize the VM.
"@

        Stop-GoldenImageTranscript
        exit 0
    }

    Invoke-GoldenImageSysprep

    exit 0
}
catch {
    Write-Host ""
    Write-Error $_.Exception.Message

    if ($TranscriptStarted) {
        Write-Host "Review the transcript log at:"
        Write-Host $LogFile
    }

    Stop-GoldenImageTranscript
    exit 1
}
finally {
    Stop-GoldenImageTranscript
}
