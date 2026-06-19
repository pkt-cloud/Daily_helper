<small>
IIS Certificate Replacement Runbook for `newdev.example.com`

Purpose
This runbook explains how to import and verify a corrected `.pfx` certificate on the IIS VM, replace the wrong certificate binding, and validate the final HTTPS configuration.

This is based on the situation:
IIS hostname is already correct: `newdev.example.com`
Problem is not the IIS hostname binding
Problem is the certificate hostname mismatch
Goal is to replace the wrong certificate with the correct `.pfx`
Keep IIS hostname as `newdev.example.com`
Bind the correct certificate to both:
`newdev.example.com:443`
`0.0.0.0:443` default binding for SAP/OpenSSL/non-SNI compatibility

Run all PowerShell commands as Administrator on the IIS VM.
</small>
---
Step 0: Set common values
```powershell
$SiteName = "EXAMPLE-DEV"
$HostName = "newdev.example.com"

$PfxPath = "C:\Temp\Certs\newdev.example.com.pfx"
$CerPath = "C:\Temp\Certs\newdev.example.com.cer"

New-Item -ItemType Directory -Force -Path "C:\Temp\Certs" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null
```
Make sure the `.pfx` and `.cer` files are already copied to:
```text
C:\Temp\Certs\
```
---
Step 1: Verify the `.cer` file
The `.cer` is usually the public certificate. It does not contain the private key. Use it to confirm the hostname and thumbprint.
```powershell
$cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)

$cer | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter, HasPrivateKey, DnsNameList, EnhancedKeyUsageList
```
Expected:
```text
Subject/DnsNameList : newdev.example.com
HasPrivateKey       : False
EnhancedKeyUsage    : Server Authentication
```
Check hostname:
```powershell
$cerDnsNames = $cer.DnsNameList | ForEach-Object { $_.Unicode }

Write-Host "DNS names in CER:"
$cerDnsNames

if (($cerDnsNames -contains $HostName) -or ($cer.Subject -like "*$HostName*")) {
    Write-Host "CER hostname is correct for $HostName" -ForegroundColor Green
}
else {
    throw "STOP: CER hostname does not match $HostName"
}
```
---
Step 2: Verify the `.pfx` hostname before importing
```powershell
$pfxPreview = Get-PfxCertificate -FilePath $PfxPath

$pfxPreview | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter, DnsNameList, EnhancedKeyUsageList
```
It may ask for the PFX password.
Expected:
```text
Subject/DnsNameList : newdev.example.com
EnhancedKeyUsage    : Server Authentication
```
Check hostname:
```powershell
$pfxDnsNames = $pfxPreview.DnsNameList | ForEach-Object { $_.Unicode }

Write-Host "DNS names in PFX:"
$pfxDnsNames

if (($pfxDnsNames -contains $HostName) -or ($pfxPreview.Subject -like "*$HostName*")) {
    Write-Host "PFX hostname is correct for $HostName" -ForegroundColor Green
}
else {
    throw "STOP: PFX hostname does not match $HostName"
}
```
---
Step 3: Compare `.cer` and `.pfx`
If the `.cer` is the same leaf/server certificate as the `.pfx`, thumbprints should match.
```powershell
Write-Host "CER Thumbprint:" $cer.Thumbprint
Write-Host "PFX Thumbprint:" $pfxPreview.Thumbprint

if ($cer.Thumbprint -eq $pfxPreview.Thumbprint) {
    Write-Host "CER and PFX match." -ForegroundColor Green
}
else {
    Write-Host "CER and PFX thumbprints do not match. This may be okay only if CER is a CA/intermediate certificate. Confirm before proceeding." -ForegroundColor Yellow
}
```
For IIS binding, the `.pfx` is the important one because it contains the private key.
---
Step 4: Import the `.pfx` into IIS VM certificate store
```powershell
$PfxPassword = Read-Host "Enter PFX password" -AsSecureString

$cert = Import-PfxCertificate `
  -FilePath $PfxPath `
  -CertStoreLocation "Cert:\LocalMachine\My" `
  -Password $PfxPassword
```
If the PFX has no password:
```powershell
$cert = Import-PfxCertificate `
  -FilePath $PfxPath `
  -CertStoreLocation "Cert:\LocalMachine\My"
```
---
Step 5: Confirm imported certificate is correct
```powershell
$cert | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter, HasPrivateKey, DnsNameList, EnhancedKeyUsageList
```
Expected:
```text
DnsNameList   : newdev.example.com
HasPrivateKey : True
```
Run safety checks:
```powershell
if (-not $cert.HasPrivateKey) {
    throw "STOP: Imported certificate does not have private key. Do not proceed."
}

$importedDnsNames = $cert.DnsNameList | ForEach-Object { $_.Unicode }

