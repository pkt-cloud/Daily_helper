## 1. Check current C: drive usage

```powershell
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" |
Select-Object `
    DeviceID,
    @{Name="SizeGB"; Expression={[math]::Round($_.Size / 1GB, 2)}},
    @{Name="UsedGB"; Expression={[math]::Round(($_.Size-$_.FreeSpace) / 1GB, 2)}},
    @{Name="FreeGB"; Expression={[math]::Round($_.FreeSpace / 1GB, 2)}},
    @{Name="UsedPercent"; Expression={
        [math]::Round((($_.Size-$_.FreeSpace)/$_.Size)*100, 2)
    }} |
Format-Table -AutoSize
```

For a build VM, try to maintain at least **30–40 GB free**, because checkout, NuGet restore, MSBuild output, packaging and ZIP creation can temporarily consume considerable space.

## 2. Verify whether `C:\azagent\A1` is still an active agent

```powershell
Get-CimInstance Win32_Service |
Where-Object {
    $_.Name -like "vstsagent*" -or
    $_.PathName -match "azagent\\A1"
} |
Select-Object Name, State, StartName, PathName |
Format-List
```

### Interpret the result

* If a running service points to `C:\azagent\A1`, the agent is active.
* If no service points to it, it may be an old agent installation.
* Do not delete the complete `A1` folder until you confirm that Azure DevOps is no longer using it.

## 3. Inspect the huge diagnostic folder

Run:

```powershell
$diag = "C:\azagent\A1\_diag"

$files = Get-ChildItem $diag -File -Recurse -Force -ErrorAction SilentlyContinue

[PSCustomObject]@{
    TotalFiles = $files.Count
    TotalGB    = [math]::Round(
        ($files | Measure-Object Length -Sum).Sum / 1GB, 2
    )
    OldestFile = ($files | Sort-Object LastWriteTime |
        Select-Object -First 1).LastWriteTime
    NewestFile = ($files | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1).LastWriteTime
} | Format-List
```

Check the most common file types:

```powershell
$files |
Group-Object Extension |
Sort-Object Count -Descending |
Select-Object -First 15 Count, Name |
Format-Table -AutoSize
```

Check the largest files:

```powershell
$files |
Sort-Object Length -Descending |
Select-Object -First 20 `
    FullName,
    @{Name="SizeMB"; Expression={[math]::Round($_.Length / 1MB, 2)}},
    LastWriteTime |
Format-Table -AutoSize
```

## 4. Preview cleanup of logs older than 14 days

Do not delete immediately. First calculate what would be removed:

```powershell
$diag   = "C:\azagent\A1\_diag"
$cutoff = (Get-Date).AddDays(-14)

$oldFiles = Get-ChildItem $diag -File -Recurse -Force `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff }

[PSCustomObject]@{
    CutoffDate = $cutoff
    FileCount  = $oldFiles.Count
    ReclaimGB  = [math]::Round(
        ($oldFiles | Measure-Object Length -Sum).Sum / 1GB, 2
    )
} | Format-List
```

This will show how much space can be recovered while retaining the latest 14 days of logs.

## 5. Safely delete old diagnostic logs

Make sure no pipeline is running. Then identify and stop only the agent associated with `A1`:

```powershell
$agentService = Get-CimInstance Win32_Service |
Where-Object { $_.PathName -match "C:\\azagent\\A1\\" }

$agentService |
Select-Object Name, State, PathName |
Format-List
```

If the correct service is shown:

```powershell
Stop-Service -Name $agentService.Name -Force
```

Delete files older than 14 days:

```powershell
$diag   = "C:\azagent\A1\_diag"
$cutoff = (Get-Date).AddDays(-14)

Get-ChildItem $diag -File -Recurse -Force `
    -ErrorAction SilentlyContinue |
Where-Object { $_.LastWriteTime -lt $cutoff } |
Remove-Item -Force -ErrorAction SilentlyContinue
```

Restart the agent:

```powershell
Start-Service -Name $agentService.Name
Get-Service -Name $agentService.Name
```

Then verify recovered space:

```powershell
Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" |
Select-Object `
    DeviceID,
    @{Name="FreeGB"; Expression={[math]::Round($_.FreeSpace / 1GB, 2)}},
    @{Name="UsedPercent"; Expression={
        [math]::Round((($_.Size-$_.FreeSpace)/$_.Size)*100, 2)
    }}
```

## Visual Studio folder

**Do not use `Remove-Item` against the Visual Studio folder.** The 28.47 GB may be required by MSBuild and .NET Framework builds.

Use **Visual Studio Installer → Modify** to review installed workloads. Potentially removable components include unused:

* C++ workloads
* Old Windows SDKs
* Mobile development workloads
* Multiple duplicate build tool versions

Keep the MSBuild and .NET Framework components required by your application.

### Conclusion

Your immediate problem is most likely:

```text
C:\azagent\A1\_diag
17.24 GB
352,248 files
```

Retaining the latest 14 days and removing older diagnostic logs should recover most of that space without affecting source code, build artifacts or the agent configuration.
