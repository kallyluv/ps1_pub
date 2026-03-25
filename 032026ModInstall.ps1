# ==========================================================
# FINAL DISTRIBUTION-READY MODRINTH COLLECTION INSTALLER
# ==========================================================
# Edit ONLY these values before sharing
$PackName = "Realm LLC | March 2026"        # Display name shown to friends
$CollectionId = "jzv4PGVM"      # <-- CHANGE THIS
$MinecraftVersion = "1.21.11"    # <-- CHANGE THIS
$Loader = "fabric"              # <-- CHANGE THIS (fabric / forge / quilt / neoforge)
# ==========================================================

$ApiBase = "https://api.modrinth.com"
$MinecraftDir = Join-Path $env:APPDATA ".minecraft"
$ModsDir = Join-Path $MinecraftDir "mods"
$Desktop = [Environment]::GetFolderPath("Desktop")
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $Desktop "$($PackName -replace '[^\w\- ]','')_InstallLog_$Timestamp.txt"

# Track already processed projects (prevents duplicate shared dependency installs)
$ProcessedProjects = New-Object 'System.Collections.Generic.HashSet[string]'

# Track collection project IDs separately so we can distinguish main mods vs dependencies
$CollectionProjectSet = New-Object 'System.Collections.Generic.HashSet[string]'

# Stats
$Stats = [ordered]@{
    MainInstalled = 0
    MainUpdated   = 0
    MainSkipped   = 0
    MainFailed    = 0

    DepInstalled  = 0
    DepUpdated    = 0
    DepSkipped    = 0
    DepFailed     = 0
}

$FailedMods = New-Object System.Collections.Generic.List[string]

# ==========================================================
# LOGGING
# ==========================================================
function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $Message
}

function Write-Section {
    param([string]$Title)

    Write-Log ""
    Write-Log "==========================================================" "White"
    Write-Log $Title "White"
    Write-Log "==========================================================" "White"
}

# ==========================================================
# HELPERS
# ==========================================================
function Add-Stat {
    param([string]$Key)
    if ($Stats.Contains($Key)) { $Stats[$Key]++ }
}

function Mark-Failure {
    param(
        [string]$Name,
        [bool]$IsDependency
    )

    $FailedMods.Add($Name) | Out-Null

    if ($IsDependency) {
        Add-Stat "DepFailed"
    }
    else {
        Add-Stat "MainFailed"
    }
}

function Ask-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }

    while ($true) {
        $answer = Read-Host "$Prompt $suffix"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }

        switch ($answer.Trim().ToLower()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
            default { Write-Log "Please enter Y or N." "Yellow" }
        }
    }
}

function Get-ModrinthJson {
    param([string]$Url)

    try {
        return Invoke-RestMethod -Uri ($ApiBase + $Url) -Method Get
    }
    catch {
        Write-Log "ERROR: Failed request $Url" "Red"
        return $null
    }
}

function Get-ProjectInfo {
    param([string]$ProjectId)
    return Get-ModrinthJson "/v2/project/$ProjectId"
}

function Get-ProjectDisplayName {
    param([string]$ProjectId)

    $project = Get-ProjectInfo $ProjectId
    if ($project) {
        if ($project.title) { return "$($project.title) ($ProjectId)" }
        if ($project.slug)  { return "$($project.slug) ($ProjectId)" }
    }

    return $ProjectId
}

function Get-LatestMatchingVersion {
    param([string]$ProjectId)

    $versions = Get-ModrinthJson "/v2/project/$ProjectId/version"
    if (-not $versions) { return $null }

    foreach ($ver in $versions) {
        if (($ver.game_versions -contains $MinecraftVersion) -and ($ver.loaders -contains $Loader)) {
            return $ver
        }
    }

    return $null
}

function Get-FilenameWithProjectId {
    param(
        [string]$OriginalFileName,
        [string]$ProjectId
    )

    $dotIndex = $OriginalFileName.LastIndexOf(".")
    if ($dotIndex -gt 0) {
        return $OriginalFileName.Insert($dotIndex, ".$ProjectId")
    }
    else {
        return "$OriginalFileName.$ProjectId"
    }
}

