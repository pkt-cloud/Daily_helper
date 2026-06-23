# Safe Proof Steps for Fresh IIS HTTPS Certificate Replacement

## Purpose

This runbook provides a safe proof-first process for replacing the IIS HTTPS certificate using a fresh `.pfx` file and optional `.p7b` chain file.

The goal is to avoid expected failures such as:

- Wrong certificate hostname
- Missing Subject Alternative Name (SAN)
- Missing Server Authentication EKU
- Missing private key
- Broken HTTP.SYS binding
- SNI/default binding mismatch
- SAP/OpenSSL trust-chain failure

---

## Important Notes

- `.pfx` is required for IIS binding because it contains the server certificate and private key.
- `.p7b` is usually a certificate chain bundle. It does not contain the private key and should not be used directly for IIS binding.
- Do not delete the old certificate from the certificate store until the new certificate is fully validated.
- Do not import a Root CA certificate into the Trusted Root store unless Infra/PKI confirms it is required and approved.
- If the fresh PFX does not contain `Server Authentication (1.3.6.1.5.5.7.3.1)`, stop immediately and do not bind it.

---

# Phase 0: Set Variables

Run PowerShell as Administrator on the IIS VM.

```powershell
$SiteName = "FIRST-DEV"
$HostName = "newdev.first.com"

$PfxPath = "C:\Temp\Certs\newdev.first.com.pfx"
$P7bPath = "C:\Temp\Certs\newdev.first.com.p7b"

New-Item -ItemType Directory -Force -Path "C:\Temp\Certs" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null
```

Update the file paths if your fresh `.pfx` and `.p7b` use different names.

---

# Phase 1: Pre-check Fresh PFX Before Changing IIS

## 1. Read the PFX

```powershell
$pfxCert = Get-PfxCertificate -FilePath $PfxPath

$pfxCert | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter, DnsNameList, EnhancedKeyUsageList
```

Expected:

```text
DnsNameList          : newdev.first.com
EnhancedKeyUsageList : Server Authentication (1.3.6.1.5.5.7.3.1)
```

## 2. Hard stop validation

```powershell
$dnsNames = $pfxCert.DnsNameList | ForEach-Object { $_.Unicode }
$ekuOids  = $pfxCert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }

if ($dnsNames -notcontains $HostName) {
    throw "STOP: PFX does not contain expected hostname in DnsNameList/SAN."
}

if ($ekuOids -notcontains "1.3.6.1.5.5.7.3.1") {
    throw "STOP: PFX does not contain Server Authentication EKU."
}

Write-Host "PFX hostname and Server Authentication EKU are correct." -ForegroundColor Green
```

Do not proceed if this fails.

---

# Phase 2: Verify Certificate Extensions

```powershell
$pfxCert.Extensions |
Select-Object @{Name="Name";Expression={$_.Oid.FriendlyName}},
              @{Name="OID";Expression={$_.Oid.Value}},
              Critical |
Format-Table -AutoSize
```

Expected important entries:

```text
Subject Alternative Name   2.5.29.17
Enhanced Key Usage         2.5.29.37
Key Usage                  2.5.29.15
Basic Constraints          2.5.29.19
```

Minimum must-have:

```text
Subject Alternative Name
Enhanced Key Usage
Server Authentication
```

---

# Phase 3: Import PFX, But Do Not Bind Yet

Importing the PFX into the certificate store is safe. It does not affect the website until you bind it.

```powershell
$PfxPassword = Read-Host "Enter PFX password" -AsSecureString

$newCert = Import-PfxCertificate `
  -FilePath $PfxPath `
  -CertStoreLocation "Cert:\LocalMachine\My" `
  -Password $PfxPassword
```

Verify private key and certificate properties:

```powershell
$newCert | Format-List Subject, Issuer, Thumbprint, NotBefore, NotAfter, HasPrivateKey, DnsNameList, EnhancedKeyUsageList
```

Expected:

```text
HasPrivateKey       : True
DnsNameList         : newdev.first.com
EnhancedKeyUsageList: Server Authentication
```

Hard stop validation after import:

```powershell
if (-not $newCert.HasPrivateKey) {
    throw "STOP: Imported certificate does not have private key."
}

$dnsNames = $newCert.DnsNameList | ForEach-Object { $_.Unicode }
$ekuOids  = $newCert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }

