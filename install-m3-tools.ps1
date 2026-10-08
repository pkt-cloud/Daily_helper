$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Log = "C:\packer-m3-tools.log"

function Log {
    param([string]$Message)
    "$(Get-Date -Format o)  $Message" | Add-Content -Path $Log -Encoding ASCII
}

function Require-Path {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Description
    )
    if (-not (Test-Path $Path)) {
        throw "$Description not found: $Path"
    }
    Log "FOUND: $Description -> $Path"
}

function Find-RequiredFile {
    param(
        [Parameter(Mandatory=$true)][string[]]$Roots,
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][string]$Description
    )
    foreach ($Root in $Roots) {
        if (-not (Test-Path $Root)) { continue }
        $Match = Get-ChildItem -Path $Root -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($Match) {
            Log "FOUND: $Description -> $($Match.FullName)"
            return $Match.FullName
        }
    }
    throw "$Description not found. Searched for $FileName under: $($Roots -join '; ')"
}

"$(Get-Date -Format o)  START MILESTONE 3" | Set-Content -Path $Log -Encoding ASCII

try {
    $BaseUrl = "http://192.168.250.1:8080"
    $LayoutZipName = "vs2026-m3-layout.zip"
    $LayoutZip = "C:\Windows\Temp\$LayoutZipName"
    $ExpectedLayoutSha256 = "AC55114C26CB37F92586BE83FC247B1DCA0968E8571FD7DD955C46F87D2624BF"
    $LayoutDir = "C:\ProgramData\VSLayout\BuildTools18.10.2"
    $InstallPath = "C:\Program Files\Microsoft Visual Studio\18\BuildTools"

    $Components = @(
        "Microsoft.VisualStudio.Workload.MSBuildTools"
        "Microsoft.VisualStudio.Workload.WebBuildTools"
        "Microsoft.Net.Component.4.6.TargetingPack"
        "Microsoft.Net.Component.4.6.1.TargetingPack"
        "Microsoft.Net.Component.4.6.1.SDK"
        "Microsoft.VisualStudio.Component.PortableLibrary"
        "Microsoft.VisualStudio.Component.NuGet.BuildTools"
        "Microsoft.VisualStudio.Component.TypeScript.TSServer"
        "Microsoft.VisualStudio.Component.WebDeploy"
    )

    Log "BEGIN: Download Visual Studio layout ZIP"
    Invoke-WebRequest -Uri "$BaseUrl/$LayoutZipName" -OutFile $LayoutZip -UseBasicParsing
    Log "END: Download Visual Studio layout ZIP"

    Require-Path -Path $LayoutZip -Description "Visual Studio layout ZIP"

    Log "BEGIN: Validate Visual Studio layout ZIP SHA256"
    $ActualLayoutSha256 = (Get-FileHash -Path $LayoutZip -Algorithm SHA256).Hash
    Log "Layout ZIP SHA256: $ActualLayoutSha256"
    if ($ActualLayoutSha256 -ne $ExpectedLayoutSha256) {
        throw "Visual Studio layout ZIP SHA256 mismatch. Expected=$ExpectedLayoutSha256 Actual=$ActualLayoutSha256"
    }
    Log "END: Validate Visual Studio layout ZIP SHA256"

    Log "BEGIN: Expand Visual Studio layout"
    if (Test-Path $LayoutDir) {
        Remove-Item $LayoutDir -Recurse -Force
    }
    New-Item -Path $LayoutDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $LayoutZip -DestinationPath $LayoutDir -Force
    Log "END: Expand Visual Studio layout"

    Require-Path -Path "$LayoutDir\Layout.json" -Description "Visual Studio Layout.json"
    Require-Path -Path "$LayoutDir\Response.json" -Description "Visual Studio Response.json"
    Require-Path -Path "$LayoutDir\Catalog.json" -Description "Visual Studio Catalog.json"

    Log "BEGIN: Locate Visual Studio Build Tools bootstrapper"
    $VsBootstrapper = Get-ChildItem -Path $LayoutDir -Filter "*.exe" -File |
        Where-Object { $_.Name -ne "vs_setup.exe" -and $_.Name -match "BuildTools" } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $VsBootstrapper) {
        throw "Visual Studio Build Tools bootstrapper could not be located in $LayoutDir"
    }
    Log "Visual Studio bootstrapper: $VsBootstrapper"
    Log "END: Locate Visual Studio Build Tools bootstrapper"

    Log "BEGIN: Install Visual Studio Build Tools 18.10.2"
    $VsArguments = @(
        "--noWeb"
        "--quiet"
        "--wait"
        "--norestart"
        "--installPath"
        $InstallPath
    )

    foreach ($Component in $Components) {
        $VsArguments += "--add"
        $VsArguments += $Component
    }

    & $VsBootstrapper @VsArguments
    $VsExitCode = $LASTEXITCODE

    Log "Visual Studio installer exit code: $VsExitCode"
    if ($VsExitCode -notin @(0, 3010)) {
        throw "Visual Studio Build Tools installation failed with exit code $VsExitCode"
    }

    $RebootRequired = ($VsExitCode -eq 3010)
    Log "Visual Studio reboot required: $RebootRequired"
    Log "END: Install Visual Studio Build Tools"

    Remove-Item $LayoutZip -Force -ErrorAction SilentlyContinue

    Log "BEGIN: Validate installed Visual Studio components"

    $VsWhereCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
        "$InstallPath\Common7\IDE\vswhere.exe"
    )

    $VsWhere = $VsWhereCandidates |
        Where-Object { $_ -and (Test-Path $_) } |
        Select-Object -First 1

    if (-not $VsWhere) {
        throw "vswhere.exe could not be located."
    }

    Log "vswhere path: $VsWhere"

    $ActualInstallPath = (& $VsWhere -products * -requires Microsoft.Component.MSBuild -property installationPath |
        Select-Object -First 1)

    if (-not $ActualInstallPath) {
        throw "vswhere could not locate a Visual Studio Build Tools installation containing MSBuild."
    }

    $ActualInstallPath = $ActualInstallPath.Trim()
    Log "Visual Studio installation path: $ActualInstallPath"

    $RequiredComponentIds = @(
        "Microsoft.Component.MSBuild"
        "Microsoft.Net.Component.4.6.TargetingPack"
        "Microsoft.Net.Component.4.6.1.TargetingPack"
        "Microsoft.Net.Component.4.6.1.SDK"
        "Microsoft.VisualStudio.Component.PortableLibrary"
        "Microsoft.VisualStudio.Component.NuGet.BuildTools"
        "Microsoft.VisualStudio.Component.TypeScript.TSServer"
        "Microsoft.VisualStudio.Component.WebDeploy"
    )

    foreach ($ComponentId in $RequiredComponentIds) {
        $Found = (& $VsWhere -products * -requires $ComponentId -property installationPath |
            Select-Object -First 1)
        if (-not $Found) {
            throw "Required Visual Studio component is not installed: $ComponentId"
        }
        Log "INSTALLED COMPONENT: $ComponentId"
    }

    Log "END: Validate installed Visual Studio components"

    Log "BEGIN: Validate x64 MSBuild"

    $MSBuildX64 = Join-Path $ActualInstallPath "MSBuild\Current\Bin\amd64\MSBuild.exe"
    Require-Path -Path $MSBuildX64 -Description "x64 MSBuild"

    $MSBuildVersion = (& $MSBuildX64 -version -nologo | Select-Object -Last 1).Trim()
    Log "MSBuild x64 version: $MSBuildVersion"

    Log "END: Validate x64 MSBuild"

    Log "BEGIN: Validate .NET Framework targeting packs"

    $ReferenceRoot = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework"

    $Net46Path  = Join-Path $ReferenceRoot ".NETFramework\v4.6"
    $Net461Path = Join-Path $ReferenceRoot ".NETFramework\v4.6.1"
    $Pcl50Path  = Join-Path $ReferenceRoot ".NETPortable\v5.0"

    Require-Path -Path $Net46Path  -Description ".NET Framework v4.6 reference assemblies"
    Require-Path -Path $Net461Path -Description ".NET Framework v4.6.1 reference assemblies"
    Require-Path -Path $Pcl50Path  -Description ".NETPortable v5.0 reference assemblies"

    Log "END: Validate .NET Framework targeting packs"

    Log "BEGIN: Validate Portable Library MSBuild targets"

    $MsbuildSearchRoots = @(
        (Join-Path $ActualInstallPath "MSBuild")
        "${env:ProgramFiles(x86)}\MSBuild"
    )

    $PortableCSharpTargets = Find-RequiredFile `
        -Roots $MsbuildSearchRoots `
        -FileName "Microsoft.Portable.CSharp.targets" `
        -Description "Microsoft.Portable.CSharp.targets"

    $PortableCoreTargets = Find-RequiredFile `
        -Roots $MsbuildSearchRoots `
        -FileName "Microsoft.Portable.Core.targets" `
        -Description "Microsoft.Portable.Core.targets"

    Log "END: Validate Portable Library MSBuild targets"

    Log "BEGIN: Validate web build tooling"

    $WebApplicationTargets = Find-RequiredFile `
        -Roots $MsbuildSearchRoots `
        -FileName "Microsoft.WebApplication.targets" `
        -Description "Microsoft.WebApplication.targets"

    Log "END: Validate web build tooling"

    Log "BEGIN: Validate TypeScript tooling"

    $TypeScriptTargets = Find-RequiredFile `
        -Roots $MsbuildSearchRoots `
        -FileName "Microsoft.TypeScript.targets" `
        -Description "Microsoft.TypeScript.targets"

    Log "END: Validate TypeScript tooling"

    Log "BEGIN: Validate Web Deploy"

    $WebDeployCandidates = @(
        "$env:ProgramFiles\IIS\Microsoft Web Deploy V3\msdeploy.exe"
        "${env:ProgramFiles(x86)}\IIS\Microsoft Web Deploy V3\msdeploy.exe"
    )

    $WebDeployExe = $WebDeployCandidates |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

    if (-not $WebDeployExe) {
        throw "Web Deploy msdeploy.exe could not be located."
    }

    Log "Web Deploy path: $WebDeployExe"
    Log "END: Validate Web Deploy"

    Log "NuGet.exe 6.14 is intentionally NOT baked into the image."
    Log "Pipeline NuGetToolInstaller will provision NuGet 6.14 at runtime."

    @"
Milestone 3 completed successfully
VisualStudioBuildTools=18.10.2
InstallPath=$ActualInstallPath
MSBuildX64=$MSBuildX64
MSBuildVersion=$MSBuildVersion
NetFramework46=$Net46Path
NetFramework461=$Net461Path
NetPortable50=$Pcl50Path
PortableCSharpTargets=$PortableCSharpTargets
PortableCoreTargets=$PortableCoreTargets
WebApplicationTargets=$WebApplicationTargets
TypeScriptTargets=$TypeScriptTargets
WebDeploy=$WebDeployExe
RebootRequired=$RebootRequired
"@ | Set-Content -Path "C:\packer-m3-ok.txt" -Encoding ASCII

    Log "SUCCESS MILESTONE 3"
}
catch {
    Log ("ERROR: " + $_.Exception.Message)
    throw
}