function Find-ExistingProjectFiles {
    param([string]$ProjectId)

    if (-not (Test-Path $ModsDir)) {
        return @()
    }

    return @(Get-ChildItem -Path $ModsDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match [regex]::Escape(".$ProjectId.") -or $_.Name -match ([regex]::Escape(".$ProjectId") + '$')
    })
}

function Backup-ModsFolder {
    if (-not (Test-Path $ModsDir)) {
        Write-Log "No existing mods folder to back up." "DarkGray"
        return $true
    }

    $backupRoot = Join-Path $MinecraftDir "modpack-installer-backups"
    $backupPath = Join-Path $backupRoot ("mods-backup-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))

    try {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Copy-Item -Path $ModsDir -Destination $backupPath -Recurse -Force
        Write-Log "Backed up current mods folder to:" "Green"
        Write-Log "  $backupPath" "Green"
        return $true
    }
    catch {
        Write-Log "ERROR: Failed to back up current mods folder." "Red"
        return $false
    }
}

function Clear-ModsFolder {
    if (-not (Test-Path $ModsDir)) {
        return $true
    }

    try {
        Get-ChildItem -Path $ModsDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction Stop
        Write-Log "Cleared existing files from mods folder." "Green"
        return $true
    }
    catch {
        Write-Log "ERROR: Failed to clear mods folder." "Red"
        return $false
    }
}

# ==========================================================
# INSTALL LOGIC
# ==========================================================
function Process-Project {
    param(
        [string]$ProjectId,
        [bool]$IsDependency = $false,
        [string]$ParentProjectId = $null
    )

    # Prevent duplicate processing
    if (-not $ProcessedProjects.Add($ProjectId)) {
        return
    }

    $projectDisplay = Get-ProjectDisplayName $ProjectId
    $prefix = if ($IsDependency) { "  [DEPENDENCY] " } else { "" }

    $version = Get-LatestMatchingVersion $ProjectId
    if (-not $version) {
        $msg = "${prefix}ERROR: No matching version for $projectDisplay [$MinecraftVersion / $Loader]"
        if ($IsDependency -and $ParentProjectId) {
            $parentDisplay = Get-ProjectDisplayName $ParentProjectId
            $msg += " (required by $parentDisplay)"
        }

        Write-Log $msg "Red"
        Mark-Failure -Name $projectDisplay -IsDependency $IsDependency
        return
    }

    # Process required dependencies first
    $requiredDeps = @($version.dependencies | Where-Object {
        $_.dependency_type -eq "required" -and $_.project_id
    })

    foreach ($dep in $requiredDeps) {
        Process-Project -ProjectId $dep.project_id -IsDependency $true -ParentProjectId $ProjectId
    }

    # Primary file
    $primaryFile = $version.files | Where-Object { $_.primary -eq $true } | Select-Object -First 1
    if (-not $primaryFile) {
        Write-Log "${prefix}ERROR: No primary file for $projectDisplay" "Red"
        Mark-Failure -Name $projectDisplay -IsDependency $IsDependency
        return
    }

    $targetFileName = Get-FilenameWithProjectId -OriginalFileName $primaryFile.filename -ProjectId $ProjectId
    $targetPath = Join-Path $ModsDir $targetFileName
    $existingFiles = @(Find-ExistingProjectFiles -ProjectId $ProjectId)
    $exactExisting = $existingFiles | Where-Object { $_.Name -eq $targetFileName } | Select-Object -First 1

    # Already current
    if ($exactExisting) {
        Write-Log "${prefix}SKIP: $projectDisplay already up to date ($targetFileName)" "DarkGray"

        if ($IsDependency) {
            Add-Stat "DepSkipped"
        }
        else {
            Add-Stat "MainSkipped"
        }
        return
    }

    $action = if ($existingFiles.Count -gt 0) { "UPDATING" } else { "INSTALLING" }

    if ($IsDependency -and $ParentProjectId) {
        $parentDisplay = Get-ProjectDisplayName $ParentProjectId
        Write-Log "${prefix}${action}: $projectDisplay -> $targetFileName (required by $parentDisplay)" "Cyan"
    }
    else {
        Write-Log "${prefix}${action}: $projectDisplay -> $targetFileName" "Cyan"
    }

    $tempPath = "$targetPath.download"

    try {
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        }

        Invoke-WebRequest -Uri $primaryFile.url -OutFile $tempPath

        if (-not (Test-Path $tempPath)) {
            throw "Download failed (temp file missing)"
        }

        $tempInfo = Get-Item $tempPath
        if ($tempInfo.Length -le 0) {
            throw "Download failed (temp file empty)"
        }

        # Remove old versions only after successful download
        foreach ($oldFile in $existingFiles) {
            try {
                Remove-Item $oldFile.FullName -Force
                Write-Log "${prefix}REMOVED: Old version $($oldFile.Name)" "DarkYellow"
            }
            catch {
                Write-Log "${prefix}WARNING: Could not remove old version $($oldFile.Name)" "Yellow"
            }
        }

        Move-Item -Path $tempPath -Destination $targetPath -Force
        Write-Log "${prefix}OK: Installed $projectDisplay" "Green"

        if ($IsDependency) {
            Add-Stat "DepInstalled"
            if ($existingFiles.Count -gt 0) { Add-Stat "DepUpdated" }
        }
        else {
            Add-Stat "MainInstalled"
            if ($existingFiles.Count -gt 0) { Add-Stat "MainUpdated" }
        }
    }
    catch {
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        }

        Write-Log "${prefix}ERROR: Failed to install $projectDisplay" "Red"
        Mark-Failure -Name $projectDisplay -IsDependency $IsDependency
    }
}