if ($dnsNames -notcontains $HostName) {
    throw "STOP: Imported certificate does not contain expected hostname."
}

if ($ekuOids -notcontains "1.3.6.1.5.5.7.3.1") {
    throw "STOP: Imported certificate does not contain Server Authentication EKU."
}

$NewThumbprint = ($newCert.Thumbprint -replace "\s", "").ToUpper()

Write-Host "New certificate passed all checks." -ForegroundColor Green
Write-Host "New Thumbprint: $NewThumbprint" -ForegroundColor Green
```

---

# Phase 4: Check Whether P7B/CA Chain Is Needed

First check Windows chain with the new cert.

```powershell
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode = "NoCheck"

$result = $chain.Build($newCert)

Write-Host "Windows chain build result:" $result

$chain.ChainStatus | Format-Table Status, StatusInformation -AutoSize
```

If the result is:

```text
True
```

then Windows/IIS likely does not need the P7B immediately.

If the result is:

```text
False
```

then inspect/import the P7B chain.

```powershell
certutil -dump $P7bPath
```

Import intermediate chain only if needed:

```powershell
certutil -addstore -f CA $P7bPath
```

Do not import root CA into `Root` unless Infra/PKI confirms it is required and approved.

---

# Phase 5: Backup Current Live Bindings

This is important for rollback.

```powershell
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

netsh http show sslcert > "C:\Temp\sslcert-before-new-cert-$timestamp.txt"

Import-Module WebAdministration

Get-WebBinding |
Select-Object protocol, bindingInformation, sslFlags |
Out-File "C:\Temp\iis-bindings-before-new-cert-$timestamp.txt"
```

Capture current old hashes:

```powershell
$oldHostOutput = netsh http show sslcert hostnameport=$($HostName):443
$oldDefaultOutput = netsh http show sslcert ipport=0.0.0.0:443

$oldHostOutput
$oldDefaultOutput
```

Save the old certificate hash values. This is your rollback proof.

---

# Phase 6: Prepare Rollback Commands Before Changing Anything

Before binding the new cert, prepare this rollback command set using the old hash.

Replace `<OLD_HOST_HASH>` with the old certificate hash from the backup.

```powershell
# ROLLBACK ONLY - do not run unless needed

$SiteName = "FIRST-DEV"
$HostName = "newdev.first.com"
$OldThumbprint = "<OLD_HOST_HASH>"

netsh http delete sslcert hostnameport=$($HostName):443
netsh http delete sslcert ipport=0.0.0.0:443

$AppId = [guid]::NewGuid().ToString("B")
netsh http add sslcert hostnameport=$($HostName):443 certhash=$OldThumbprint certstorename=MY appid=$AppId

$AppId = [guid]::NewGuid().ToString("B")
netsh http add sslcert ipport=0.0.0.0:443 certhash=$OldThumbprint certstorename=MY appid=$AppId

iisreset
```

Do not run this now. Keep it ready.

---

# Phase 7: Bind the New Certificate

Delete only these two bindings:

```powershell
netsh http delete sslcert hostnameport=$($HostName):443
netsh http delete sslcert ipport=0.0.0.0:443
```

If it says not found, continue.

Add new certificate to the hostname binding:

```powershell
$AppId = [guid]::NewGuid().ToString("B")

netsh http add sslcert hostnameport=$($HostName):443 certhash=$NewThumbprint certstorename=MY appid=$AppId
```

Add new certificate to default binding:

```powershell
$AppId = [guid]::NewGuid().ToString("B")

