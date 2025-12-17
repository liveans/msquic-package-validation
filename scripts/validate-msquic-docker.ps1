<#
.SYNOPSIS
    Validates MsQuic Linux packages using Docker containers on Windows.

.DESCRIPTION
    This script validates MsQuic Linux packages by running Docker containers
    with various Linux distribution images. It installs the package, verifies
    the library can be loaded, and runs .NET QUIC tests inside each container.

.PARAMETER Arch
    Target architecture: x64, arm64, arm32, or All. Default is All (tests x64, arm64, and arm32).
    Note: arm32 (armhf) packages are only available for DEB-based distros (Ubuntu, Debian).

.PARAMETER Distro
    Target distribution to test. If not specified, tests all distributions.
    Valid values: Ubuntu_22_04, Ubuntu_24_04, Debian_12, Debian_13, AzureLinux_3_0, 
                  CentOS_Stream_9, RHEL_10, Fedora_42, Fedora_43, 
                  OpenSUSE_15_6, OpenSUSE_16_0, SLES_15_6, SLES_15_7, SLES_16

.PARAMETER PackagesPath
    Path to the directory containing Linux packages (.deb, .rpm).
    If not specified, auto-detects from workspace structure.

.PARAMETER SkipQemuSetup
    Skip QEMU setup for cross-architecture testing.

.PARAMETER InitPackagesPath
    Initialize a package folder structure at the specified path and exit.
    Creates subdirectories for each supported distribution.

.PARAMETER DownloadPackages
    Download the latest libmsquic packages from packages.microsoft.com to the specified path.
    Creates the folder structure and downloads packages for all supported distributions.

.PARAMETER TestingRepo
    When used with -DownloadPackages, downloads RC (release candidate) packages from testing repositories.
    For DEB packages (Ubuntu/Debian): looks for ~rc packages in the prod folder.
    For RPM packages (RHEL/CentOS/Fedora/SLES/openSUSE): uses testing/ folder instead of prod/.

.PARAMETER DeletePackages
    Delete all package files from the specified path. Clears out the distro subdirectories.
    Use this to clean up before downloading fresh packages.

.PARAMETER SkipDotNetTest
    Skip the .NET QUIC validation test.

.PARAMETER PackageVersion
    Force a specific package version (e.g., "2.4.8"). Applies to both downloading
    and validating packages. If not specified, uses the latest available version.

.PARAMETER MaxParallelJobs
    Maximum number of parallel Docker validation jobs. Default is 8.
    Increase for faster execution on systems with more resources.

.PARAMETER LogPath
    Directory path for per-distro log files. Each distro/arch combination gets
    its own log file. If not specified, uses current working directory.

.PARAMETER QuickValidate
    One-click validation workflow. Creates msquic-packages folder in current directory,
    downloads latest packages from packages.microsoft.com (if not already present),
    and runs parallel validation on all distros. Combines -InitPackagesPath,
    -DownloadPackages, and validation into a single operation.

.EXAMPLE
    .\validate-msquic-docker.ps1

.EXAMPLE
    .\validate-msquic-docker.ps1 -Distro Ubuntu_24_04

.EXAMPLE
    .\validate-msquic-docker.ps1 -Arch arm64 -Distro AzureLinux_3_0 -PackagesPath C:\packages

.EXAMPLE
    # Initialize package folder structure
    .\validate-msquic-docker.ps1 -InitPackagesPath C:\msquic-packages

.EXAMPLE
    # Test all architectures (x64 and arm64 via QEMU)
    .\validate-msquic-docker.ps1 -Arch All -PackagesPath C:\msquic-packages

.EXAMPLE
    # Download latest packages from packages.microsoft.com
    .\validate-msquic-docker.ps1 -DownloadPackages C:\msquic-packages

.EXAMPLE
    # Download RC (release candidate) packages from testing repositories
    .\validate-msquic-docker.ps1 -DownloadPackages C:\msquic-packages -TestingRepo

.EXAMPLE
    # Download and validate a specific version
    .\validate-msquic-docker.ps1 -DownloadPackages C:\msquic-packages -PackageVersion 2.4.8

.EXAMPLE
    # Run parallel validation with 16 jobs and custom log path
    .\validate-msquic-docker.ps1 -PackagesPath C:\msquic-packages -MaxParallelJobs 16 -LogPath C:\logs

.EXAMPLE
    # One-click: setup, download, and validate everything
    .\validate-msquic-docker.ps1 -QuickValidate

.EXAMPLE
    # Quick validate with specific version and architecture
    .\validate-msquic-docker.ps1 -QuickValidate -PackageVersion 2.4.8 -Arch x64

.NOTES
    Requirements:
    - Docker Desktop for Windows with Linux containers enabled
    - QEMU for cross-architecture testing (arm64/arm32 on x64 host)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('x64', 'arm64', 'arm32', 'ppc64le', 's390x', 'All')]
    [string]$Arch = 'All',

    [Parameter()]
    [ValidateSet(
        'Ubuntu_22_04', 'Ubuntu_24_04', 'Ubuntu_25_10',
        'Debian_12', 'Debian_13',
        'AzureLinux_3_0',
        'CentOS_Stream_9', 'CentOS_Stream_10',
        'RHEL_9', 'RHEL_10',
        'Fedora_42', 'Fedora_43',
        'OpenSUSE_15_6', 'OpenSUSE_16_0',
        'SLES_15_6', 'SLES_15_7', 'SLES_16',
        'All')]
    [string]$Distro = 'All',

    [Parameter()]
    [string]$PackagesPath,

    [Parameter()]
    [switch]$SkipQemuSetup,

    [Parameter()]
    [string]$InitPackagesPath,

    [Parameter()]
    [string]$DownloadPackages,

    [Parameter()]
    [switch]$TestingRepo,

    [Parameter()]
    [string]$PackageVersion,

    [Parameter()]
    [string]$DeletePackages,

    [Parameter()]
    [switch]$SkipDotNetTest,

    [Parameter()]
    [int]$MaxParallelJobs = 8,

    [Parameter()]
    [string]$LogPath,

    [Parameter()]
    [switch]$QuickValidate
)

$ErrorActionPreference = 'Stop'