# ==========================================================
# START
# ==========================================================
try {
    New-Item -ItemType File -Path $LogFile -Force | Out-Null
}
catch {
    Write-Host "ERROR: Could not create log file on Desktop." -ForegroundColor Red
    Pause
    exit 1
}

Write-Section "$PackName Installer"
Write-Log "Pack Name:   $PackName"
Write-Log "Collection:  $CollectionId"
Write-Log "Minecraft:   $MinecraftVersion"
Write-Log "Loader:      $Loader"
Write-Log "Minecraft:   $MinecraftDir"
Write-Log "Mods Folder: $ModsDir"
Write-Log "Log File:    $LogFile"

# Basic .minecraft check
if (-not (Test-Path $MinecraftDir)) {
    Write-Log ""
    Write-Log "ERROR: Could not find your .minecraft folder." "Red"
    Write-Log "Expected path:" "Red"
    Write-Log "  $MinecraftDir" "Red"
    Write-Log ""
    Write-Log "Please launch Minecraft at least once first, then run this installer again." "Yellow"
    Write-Log ""
    Pause
    exit 1
}

# Ensure mods folder exists
if (-not (Test-Path $ModsDir)) {
    try {
        New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null
        Write-Log ""
        Write-Log "Created mods folder." "Green"
    }
    catch {
        Write-Log ""
        Write-Log "ERROR: Could not create mods folder." "Red"
        Pause
        exit 1
    }
}

# Fetch collection
Write-Log ""
Write-Log "Fetching mod collection..." "White"
$collection = Get-ModrinthJson "/v3/collection/$CollectionId"

if (-not $collection) {
    Write-Log "ERROR: Could not fetch collection $CollectionId" "Red"
    Pause
    exit 1
}

$projects = @($collection.projects)
if (-not $projects -or $projects.Count -eq 0) {
    Write-Log "ERROR: This collection contains no projects." "Red"
    Pause
    exit 1
}

foreach ($projectId in $projects) {
    [void]$CollectionProjectSet.Add($projectId)
}

Write-Log "Found $($projects.Count) mod(s) in collection." "Green"

# User-friendly safety prompts
Write-Section "Before We Install"

