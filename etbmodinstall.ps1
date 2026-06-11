[CmdletBinding()]
param(
	[string]$GameDirectory,
	[switch]$KeepDownloads
)

$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UE4SSPage = 'https://www.mediafire.com/file/nmfnxv8ssqobcd1/UE4SS-ETB-138-1-3-0-1778596571.zip/file'
$BiggerBackroomsPage = 'https://www.mediafire.com/file/o5e4b2kc0umzfxe/BiggerBackrooms-164-3-1781125418.zip/file'

function Normalize-VdfPath {
	param([Parameter(Mandatory = $true)][string]$PathText)

	return ($PathText -replace '\\\\', '\').Trim()
}

function Resolve-MediaFireDownloadUrl {
	param([Parameter(Mandatory = $true)][string]$PageUrl)

	$headers = @{
		'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
	}

	$response = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -Headers $headers

	$patterns = @(
		'href="(https://download[^"]+)"',
		'id="downloadButton"[^>]*href="([^"]+)"',
		'kNO\s*=\s*"(https://download[^"]+)"'
	)

	foreach ($pattern in $patterns) {
		$match = [regex]::Match($response.Content, $pattern)
		if ($match.Success) {
			return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
		}
	}

	throw "Could not resolve a direct download URL from MediaFire page: $PageUrl"
}

function Get-SteamRoots {
	$roots = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

	$registryLocations = @(
		@{ Path = 'HKCU:\Software\Valve\Steam'; Value = 'SteamPath' },
		@{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Value = 'InstallPath' },
		@{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Value = 'InstallPath' }
	)

	foreach ($entry in $registryLocations) {
		try {
			$value = (Get-ItemProperty -Path $entry.Path -Name $entry.Value -ErrorAction Stop).$($entry.Value)
			if ($value -and (Test-Path $value)) {
				[void]$roots.Add((Resolve-Path $value).Path)
			}
		}
		catch {
			continue
		}
	}

	$defaultRoots = @()

	if (${env:ProgramFiles(x86)}) {
		$defaultRoots += (Join-Path ${env:ProgramFiles(x86)} 'Steam')
	}

	if ($env:ProgramFiles) {
		$defaultRoots += (Join-Path $env:ProgramFiles 'Steam')
	}

	foreach ($root in $defaultRoots) {
		if ($root -and (Test-Path $root)) {
			[void]$roots.Add((Resolve-Path $root).Path)
		}
	}

	return [string[]]$roots
}

function Get-SteamLibraries {
	param([Parameter(Mandatory = $true)][string[]]$SteamRoots)

	$libraries = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

	foreach ($root in $SteamRoots) {
		[void]$libraries.Add($root)

		$libraryVdf = Join-Path $root 'steamapps\libraryfolders.vdf'
		if (-not (Test-Path $libraryVdf)) {
			continue
		}

		$raw = Get-Content -LiteralPath $libraryVdf -Raw

		foreach ($match in [regex]::Matches($raw, '"path"\s*"([^"]+)"')) {
			$libraryPath = Normalize-VdfPath -PathText $match.Groups[1].Value
			if ($libraryPath -and (Test-Path $libraryPath)) {
				[void]$libraries.Add((Resolve-Path $libraryPath).Path)
			}
		}

		foreach ($match in [regex]::Matches($raw, '^\s*"\d+"\s*"([^"]+)"\s*$', [Text.RegularExpressions.RegexOptions]::Multiline)) {
			$libraryPath = Normalize-VdfPath -PathText $match.Groups[1].Value
			if ($libraryPath -match '^[A-Za-z]:\\' -or $libraryPath -like '\\\\*') {
				if (Test-Path $libraryPath) {
					[void]$libraries.Add((Resolve-Path $libraryPath).Path)
				}
			}
		}
	}

	return [string[]]$libraries
}

function Find-EscapeTheBackroomsDirectory {
	param([string]$ManualPath)

	if ($ManualPath) {
		if (-not (Test-Path $ManualPath)) {
			throw "Specified game directory does not exist: $ManualPath"
		}

		$resolvedManual = (Resolve-Path $ManualPath).Path

		# Allow passing the inner folder: ...\EscapeTheBackrooms\EscapeTheBackrooms
		if (
			(Test-Path (Join-Path $resolvedManual 'Binaries\Win64')) -and
			(Test-Path (Join-Path $resolvedManual 'Content\Paks'))
		) {
			return (Split-Path -Path $resolvedManual -Parent)
		}

		$manualCandidates = @(
			$resolvedManual,
			(Join-Path $resolvedManual 'EscapeTheBackrooms'),
			(Join-Path $resolvedManual 'steamapps\common\EscapeTheBackrooms')
		)

		foreach ($candidate in $manualCandidates) {
			if (Test-Path (Join-Path $candidate 'EscapeTheBackrooms\Binaries\Win64')) {
				return $candidate
			}
		}

		throw "Specified path does not look like an Escape the Backrooms install: $resolvedManual"
	}

	$steamRoots = Get-SteamRoots
	if ($steamRoots.Count -eq 0) {
		throw 'No Steam installation folders were found.'
	}

	$libraries = Get-SteamLibraries -SteamRoots $steamRoots

	foreach ($library in $libraries) {
		$candidate = Join-Path $library 'steamapps\common\EscapeTheBackrooms'
		if (Test-Path (Join-Path $candidate 'EscapeTheBackrooms\Binaries\Win64')) {
			return $candidate
		}
	}

	throw 'Escape the Backrooms was not found in detected Steam libraries.'
}

Write-Host 'Locating Escape the Backrooms directory...'
$gameRoot = Find-EscapeTheBackroomsDirectory -ManualPath $GameDirectory

$ue4ssTarget = Join-Path $gameRoot 'EscapeTheBackrooms\Binaries\Win64'
$logicModsTarget = Join-Path $gameRoot 'EscapeTheBackrooms\Content\Paks\LogicMods'

if (-not (Test-Path $ue4ssTarget)) {
	throw "UE4SS target folder does not exist: $ue4ssTarget"
}

if (-not (Test-Path $logicModsTarget)) {
	Write-Host 'Creating LogicMods folder...'
	$null = New-Item -ItemType Directory -Path $logicModsTarget -Force
}

$downloadRoot = Join-Path $env:TEMP 'etbmods'
$null = New-Item -ItemType Directory -Path $downloadRoot -Force

$ue4ssZip = Join-Path $downloadRoot 'UE4SS.zip'
$biggerBackroomsZip = Join-Path $downloadRoot 'BiggerBackrooms.zip'

Write-Host "Game directory found: $gameRoot"
Write-Host 'Resolving UE4SS download URL...'
$ue4ssDirectUrl = Resolve-MediaFireDownloadUrl -PageUrl $UE4SSPage
Write-Host 'Resolving BiggerBackrooms download URL...'
$biggerBackroomsDirectUrl = Resolve-MediaFireDownloadUrl -PageUrl $BiggerBackroomsPage

$headers = @{
	'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
}

Write-Host 'Downloading UE4SS...'
Invoke-WebRequest -Uri $ue4ssDirectUrl -OutFile $ue4ssZip -UseBasicParsing -Headers $headers

Write-Host 'Downloading BiggerBackrooms...'
Invoke-WebRequest -Uri $biggerBackroomsDirectUrl -OutFile $biggerBackroomsZip -UseBasicParsing -Headers $headers

Write-Host "Extracting UE4SS to: $ue4ssTarget"
Expand-Archive -LiteralPath $ue4ssZip -DestinationPath $ue4ssTarget -Force

Write-Host "Extracting BiggerBackrooms to: $logicModsTarget"
Expand-Archive -LiteralPath $biggerBackroomsZip -DestinationPath $logicModsTarget -Force

if (-not $KeepDownloads) {
	Remove-Item -LiteralPath $ue4ssZip -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath $biggerBackroomsZip -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Install complete.'
Write-Host "UE4SS installed to: $ue4ssTarget"
Write-Host "BiggerBackrooms installed to: $logicModsTarget"
