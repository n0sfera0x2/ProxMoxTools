#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepares a Windows 11 VM on Proxmox for conversion into a template.

.DESCRIPTION
    This script:

      - Enables Remote Desktop and its firewall rules
      - Disables sleep and hibernation
      - Finds the attached VirtIO ISO
      - Installs or verifies the QEMU Guest Agent
      - Installs Windows updates using the Windows Update API
      - Detects whether a reboot is required
      - Disables BitLocker and waits for complete decryption
      - Cleans temporary files
      - Runs DISM component cleanup
      - Runs Sysprep with /generalize /oobe /shutdown /mode:vm

    It intentionally does not install applications through WinGet because
    user-scoped AppX/MSIX packages can prevent Sysprep from succeeding.

.PARAMETER SkipWindowsUpdate
    Skips Windows Update.

.PARAMETER SkipQemuAgentInstall
    Does not attempt to install the QEMU Guest Agent from the VirtIO ISO.
    The script will still verify whether the service exists.

.PARAMETER SkipBitLocker
    Skips BitLocker decryption checks. This is not recommended for templates.

.PARAMETER SkipCleanup
    Skips temporary-file and DISM cleanup.

.PARAMETER SkipSysprep
    Performs preparation but does not run Sysprep.

.PARAMETER ForceSysprep
    Allows Sysprep to continue when a pending reboot is detected.

.EXAMPLE
    .\Prepare-GoldenImage.ps1

.EXAMPLE
    .\Prepare-GoldenImage.ps1 -SkipWindowsUpdate

.EXAMPLE
    .\Prepare-GoldenImage.ps1 -SkipSysprep
#>

[CmdletBinding()]
param(
    [switch]$SkipWindowsUpdate,
    [switch]$SkipQemuAgentInstall,
    [switch]$SkipBitLocker,
    [switch]$SkipCleanup,
    [switch]$SkipSysprep,
    [switch]$ForceSysprep
)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$WorkingDirectory = "C:\GoldenImage"
$LogDirectory = Join-Path $WorkingDirectory "Logs"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDirectory "GoldenImage-$Timestamp.log"

$script:TranscriptStarted = $false


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
            # Ignore transcript stop errors.
        }

        $script:TranscriptStarted = $false
    }
}


function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $principal = New-Object `
        Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Test-PendingReboot {
    $rebootPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile"
    )

    foreach ($path in $rebootPaths) {
        if (Test-Path $path) {
            return $true
        }
    }

    $sessionManagerPath =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"

    $pendingRename = Get-ItemProperty `
        -Path $sessionManagerPath `
        -Name "PendingFileRenameOperations" `
        -ErrorAction SilentlyContinue

    if ($null -ne $pendingRename) {
        return $true
    }

    return $false
}


function Configure-PowerSettings {
    Write-Step "Configuring power settings"

    powercfg.exe /hibernate off | Out-Null
    powercfg.exe /change monitor-timeout-ac 0 | Out-Null
    powercfg.exe /change standby-timeout-ac 0 | Out-Null
    powercfg.exe /change disk-timeout-ac 0 | Out-Null

    Write-Success "Sleep and hibernation are disabled."
}


function Configure-RemoteDesktop {
    Write-Step "Enabling Remote Desktop"

    $terminalServerPath =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"

    Set-ItemProperty `
        -Path $terminalServerPath `
        -Name "fDenyTSConnections" `
        -Value 0

    $rdpTcpPath =
        "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

    Set-ItemProperty `
        -Path $rdpTcpPath `
        -Name "UserAuthentication" `
        -Value 1

    Enable-NetFirewallRule `
        -DisplayGroup "Remote Desktop" `
        -ErrorAction SilentlyContinue

    $termService = Get-Service `
        -Name "TermService" `
        -ErrorAction SilentlyContinue

    if ($termService) {
        Set-Service `
            -Name "TermService" `
            -StartupType Automatic

        if ($termService.Status -ne "Running") {
            Start-Service `
                -Name "TermService" `
                -ErrorAction SilentlyContinue
        }
    }

    Write-Success "Remote Desktop is enabled with Network Level Authentication."
}


function Find-VirtioDrive {
    $volumes = Get-CimInstance Win32_LogicalDisk |
        Where-Object {
            $_.DriveType -eq 5 -and $_.DeviceID
        }

    foreach ($volume in $volumes) {
        $driveRoot = "$($volume.DeviceID)\"

        $knownPaths = @(
            "virtio-win-guest-tools.exe",
            "guest-agent\qemu-ga-x86_64.msi",
            "guest-agent\qemu-ga-x86.msi"
        )

        foreach ($relativePath in $knownPaths) {
            $candidate = Join-Path $driveRoot $relativePath

            if (Test-Path $candidate) {
                return $volume.DeviceID
            }
        }
    }

    return $null
}


