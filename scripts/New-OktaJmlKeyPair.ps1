<#
.SYNOPSIS
  Generates the RSA key pair for the MFG-JML-Leaver-Containment Okta service app on the server that will use it.
  The private key stays in a locked-down folder on this server. Only the public key (JWK) goes to Okta.
.DESCRIPTION
  Run once, as an administrator, on the server that runs the containment step (MFG-MGMT01 in the lab).
  Paste the printed JWK into the service app: General > Public keys > Edit > Add key.
.EXAMPLE
  ./scripts/New-OktaJmlKeyPair.ps1
#>
[CmdletBinding()]
param(
    [string]$KeyDirectory = 'C:\Lab\okta-jml-key',
    [string]$KeyId        = 'mfg-jml-2026-10'
)
$ErrorActionPreference = 'Stop'

$privatePath = Join-Path $KeyDirectory 'okta-jml-private.pem'
if (Test-Path $privatePath) { throw "A private key already exists at $privatePath. Rotate deliberately: move it aside first." }

New-Item -ItemType Directory $KeyDirectory -Force | Out-Null
# Only Administrators and SYSTEM, nothing inherited from C:\Lab
icacls $KeyDirectory /inheritance:r /grant 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null

function ConvertTo-B64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    Set-Content $privatePath $rsa.ExportPkcs8PrivateKeyPem()
    $p   = $rsa.ExportParameters($false)
    $jwk = [ordered]@{
        kty = 'RSA'; kid = $KeyId; use = 'sig'; alg = 'RS256'
        e   = (ConvertTo-B64Url $p.Exponent)
        n   = (ConvertTo-B64Url $p.Modulus)
    } | ConvertTo-Json -Compress
} finally { $rsa.Dispose() }

$jwk | Set-Content (Join-Path $KeyDirectory 'okta-jml-public.jwk.json')

Write-Host "Private key: $privatePath (Administrators and SYSTEM only)"
Write-Host "Public key (paste into Okta):"
Write-Host $jwk