$modsFileCount = @(Get-ChildItem -Path $ModsDir -File -ErrorAction SilentlyContinue).Count
Write-Log "Your current mods folder contains $modsFileCount file(s)." "White"
Write-Log ""

$doBackup = Ask-YesNo -Prompt "Back up your current mods folder before installing?" -Default $true
if ($doBackup) {
    if (-not (Backup-ModsFolder)) {
        Write-Log ""
        $continueWithoutBackup = Ask-YesNo -Prompt "Backup failed. Continue anyway?" -Default $false
        if (-not $continueWithoutBackup) {
            Write-Log "Install cancelled." "Yellow"
            Pause
            exit 1
        }
    }
}

$clearExisting = Ask-YesNo -Prompt "Clear existing mods folder first? (Recommended for best compatibility)" -Default $false
if ($clearExisting) {
    if (-not (Clear-ModsFolder)) {
        Write-Log "Install cancelled because mods folder could not be cleared." "Red"
        Pause
        exit 1
    }
}

Write-Section "Installing Mods"

foreach ($projectId in $projects) {
    Process-Project -ProjectId $projectId
}

# ==========================================================
# SUMMARY
# ==========================================================
Write-Section "Install Summary"

$depProcessed = $Stats.DepInstalled + $Stats.DepSkipped + $Stats.DepFailed
$totalInstalled = $Stats.MainInstalled + $Stats.DepInstalled
$totalUpdated = $Stats.MainUpdated + $Stats.DepUpdated
$totalSkipped = $Stats.MainSkipped + $Stats.DepSkipped
$totalFailed = $Stats.MainFailed + $Stats.DepFailed
$totalProcessed = $totalInstalled + $totalSkipped + $totalFailed

Write-Log "Main Mods (from collection):" "White"
Write-Log "  Total in collection: $($projects.Count)"
Write-Log "  Installed:           $($Stats.MainInstalled)"
Write-Log "  Updated:             $($Stats.MainUpdated)"
Write-Log "  Skipped:             $($Stats.MainSkipped)"
Write-Log "  Failed:              $($Stats.MainFailed)"

if ($depProcessed -gt 0) {
    Write-Log ""
    Write-Log "Dependencies:" "White"
    Write-Log "  Total processed:     $depProcessed"
    Write-Log "  Installed:           $($Stats.DepInstalled)"
    Write-Log "  Updated:             $($Stats.DepUpdated)"
    Write-Log "  Skipped:             $($Stats.DepSkipped)"
    Write-Log "  Failed:              $($Stats.DepFailed)"
}

Write-Log ""
Write-Log "Overall:" "White"
Write-Log "  Total processed:     $totalProcessed"
Write-Log "  Installed:           $totalInstalled"
Write-Log "  Updated:             $totalUpdated"
Write-Log "  Skipped:             $totalSkipped"
Write-Log "  Failed:              $totalFailed"

if ($FailedMods.Count -gt 0) {
    Write-Log ""
    Write-Log "Failed Mods:" "Red"
    foreach ($mod in $FailedMods) {
        Write-Log "  - $mod" "Red"
    }
}

Write-Section "Important Final Info"
Write-Log "This modpack requires Minecraft version: $MinecraftVersion" "Yellow"
Write-Log "This modpack requires loader:            $Loader" "Yellow"
Write-Log ""
Write-Log "Make sure you have the correct mod loader installed before launching Minecraft." "Yellow"
Write-Log "If the game crashes, the most common causes are:" "Yellow"
Write-Log "  1) Wrong Minecraft version" "Yellow"
Write-Log "  2) Wrong mod loader ($Loader required)" "Yellow"
Write-Log "  3) Other leftover mods causing conflicts" "Yellow"
Write-Log ""
Write-Log "Install complete. Your mods folder is here:" "Green"
Write-Log "  $ModsDir" "Green"
Write-Log ""
Write-Log "A full install log was saved here:" "Green"
Write-Log "  $LogFile" "Green"
Write-Log ""

Pause
