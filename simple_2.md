## 1. Check current free space

```powershell
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" |
Select-Object `
    DeviceID,
    @{Name="SizeGB";Expression={[math]::Round($_.Size/1GB,2)}},
    @{Name="UsedGB";Expression={[math]::Round(($_.Size-$_.FreeSpace)/1GB,2)}},
    @{Name="FreeGB";Expression={[math]::Round($_.FreeSpace/1GB,2)}},
    @{Name="UsedPercent";Expression={
        [math]::Round((($_.Size-$_.FreeSpace)/$_.Size)*100,2)
    }} |
Format-Table -AutoSize
```

For this build VM, try to maintain at least **30–40 GB free**, depending on build size.

## 2. Inspect remaining `_diag` usage

Check which folders remain large:

```powershell
$path = "C:\azagent\A1\_diag"

Get-ChildItem $path -Directory -Force -ErrorAction SilentlyContinue |
ForEach-Object {
    $size = Get-ChildItem $_.FullName -File -Recurse -Force `
        -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum

    [PSCustomObject]@{
        Folder       = $_.FullName
        SizeGB       = [math]::Round($size.Sum / 1GB, 2)
        LastModified = $_.LastWriteTime
    }
} |
Sort-Object SizeGB -Descending |
Format-Table -AutoSize
```

Also check the remaining oldest files:

```powershell
Get-ChildItem "C:\azagent\A1\_diag" -File -Recurse -Force |
Sort-Object LastWriteTime |
Select-Object -First 30 FullName, LastWriteTime,
    @{Name="SizeMB";Expression={[math]::Round($_.Length/1MB,2)}} |
Format-Table -AutoSize
```

You can consider retaining only **7 days** instead of 14 days if the agent generates logs very quickly, but keep enough logs for troubleshooting.

## 3. Examine Azure DevOps work directories

Your earlier output showed:

```text
C:\agent\_work       3.06 GB
C:\azagent\A1\_work  0 GB
```

`3.06 GB` is not critical, but inspect the contents:

```powershell
$path = "C:\agent\_work"

Get-ChildItem $path -Directory -Force |
ForEach-Object {
    $size = Get-ChildItem $_.FullName -File -Recurse -Force `
        -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum

    [PSCustomObject]@{
        Folder       = $_.Name
        FullPath     = $_.FullName
        SizeGB       = [math]::Round($size.Sum / 1GB, 2)
        LastModified = $_.LastWriteTime
    }
} |
Sort-Object SizeGB -Descending |
Format-Table -AutoSize
```

Typical folders include:

```text
_work\1
_work\2
_work\3
_work\_temp
_work\_tasks
_work\_tool
```

When no pipeline is running and the correct agent service is stopped, old numbered build folders can usually be cleared:

```text
C:\agent\_work\1
C:\agent\_work\2
C:\agent\_work\3
```

Do not delete the agent root configuration, such as:

```text
.agent
.credentials
bin
externals
```

Deleting `_tasks` or `_tool` is possible, but subsequent pipelines will need to download the tools/tasks again. Keep them unless they are unusually large.

## 4. Check Visual Studio subfolders

Visual Studio currently consumes approximately **28.47 GB**, making it the next major area.

Inspect its immediate subfolders:

```powershell
$path = "C:\Program Files\Microsoft Visual Studio"

Get-ChildItem $path -Directory -Recurse -Depth 3 -Force `
    -ErrorAction SilentlyContinue |
ForEach-Object {
    $size = Get-ChildItem $_.FullName -File -Recurse -Force `
        -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum

    [PSCustomObject]@{
        Folder = $_.FullName
        SizeGB = [math]::Round($size.Sum / 1GB, 2)
    }
} |
Where-Object { $_.SizeGB -ge 1 } |
Sort-Object SizeGB -Descending |
Select-Object -First 30 |
Format-Table -AutoSize
```

Pay particular attention to folders such as:

```text
VC\Tools\MSVC
MSBuild
SDK
Common7
```

**Do not delete Visual Studio files manually.**

Open:

```text
Visual Studio Installer
→ Installed version
→ Modify
→ Individual components
```

Remove only components not required by the pipeline, such as:

* Unused C++ toolsets
* Old Windows SDK versions
* Mobile development workloads
* Duplicate .NET SDKs
* Unused test tools

Keep the MSBuild and .NET Framework targeting packs required by the application.

## 5. Check NuGet caches

First list the NuGet cache locations:

```powershell
dotnet nuget locals all --list
```

Check their size:

```powershell
$nugetPaths = @(
    "$env:USERPROFILE\.nuget\packages",
    "$env:LOCALAPPDATA\NuGet\v3-cache",
    "$env:LOCALAPPDATA\NuGet\Cache"
)

