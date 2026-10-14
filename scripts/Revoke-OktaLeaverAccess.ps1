<#
.SYNOPSIS
  Okta leaver containment: clears every Okta session and OAuth token, then deactivates the user.
.DESCRIPTION
  Authenticates as the MFG-JML-Leaver-Containment API service app with a private key JWT.
  No API token, no client secret. The app holds a custom admin role (view users, edit lifecycle
  states, clear sessions) scoped to the MFG-Workforce-AD-Sourced group, so it cannot act on admins.
  Every run, including dry runs and failures, appends one JSON line to the audit log.
  Safe to re-run: an already-deactivated user gets sessions cleared again and nothing else.
  Exit codes match the JML engine: 0 contained, 3 containment failed (page someone).
.EXAMPLE
  ./scripts/Revoke-OktaLeaverAccess.ps1 -UserPrincipalName agrant@isaiahherard26gmail.onmicrosoft.com -WhatIf
.EXAMPLE
  ./scripts/Revoke-OktaLeaverAccess.ps1 -UserPrincipalName agrant@isaiahherard26gmail.onmicrosoft.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$OktaDomain = 'trial-3542283.okta.com',
    [string]$ClientId   = '0oa18pxx0mddOzlGN698',
    [string]$KeyId      = 'mfg-jml-2026-10',
    [string]$KeyPath    = 'C:\Lab\okta-jml-key\okta-jml-private.pem',
    [string]$AuditPath  = 'C:\Lab\meridian-jml-engine\output\logs\okta-containment.jsonl'
)
$ErrorActionPreference = 'Stop'

function ConvertTo-B64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Get-OktaAccessToken {
    $tokenUrl = "https://$OktaDomain/oauth2/v1/token"
    $now      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header   = @{ alg = 'RS256'; kid = $KeyId; typ = 'JWT' } | ConvertTo-Json -Compress
    $payload  = @{ iss = $ClientId; sub = $ClientId; aud = $tokenUrl; iat = $now; exp = $now + 300; jti = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
    $unsigned = (ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($header))) + '.' + (ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($payload)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem((Get-Content $KeyPath -Raw))
        $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
    $body = @{
        grant_type            = 'client_credentials'
        scope                 = 'okta.users.read okta.users.manage'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = "$unsigned.$(ConvertTo-B64Url $sig)"
    }
    (Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
}

$record = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); user = $UserPrincipalName; oktaUserId = $null; statusBefore = $null
    sessionsCleared = $false; deactivated = $false; result = 'Failed'; error = $null
    operator = "$env:USERDOMAIN\$env:USERNAME"; whatIf = [bool]$WhatIfPreference
}
$exitCode = 3

try {
    $token = Get-OktaAccessToken
    $h     = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
    $base  = "https://$OktaDomain/api/v1/users"

    $user = Invoke-RestMethod -Uri "$base/$([uri]::EscapeDataString($UserPrincipalName))" -Headers $h
    $record.oktaUserId = $user.id; $record.statusBefore = $user.status
    Write-Host "Found $($user.profile.login)  status=$($user.status)  id=$($user.id)"

    # 1. Containment first: end every Okta session and revoke every OAuth token issued to apps
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Clear all Okta sessions and OAuth tokens')) {
        Invoke-RestMethod -Method Delete -Uri "$base/$($user.id)/sessions?oauthTokens=true" -Headers $h | Out-Null
        $record.sessionsCleared = $true; Write-Host '  * sessions and OAuth tokens cleared'
    }
    # 2. Deactivate, which also triggers deprovisioning in every app Okta provisions to
    if ($user.status -ne 'DEPROVISIONED' -and $PSCmdlet.ShouldProcess($UserPrincipalName, 'Deactivate Okta user')) {
        Invoke-RestMethod -Method Post -Uri "$base/$($user.id)/lifecycle/deactivate?sendEmail=false" -Headers $h | Out-Null
        $record.deactivated = $true; Write-Host '  * user deactivated'
    }
    $record.result = if ($WhatIfPreference) { 'WhatIf' } else { 'Contained' }
    $exitCode = 0
}
catch {
    $record.error = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $record.error += " | $($_.ErrorDetails.Message)" }
    Write-Warning "Containment failed: $($record.error)"
}
finally {
    New-Item -ItemType Directory (Split-Path $AuditPath) -Force -WhatIf:$false | Out-Null
    ($record | ConvertTo-Json -Compress) | Add-Content $AuditPath -WhatIf:$false
    Write-Host "Audit: $AuditPath"
}
exit $exitCode