function Get-QemuGuestAgentService {
    $serviceNames = @(
        "QEMU-GA",
        "qemu-ga"
    )

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service `
            -Name $serviceName `
            -ErrorAction SilentlyContinue

        if ($service) {
            return $service
        }
    }

    return $null
}


function Install-QemuGuestAgent {
    Write-Step "Installing or verifying QEMU Guest Agent"

    $existingService = Get-QemuGuestAgentService

    if ($existingService) {
        Write-Info "QEMU Guest Agent is already installed."
    }
    elseif ($SkipQemuAgentInstall) {
        Write-Warning (
            "QEMU Guest Agent installation was skipped and the service " +
            "is not currently installed."
        )

        return
    }
    else {
        $virtioDrive = Find-VirtioDrive

        if (-not $virtioDrive) {
            throw @"
The VirtIO driver ISO could not be located.

In Proxmox, attach virtio-win.iso to the VM as a CD/DVD drive and rerun
this script.

You can also run the script with -SkipQemuAgentInstall if the agent was
installed another way.
"@
        }

        Write-Info "VirtIO ISO detected at $virtioDrive"

        $driveRoot = "$virtioDrive\"

        $agentMsiCandidates = @(
            (Join-Path $driveRoot "guest-agent\qemu-ga-x86_64.msi"),
            (Join-Path $driveRoot "guest-agent\qemu-ga-x86.msi")
        )

        $agentMsi = $agentMsiCandidates |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1

        if ($agentMsi) {
            Write-Info "Installing QEMU Guest Agent from:"
            Write-Info $agentMsi

            $msiArguments = @(
                "/i"
                "`"$agentMsi`""
                "/qn"
                "/norestart"
            )

            $msiProcess = Start-Process `
                -FilePath "msiexec.exe" `
                -ArgumentList $msiArguments `
                -Wait `
                -PassThru `
                -NoNewWindow

            if ($msiProcess.ExitCode -notin @(0, 3010, 1641)) {
                throw (
                    "QEMU Guest Agent installation returned exit code " +
                    "$($msiProcess.ExitCode)."
                )
            }
        }
        else {
            $guestToolsInstaller =
                Join-Path $driveRoot "virtio-win-guest-tools.exe"

            if (-not (Test-Path $guestToolsInstaller)) {
                throw "No QEMU Guest Agent installer was found on the VirtIO ISO."
            }

            Write-Info "Installing VirtIO guest tools from:"
            Write-Info $guestToolsInstaller

            $guestToolsProcess = Start-Process `
                -FilePath $guestToolsInstaller `
                -ArgumentList "/quiet", "/norestart" `
                -Wait `
                -PassThru

            if ($guestToolsProcess.ExitCode -notin @(0, 3010, 1641)) {
                throw (
                    "VirtIO guest tools returned exit code " +
                    "$($guestToolsProcess.ExitCode)."
                )
            }
        }

        Start-Sleep -Seconds 5

        $existingService = Get-QemuGuestAgentService

        if (-not $existingService) {
            throw @"
The QEMU Guest Agent installer completed, but the service was not found.

Try manually running virtio-win-guest-tools.exe from the VirtIO ISO,
then rerun this script with -SkipQemuAgentInstall.
"@
        }
    }

    Set-Service `
        -Name $existingService.Name `
        -StartupType Automatic

    if ($existingService.Status -ne "Running") {
        Start-Service `
            -Name $existingService.Name `
            -ErrorAction Stop
    }

    $existingService = Get-Service -Name $existingService.Name

    Write-Info "Service name: $($existingService.Name)"
    Write-Info "Service status: $($existingService.Status)"
    Write-Success "QEMU Guest Agent is installed and configured."
}


function Install-WindowsUpdates {
    Write-Step "Installing Windows updates"

    Write-Info "Searching for applicable Windows updates."

    $updateSession = New-Object `
        -ComObject "Microsoft.Update.Session"

    $updateSearcher = $updateSession.CreateUpdateSearcher()

    $searchResult = $updateSearcher.Search(
        "IsInstalled=0 and IsHidden=0"
    )

    if ($searchResult.Updates.Count -eq 0) {
        Write-Success "No applicable Windows updates were found."
        return
    }

    Write-Info (
        "$($searchResult.Updates.Count) applicable update(s) found."
    )

    $updatesToInstall = New-Object `
        -ComObject "Microsoft.Update.UpdateColl"

    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)

        Write-Info "Found: $($update.Title)"

        if (-not $update.EulaAccepted) {
            $update.AcceptEula()
        }

        [void]$updatesToInstall.Add($update)
    }

    Write-Info "Downloading Windows updates."

    $downloader = $updateSession.CreateUpdateDownloader()
    $downloader.Updates = $updatesToInstall

    $downloadResult = $downloader.Download()

    Write-Info "Download result code: $($downloadResult.ResultCode)"

    $downloadedUpdates = New-Object `
        -ComObject "Microsoft.Update.UpdateColl"

    for ($index = 0; $index -lt $updatesToInstall.Count; $index++) {
        $update = $updatesToInstall.Item($index)

        if ($update.IsDownloaded) {
            [void]$downloadedUpdates.Add($update)
        }
        else {
            Write-Warning "Update did not download: $($update.Title)"
        }
    }

    if ($downloadedUpdates.Count -eq 0) {
        throw "No Windows updates were successfully downloaded."
    }

    Write-Info "Installing downloaded Windows updates."

    $installer = $updateSession.CreateUpdateInstaller()
    $installer.Updates = $downloadedUpdates

    $installationResult = $installer.Install()

    Write-Info (
        "Windows Update result code: " +
        "$($installationResult.ResultCode)"
    )

    for ($index = 0; $index -lt $downloadedUpdates.Count; $index++) {
        $update = $downloadedUpdates.Item($index)
        $updateResult = $installationResult.GetUpdateResult($index)

        Write-Info (
            "$($update.Title) -- result code " +
            "$($updateResult.ResultCode)"
        )
    }

    if ($installationResult.RebootRequired) {
        Write-Warning "Windows Update requires a reboot."
    }
    else {
        Write-Success "Windows updates completed without requesting a reboot."
    }
}


function Disable-GoldenImageBitLocker {
    Write-Step "Checking BitLocker status"

    $bitLockerVolume = Get-BitLockerVolume `
        -MountPoint "C:" `
        -ErrorAction SilentlyContinue

    if (-not $bitLockerVolume) {
        Write-Info "No BitLocker volume information was returned."
        return
    }

    Write-Info (
        "Volume status: " +
        "$($bitLockerVolume.VolumeStatus)"
    )

    Write-Info (
        "Protection status: " +
        "$($bitLockerVolume.ProtectionStatus)"
    )

    Write-Info (
        "Encryption percentage: " +
        "$($bitLockerVolume.EncryptionPercentage)%"
    )

    if (
        $bitLockerVolume.VolumeStatus -eq "FullyDecrypted" -and
        $bitLockerVolume.EncryptionPercentage -eq 0
    ) {
        Write-Success "The operating-system volume is fully decrypted."
        return
    }

    Write-Info "Turning BitLocker off for C:."

    Disable-BitLocker `
        -MountPoint "C:" `
        -ErrorAction Stop |
        Out-Null

    Write-Info "Waiting for BitLocker decryption to complete."

    while ($true) {
        Start-Sleep -Seconds 15

        $bitLockerVolume = Get-BitLockerVolume `
            -MountPoint "C:" `
            -ErrorAction Stop

        $percentage = $bitLockerVolume.EncryptionPercentage

        Write-Host (
            "[INFO] BitLocker encryption remaining: " +
            "$percentage%"
        )

        if (
            $bitLockerVolume.VolumeStatus -eq "FullyDecrypted" -and
            $percentage -eq 0
        ) {
            break
        }
    }

    Write-Success "BitLocker decryption is complete."
}


function Remove-TemporaryData {
    Write-Step "Cleaning temporary files"

    try {
        Stop-Service `
            -Name "wuauserv" `
            -Force `
            -ErrorAction SilentlyContinue

        Stop-Service `
            -Name "bits" `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {
        # Continue even if services cannot be stopped.
    }

    $temporaryPaths = @(
        "$env:TEMP\*",
        "$env:LOCALAPPDATA\Temp\*",
        "C:\Windows\Temp\*",
        "C:\Windows\SoftwareDistribution\Download\*"
    )

    foreach ($temporaryPath in $temporaryPaths) {
        Write-Info "Cleaning $temporaryPath"

        Remove-Item `
            -Path $temporaryPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    try {
        Start-Service `
            -Name "bits" `
            -ErrorAction SilentlyContinue

        Start-Service `
            -Name "wuauserv" `
            -ErrorAction SilentlyContinue
    }
    catch {
        # Services will start automatically later if required.
    }

    Clear-RecycleBin `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Success "Temporary-file cleanup completed."
}