foreach ($path in $nugetPaths) {
    if (Test-Path $path) {
        $size = Get-ChildItem $path -File -Recurse -Force `
            -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum

        [PSCustomObject]@{
            Path   = $path
            SizeGB = [math]::Round($size.Sum / 1GB, 2)
        }
    }
}
```

To clear all NuGet caches:

```powershell
dotnet nuget locals all --clear
```

Be aware that the next build will download packages again. On a restricted/private network, confirm package-feed connectivity before clearing them.

Also check which account runs the agent because its cache may be under another user profile:

```powershell
Get-CimInstance Win32_Service |
Where-Object { $_.Name -like "vstsagent*" } |
Select-Object Name, StartName, PathName |
Format-List
```

## 6. Check npm and Node.js caches

Find the npm cache location:

```powershell
npm config get cache
```

Check cache health and size:

```powershell
npm cache verify
```

To calculate its size:

```powershell
$npmCache = npm config get cache

$size = Get-ChildItem $npmCache -File -Recurse -Force `
    -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum

[PSCustomObject]@{
    Path   = $npmCache
    SizeGB = [math]::Round($size.Sum / 1GB, 2)
}
```

Clear it only when necessary:

```powershell
npm cache clean --force
```

The next frontend build will download dependencies again.

## 7. Find large ZIPs, packages and build outputs

Build agents often retain old deployment packages.

Search for files larger than 500 MB:

```powershell
Get-ChildItem C:\ -File -Recurse -Force -ErrorAction SilentlyContinue |
Where-Object { $_.Length -ge 500MB } |
Sort-Object Length -Descending |
Select-Object -First 50 `
    FullName,
    @{Name="SizeGB";Expression={[math]::Round($_.Length/1GB,2)}},
    LastWriteTime |
Format-Table -AutoSize
```

Search specifically for old build artifacts:

```powershell
Get-ChildItem C:\ -File -Recurse -Force -ErrorAction SilentlyContinue |
Where-Object {
    $_.Extension -in @(".zip", ".nupkg", ".msi", ".exe", ".pdb") -and
    $_.LastWriteTime -lt (Get-Date).AddDays(-30)
} |
Sort-Object Length -Descending |
Select-Object -First 100 `
    FullName,
    @{Name="SizeMB";Expression={[math]::Round($_.Length/1MB,2)}},
    LastWriteTime |
Format-Table -AutoSize
```

Look for locations such as:

```text
C:\Temp
C:\J
C:\Build
C:\Artifacts
C:\Deploy
C:\agent\_work
```

Also look for old folders named:

```text
_work_backup
backup
old
publish
PackageTmp
artifacts
drop
```

## 8. Check Windows component-store usage

Analyze first:

```powershell
DISM.exe /Online /Cleanup-Image /AnalyzeComponentStore
```

When cleanup is recommended:

```powershell
DISM.exe /Online /Cleanup-Image /StartComponentCleanup
```

Do not manually delete anything from:

```text
C:\Windows\WinSxS
```

Avoid `/ResetBase` unless you accept losing the ability to uninstall superseded Windows updates.

## 9. Check Windows Update downloads

Check size:

```powershell
$path = "C:\Windows\SoftwareDistribution\Download"

$size = Get-ChildItem $path -File -Recurse -Force `
    -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum

[PSCustomObject]@{
    Path   = $path
    SizeGB = [math]::Round($size.Sum / 1GB, 2)
}
```

Prefer Windows **Disk Cleanup** or **Storage Settings** rather than manually deleting Windows Update files.

You can launch:

```powershell
cleanmgr.exe
```

Select:

* Windows Update Cleanup
* Temporary files
* Delivery Optimization files
* System error memory dump files
* Recycle Bin

## 10. Check memory dumps and IIS logs

```powershell
$paths = @(
    "C:\Windows\MEMORY.DMP",
    "C:\Windows\Minidump",
    "C:\inetpub\logs",
    "C:\ProgramData\Microsoft\Windows\WER",
    "C:\Windows\Logs"
)

foreach ($path in $paths) {
    if (Test-Path $path) {
        $item = Get-Item $path -Force

        if ($item.PSIsContainer) {
            $size = Get-ChildItem $path -File -Recurse -Force `
                -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum

            [PSCustomObject]@{
                Path   = $path
                SizeGB = [math]::Round($size.Sum / 1GB, 2)
            }
        }
        else {
            [PSCustomObject]@{
                Path   = $path
                SizeGB = [math]::Round($item.Length / 1GB, 2)
            }
        }
    }
}
```

## Recommended priority

Based on your current findings:

1. Check the remaining `C:\azagent\A1\_diag` logs.
2. Review unnecessary Visual Studio workloads through Visual Studio Installer.
3. Search for old ZIP, publish and artifact files.
4. Check NuGet and npm caches.
5. Review old Azure DevOps numbered workspaces.
6. Run Windows component-store and Disk Cleanup.
7. Check dumps, IIS logs and old backup folders.

Do not blindly delete package caches or build tools until you confirm that package feeds and installers are accessible from the private build environment.
