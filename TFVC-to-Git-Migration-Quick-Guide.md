# TFVC to Git Branch Migration

This tool migrates one or more TFVC branches, including their history, into branches in a single Git repository.

## Required files

Keep these files in the same folder:

```text
tfvc-git-multibranch-config.ps1
migration.config.psd1
branches.txt
```

## 1. Update `migration.config.psd1`

```powershell
@{
    OrgUrl = 'https://dev.azure.com/<organization>'

    GitRemoteUrl = 'https://dev.azure.com/<organization>/<project>/_git/<git-repository>'

    BranchListFile = '.\branches.txt'
    BaseFolder      = '.\work\MultiBranch'
    LogFile         = '.\logs\tfvc-git-migration.log'

    RemoteName = 'origin'

    ReuseExistingLocalRepo   = $false
    SkipIfRemoteBranchExists = $true
    ContinueOnBranchFailure  = $true
    PushTags                 = $false
}
```

## 2. Update `branches.txt`

Add one TFVC branch path per line:

```text
$/<TFVCProject>/branches/PIP-FIRST
$/<TFVCProject>/branches/QA
$/<TFVCProject>/branches/Release
```

A single branch also works:

```text
$/<TFVCProject>/branches/PIP-FIRST
```

Optional custom Git branch name:

```text
$/<TFVCProject>/branches/Old Branch Name|new-git-branch-name
```

## 3. Install required tools

Open PowerShell.

### Install Git for Windows

```powershell
winget install --id Git.Git -e --source winget
```

Close and reopen PowerShell, then verify:

```powershell
git --version
```

### Install Git LFS

```powershell
winget install --id GitHub.GitLFS -e --source winget
git lfs install
```

Verify:

```powershell
git lfs --version
```

### Install `git-tfs` without Chocolatey

```powershell
$Version = '0.34.0'
$InstallRoot = "$env:LOCALAPPDATA\Programs\git-tfs"
$ZipPath = "$env:TEMP\GitTfs-$Version.zip"
$DownloadUrl = "https://github.com/git-tfs/git-tfs/releases/download/v$Version/GitTfs-$Version.zip"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (Test-Path $InstallRoot) {
    Remove-Item $InstallRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath
Expand-Archive -Path $ZipPath -DestinationPath $InstallRoot -Force

$GitTfsExe = Get-ChildItem `
    -Path $InstallRoot `
    -Filter 'git-tfs.exe' `
    -Recurse |
    Select-Object -First 1

if (-not $GitTfsExe) {
    throw "git-tfs.exe was not found under $InstallRoot"
}

$GitTfsFolder = $GitTfsExe.Directory.FullName
$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$UserPathItems = @($UserPath -split ';' | Where-Object { $_ })

if ($UserPathItems -notcontains $GitTfsFolder) {
    $NewUserPath = (($UserPathItems + $GitTfsFolder) -join ';')
    [Environment]::SetEnvironmentVariable('Path', $NewUserPath, 'User')
}

$env:Path = "$GitTfsFolder;$env:Path"

git tfs --version
```

`git-tfs` also requires the Visual Studio/Team Explorer TFVC client components to communicate with TFVC.

### Verify everything

```powershell
git --version
git tfs --version
git lfs --version
```

## 4. Run the migration

Open PowerShell in the script folder:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\tfvc-git-multibranch-config.ps1
```

To use a specific config file:

```powershell
.\tfvc-git-multibranch-config.ps1 `
  -ConfigPath ".\migration.config.psd1"
```

## 5. Restart after interruption

The script can be safely rerun with:

```powershell
ReuseExistingLocalRepo   = $false
SkipIfRemoteBranchExists = $true
```

Already migrated remote branches are skipped. Incomplete branches are cloned and pushed again.

For a clean restart, delete only the temporary work folder:

```powershell
Remove-Item ".\work\MultiBranch" -Recurse -Force
```

Then rerun the script.

## 6. Validate migrated branches

```powershell
git ls-remote --heads `
  "https://dev.azure.com/<organization>/<project>/_git/<git-repository>"
```

## Log file

```text
.\logs\tfvc-git-migration.log
```

## Important

- Create the target Git repository as an empty repository.
- Stop TFVC check-ins before the final migration.
- Each branch keeps its own history.
- TFVC merge relationships are not recreated as native Git merge commits.