function Invoke-ComponentCleanup {
    Write-Step "Cleaning the Windows component store"

    $arguments = @(
        "/Online"
        "/Cleanup-Image"
        "/StartComponentCleanup"
    )

    $process = Start-Process `
        -FilePath "dism.exe" `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($process.ExitCode -ne 0) {
        Write-Warning (
            "DISM component cleanup returned exit code " +
            "$($process.ExitCode)."
        )

        return
    }

    Write-Success "Windows component-store cleanup completed."
}


function Invoke-GoldenImageSysprep {
    Write-Step "Running Sysprep"

    $sysprepPath =
        "$env:WINDIR\System32\Sysprep\Sysprep.exe"

    if (-not (Test-Path $sysprepPath)) {
        throw "Sysprep was not found at $sysprepPath."
    }

    Write-Warning @"
Sysprep will generalize this Windows installation and shut down the VM.

After the VM powers off:

  1. Do not boot the original VM again.
  2. Detach the Windows installation ISO.
  3. Detach the VirtIO ISO.
  4. Enable QEMU Guest Agent in Proxmox under VM Options.
  5. Convert the VM into a Proxmox template.
"@

    $confirmation = Read-Host "Type SYSPREP to continue"

    if ($confirmation -cne "SYSPREP") {
        throw "Sysprep was cancelled."
    }

    Stop-GoldenImageTranscript

    $arguments = @(
        "/generalize"
        "/oobe"
        "/shutdown"
        "/mode:vm"
    )

    $process = Start-Process `
        -FilePath $sysprepPath `
        -ArgumentList $arguments `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw @"
Sysprep returned exit code $($process.ExitCode).

Review:

C:\Windows\System32\Sysprep\Panther\setuperr.log
C:\Windows\System32\Sysprep\Panther\setupact.log
"@
    }
}


try {
    if (-not (Test-Administrator)) {
        throw "Run this script from an elevated PowerShell window."
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

    $script:TranscriptStarted = $true

    Write-Step "Starting Windows 11 golden-image preparation"

    $operatingSystem = Get-CimInstance `
        -ClassName Win32_OperatingSystem

    Write-Info "Computer name: $env:COMPUTERNAME"
    Write-Info "Windows edition: $($operatingSystem.Caption)"
    Write-Info "Windows build: $($operatingSystem.BuildNumber)"
    Write-Info "Transcript log: $LogFile"

    Configure-PowerSettings
    Configure-RemoteDesktop
    Install-QemuGuestAgent

    if ($SkipWindowsUpdate) {
        Write-Step "Skipping Windows Update"
        Write-Info "-SkipWindowsUpdate was specified."
    }
    else {
        Install-WindowsUpdates
    }

    if (Test-PendingReboot) {
        Write-Warning @"
Windows requires a reboot.

The safest workflow is:

  1. Restart Windows.
  2. Sign back in.
  3. Rerun this script with:

     .\Prepare-GoldenImage.ps1 -SkipWindowsUpdate

This allows pending updates and driver changes to finish before Sysprep.
"@

        if (-not $ForceSysprep) {
            throw "A pending reboot was detected. Restart Windows and rerun the script."
        }

        Write-Warning (
            "Continuing because -ForceSysprep was specified. " +
            "This is not recommended."
        )
    }

    if ($SkipBitLocker) {
        Write-Step "Skipping BitLocker check"
        Write-Warning (
            "Sysprep will fail if the operating-system volume is encrypted."
        )
    }
    else {
        Disable-GoldenImageBitLocker
    }

    if ($SkipCleanup) {
        Write-Step "Skipping image cleanup"
    }
    else {
        Remove-TemporaryData
        Invoke-ComponentCleanup
    }

    if ($SkipSysprep) {
        Write-Step "Preparation completed without Sysprep"

        Write-Success @"
The VM has been prepared, but it has not been generalized.

Rerun the script without -SkipSysprep when you are ready to create
the template.
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

    if ($script:TranscriptStarted) {
        Write-Host ""
        Write-Host "Transcript log:"
        Write-Host $LogFile
    }

    Stop-GoldenImageTranscript
    exit 1
}
finally {
    Stop-GoldenImageTranscript
}