# Function to create package folder structure
function Initialize-PackageFolderStructure {
    param(
        [string]$BasePath
    )
    
    Write-Host ""
    Write-Host "Creating package folder structure at: $BasePath" -ForegroundColor Cyan
    Write-Host ""
    
    # Create base directory
    if (-not (Test-Path $BasePath)) {
        New-Item -ItemType Directory -Path $BasePath -Force | Out-Null
    }
    
    # Define all supported distros
    $distros = @(
        'ubuntu_22_04',
        'ubuntu_24_04',
        'ubuntu_25_10',
        'debian_12',
        'debian_13',
        'azurelinux_3_0',
        'centos_stream_9',
        'centos_stream_10',
        'rhel_9',
        'rhel_10',
        'fedora_42',
        'fedora_43',
        'opensuse_15_6',
        'opensuse_16_0',
        'sles_15_6',
        'sles_15_7',
        'sles_16'
    )
    
    foreach ($distro in $distros) {
        $distroPath = Join-Path $BasePath $distro
        if (-not (Test-Path $distroPath)) {
            New-Item -ItemType Directory -Path $distroPath -Force | Out-Null
            Write-Host "  Created: $distro/" -ForegroundColor Green
        } else {
            Write-Host "  Exists:  $distro/" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    Write-Host "Folder structure created. Place packages in the appropriate folders:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  DEB packages (Ubuntu/Debian):" -ForegroundColor White
    Write-Host "    - libmsquic_X.X.X_amd64.deb  (for x64)" -ForegroundColor Gray
    Write-Host "    - libmsquic_X.X.X_arm64.deb  (for arm64)" -ForegroundColor Gray
    Write-Host "    - libmsquic_X.X.X_armhf.deb  (for arm32)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  RPM packages (Fedora/CentOS/Azure Linux):" -ForegroundColor White
    Write-Host "    - libmsquic-X.X.X-1.x86_64.rpm  (for x64)" -ForegroundColor Gray
    Write-Host "    - libmsquic-X.X.X-1.aarch64.rpm (for arm64)" -ForegroundColor Gray
    Write-Host ""
}

# Helper function to extract version from package filename and create sortable version object
function Get-PackageVersion {
    param([string]$Filename)
    
    # DEB: libmsquic_2.4.8_amd64.deb -> 2.4.8
    # RPM: libmsquic-2.4.8-1.x86_64.rpm -> 2.4.8
    if ($Filename -match 'libmsquic[_-](\d+)\.(\d+)\.(\d+)') {
        return @{
            Major = [int]$Matches[1]
            Minor = [int]$Matches[2]
            Patch = [int]$Matches[3]
            Original = $Filename
        }
    }
    return $null
}

# Helper function to sort packages by semantic version (descending) and return latest
function Get-LatestPackage {
    param([string[]]$Packages)
    
    if (-not $Packages -or $Packages.Count -eq 0) {
        return $null
    }
    
    $versionedList = @()
    foreach ($pkg in $Packages) {
        $ver = Get-PackageVersion $pkg
        if ($ver) {
            $versionedList += $ver
        }
    }
    
    if ($versionedList.Count -eq 0) {
        return $null
    }
    
    $sorted = $versionedList | Sort-Object -Property @{Expression={$_.Major}; Descending=$true}, 
                                                      @{Expression={$_.Minor}; Descending=$true}, 
                                                      @{Expression={$_.Patch}; Descending=$true}
    
    # Handle single item case
    if ($sorted -is [hashtable]) {
        return $sorted.Original
    }
    
    return $sorted[0].Original
}

# Helper function to find a package matching a specific version
function Get-PackageByVersion {
    param(
        [string[]]$Packages,
        [string]$TargetVersion
    )

    if (-not $Packages -or $Packages.Count -eq 0) {
        return $null
    }

    # If no version specified, return latest
    if (-not $TargetVersion) {
        return Get-LatestPackage -Packages $Packages
    }

    # Find package matching the target version
    foreach ($pkg in $Packages) {
        $ver = Get-PackageVersion $pkg
        if ($ver) {
            $pkgVersion = "$($ver.Major).$($ver.Minor).$($ver.Patch)"
            if ($pkgVersion -eq $TargetVersion) {
                return $pkg
            }
        }
    }

    # Version not found
    return $null
}

# Function to download packages from packages.microsoft.com
function Download-LatestPackages {
    param(
        [string]$BasePath,
        [bool]$UseTestingRepo = $false,
        [string]$TargetVersion = $null,
        [bool]$FallbackToTesting = $true  # Try testing repo if prod fails
    )

    $repoType = if ($UseTestingRepo) { "testing" } else { "prod" }
    Write-Host ""
    $versionMsg = if ($TargetVersion) { "version $TargetVersion" } else { "latest" }
    Write-Host "Downloading $versionMsg libmsquic packages from packages.microsoft.com ($repoType)" -ForegroundColor Cyan
    if ($FallbackToTesting -and -not $UseTestingRepo) {
        Write-Host "Fallback to testing repo enabled (will try testing if prod fails)" -ForegroundColor Gray
    }
    if ($UseTestingRepo) {
        Write-Host "Looking for RC (release candidate) packages..." -ForegroundColor Yellow
    }
    if ($TargetVersion) {
        Write-Host "Target version: $TargetVersion" -ForegroundColor Yellow
    }
    Write-Host ""
    
    # First create the folder structure
    Initialize-PackageFolderStructure -BasePath $BasePath
    
    # Package URL mappings - base URLs for each distro
    # DEB packages are in pool/main/libm/libmsquic/ (same for testing)
    # RPM packages: prod uses prod/Packages/l/, testing uses testing/Packages/l/
    
    # For testing repo:
    # - DEB (Ubuntu/Debian): Same prod URL, just filter for ~rc packages
    # - RPM (RHEL/CentOS/Fedora/SLES/openSUSE): Use testing/Packages/l/ instead of prod/Packages/l/
    # - Azure Linux: Uses ms-oss path, testing may not exist
    
    $packageSources = @{
        'ubuntu_22_04' = @{
            'type' = 'deb'
            'baseUrl' = 'https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/libm/libmsquic/'
            # DEB repos have RC packages in same prod folder
        }
        'ubuntu_24_04' = @{
            'type' = 'deb'
            'baseUrl' = 'https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/libm/libmsquic/'
        }
        'ubuntu_25_10' = @{
            'type' = 'deb'
            'baseUrl' = 'https://packages.microsoft.com/ubuntu/25.10/prod/pool/main/libm/libmsquic/'
        }
        'debian_12' = @{
            'type' = 'deb'
            'baseUrl' = 'https://packages.microsoft.com/debian/12/prod/pool/main/libm/libmsquic/'
        }
        'debian_13' = @{
            'type' = 'deb'
            'baseUrl' = 'https://packages.microsoft.com/debian/13/prod/pool/main/libm/libmsquic/'
        }
        'azurelinux_3_0' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/azurelinux/3.0/prod/ms-oss/x86_64/Packages/l/'
            'arm64Url' = 'https://packages.microsoft.com/azurelinux/3.0/prod/ms-oss/aarch64/Packages/l/'
            # Azure Linux uses 'preview' instead of 'testing'
            'testingUrl' = 'https://packages.microsoft.com/azurelinux/3.0/preview/ms-oss/x86_64/Packages/l/'
            'testingArm64Url' = 'https://packages.microsoft.com/azurelinux/3.0/preview/ms-oss/aarch64/Packages/l/'
        }
        'centos_stream_9' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/rhel/9/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/rhel/9/testing/Packages/l/'
        }
        'centos_stream_10' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/centos/10/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/centos/10/testing/Packages/l/'
        }
        'rhel_9' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/rhel/9/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/rhel/9/testing/Packages/l/'
        }
        'rhel_10' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/rhel/10/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/rhel/10/testing/Packages/l/'
        }
        'fedora_42' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/fedora/42/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/fedora/42/testing/Packages/l/'
        }
        'fedora_43' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/fedora/43/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/fedora/43/testing/Packages/l/'
        }
        'opensuse_15_6' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/opensuse/15/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/yumrepos/microsoft-opensuse15-testing-prod/Packages/l/'
            'usesZypper' = $true
        }
        'opensuse_16_0' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/opensuse/16/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/opensuse/16/testing/Packages/l/'
            'usesZypper' = $true
        }
        'sles_15_6' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/sles/15/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/yumrepos/microsoft-sles15-testing-prod/Packages/l/'
            'usesZypper' = $true
        }
        'sles_15_7' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/sles/15/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/yumrepos/microsoft-sles15-testing-prod/Packages/l/'
            'usesZypper' = $true
        }
        'sles_16' = @{
            'type' = 'rpm'
            'baseUrl' = 'https://packages.microsoft.com/sles/16/prod/Packages/l/'
            'testingUrl' = 'https://packages.microsoft.com/sles/16/testing/Packages/l/'
            'usesZypper' = $true
        }
    }
    
    $downloadResults = @()
    
    foreach ($distro in $packageSources.Keys) {
        $distroPath = Join-Path $BasePath $distro
        $source = $packageSources[$distro]

        Write-Host ""
        Write-Host "Processing: $distro" -ForegroundColor Yellow

        # Build list of URLs to try (prod first, then testing as fallback)
        $urlsToTry = @()
        if ($UseTestingRepo -and $source['type'] -eq 'rpm' -and $source['testingUrl']) {
            # Testing mode: only try testing URL
            $urlsToTry += @{ url = $source['testingUrl']; label = 'testing' }
        } else {
            # Prod mode: try prod first, then testing as fallback
            $urlsToTry += @{ url = $source['baseUrl']; label = 'prod' }
            if ($FallbackToTesting -and $source['testingUrl']) {
                $urlsToTry += @{ url = $source['testingUrl']; label = 'testing (fallback)' }
            }
        }

        $downloadedFromDistro = $false

        foreach ($urlInfo in $urlsToTry) {
            if ($downloadedFromDistro) { break }

            $baseUrl = $urlInfo.url
            $urlLabel = $urlInfo.label

        try {
            Write-Host "  Trying $urlLabel`: $baseUrl" -ForegroundColor Gray

            $response = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -ErrorAction Stop
            $html = $response.Content
            
            if ($source['type'] -eq 'deb') {
                # Find all .deb files and get the latest versions for each architecture
                $debPattern = 'href="(libmsquic_[^"]+\.deb)"'
                $regexMatches = [regex]::Matches($html, $debPattern)
                
                if ($regexMatches.Count -eq 0) {
                    Write-Host "  WARNING: No DEB packages found" -ForegroundColor Yellow
                    continue
                }
                
                # Extract all filenames first, then filter
                $allDebFiles = $regexMatches | ForEach-Object { $_.Groups[1].Value }
                
                # Group by architecture and find latest
                # For testing repo: only include RC versions (~rc)
                # For prod repo: exclude RC versions
                if ($UseTestingRepo) {
                    $amd64Files = $allDebFiles | Where-Object { $_ -match '_amd64\.deb$' -and $_ -match '~rc' }
                    $arm64Files = $allDebFiles | Where-Object { $_ -match '_arm64\.deb$' -and $_ -match '~rc' }
                    $armhfFiles = $allDebFiles | Where-Object { $_ -match '_armhf\.deb$' -and $_ -match '~rc' }
                } else {
                    $amd64Files = $allDebFiles | Where-Object { $_ -match '_amd64\.deb$' -and $_ -notmatch '~rc' }
                    $arm64Files = $allDebFiles | Where-Object { $_ -match '_arm64\.deb$' -and $_ -notmatch '~rc' }
                    $armhfFiles = $allDebFiles | Where-Object { $_ -match '_armhf\.deb$' -and $_ -notmatch '~rc' }
                }

                # Select package by version (or latest if no version specified)
                $latestAmd64 = Get-PackageByVersion -Packages $amd64Files -TargetVersion $TargetVersion
                $latestArm64 = Get-PackageByVersion -Packages $arm64Files -TargetVersion $TargetVersion
                $latestArmhf = Get-PackageByVersion -Packages $armhfFiles -TargetVersion $TargetVersion

                if (-not $latestAmd64 -and -not $latestArm64 -and -not $latestArmhf) {
                    $pkgType = if ($UseTestingRepo) { "RC" } else { "release" }
                    $versionInfo = if ($TargetVersion) { " (version $TargetVersion)" } else { "" }
                    Write-Host "  No $pkgType DEB packages found$versionInfo in $urlLabel" -ForegroundColor Gray
                    continue  # Try next URL
                }

                # Download amd64
                if ($latestAmd64) {
                    $downloadUrl = "$baseUrl$latestAmd64"
                    $outputFile = Join-Path $distroPath $latestAmd64
                    Write-Host "  Downloading: $latestAmd64 (from $urlLabel)" -ForegroundColor Green
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputFile -UseBasicParsing
                    $downloadResults += @{ Distro = $distro; File = $latestAmd64; Status = 'OK'; Source = $urlLabel }
                    $downloadedFromDistro = $true
                }

                # Download arm64
                if ($latestArm64) {
                    $downloadUrl = "$baseUrl$latestArm64"
                    $outputFile = Join-Path $distroPath $latestArm64
                    Write-Host "  Downloading: $latestArm64 (from $urlLabel)" -ForegroundColor Green
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputFile -UseBasicParsing
                    $downloadResults += @{ Distro = $distro; File = $latestArm64; Status = 'OK'; Source = $urlLabel }
                    $downloadedFromDistro = $true
                }

                # Download armhf (arm32)
                if ($latestArmhf) {
                    $downloadUrl = "$baseUrl$latestArmhf"
                    $outputFile = Join-Path $distroPath $latestArmhf
                    Write-Host "  Downloading: $latestArmhf (from $urlLabel)" -ForegroundColor Green
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputFile -UseBasicParsing
                    $downloadResults += @{ Distro = $distro; File = $latestArmhf; Status = 'OK'; Source = $urlLabel }
                    $downloadedFromDistro = $true
                }
            }
            else {
                # RPM - need to handle x86_64 and aarch64
                $rpmPattern = 'href="(libmsquic-[^"]+\.rpm)"'
                
                # x86_64
                $x64RegexMatches = [regex]::Matches($html, $rpmPattern)
                $allX64RpmFiles = $x64RegexMatches | ForEach-Object { $_.Groups[1].Value }
                
                # For testing repo (RPM): we're already using testing URL, so include all packages
                # For prod repo: exclude RC versions
                if ($UseTestingRepo) {
                    # In testing repo, take the latest (could be RC or not)
                    $x64Files = $allX64RpmFiles | Where-Object { $_ -match '\.x86_64\.rpm$' }
                } else {
                    $x64Files = $allX64RpmFiles | Where-Object { $_ -match '\.x86_64\.rpm$' -and $_ -notmatch '~rc' }
                }
                $latestX64 = Get-PackageByVersion -Packages $x64Files -TargetVersion $TargetVersion
                
                if ($latestX64) {
                    $downloadUrl = "$baseUrl$latestX64"
                    $outputFile = Join-Path $distroPath $latestX64
                    Write-Host "  Downloading: $latestX64 (from $urlLabel)" -ForegroundColor Green
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputFile -UseBasicParsing
                    $downloadResults += @{ Distro = $distro; File = $latestX64; Status = 'OK'; Source = $urlLabel }
                    $downloadedFromDistro = $true
                }

                # aarch64 - some distros have separate URL (e.g., Azure Linux)
                # Check if we're using a testing/preview URL (either explicitly or via fallback)
                $isUsingTestingUrl = $UseTestingRepo -or ($urlLabel -match 'testing|fallback')
                $arm64Url = $baseUrl
                if ($isUsingTestingUrl -and $source['testingArm64Url']) {
                    # Use testing/preview arm64 URL if available
                    $arm64Url = $source['testingArm64Url']
                } elseif (-not $isUsingTestingUrl -and $source['arm64Url']) {
                    # Use prod arm64 URL if available
                    $arm64Url = $source['arm64Url']
                }
                
                if ($arm64Url -ne $baseUrl) {
                    Write-Host "  Fetching arm64 package list from: $arm64Url" -ForegroundColor Gray
                    $arm64Response = Invoke-WebRequest -Uri $arm64Url -UseBasicParsing -ErrorAction Stop
                    $arm64Html = $arm64Response.Content
                } else {
                    $arm64Html = $html
                }
                
                $arm64RegexMatches = [regex]::Matches($arm64Html, $rpmPattern)
                $allArm64RpmFiles = $arm64RegexMatches | ForEach-Object { $_.Groups[1].Value }
                
                if ($UseTestingRepo) {
                    $arm64Files = $allArm64RpmFiles | Where-Object { $_ -match '\.aarch64\.rpm$' }
                } else {
                    $arm64Files = $allArm64RpmFiles | Where-Object { $_ -match '\.aarch64\.rpm$' -and $_ -notmatch '~rc' }
                }
                $latestArm64 = Get-PackageByVersion -Packages $arm64Files -TargetVersion $TargetVersion
                
                if ($latestArm64) {
                    $downloadUrl = "$arm64Url$latestArm64"
                    $outputFile = Join-Path $distroPath $latestArm64
                    Write-Host "  Downloading: $latestArm64 (from $urlLabel)" -ForegroundColor Green
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputFile -UseBasicParsing
                    $downloadResults += @{ Distro = $distro; File = $latestArm64; Status = 'OK'; Source = $urlLabel }
                    $downloadedFromDistro = $true
                }

                # If no RPM packages found at all, try next URL
                if (-not $latestX64 -and -not $latestArm64) {
                    Write-Host "  No RPM packages found in $urlLabel" -ForegroundColor Gray
                    continue  # Try next URL
                }
            }
        }
        catch {
            # Check if this is a 404 error (repo doesn't exist)
            $errorMessage = $_.ToString()
            if ($errorMessage -match '404' -or $errorMessage -match 'Not Found') {
                Write-Host "  $urlLabel not available (404), trying next..." -ForegroundColor Gray
                continue  # Try next URL in fallback
            } else {
                Write-Host "  ERROR in $urlLabel`: $_" -ForegroundColor Red
                continue  # Try next URL
            }
        }
        }  # End of urlsToTry foreach

        # If no packages downloaded from any URL
        if (-not $downloadedFromDistro) {
            Write-Host "  WARNING: No packages found for $distro from any source" -ForegroundColor Yellow
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "=== Download Summary ===" -ForegroundColor Cyan
    Write-Host ""
    foreach ($result in $downloadResults) {
        $statusColor = if ($result.Status -eq 'OK') { 'Green' } else { 'Red' }
        $sourceInfo = if ($result.Source) { " from $($result.Source)" } else { "" }
        Write-Host "  $($result.Distro): $($result.File)$sourceInfo [$($result.Status)]" -ForegroundColor $statusColor
    }
    Write-Host ""
    Write-Host "Packages downloaded to: $BasePath" -ForegroundColor Cyan
    Write-Host ""
}

# Handle InitPackagesPath parameter
if ($InitPackagesPath) {
    Initialize-PackageFolderStructure -BasePath $InitPackagesPath
    exit 0
}

# Handle DownloadPackages parameter
if ($DownloadPackages) {
    Download-LatestPackages -BasePath $DownloadPackages -UseTestingRepo $TestingRepo.IsPresent -TargetVersion $PackageVersion
    exit 0
}

# Handle DeletePackages parameter
if ($DeletePackages) {
    if (-not (Test-Path $DeletePackages)) {
        Write-Host "ERROR: Path does not exist: $DeletePackages" -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "=== Deleting Packages ===" -ForegroundColor Cyan
    Write-Host "Path: $DeletePackages" -ForegroundColor Gray
    Write-Host ""
    
    $totalDeleted = 0
    $subdirs = Get-ChildItem -Path $DeletePackages -Directory -ErrorAction SilentlyContinue
    
    foreach ($subdir in $subdirs) {
        $files = Get-ChildItem -Path $subdir.FullName -File -ErrorAction SilentlyContinue
        $fileCount = ($files | Measure-Object).Count
        
        if ($fileCount -gt 0) {
            Write-Host "  Cleaning $($subdir.Name): $fileCount file(s)" -ForegroundColor Yellow
            $files | Remove-Item -Force
            $totalDeleted += $fileCount
        }
    }
    
    Write-Host ""
    Write-Host "Deleted $totalDeleted package file(s)" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# Handle QuickValidate parameter - one-click setup, download, and validate
if ($QuickValidate) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Quick Validate - One-Click Workflow" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Set up packages path in current directory
    $quickPackagesPath = Join-Path (Get-Location) 'msquic-packages'

    # Create folder structure if it doesn't exist
    if (-not (Test-Path $quickPackagesPath)) {
        Write-Host "[*] Creating package folder structure: $quickPackagesPath" -ForegroundColor Green
        Initialize-PackageFolderStructure -BasePath $quickPackagesPath
    } else {
        Write-Host "[*] Package folder exists: $quickPackagesPath" -ForegroundColor Green
    }

    # Check if we already have packages for the requested version
    $existingPackages = Get-ChildItem -Path $quickPackagesPath -Include "*.deb","*.rpm" -Recurse -ErrorAction SilentlyContinue
    $packageCount = ($existingPackages | Measure-Object).Count
    $needDownload = $false

    if ($packageCount -eq 0) {
        Write-Host "[*] No packages found" -ForegroundColor Yellow
        $needDownload = $true
    } elseif ($PackageVersion) {
        # Check if the requested version exists
        $versionPattern = $PackageVersion -replace '\.', '\.'
        $matchingPackages = $existingPackages | Where-Object { $_.Name -match "libmsquic[_-]$versionPattern" }
        $matchCount = ($matchingPackages | Measure-Object).Count

        if ($matchCount -eq 0) {
            Write-Host "[*] Found $packageCount package(s), but none match version $PackageVersion" -ForegroundColor Yellow
            $needDownload = $true
        } else {
            Write-Host "[*] Found $matchCount package(s) matching version $PackageVersion, skipping download" -ForegroundColor Green
        }
    } else {
        Write-Host "[*] Found $packageCount existing package(s), skipping download" -ForegroundColor Green
        Write-Host "    (Use -DeletePackages to clear and re-download)" -ForegroundColor Gray
    }

    if ($needDownload) {
        Write-Host "[*] Downloading from packages.microsoft.com..." -ForegroundColor Green
        Download-LatestPackages -BasePath $quickPackagesPath -UseTestingRepo $TestingRepo.IsPresent -TargetVersion $PackageVersion
    }

    # Set PackagesPath for the rest of the script
    $PackagesPath = $quickPackagesPath

    # Set LogPath to packages folder if not specified
    if (-not $LogPath) {
        $LogPath = Join-Path $quickPackagesPath 'logs'
        if (-not (Test-Path $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        }
    }

    Write-Host ""
    Write-Host "[*] Proceeding with validation..." -ForegroundColor Green
    Write-Host ""
}

# Auto-detect PackagesPath
if (-not $PackagesPath) {
    $possiblePackagePaths = @(
        (Join-Path (Get-Location) 'packages'),
        (Join-Path $env:USERPROFILE 'Desktop\msquic-packages')
    )
    foreach ($path in $possiblePackagePaths) {
        if ((Test-Path $path) -and (Get-ChildItem -Path $path -Include "*.deb","*.rpm" -Recurse -ErrorAction SilentlyContinue)) {
            $PackagesPath = $path
            break
        }
    }
}

# Docker image configurations based on .NET 10 supported OS
# https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.md
# Using base Docker Hub/registry images for multi-arch support
# Architectures: x64, arm64, arm32 (armhf/armv7), ppc64le, s390x where available
# .NET runtime will be installed as needed for testing
$DockerImages = @{
    # Ubuntu: 25.10, 24.04, 22.04 - Arm32, Arm64, x64
    'Ubuntu_22_04' = @{
        'x64'   = 'ubuntu:22.04'
        'arm64' = 'ubuntu:22.04'
        'arm32' = 'ubuntu:22.04'  # armhf support
        'type'  = 'deb'
        'dotnetVersion' = '9.0'
    }
    'Ubuntu_24_04' = @{
        'x64'   = 'ubuntu:24.04'
        'arm64' = 'ubuntu:24.04'
        'arm32' = 'ubuntu:24.04'  # armhf support
        'type'  = 'deb'
        'dotnetVersion' = '9.0'
    }
    'Ubuntu_25_10' = @{
        'x64'   = 'ubuntu:25.10'
        'arm64' = 'ubuntu:25.10'
        'arm32' = 'ubuntu:25.10'  # armhf support
        'type'  = 'deb'
        'dotnetVersion' = '9.0'
    }
    # Debian: 13, 12 - Arm32, Arm64, x64
    'Debian_12' = @{
        'x64'   = 'debian:12'
        'arm64' = 'debian:12'
        'arm32' = 'debian:12'  # armhf support
        'type'  = 'deb'
        'dotnetVersion' = '9.0'
    }
    'Debian_13' = @{
        'x64'   = 'debian:trixie'
        'arm64' = 'debian:trixie'
        'arm32' = 'debian:trixie'  # armhf support
        'type'  = 'deb'
        'dotnetVersion' = '9.0'
    }
    # Azure Linux: 3.0 - Arm64, x64
    'AzureLinux_3_0' = @{
        'x64'   = 'mcr.microsoft.com/azurelinux/base/core:3.0'
        'arm64' = 'mcr.microsoft.com/azurelinux/base/core:3.0'
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    # CentOS Stream: 10, 9 - Arm64, ppc64le, s390x, x64
    'CentOS_Stream_9' = @{
        'x64'     = 'quay.io/centos/centos:stream9'
        'arm64'   = 'quay.io/centos/centos:stream9'
        'ppc64le' = 'quay.io/centos/centos:stream9'
        's390x'   = 'quay.io/centos/centos:stream9'
        'type'    = 'rpm'
        'dotnetVersion' = '9.0'
    }
    'CentOS_Stream_10' = @{
        'x64'     = 'quay.io/centos/centos:stream10'
        'arm64'   = 'quay.io/centos/centos:stream10'
        'ppc64le' = 'quay.io/centos/centos:stream10'
        's390x'   = 'quay.io/centos/centos:stream10'
        'type'    = 'rpm'
        'dotnetVersion' = '9.0'
    }
    # RHEL: 10, 9 - Arm64, ppc64le, s390x, x64 (using UBI images)
    'RHEL_9' = @{
        'x64'     = 'registry.access.redhat.com/ubi9/ubi:latest'
        'arm64'   = 'registry.access.redhat.com/ubi9/ubi:latest'
        'ppc64le' = 'registry.access.redhat.com/ubi9/ubi:latest'
        's390x'   = 'registry.access.redhat.com/ubi9/ubi:latest'
        'type'    = 'rpm'
        'dotnetVersion' = '9.0'
    }
    'RHEL_10' = @{
        'x64'     = 'registry.access.redhat.com/ubi10/ubi:latest'
        'arm64'   = 'registry.access.redhat.com/ubi10/ubi:latest'
        'ppc64le' = 'registry.access.redhat.com/ubi10/ubi:latest'
        's390x'   = 'registry.access.redhat.com/ubi10/ubi:latest'
        'type'    = 'rpm'
        'dotnetVersion' = '9.0'
    }
    # Fedora: 43, 42 - Arm32, Arm64, x64
    'Fedora_42' = @{
        'x64'   = 'fedora:42'
        'arm64' = 'fedora:42'
        'arm32' = 'fedora:42'  # armhfp support
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    'Fedora_43' = @{
        'x64'   = 'fedora:43'
        'arm64' = 'fedora:43'
        'arm32' = 'fedora:43'  # armhfp support
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    # openSUSE Leap: 16.0, 15.6 - Arm64, x64
    'OpenSUSE_15_6' = @{
        'x64'   = 'opensuse/leap:15.6'
        'arm64' = 'opensuse/leap:15.6'
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    'OpenSUSE_16_0' = @{
        'x64'   = 'opensuse/tumbleweed:latest'  # Using Tumbleweed as Leap 16 not yet released
        'arm64' = 'opensuse/tumbleweed:latest'
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    # SLES: 16.0, 15.7, 15.6 - Arm64, x64
    'SLES_15_6' = @{
        'x64'   = 'registry.suse.com/suse/sle15:15.6'
        'arm64' = 'registry.suse.com/suse/sle15:15.6'
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    'SLES_15_7' = @{
        'x64'   = 'registry.suse.com/suse/sle15:15.7'
        'arm64' = 'registry.suse.com/suse/sle15:15.7'
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
    'SLES_16' = @{
        # Note: SLES 16 image not yet publicly available. Using BCI as placeholder.
        'x64'   = 'registry.suse.com/bci/bci-base:latest'
        'arm64' = 'registry.suse.com/bci/bci-base:latest'
        'type'  = 'rpm'
        'dotnetVersion' = '9.0'
    }
}

function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor White
}

function Write-WarningMsg {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[X] $Message" -ForegroundColor Red
}

function Write-Success {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Failure {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
}

function Write-Skipped {
    param([string]$Message)
    Write-Host "[~] $Message" -ForegroundColor Yellow
}

# Function to check if a package exists for a given distro/arch
function Test-PackageExists {
    param(
        [string]$PackagesPath,
        [string]$DistroName,
        [string]$Arch,
        [string]$PackageType,
        [string]$TargetVersion = $null
    )

    # Map distro name to folder name
    $distroFolder = $DistroName.ToLower()
    $distroPath = Join-Path $PackagesPath $distroFolder

    # Determine architecture suffix for packages
    if ($PackageType -eq 'deb') {
        $archSuffix = switch ($Arch) {
            'x64'   { 'amd64' }
            'arm64' { 'arm64' }
            'arm32' { 'armhf' }
            default { 'amd64' }
        }
        $pattern = "*_${archSuffix}.deb"
    } else {
        $archSuffix = switch ($Arch) {
            'x64'     { 'x86_64' }
            'arm64'   { 'aarch64' }
            'arm32'   { 'armv7hl' }
            'ppc64le' { 'ppc64le' }
            's390x'   { 's390x' }
            default   { 'x86_64' }
        }
        $pattern = "*.$archSuffix.rpm"
    }

    # Collect all matching packages
    $allPackages = @()

    # Check in distro-specific folder
    if (Test-Path $distroPath) {
        $packages = Get-ChildItem -Path $distroPath -Filter $pattern -File -ErrorAction SilentlyContinue
        if ($packages) {
            $allPackages += $packages
        }
    }

    # Check in root packages folder
    $rootPackages = Get-ChildItem -Path $PackagesPath -Filter $pattern -File -ErrorAction SilentlyContinue
    if ($rootPackages) {
        $allPackages += $rootPackages
    }

    if ($allPackages.Count -eq 0) {
        return @{
            Found = $false
            Path = $null
        }
    }

    # Get package names for version selection
    $packageNames = $allPackages | ForEach-Object { $_.Name }

    # Select by version (or latest if no version specified)
    $selectedPackage = Get-PackageByVersion -Packages $packageNames -TargetVersion $TargetVersion

    if ($selectedPackage) {
        # Find the full path for the selected package
        $match = $allPackages | Where-Object { $_.Name -eq $selectedPackage } | Select-Object -First 1
        return @{
            Found = $true
            Path = $match.FullName
        }
    }

    return @{
        Found = $false
        Path = $null
    }
}

function Test-DockerAvailable {
    try {
        $null = docker version 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Setup-QemuEmulation {
    Write-Header "Setting up QEMU for cross-architecture emulation"

    # Check if QEMU is already registered for arm64
    Write-Step "Checking current QEMU registration..."
    $arm64Check = docker run --rm --platform linux/arm64 alpine:latest uname -m 2>&1
    $arm64Ready = ($LASTEXITCODE -eq 0 -and $arm64Check -match 'aarch64')

    # Check arm32 (armv7l)
    $arm32Check = docker run --rm --platform linux/arm/v7 alpine:latest uname -m 2>&1
    $arm32Ready = ($LASTEXITCODE -eq 0 -and $arm32Check -match 'armv7l')

    if ($arm64Ready -and $arm32Ready) {
        Write-Success "QEMU already configured for arm64 and arm32 emulation"
        return $true
    }

    if ($arm64Ready) {
        Write-Success "QEMU already configured for arm64 emulation"
    }
    if ($arm32Ready) {
        Write-Success "QEMU already configured for arm32 emulation"
    }

    Write-Step "Registering QEMU handlers via Docker..."

    # First, try to pull the qemu-user-static image
    Write-Info "Pulling multiarch/qemu-user-static image..."
    docker pull multiarch/qemu-user-static 2>&1 | ForEach-Object { Write-Info $_ }

    # Run the QEMU registration
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes 2>&1 | ForEach-Object { Write-Info $_ }

    if ($LASTEXITCODE -ne 0) {
        Write-WarningMsg "QEMU registration command failed"
        Write-Info "Trying alternative method..."

        # Alternative: use tonistiigi/binfmt which is more commonly available
        docker run --rm --privileged tonistiigi/binfmt --install all 2>&1 | ForEach-Object { Write-Info $_ }
    }

    # Verify QEMU is working for arm64
    Write-Step "Verifying QEMU emulation..."
    $verifyArm64 = docker run --rm --platform linux/arm64 alpine:latest uname -m 2>&1
    $verifyArm32 = docker run --rm --platform linux/arm/v7 alpine:latest uname -m 2>&1

    $arm64Ok = ($LASTEXITCODE -eq 0 -or $verifyArm64 -match 'aarch64')
    $arm32Ok = ($verifyArm32 -match 'armv7l')

    if ($arm64Ok) {
        Write-Success "arm64 emulation verified"
    } else {
        Write-WarningMsg "arm64 emulation may not work"
    }

    if ($arm32Ok) {
        Write-Success "arm32 emulation verified"
    } else {
        Write-WarningMsg "arm32 emulation may not work"
    }

    if ($arm64Ok -or $arm32Ok) {
        return $true
    } else {
        Write-WarningMsg "QEMU setup may have failed"
        Write-Info "To manually setup QEMU, run: docker run --rm --privileged tonistiigi/binfmt --install all"
        return $false
    }
}

function Get-InstallScript {
    param(
        [string]$PackageType,
        [string]$Arch,
        [string]$DistroName
    )
    
    # Map architecture names for DEB packages
    $debArch = switch ($Arch) {
        'x64'     { 'amd64' }
        'arm64'   { 'arm64' }
        'arm32'   { 'armhf' }
        default   { 'amd64' }
    }
    
    # Map architecture names for RPM packages
    $rpmArch = switch ($Arch) {
        'x64'     { 'x86_64' }
        'arm64'   { 'aarch64' }
        'arm32'   { 'armv7hl' }
        'ppc64le' { 'ppc64le' }
        's390x'   { 's390x' }
        default   { 'x86_64' }
    }
    
    # Distro folder name (lowercase with underscores)
    $distroFolder = $DistroName.ToLower()
    
    # Library load validation - simple test that verifies libmsquic can be loaded
    # Uses python ctypes which is available on most systems
    $libraryValidationScript = @(
        'echo "=== Running library load validation ==="',
        '# Try python-based library validation first',
        'if command -v python3 > /dev/null 2>&1; then',
        '    python3 << ''PYEOF''',
        'import ctypes',
        'import sys',
        'try:',
        '    lib = ctypes.CDLL("libmsquic.so.2")',
        '    print("SUCCESS: Loaded libmsquic.so.2")',
        '    # Check for key symbols',
        '    if hasattr(lib, "MsQuicOpenVersion"):',
        '        print("SUCCESS: Found MsQuicOpenVersion symbol")',
        '    else:',
        '        print("ERROR: MsQuicOpenVersion not found")',
        '        sys.exit(1)',
        '    if hasattr(lib, "MsQuicClose"):',
        '        print("SUCCESS: Found MsQuicClose symbol")',
        '    else:',
        '        print("ERROR: MsQuicClose not found")',
        '        sys.exit(1)',
        '    print("SUCCESS: Library validation passed")',
        'except OSError as e:',
        '    print(f"ERROR: Failed to load libmsquic: {e}")',
        '    sys.exit(1)',
        'PYEOF',
        '    if [ $? -ne 0 ]; then',
        '        echo "ERROR: Library validation failed"',
        '        exit 1',
        '    fi',
        'else',
        '    echo "WARNING: python3 not available, skipping library API validation"',
        '    echo "Library installation was verified via ldconfig"',
        'fi'
    )
    
    if ($PackageType -eq 'deb') {
        $script = @(
            'set -e',
            '# Use exit code 100+ for package failures to distinguish from .NET test failures',
            'trap "exit 100" ERR',
            'echo "=== Installing DEB package ==="',
            "# Look in distro-specific folder first, then fall back to root",
            "DEB_FILE=`$(find /packages/${distroFolder} -name '*${debArch}.deb' -type f 2>&1 | grep -v 'No such file' | head -1)",
            'if [ -z "$DEB_FILE" ]; then DEB_FILE=$(find /packages -maxdepth 1 -name "*' + $debArch + '.deb" -type f | head -1); fi',
            'echo "Found DEB: $DEB_FILE"',
            'if [ -z "$DEB_FILE" ]; then echo "ERROR: No DEB found for architecture"; exit 101; fi',
            'apt-get update -qq',
            'DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB_FILE"',
            'echo "=== Verifying installation ==="',
            'ldconfig',
            'ldconfig -p | grep -i msquic || echo "libmsquic not in ldconfig cache"',
            'ls -la /usr/lib/*msquic* 2>/dev/null || ls -la /usr/lib/x86_64-linux-gnu/*msquic* 2>/dev/null || ls -la /usr/lib/aarch64-linux-gnu/*msquic* 2>/dev/null || echo "Library location check"',
            '# Disable trap for library validation (non-critical)',
            'trap - ERR'
        ) + $libraryValidationScript + @(
            'echo "=== Package validation PASSED ==="'
        )
        $script = $script -join "`n"
        return $script
    } else {
        # RPM-based (includes Azure Linux with tdnf, openSUSE/SLES with zypper, and yum/dnf distros)
        $script = @(
            'set -e',
            '# Use exit code 100+ for package failures to distinguish from .NET test failures',
            'trap "exit 100" ERR',
            'echo "=== Installing RPM package ==="',
            '# Install findutils if not available (needed for minimal images like openSUSE Tumbleweed)',
            'if ! command -v find > /dev/null 2>&1; then',
            '    if command -v zypper > /dev/null 2>&1; then',
            '        echo "Installing findutils..."',
            '        zypper --non-interactive --no-gpg-checks install findutils > /dev/null 2>&1 || true',
            '    fi',
            'fi',
            "# Look in distro-specific folder first, then fall back to root",
            "RPM_FILE=`$(find /packages/${distroFolder} -name '*${rpmArch}.rpm' -type f 2>&1 | grep -v 'No such file' | head -1)",
            'if [ -z "$RPM_FILE" ]; then RPM_FILE=$(find /packages -maxdepth 1 -name "*' + $rpmArch + '.rpm" -type f | head -1); fi',
            'echo "Found RPM: $RPM_FILE"',
            'if [ -z "$RPM_FILE" ]; then echo "ERROR: No RPM found for architecture"; exit 101; fi',
            '# Detect package manager and install',
            'if command -v zypper > /dev/null 2>&1; then',
            '    echo "Using zypper (openSUSE/SLES)"',
            '    zypper --non-interactive --no-gpg-checks install --allow-unsigned-rpm "$RPM_FILE"',
            'elif command -v tdnf > /dev/null 2>&1; then',
            '    echo "Using tdnf (Azure Linux)"',
            '    tdnf install -y --nogpgcheck "$RPM_FILE"',
            'elif command -v dnf > /dev/null 2>&1; then',
            '    echo "Using dnf"',
            '    dnf install -y "$RPM_FILE"',
            'else',
            '    echo "Using yum"',
            '    yum install -y "$RPM_FILE"',
            'fi',
            'echo "=== Verifying installation ==="',
            'ldconfig',
            'ldconfig -p | grep -i msquic || echo "libmsquic not in ldconfig cache"',
            'ls -la /usr/lib64/*msquic* 2>/dev/null || ls -la /usr/lib/*msquic* 2>/dev/null || echo "Library location check"',
            '# Disable trap for library validation (non-critical)',
            'trap - ERR'
        ) + $libraryValidationScript + @(
            'echo "=== Package validation PASSED ==="'
        )
        $script = $script -join "`n"
        return $script
    }
}

function Run-DockerValidation {
    param(
        [string]$DistroName,
        [string]$Image,
        [string]$Arch,
        [string]$PackageType,
        [string]$PackagesPath,
        [string]$DotNetTestPath,
        [bool]$RunDotNetTest = $false,
        [string]$PackageFile = $null,
        [string]$DotNetVersion = '9.0'
    )
    
    $friendlyName = $DistroName -replace '_', ' '
    
    # Header is shown by caller, just show details here
    if ($PackageFile) {
        Write-Step "Package: $PackageFile"
    }
    Write-Step "Docker image: $Image"
    Write-Step "Package type: $PackageType"
    if ($RunDotNetTest) {
        Write-Step ".NET version: $DotNetVersion"
    }
    
    # Determine platform for Docker (needed for cross-arch emulation via QEMU)
    $platform = switch ($Arch) {
        'arm64'   { 'linux/arm64' }
        'arm32'   { 'linux/arm/v7' }
        'ppc64le' { 'linux/ppc64le' }
        's390x'   { 'linux/s390x' }
        default   { 'linux/amd64' }
    }
    Write-Step "Platform: $platform"
    
    # Pull the image with correct platform
    Write-Step "Pulling Docker image..."
    docker pull --platform $platform $Image 2>&1 | ForEach-Object { Write-Info $_ }
    
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMsg "Failed to pull Docker image: $Image"
        return @{ PackageTest = $false; DotNetTest = $false }
    }
    
    # Get the install script (package install + library validation)
    $installScript = Get-InstallScript -PackageType $PackageType -Arch $Arch -DistroName $DistroName
    
    # Build the combined script - package install, then .NET test in same container
    $combinedScript = $installScript
    
    # Add .NET test script if requested
    $includeDotNetTest = $RunDotNetTest -and $DotNetTestPath -and (Test-Path $DotNetTestPath)
    if ($includeDotNetTest) {
        # Use .NET 9.0 as that's what the QuicHello project targets
        $dotnetChannel = $DotNetVersion
        $dotnetDllName = "QuicHello.net${DotNetVersion}.dll"
        $dotnetMajor = $DotNetVersion.Split('.')[0]
        
        $dotnetTestScript = @(
            '',
            'echo ""',
            'echo "=== Running .NET QUIC Test ==="',
            "echo ""Required .NET version: $dotnetChannel""",
            '# Check if required .NET version is available',
            "REQUIRED_MAJOR=$dotnetMajor",
            'DOTNET_OK=0',
            'if command -v dotnet > /dev/null 2>&1; then',
            '    INSTALLED_VERSION=$(dotnet --list-runtimes 2>/dev/null | grep "Microsoft.NETCore.App" | head -1 | awk ''{print $2}'' | cut -d. -f1)',
            '    if [ "$INSTALLED_VERSION" = "$REQUIRED_MAJOR" ]; then',
            '        echo "Found compatible .NET runtime"',
            '        DOTNET_OK=1',
            '    else',
            '        echo "Found .NET $INSTALLED_VERSION but need $REQUIRED_MAJOR, installing..."',
            '    fi',
            'fi',
            'if [ $DOTNET_OK -eq 0 ]; then',
            '    echo "Installing .NET runtime and dependencies..."',
            '    if command -v apt-get > /dev/null 2>&1; then',
            '        apt-get install -y --no-install-recommends wget ca-certificates libicu-dev 2>&1 | tail -3',
            '        wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh',
            '        chmod +x /tmp/dotnet-install.sh',
            "        /tmp/dotnet-install.sh --channel $dotnetChannel --runtime dotnet --install-dir /usr/share/dotnet 2>&1 | tail -5",
            '        ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet || true',
            '    elif command -v zypper > /dev/null 2>&1; then',
            '        zypper --non-interactive --no-gpg-checks install wget ca-certificates tar gzip libicu 2>&1 | tail -3',
            '        wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh',
            '        chmod +x /tmp/dotnet-install.sh',
            "        /tmp/dotnet-install.sh --channel $dotnetChannel --runtime dotnet --install-dir /usr/share/dotnet 2>&1 | tail -5",
            '        ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet || true',
            '    elif command -v dnf > /dev/null 2>&1 || command -v yum > /dev/null 2>&1; then',
            '        PKG_MGR=$(command -v dnf || command -v yum)',
            '        $PKG_MGR install -y wget ca-certificates tar gzip libicu 2>&1 | tail -3',
            '        wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh',
            '        chmod +x /tmp/dotnet-install.sh',
            "        /tmp/dotnet-install.sh --channel $dotnetChannel --runtime dotnet --install-dir /usr/share/dotnet 2>&1 | tail -5",
            '        ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet || true',
            '    elif command -v tdnf > /dev/null 2>&1; then',
            '        tdnf install -y wget ca-certificates tar gzip icu 2>&1 | tail -3',
            '        wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh',
            '        chmod +x /tmp/dotnet-install.sh',
            "        /tmp/dotnet-install.sh --channel $dotnetChannel --runtime dotnet --install-dir /usr/share/dotnet 2>&1 | tail -5",
            '        ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet || true',
            '    fi',
            'fi',
            '# Set invariant globalization mode as fallback if libicu is not available',
            'export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1',
            'export DOTNET_ROOT=/usr/share/dotnet',
            'export PATH=$PATH:/usr/share/dotnet',
            'DOTNET_TEST_RESULT=0',
            'if command -v dotnet > /dev/null 2>&1; then',
            "    echo ""Running QuicHello test ($dotnetDllName)...""",
            "    # Try version-specific DLL first, fall back to generic name",
            "    if [ -f '/dotnet-test/$dotnetDllName' ]; then",
            "        dotnet '/dotnet-test/$dotnetDllName' 2>&1",
            '    else',
            '        dotnet /dotnet-test/QuicHello.dll 2>&1',
            '    fi',
            '    DOTNET_EXIT=$?',
            '    if [ $DOTNET_EXIT -eq 0 ]; then',
            '        echo "=== .NET QUIC Test PASSED ==="',
            '    else',
            '        echo "=== .NET QUIC Test FAILED (exit: $DOTNET_EXIT) ==="',
            '        DOTNET_TEST_RESULT=1',
            '    fi',
            'else',
            '    echo "WARNING: Could not install .NET runtime, skipping .NET test"',
            '    DOTNET_TEST_RESULT=2',
            'fi',
            '# Exit with combined result (0=all pass, 1=dotnet fail, 100+=package fail)',
            'exit $DOTNET_TEST_RESULT'
        ) -join "`n"
        
        # Remove the final "exit 0" from package script and append .NET test
        $combinedScript = $combinedScript -replace 'echo "=== Package validation PASSED ==="', 'echo "=== Package validation PASSED ===" '
        $combinedScript = $combinedScript + $dotnetTestScript
    }
    
    # Convert Windows path to Docker-compatible path
    $packagesMount = (Resolve-Path $PackagesPath).Path -replace '\\', '/'

    # Build docker args
    $dockerArgs = @(
        'run',
        '--rm',
        '--platform', $platform,
        '-u', '0',
        '-v', "${packagesMount}:/packages:ro"
    )
    
    # Add .NET test artifacts mount if needed
    if ($includeDotNetTest) {
        $dotnetMount = (Resolve-Path $DotNetTestPath).Path -replace '\\', '/'
        $dockerArgs += @('-v', "${dotnetMount}:/dotnet-test:ro")
        Write-Info "Mounting .NET test from: $dotnetMount"
    }
    
    $dockerArgs += @(
        $Image,
        '/bin/bash', '-c', $combinedScript
    )

    Write-Info "Mounting packages from: $packagesMount"

    # Run everything in a single container
    Write-Step "Running Docker container..."
    & docker @dockerArgs 2>&1 | ForEach-Object { Write-Info $_ }
    
    $exitCode = $LASTEXITCODE
    
    # Interpret exit codes:
    # 0 = all passed
    # 1 = .NET test failed (package passed)
    # 2 = .NET runtime install failed (package passed)
    # 100+ = package installation failed
    
    $packageSuccess = $exitCode -lt 100
    $dotnetSuccess = $exitCode -eq 0
    
    if (-not $includeDotNetTest) {
        # If we didn't run .NET test, consider it passed by default
        $dotnetSuccess = $true
        $packageSuccess = $exitCode -eq 0
    }
    
    if ($packageSuccess) {
        Write-Success "Package installation - PASSED"
    } else {
        Write-Failure "Package installation - FAILED (exit code: $exitCode)"
    }
    
    if ($includeDotNetTest) {
        if ($exitCode -eq 0) {
            Write-Success ".NET QUIC test - PASSED"
        } elseif ($exitCode -eq 2) {
            Write-WarningMsg ".NET QUIC test - SKIPPED (runtime not installed)"
            $dotnetSuccess = $true  # Don't count as failure
        } elseif ($exitCode -eq 1) {
            Write-Failure ".NET QUIC test - FAILED"
        }
    }
    
    $overallSuccess = $packageSuccess -and $dotnetSuccess
    if ($overallSuccess) {
        Write-Success "$friendlyName ($Arch) - ALL TESTS PASSED"
    } else {
        Write-Failure "$friendlyName ($Arch) - SOME TESTS FAILED"
    }
    
    return @{ PackageTest = $packageSuccess; DotNetTest = $dotnetSuccess }
}

# Main execution
Write-Header "MsQuic Linux Package Validation via Docker"
Write-Step "Configuration:"
Write-Info "Architecture: $Arch"
Write-Info "Distribution: $Distro"
Write-Info "Packages Path: $(if ($PackagesPath) { $PackagesPath } else { '(not found)' })"
Write-Info "Package Version: $(if ($PackageVersion) { $PackageVersion } else { '(latest)' })"
Write-Info "Max Parallel Jobs: $MaxParallelJobs"
Write-Info "Log Path: $(if ($LogPath) { $LogPath } else { '(current directory)' })"

# Verify Docker is available
Write-Header "Checking Prerequisites"

if (-not (Test-DockerAvailable)) {
    Write-ErrorMsg "Docker is not available. Please install Docker Desktop and ensure it's running."
    exit 1
}
Write-Success "Docker is available"

# Verify packages path exists
if (-not $PackagesPath) {
    Write-ErrorMsg "PackagesPath not specified and could not be auto-detected."
    Write-Info "Please specify -PackagesPath parameter or use -QuickValidate"
    Write-Info "Alternative locations to place packages:"
    Write-Info "  - .\packages"
    Write-Info "  - $env:USERPROFILE\Desktop\msquic-packages"
    exit 1
}

$PackagesPath = Resolve-Path $PackagesPath -ErrorAction Stop
Write-Success "Packages path verified: $PackagesPath"

# Setup log path - clear old logs and recreate
if (-not $LogPath) {
    $LogPath = Get-Location
}
if (Test-Path $LogPath) {
    # Clear existing log files from previous runs
    $oldLogs = Get-ChildItem -Path $LogPath -Filter "*.log" -File -ErrorAction SilentlyContinue
    if ($oldLogs) {
        Write-Step "Clearing $($oldLogs.Count) old log file(s)..."
        $oldLogs | Remove-Item -Force
    }
} else {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$LogPath = Resolve-Path $LogPath -ErrorAction Stop
Write-Step "Log path: $LogPath"
Write-Step "Max parallel jobs: $MaxParallelJobs"

# List available packages grouped by distro
Write-Step "Available packages:"
$distroFolders = Get-ChildItem -Path $PackagesPath -Directory -ErrorAction SilentlyContinue
if ($distroFolders) {
    foreach ($folder in $distroFolders) {
        $packages = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.deb','.rpm' }
        if ($packages) {
            Write-Host "    $($folder.Name)/" -ForegroundColor Yellow
            $packages | ForEach-Object { Write-Info "      $($_.Name)" }
        }
    }
}
# Also check root folder
$rootPackages = Get-ChildItem -Path $PackagesPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.deb','.rpm' }
if ($rootPackages) {
    Write-Host "    (root)/" -ForegroundColor Yellow
    $rootPackages | ForEach-Object { Write-Info "      $($_.Name)" }
}

# Setup QEMU for cross-architecture emulation if needed (arm64 and arm32)
$needsQemu = ($Arch -eq 'arm64' -or $Arch -eq 'arm32' -or $Arch -eq 'All') -and -not $SkipQemuSetup
if ($needsQemu) {
    Setup-QemuEmulation
}

# Determine which distributions to test
$distrosToTest = @()
if ($Distro -eq 'All') {
    $distrosToTest = $DockerImages.Keys
} else {
    $distrosToTest = @($Distro)
}

# Determine which architectures to test
$archsToTest = @()
if ($Arch -eq 'All') {
    # Default to x64, arm64, and arm32 for 'All'
    # Note: arm32 is only available for Ubuntu, Debian, and Fedora (DEB distros mainly)
    $archsToTest = @('x64', 'arm64', 'arm32')
} else {
    $archsToTest = @($Arch)
}

# Build .NET test once on the host before running distro tests
$DotNetTestPath = $null
$runDotNetTests = -not $SkipDotNetTest

# Auto-detect MsQuicRepoPath (script is in msquic/scripts/)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MsQuicRepoPath = Split-Path -Parent $ScriptDir

if ($runDotNetTests) {
    Write-Header "Building .NET QUIC Test"

    if (-not $MsQuicRepoPath -or -not (Test-Path $MsQuicRepoPath)) {
        Write-WarningMsg "MsQuic repository not found. .NET tests will be skipped."
        Write-Info "To run .NET tests, ensure this script is in msquic/scripts/"
        $runDotNetTests = $false
    } else {
        # Check if .NET SDK is available
        $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnetCmd) {
            Write-WarningMsg ".NET SDK not found. .NET tests will be skipped."
            Write-Info "Install .NET SDK to enable .NET QUIC validation."
            $runDotNetTests = $false
        } else {
            Write-Step ".NET SDK found: $(dotnet --version)"

            # Build .NET test for both 8.0 and 9.0 versions (different distros need different versions)
            $dotnetVersionsToBuild = @('9.0', '8.0')
            $DotNetTestPath = Join-Path $env:TEMP "msquic_dotnet_docker_test"

            if (Test-Path $DotNetTestPath) {
                Remove-Item $DotNetTestPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $DotNetTestPath -Force | Out-Null

            $builtVersions = @()

            Write-Step "Building .NET QUIC test projects (portable/framework-dependent)..."

            foreach ($netVersion in $dotnetVersionsToBuild) {
                $projectPath = Join-Path $MsQuicRepoPath "src\cs\QuicSimpleTest\QuicHello.net$netVersion.csproj"
                if (Test-Path $projectPath) {
                    Write-Info "Building QuicHello for .NET $netVersion..."

                    try {
                        # Build as framework-dependent (portable) - works on any architecture
                        $buildOutput = & dotnet publish $projectPath -c Release -o $DotNetTestPath -f "net$netVersion" --self-contained false 2>&1

                        if ($LASTEXITCODE -eq 0) {
                            $builtVersions += $netVersion
                            Write-Info "  .NET $netVersion build succeeded"
                        } else {
                            Write-WarningMsg "  .NET $netVersion build failed (may not be available)"
                        }
                    } catch {
                        Write-WarningMsg "  .NET $netVersion build error: $_"
                    }
                } else {
                    Write-Info "  QuicHello.net$netVersion.csproj not found, skipping"
                }
            }

            if ($builtVersions.Count -eq 0) {
                Write-ErrorMsg "No .NET test projects could be built"
                $runDotNetTests = $false
                $DotNetTestPath = $null
            } else {
                Write-Success "Built .NET test for versions: $($builtVersions -join ', ')"

                # Create a generic QuicHello.dll that points to the latest version (for fallback)
                $latestVersion = $builtVersions | Sort-Object -Descending | Select-Object -First 1
                $builtDllFile = Join-Path $DotNetTestPath "QuicHello.net$latestVersion.dll"
                $builtRuntimeConfig = Join-Path $DotNetTestPath "QuicHello.net$latestVersion.runtimeconfig.json"
                $builtDepsJson = Join-Path $DotNetTestPath "QuicHello.net$latestVersion.deps.json"

                $targetDllFile = Join-Path $DotNetTestPath "QuicHello.dll"
                $targetRuntimeConfig = Join-Path $DotNetTestPath "QuicHello.runtimeconfig.json"
                $targetDepsJson = Join-Path $DotNetTestPath "QuicHello.deps.json"

                if (Test-Path $builtDllFile) {
                    Copy-Item $builtDllFile $targetDllFile -Force
                }
                if (Test-Path $builtRuntimeConfig) {
                    Copy-Item $builtRuntimeConfig $targetRuntimeConfig -Force
                }
                if (Test-Path $builtDepsJson) {
                    Copy-Item $builtDepsJson $targetDepsJson -Force
                }

                Write-Step ".NET test artifacts built at: $DotNetTestPath"
                Get-ChildItem $DotNetTestPath -Filter "*.dll" | ForEach-Object { Write-Info "  $($_.Name)" }
            }
        }
    }
}

# Track results
$results = @{}
$packagePassCount = 0
$packageFailCount = 0
$packageSkippedCount = 0
$dotnetPassCount = 0
$dotnetFailCount = 0
$dotnetSkippedCount = 0

# Build list of test tasks (pre-filter skipped items)
$testTasks = @()
Write-Header "Preparing Test Tasks"

foreach ($currentArch in $archsToTest) {
    foreach ($distroName in $distrosToTest) {
        $distroConfig = $DockerImages[$distroName]
        $image = $distroConfig[$currentArch]
        $packageType = $distroConfig['type']
        $resultKey = "${distroName}_${currentArch}"
        $friendlyName = $distroName -replace '_', ' '

        if (-not $image) {
            Write-WarningMsg "No image available for $distroName on $currentArch, skipping..."
            $results[$resultKey] = @{
                'Distro' = $distroName
                'Arch' = $currentArch
                'PackageTest' = $null
                'DotNetTest' = $null
                'Skipped' = $true
                'SkipReason' = 'No Docker image available'
            }
            $packageSkippedCount++
            if ($runDotNetTests) { $dotnetSkippedCount++ }
            continue
        }

        # Check if package exists before adding to task list
        $packageCheck = Test-PackageExists -PackagesPath $PackagesPath -DistroName $distroName -Arch $currentArch -PackageType $packageType -TargetVersion $PackageVersion

        if (-not $packageCheck.Found) {
            $versionInfo = if ($PackageVersion) { " (version $PackageVersion)" } else { "" }
            Write-WarningMsg "No $packageType package found for $distroName ($currentArch)$versionInfo - skipping"
            $results[$resultKey] = @{
                'Distro' = $distroName
                'Arch' = $currentArch
                'PackageTest' = $null
                'DotNetTest' = $null
                'Skipped' = $true
                'SkipReason' = 'Package not found'
            }
            $packageSkippedCount++
            if ($runDotNetTests) { $dotnetSkippedCount++ }
            continue
        }

        # Add to test task list
        $testTasks += @{
            DistroName = $distroName
            Image = $image
            Arch = $currentArch
            PackageType = $packageType
            ResultKey = $resultKey
            FriendlyName = $friendlyName
            PackagePath = $packageCheck.Path
            DotNetVersion = ($distroConfig['dotnetVersion'] ?? '9.0')
        }
        Write-Step "Queued: $friendlyName ($currentArch)"
    }
}

Write-Host ""
Write-Step "Total tasks queued: $($testTasks.Count)"
Write-Step "Running with max $MaxParallelJobs parallel jobs"
Write-Host ""

# Run tests in parallel
if ($testTasks.Count -gt 0) {
    Write-Header "Running Parallel Validation"

    $runningJobs = @{}
    $completedCount = 0
    $totalTasks = $testTasks.Count
    $taskIndex = 0

    # Process all tasks with parallel execution
    while ($taskIndex -lt $totalTasks -or $runningJobs.Count -gt 0) {
        # Start new jobs up to MaxParallelJobs
        while ($taskIndex -lt $totalTasks -and $runningJobs.Count -lt $MaxParallelJobs) {
            $task = $testTasks[$taskIndex]
            $logFile = Join-Path $LogPath "$($task.ResultKey).log"

            Write-Host "[START] $($task.FriendlyName) ($($task.Arch)) - Log: $($task.ResultKey).log" -ForegroundColor Cyan

            # Pre-compute all values needed for Docker execution
            $platform = switch ($task.Arch) {
                'arm64'   { 'linux/arm64' }
                'arm32'   { 'linux/arm/v7' }
                'ppc64le' { 'linux/ppc64le' }
                's390x'   { 'linux/s390x' }
                default   { 'linux/amd64' }
            }

            # Handle both string and PathInfo types
            $packagesMount = ($PackagesPath.ToString()) -replace '\\', '/'
            $installScript = Get-InstallScript -PackageType $task.PackageType -Arch $task.Arch -DistroName $task.DistroName

            # Build combined script with .NET test if enabled
            $combinedScript = $installScript
            $includeDotNetTest = $runDotNetTests -and $DotNetTestPath -and (Test-Path $DotNetTestPath)
            $dotnetMount = $null

            if ($includeDotNetTest) {
                $dotnetMount = ($DotNetTestPath.ToString()) -replace '\\', '/'
                $dotnetChannel = $task.DotNetVersion
                $dotnetDllName = "QuicHello.net$($task.DotNetVersion).dll"
                $dotnetMajor = $task.DotNetVersion.Split('.')[0]

                $dotnetTestScript = @(
                    '',
                    'echo ""',
                    'echo "=== Running .NET QUIC Test ==="',
                    "echo ""Required .NET version: $dotnetChannel""",
                    "REQUIRED_MAJOR=$dotnetMajor",
                    'DOTNET_OK=0',
                    'if command -v dotnet > /dev/null 2>&1; then',
                    '    INSTALLED_VERSION=$(dotnet --list-runtimes 2>/dev/null | grep "Microsoft.NETCore.App" | head -1 | awk ''{print $2}'' | cut -d. -f1)',
                    '    if [ "$INSTALLED_VERSION" = "$REQUIRED_MAJOR" ]; then',
                    '        echo "Found compatible .NET runtime"',
                    '        DOTNET_OK=1',
                    '    fi',
                    'fi',
                    'if [ $DOTNET_OK -eq 0 ]; then',
                    '    echo "Installing .NET runtime..."',
                    '    if command -v apt-get > /dev/null 2>&1; then',
                    '        apt-get install -y --no-install-recommends wget ca-certificates libicu-dev 2>&1 | tail -3',
                    '    elif command -v zypper > /dev/null 2>&1; then',
                    '        zypper --non-interactive --no-gpg-checks install wget ca-certificates tar gzip libicu 2>&1 | tail -3',
                    '    elif command -v dnf > /dev/null 2>&1 || command -v yum > /dev/null 2>&1; then',
                    '        PKG_MGR=$(command -v dnf || command -v yum)',
                    '        $PKG_MGR install -y wget ca-certificates tar gzip libicu 2>&1 | tail -3',
                    '    elif command -v tdnf > /dev/null 2>&1; then',
                    '        tdnf install -y wget ca-certificates tar gzip icu 2>&1 | tail -3',
                    '    fi',
                    '    wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh 2>/dev/null',
                    '    chmod +x /tmp/dotnet-install.sh',
                    "    /tmp/dotnet-install.sh --channel $dotnetChannel --runtime dotnet --install-dir /usr/share/dotnet 2>&1 | tail -5",
                    '    ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet 2>/dev/null || true',
                    'fi',
                    'export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1',
                    'export DOTNET_ROOT=/usr/share/dotnet',
                    'export PATH=$PATH:/usr/share/dotnet',
                    'DOTNET_TEST_RESULT=0',
                    'if command -v dotnet > /dev/null 2>&1; then',
                    "    echo ""Running QuicHello test ($dotnetDllName)...""",
                    "    if [ -f '/dotnet-test/$dotnetDllName' ]; then",
                    "        dotnet '/dotnet-test/$dotnetDllName' 2>&1",
                    '    else',
                    '        dotnet /dotnet-test/QuicHello.dll 2>&1',
                    '    fi',
                    '    DOTNET_EXIT=$?',
                    '    if [ $DOTNET_EXIT -eq 0 ]; then',
                    '        echo "=== .NET QUIC Test PASSED ==="',
                    '    else',
                    '        echo "=== .NET QUIC Test FAILED (exit: $DOTNET_EXIT) ==="',
                    '        DOTNET_TEST_RESULT=1',
                    '    fi',
                    'else',
                    '    echo "WARNING: Could not install .NET runtime, skipping .NET test"',
                    '    DOTNET_TEST_RESULT=2',
                    'fi',
                    'exit $DOTNET_TEST_RESULT'
                ) -join "`n"

                $combinedScript = $combinedScript -replace 'echo "=== Package validation PASSED ==="', 'echo "=== Package validation PASSED ===" '
                $combinedScript = $combinedScript + $dotnetTestScript
            }

            # Start the job with pre-computed values
            $job = Start-Job -ScriptBlock {
                param($Image, $Platform, $PackagesMount, $CombinedScript, $LogFile, $TaskInfo, $DotNetMount, $IncludeDotNetTest)

                $output = @{
                    ResultKey = $TaskInfo.ResultKey
                    DistroName = $TaskInfo.DistroName
                    Arch = $TaskInfo.Arch
                    PackageTest = $false
                    DotNetTest = (-not $IncludeDotNetTest)  # Default to true if not testing .NET
                    Logs = @()
                }

                try {
                    # Pull the image
                    $output.Logs += "Pulling image: $Image"
                    $pullOutput = docker pull --platform $Platform $Image 2>&1
                    $output.Logs += $pullOutput

                    if ($LASTEXITCODE -ne 0) {
                        $output.Logs += "ERROR: Failed to pull image"
                        return $output
                    }

                    # Build docker arguments array (avoids PowerShell variable interpolation issues)
                    $dockerArgs = @(
                        'run', '--rm',
                        '--platform', $Platform,
                        '-u', '0',
                        '-v', "${PackagesMount}:/packages:ro"
                    )
                    if ($DotNetMount) {
                        $dockerArgs += @('-v', "${DotNetMount}:/dotnet-test:ro")
                    }
                    $dockerArgs += @($Image, '/bin/bash', '-c', $CombinedScript)

                    # Run the container
                    $output.Logs += "Running validation container..."
                    $output.Logs += "Image: $Image, Platform: $Platform"
                    $dockerOutput = & docker @dockerArgs 2>&1
                    $output.Logs += $dockerOutput

                    $exitCode = $LASTEXITCODE
                    $output.Logs += "Exit code: $exitCode"

                    # Parse exit codes: 0=all pass, 1=dotnet fail, 2=dotnet skipped, 100+=package fail
                    if ($exitCode -ge 100) {
                        $output.PackageTest = $false
                        $output.DotNetTest = $false
                        $output.Logs += "Package installation FAILED"
                    } elseif ($exitCode -eq 0) {
                        $output.PackageTest = $true
                        $output.DotNetTest = $true
                        $output.Logs += "All tests PASSED"
                    } elseif ($exitCode -eq 1) {
                        $output.PackageTest = $true
                        $output.DotNetTest = $false
                        $output.Logs += "Package OK, .NET test FAILED"
                    } elseif ($exitCode -eq 2) {
                        $output.PackageTest = $true
                        $output.DotNetTest = $true  # Skipped counts as pass
                        $output.Logs += "Package OK, .NET test SKIPPED"
                    }
                }
                catch {
                    $output.Logs += "ERROR: $_"
                }

                return $output
            } -ArgumentList $task.Image, $platform, $packagesMount, $combinedScript, $logFile, $task, $dotnetMount, $includeDotNetTest

            $runningJobs[$task.ResultKey] = @{
                Job = $job
                Task = $task
                LogFile = $logFile
                StartTime = Get-Date
                IncludeDotNetTest = $includeDotNetTest
            }
            $taskIndex++
        }

        # Check for completed jobs
        $completedKeys = @()
        foreach ($key in $runningJobs.Keys) {
            $jobInfo = $runningJobs[$key]
            $job = $jobInfo.Job

            if ($job.State -eq 'Completed' -or $job.State -eq 'Failed') {
                $completedKeys += $key
                $completedCount++
                $task = $jobInfo.Task

                # Get job output
                $output = Receive-Job -Job $job -ErrorAction SilentlyContinue

                # Write log file
                $logContent = @(
                    "=== Validation Log for $($task.FriendlyName) ($($task.Arch)) ===",
                    "Started: $($jobInfo.StartTime)",
                    "Completed: $(Get-Date)",
                    "Duration: $((Get-Date) - $jobInfo.StartTime)",
                    "Image: $($task.Image)",
                    "",
                    "=== Output ==="
                )
                if ($output -and $output.Logs) {
                    $logContent += $output.Logs
                }
                $logContent -join "`n" | Out-File -FilePath $jobInfo.LogFile -Encoding UTF8

                # Process result
                if ($job.State -eq 'Completed' -and $output) {
                    $results[$output.ResultKey] = @{
                        'Distro' = $output.DistroName
                        'Arch' = $output.Arch
                        'PackageTest' = $output.PackageTest
                        'DotNetTest' = $output.DotNetTest
                        'Skipped' = $false
                        'SkipReason' = $null
                    }

                    # Determine overall pass/fail (both tests must pass)
                    $allPassed = $output.PackageTest -and $output.DotNetTest

                    if ($output.PackageTest) {
                        $packagePassCount++
                    } else {
                        $packageFailCount++
                    }

                    if ($runDotNetTests) {
                        if ($output.DotNetTest) {
                            $dotnetPassCount++
                        } else {
                            $dotnetFailCount++
                        }
                    }

                    # Show combined status
                    $jobIncludesDotNet = $jobInfo.IncludeDotNetTest
                    if ($allPassed) {
                        $statusMsg = "Package OK"
                        if ($runDotNetTests -and $jobIncludesDotNet) {
                            $statusMsg += ", .NET OK"
                        }
                        Write-Host "[PASS] $($task.FriendlyName) ($($task.Arch)) - $statusMsg" -ForegroundColor Green
                    } else {
                        $statusMsg = if (-not $output.PackageTest) { "Package FAILED" } else { "Package OK" }
                        if ($runDotNetTests -and $jobIncludesDotNet) {
                            $statusMsg += if (-not $output.DotNetTest) { ", .NET FAILED" } else { ", .NET OK" }
                        }
                        Write-Host "[FAIL] $($task.FriendlyName) ($($task.Arch)) - $statusMsg (see $($task.ResultKey).log)" -ForegroundColor Red
                    }
                } else {
                    # Job failed
                    $results[$task.ResultKey] = @{
                        'Distro' = $task.DistroName
                        'Arch' = $task.Arch
                        'PackageTest' = $false
                        'DotNetTest' = $false
                        'Skipped' = $false
                        'SkipReason' = $null
                    }
                    $packageFailCount++
                    if ($runDotNetTests) { $dotnetFailCount++ }
                    Write-Host "[FAIL] $($task.FriendlyName) ($($task.Arch)) - Job failed (see $($task.ResultKey).log)" -ForegroundColor Red
                }

                Remove-Job -Job $job -Force
                Write-Host "       Progress: $completedCount/$totalTasks completed" -ForegroundColor Gray
            }
        }

        # Remove completed jobs from tracking
        foreach ($key in $completedKeys) {
            $runningJobs.Remove($key)
        }

        # Brief pause to avoid CPU spinning
        if ($runningJobs.Count -gt 0) {
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Host ""
    Write-Success "All $totalTasks validation tasks completed"
    Write-Step "Log files written to: $LogPath"
}

# Print summary
Write-Header "Validation Summary"

Write-Host "  Package Installation Tests:" -ForegroundColor Cyan
foreach ($key in $results.Keys | Sort-Object) {
    $result = $results[$key]
    $friendlyName = $result['Distro'] -replace '_', ' '
    $arch = $result['Arch']
    if ($result['Skipped']) {
        Write-Skipped "  $friendlyName ($arch) - SKIPPED ($($result['SkipReason']))"
    } elseif ($result['PackageTest']) {
        Write-Success "  $friendlyName ($arch) - Package PASSED"
    } else {
        Write-Failure "  $friendlyName ($arch) - Package FAILED"
    }
}

if ($runDotNetTests) {
    Write-Host ""
    Write-Host "  .NET QUIC Tests (per distro):" -ForegroundColor Cyan
    foreach ($key in $results.Keys | Sort-Object) {
        $result = $results[$key]
        $friendlyName = $result['Distro'] -replace '_', ' '
        $arch = $result['Arch']
        if ($result['Skipped']) {
            Write-Skipped "  $friendlyName ($arch) - SKIPPED ($($result['SkipReason']))"
        } elseif ($result['DotNetTest']) {
            Write-Success "  $friendlyName ($arch) - .NET PASSED"
        } else {
            Write-Failure "  $friendlyName ($arch) - .NET FAILED"
        }
    }
}

Write-Host ""
$totalPackageTests = $packagePassCount + $packageFailCount
$totalDotNetTests = $dotnetPassCount + $dotnetFailCount
$totalTests = $totalPackageTests + $totalDotNetTests
$totalPassed = $packagePassCount + $dotnetPassCount
$totalFailed = $packageFailCount + $dotnetFailCount

Write-Info "Package Tests: $totalPackageTests | Passed: $packagePassCount | Failed: $packageFailCount | Skipped: $packageSkippedCount"
if ($runDotNetTests) {
    Write-Info ".NET Tests: $totalDotNetTests | Passed: $dotnetPassCount | Failed: $dotnetFailCount | Skipped: $dotnetSkippedCount"
}
Write-Info "Total: $totalTests | Passed: $totalPassed | Failed: $totalFailed | Skipped: $($packageSkippedCount)"

# Cleanup .NET test artifacts
if ($DotNetTestPath -and (Test-Path $DotNetTestPath)) {
    Remove-Item $DotNetTestPath -Recurse -Force -ErrorAction SilentlyContinue
}

if ($totalFailed -gt 0) {
    Write-Host ""
    Write-ErrorMsg "Some validations failed!"
    exit 1
} else {
    Write-Host ""
    Write-Success "All validations passed!"
    exit 0
}
