param(
    [int]$IntervalSeconds = 30,
    [int]$MaxAttempts = 0, # 0 = run until stopped
    [switch]$Verbose # Show full API response for debugging
)

# Ensure presence cmdlets are available (they live in Users.Actions in older SDKs, CloudCommunications in current SDKs)
function Ensure-GraphModules {
    param(
        [string]$PreferredCmd = 'Get-MgCommunicationPresence'
    )

    # Pick the highest version that exists for BOTH CloudCommunications and Authentication to avoid binding mismatches
    $cloudVersions = Get-Module -ListAvailable Microsoft.Graph.CloudCommunications | Select-Object -ExpandProperty Version -Unique
    $authVersions  = Get-Module -ListAvailable Microsoft.Graph.Authentication   | Select-Object -ExpandProperty Version -Unique
    $commonVersions = @($cloudVersions) | Where-Object { $authVersions -contains $_ } | Sort-Object {[version]$_} -Descending

    if (-not $commonVersions) {
        throw "No matching versions found for Microsoft.Graph.CloudCommunications and Microsoft.Graph.Authentication. Reinstall both: Install-Module Microsoft.Graph.Authentication,Microsoft.Graph.CloudCommunications -Scope CurrentUser -Force"
    }

    $versionToUse = $commonVersions[0]

    # Import all required modules with matching version
    Import-Module Microsoft.Graph.Authentication -RequiredVersion $versionToUse -Force -ErrorAction Stop
    Import-Module Microsoft.Graph.CloudCommunications -RequiredVersion $versionToUse -Force -ErrorAction Stop
    
    # Import Users module with same version (needed for Get-MgUser)
    $usersVersions = Get-Module -ListAvailable Microsoft.Graph.Users | Select-Object -ExpandProperty Version -Unique
    if ($usersVersions -contains $versionToUse) {
        Import-Module Microsoft.Graph.Users -RequiredVersion $versionToUse -Force -ErrorAction Stop
    }
    else {
        # Use latest Users version available
        $latestUsersVersion = ($usersVersions | Sort-Object {[version]$_} -Descending)[0]
        Import-Module Microsoft.Graph.Users -RequiredVersion $latestUsersVersion -Force -ErrorAction Stop
    }

    # After importing, return the available presence cmdlet name
    $presenceCmd = Get-Command Get-MgCommunicationPresence -ErrorAction SilentlyContinue
    if (-not $presenceCmd) { $presenceCmd = Get-Command Get-MgUserPresence -ErrorAction SilentlyContinue }
    if (-not $presenceCmd) {
        throw "Presence cmdlet still missing after importing v$versionToUse. Reinstall: Install-Module Microsoft.Graph.CloudCommunications -Scope CurrentUser -Force"
    }

    return $presenceCmd.Name
}

function Convert-PresenceToColor {
    param([string]$Availability)

    switch ($Availability) {
        'Available' { 'Green' ; break }
        'AvailableIdle' { 'Green' ; break }
        'Busy' { 'Red' ; break }
        'BusyIdle' { 'Red' ; break }
        'DoNotDisturb' { 'Red' ; break }
        'InACall' { 'Red' ; break }
        'InAConferenceCall' { 'Red' ; break }
        'Presenting' { 'Red' ; break }
        'Away' { 'Orange' ; break }
        'BeRightBack' { 'Orange' ; break }
        'OffWork' { 'Orange' ; break }
        'Offline' { 'Red' ; break }
        'PresenceUnknown' { 'Yellow' ; break } # Teams offline or not synced
        default { 'Yellow' } # Unknown state defaults to yellow (not available)
    }
}