netsh http add sslcert ipport=0.0.0.0:443 certhash=$NewThumbprint certstorename=MY appid=$AppId
```

Restart IIS:

```powershell
iisreset
```

---

# Phase 8: Verify HTTP.SYS Bindings After Change

```powershell
netsh http show sslcert hostnameport=$($HostName):443
netsh http show sslcert ipport=0.0.0.0:443
```

Both should show:

```text
Certificate Hash : <NewThumbprint>
```

If hostname and default binding show different hashes, stop and fix before SAP retest.

---

# Phase 9: Verify IIS Binding Is Still Correct

```powershell
Get-WebBinding -Name $SiteName -Protocol "https" |
Select-Object protocol, bindingInformation, sslFlags
```

Expected:

```text
https    *:443:newdev.first.com    1
```

---

# Phase 10: Test From Windows curl

```powershell
curl.exe -v https://newdev.first.com/
```

Expected:

```text
HTTP/1.1 200 OK
```

There should be no:

```text
SEC_E_CERT_WRONG_USAGE
SEC_E_WRONG_PRINCIPAL
unable to get local issuer certificate
```

If curl fails with certificate usage or name errors, rollback or stop for analysis.

---

# Phase 11: Test Using Git Bash With SNI

```bash
openssl s_client -connect newdev.first.com:443 -servername newdev.first.com -verify_hostname newdev.first.com </dev/null 2>&1 | grep -E "subject=|issuer=|Verify return code|Verification"
```

Expected when Git Bash/OpenSSL trusts the issuing CA:

```text
Verify return code: 0 (ok)
```

Note: If the certificate is issued by an internal CA, Git Bash/OpenSSL may still show:

```text
Verify return code: 21 (unable to verify the first certificate)
```

even when Windows curl works. This usually means Git Bash/OpenSSL does not trust the internal CA chain. In that case, verify using the CA chain file:

```bash
openssl s_client -connect newdev.first.com:443 -servername newdev.first.com -verify_hostname newdev.first.com -CAfile /c/Temp/Certs/ca-chain.pem </dev/null 2>&1 | grep -E "subject=|issuer=|Verify return code|Verification"
```

If SAP uses its own truststore, the Root/Intermediate certificates from the P7B may need to be imported into SAP PO truststore.

---

# Phase 12: Test No-SNI / Default Certificate Behavior

This proves non-SNI clients will also receive the correct certificate from the default binding.

```bash
openssl s_client -connect newdev.first.com:443 -verify_hostname newdev.first.com </dev/null 2>&1 | grep -E "subject=|issuer=|Verify return code|Verification"
```

Expected if OpenSSL trusts the CA:

```text
Verify return code: 0 (ok)
```

If SNI test passes but no-SNI test shows a different certificate subject or wrong hostname, the default `0.0.0.0:443` binding is not correctly bound.

If only the verify code fails with `21`, it may be a trust-chain issue in Git Bash/OpenSSL rather than an IIS binding issue.

---

# Phase 13: Browser Test

From a machine that can reach the Dev URL:

```text
https://newdev.first.com/
```

Check certificate details:

```text
Issued to: newdev.first.com
Enhanced Key Usage: Server Authentication
Certificate path: valid
```

---

# Phase 14: SAP PO Retest

Ask SAP to test only after:

```text
Windows curl test passes
OpenSSL SNI test serves the correct certificate
OpenSSL no-SNI/default test serves the correct certificate
```

SAP URL must be:

```text
https://newdev.first.com/
```

Not:

```text
https://IP-address/
https://old-hostname/
```

---

# Safe Stop Rules

Stop and do not bind if any of these fail before binding:

```text
PFX missing Server Authentication EKU
PFX missing SAN/DnsNameList hostname
PFX missing private key after import
Certificate expired or not valid yet
Wrong hostname in certificate
```

Stop and rollback if any of these fail after binding:

```text
curl shows SEC_E_CERT_WRONG_USAGE
curl shows SEC_E_WRONG_PRINCIPAL
hostname and default bindings use different certificate hashes
remote served certificate does not match new thumbprint
site fails to load
```

---

# Best Practical Change Order

```text
1. Verify fresh PFX
2. Import PFX
3. Validate private key and EKU
4. Validate SAN/hostname
5. Check Windows chain
6. Backup current bindings
7. Prepare rollback commands
8. Bind new certificate
9. Verify HTTP.SYS hostname and default bindings
10. Test curl
11. Test OpenSSL with SNI
12. Test OpenSSL without SNI
13. Browser validation
14. SAP PO retest
```

---

# Final Recommendation

Proceed with the fresh PFX only after it passes the pre-checks.

Use the P7B only if:

```text
Windows chain build fails
curl/browser shows chain trust error
Git Bash/OpenSSL/SAP shows unable to verify certificate chain
SAP PO requires Root/Intermediate certificates in its truststore
```

Do not delete the old certificate from the certificate store until the new certificate is fully validated and stable.