if (($importedDnsNames -notcontains $HostName) -and ($cert.Subject -notlike "*$HostName*")) {
    throw "STOP: Imported certificate does not match $HostName. Do not proceed."
}

$Thumbprint = ($cert.Thumbprint -replace "\s","").ToUpper()

Write-Host "Using certificate thumbprint: $Thumbprint" -ForegroundColor Green
```
---
Step 6: Backup existing IIS and HTTP.SYS bindings
```powershell
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

netsh http show sslcert > "C:\Temp\sslcert-before-cert-replace-$timestamp.txt"

Import-Module WebAdministration

Get-WebBinding |
Select-Object protocol, bindingInformation, sslFlags |
Out-File "C:\Temp\iis-bindings-before-cert-replace-$timestamp.txt"
```
---
Step 7: Confirm IIS hostname is already correct
Do not change the IIS hostname unless it is missing.
```powershell
Get-WebBinding -Name $SiteName -Protocol "https" |
Select-Object protocol, bindingInformation, sslFlags
```
Expected:
```text
https    *:443:newdev.example.com    1
```
If it already exists, do not modify it.
If it is missing, create it:
```powershell
$currentBinding = Get-WebBinding -Name $SiteName -Protocol "https" |
Where-Object { $_.bindingInformation -eq "*:443:$HostName" }

if (-not $currentBinding) {
    New-WebBinding `
      -Name $SiteName `
      -Protocol https `
      -Port 443 `
      -HostHeader $HostName `
      -SslFlags 1
}
else {
    Write-Host "IIS hostname binding already exists for $HostName" -ForegroundColor Green
}
```
---
Step 8: Remove old/wrong certificate bindings
This removes certificate bindings only. It does not delete the IIS site.
Do not delete `44300`, `44301`, `44302`, etc.
Run only these:
```powershell
netsh http delete sslcert hostnameport=$($HostName):443
```
Delete old default certificate binding:
```powershell
netsh http delete sslcert ipport=0.0.0.0:443
```
Delete old/malformed env-agent bindings if present:
```powershell
netsh http delete sslcert hostnameport=env-agent-vm.example.com:443
netsh http delete sslcert hostnameport=env-agent-vm.example.comenv-agent-vm.example.com:443
```
If any command says:
```text
The system cannot find the file specified
```
that is okay. Continue.
---
Step 9: Bind correct certificate to `newdev.example.com:443`
```powershell
$AppId = [guid]::NewGuid().ToString("B")

netsh http add sslcert hostnameport=$($HostName):443 certhash=$Thumbprint certstorename=MY appid=$AppId
```
---
Step 10: Bind correct certificate to default `0.0.0.0:443`
This is important because earlier OpenSSL/SAP-style clients were receiving the old default self-signed certificate.
```powershell
$AppId = [guid]::NewGuid().ToString("B")

netsh http add sslcert ipport=0.0.0.0:443 certhash=$Thumbprint certstorename=MY appid=$AppId
```
---
Step 11: Restart IIS
```powershell
iisreset
```
---
Step 12: Verify HTTP.SYS certificate bindings
```powershell
netsh http show sslcert hostnameport=newdev.example.com:443
netsh http show sslcert ipport=0.0.0.0:443
```
Both should show the same new correct certificate hash:
```text
Certificate Hash : <new correct thumbprint>
```
---
Step 13: Verify IIS binding is still correct
```powershell
Get-WebBinding -Name $SiteName -Protocol "https" |
Select-Object protocol, bindingInformation, sslFlags
```
Expected:
```text
https    *:443:newdev.example.com    1
```
---
Step 14: Test using PowerShell curl
```powershell
curl.exe -v https://newdev.example.com/
```
Expected:
```text
HTTP/1.1 200 OK
```
You should not see:
```text
SEC_E_WRONG_PRINCIPAL
```
---
Step 15: Test using Git Bash OpenSSL
```bash
openssl s_client -connect newdev.example.com:443 -servername newdev.example.com -verify_hostname newdev.example.com </dev/null 2>&1 | grep -E "subject=|issuer=|Verify return code|Verification"
```
Expected:
```text
subject=CN=newdev.example.com
issuer=CN=Sectigo ...
Verify return code: 0 (ok)
```
If this still shows:
```text
subject=CN=env-agent-vm.example.com
```
then the old default certificate is still bound somewhere.
---
Step 16: Final SAP PO validation
SAP PO should use exactly:
```text
https://newdev.example.com/
```
Not:
```text
https://10.110.12.5/
https://env-agent-vm.example.com/
```
---
Summary
You are not changing the IIS hostname.
You are keeping:
```text
newdev.example.com
```
You are only replacing the certificate bound to:
```text
newdev.example.com:443
0.0.0.0:443
```
with the new correct `.pfx` certificate.