function Ensure-GraphConnection {
    # Use script-scoped variable to track if we've already tried to connect
    if ($script:GraphConnectionAttempted) {
        $ctx = Get-MgContext
        if ($ctx) {
            return $script:UserPresenceId
        }
        # If context lost and we already tried, fail silently
        return $script:UserPresenceId
    }
    
    $ctx = Get-MgContext
    if (-not $ctx) {
        Write-Host 'Signing in to Microsoft Graph (delegated)...' -ForegroundColor Cyan
        # CloudCommunications.GetMgCommunicationPresence requires presence.read.all
        try {
            Connect-MgGraph -Scopes 'presence.read.all','User.Read' -ErrorAction Stop 2>$null | Out-Null
            $script:GraphConnectionAttempted = $true
        }
        catch {
            Write-Warning "Failed to connect to Microsoft Graph: $_"
            $script:GraphConnectionAttempted = $true
            return 'me'
        }
    }
    else {
        $script:GraphConnectionAttempted = $true
    }
    
    # Fetch current user ID via Graph API (avoids Get-MgUser versioning issues)
    try {
        $userInfo = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,displayName,userPrincipalName' -ErrorAction Stop
        $script:UserPresenceId = $userInfo.id
        if ($Verbose) {
            $ctx = Get-MgContext
            Write-Host "Logged in as: $($ctx.Account)" -ForegroundColor Green
            Write-Host "User ID: $($userInfo.id)" -ForegroundColor Cyan
        }
        return $userInfo.id
    }
    catch {
        Write-Warning "Could not fetch user ID: $($_.Exception.Message)"
        return 'me'  # Fallback
    }
}

$attempt = 0
$presenceCmdName = Ensure-GraphModules
$presenceIdentifier = Ensure-GraphConnection

if ($Verbose) {
    Write-Host "Polling Teams presence for current user..." -ForegroundColor Cyan
    Write-Host ""
}

while ($true) {
    if ($MaxAttempts -gt 0 -and $attempt -ge $MaxAttempts) { break }
    $attempt++

    try {
        # /me/presence uses delegated permissions; requires Presence.Read consent
        if ($presenceCmdName -eq 'Get-MgCommunicationPresence') {
            $presence = Get-MgCommunicationPresence -PresenceId $presenceIdentifier
        }
        else {
            # Get-MgUserPresence also supports 'me' identifier
            $presence = Get-MgUserPresence -UserId $presenceIdentifier
        }
        
        # Debug: show raw API response if -Verbose flag is set
        if ($Verbose) {
            Write-Host "DEBUG Raw API response:" -ForegroundColor Yellow
            $presence | Format-List | Out-Host
            
            # Also try alternative endpoint if available
            if ($presenceCmdName -eq 'Get-MgCommunicationPresence') {
                Write-Host "Trying alternative Get-MgUserPresence endpoint..." -ForegroundColor Yellow
                try {
                    $altPresence = Get-MgUserPresence -UserId $presenceIdentifier -ErrorAction Stop
                    Write-Host "Alternative endpoint result:" -ForegroundColor Yellow
                    $altPresence | Format-List | Out-Host
                }
                catch {
                    Write-Host "Alternative endpoint not available: $($_.Exception.Message)" -ForegroundColor Gray
                }
            }
            
            Write-Host "TIP: If Availability is PresenceUnknown, check that:" -ForegroundColor Cyan
            Write-Host "  1. Teams Desktop client is running (not Teams for Web)" -ForegroundColor Cyan
            Write-Host "  2. You are signed in with the SAME account in Teams as Graph" -ForegroundColor Cyan
            Write-Host "  3. Wait 1-2 minutes for presence to sync to Microsoft Graph" -ForegroundColor Cyan
            Write-Host "  4. Set your status in Teams to Available/Busy/etc" -ForegroundColor Cyan
            Write-Host "  5. Check Teams settings: Settings > Privacy > Activity-based presence" -ForegroundColor Cyan
            Write-Host ""
        }
        
        $color = Convert-PresenceToColor -Availability $presence.Availability

        [pscustomobject]@{
            Timestamp   = (Get-Date).ToString('s')
            Availability = $presence.Availability
            Activity     = $presence.Activity
            Color        = $color
        }
    }
    catch {
        Write-Warning "Failed to read presence: $($_.Exception.Message)"
    }

    # Only sleep after the first attempt (so we output immediately on first run)
    if ($attempt -gt 1) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}
