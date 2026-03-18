param (
    [Parameter(Position = 0)][string]$action,   # action to execute
    [Parameter()][string]$newAccount,           # account name to create/use
    [Parameter()][switch]$cloudCommands,        # show executed commands
    [Parameter()][switch]$detailedMode,         # verbose output
    [Parameter()][switch]$whatif                # do not make changes
)

function Get-Help {
    Write-Host
    Write-Host "Action required. Options are 'create'."
    Write-Host "Example: ./harness-account.ps1 create -newAccount MyDemoAccount"
    Write-Host
}

function Send-Update {
    param(
        [string]$content,
        [int]$type = 1, # 0=debug,1=info,2=error,3=fatal
        [string]$run,
        [switch]$append,
        [switch]$errorSuppression,
        [switch]$outputSuppression,
        [switch]$whatIf
    )

    $params = @{}
    if ($whatIf) { $whatIfComment = "!WHATIF! " }

    if ($run) {
        $params['ForegroundColor'] = "Magenta"
        $start = "[$whatIfComment>]"
    }
    else {
        switch ($type) {
            0 { $params['ForegroundColor'] = "DarkBlue";  $start = "[.]" }
            1 { $params['ForegroundColor'] = "DarkGreen"; $start = "[-]" }
            2 { $params['ForegroundColor'] = "DarkRed";   $start = "[X]" }
            3 { $params['ForegroundColor'] = "DarkRed";   $start = "[XX] Exiting with error:" }
            default { $params['ForegroundColor'] = "Gray"; $start = "" }
        }
    }

    if ($script:outputLevel -eq 0) {
        $callStack = Get-PSCallStack
        if ($callStack.Count -gt 1) {
            $functionName = " <$($callStack[1].FunctionName)>"
        }
        else {
            $functionName = " <Called Directly>"
        }
        $start = "$start$functionName"
    }

    if ($run -and $script:showCommands) { $showcmd = " [ $run ] " }
    if ($script:currentLogEntry) {
        $screenOutput = "$content$showcmd"
    }
    else {
        $screenOutput = "   $start $content$showcmd"
    }

    if ($append) {
        $params['NoNewLine'] = $true
        $script:currentLogEntry = "$script:currentLogEntry $content$showcmd"
    }
    else {
        $script:currentLogEntry = $null
    }

    if ($type -ge $script:outputLevel) {
        Write-Host @params $screenOutput
    }

    if ($whatIf) { return }
    if ($type -eq 3) { throw $content }

    if ($run -and $errorSuppression -and $outputSuppression) { return Invoke-Expression $run 1>$null }
    if ($run -and $errorSuppression) { return Invoke-Expression $run 2>$null }
    if ($run -and $outputSuppression) { return Invoke-Expression $run 1>$null }
    if ($run) { return Invoke-Expression $run }
}

function Get-Prefs($scriptPath) {
    $PSDefaultParameterValues['Invoke-*:Verbose'] = $false
    $script:outputLevel = if ($detailedMode) { 0 } else { 1 }
    $script:showCommands = [bool]$cloudCommands
    $script:config = [PSCustomObject]@{}

    if ($scriptPath) {
        $script:configFile = "$($scriptPath).conf"
        Send-Update -type 0 -content "Config: $($script:configFile)"
    }
}

function Set-Prefs {
    param(
        [string]$k,
        $v
    )

    if ($null -ne $v -and $k) {
        $script:config | Add-Member -MemberType NoteProperty -Name $k -Value $v -Force
    }

    if ($script:configFile) {
        $script:config | ConvertTo-Json -Depth 20 | Out-File $script:configFile
    }
}

function Save-OutputVariables {
    foreach ($item in $script:config.psobject.Properties) {
        if (Test-Path "Env:$($item.Name)") {
            Remove-Item "Env:$($item.Name)"
        }
        New-Item -Path "Env:$($item.Name)" -Value $item.Value | Out-Null
    }
}

function Test-PreFlight {
    if (Get-Command gcloud -ErrorAction SilentlyContinue) {
        Send-Update -type 1 -content "gcloud commands available."
    }
    else {
        Send-Update -type 3 -content "gcloud commands not found. Install Google Cloud SDK first."
    }
}

function Get-AdminProjectId {
    $project = Send-Update -type 1 -content "Finding administration project" -run "gcloud projects list --filter='name:administration' --format=json" | ConvertFrom-Json

    if (-not $project) {
        Send-Update -type 3 -content "Failed to find the administration project."
    }

    if ($project -is [array]) {
        $project = $project[0]
    }

    Set-Prefs -k "AdminProjectId" -v $project.projectId
    return $project.projectId
}

function Get-HarnessAdminCredentials {
    if (-not $script:config.AdminProjectId) {
        Get-AdminProjectId | Out-Null
    }

    $harnessPortalToken = Send-Update -type 1 -content "Retrieving Harness portal token" -run "gcloud secrets versions access latest --secret='HarnessEventsAdmin' --project=$($script:config.AdminProjectId)"
    if (-not $harnessPortalToken) {
        Send-Update -type 3 -content "Failed to retrieve HarnessEventsAdmin secret."
    }

    $script:harnessAdminHeaders = @{
        "authorization" = "Bearer $harnessPortalToken"
    }
}

function Add-Account {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$accountName
    )

    if (-not $script:config.AdminProjectId) {
        Get-AdminProjectId | Out-Null
    }
    if (-not $script:harnessAdminHeaders) {
        Get-HarnessAdminCredentials
    }

    Send-Update -type 1 -content "Preparing account creation for: $accountName"

    $startDate = [System.DateTimeOffset]::new((Get-Date)).ToUnixTimeSeconds() * 1000
    $expirationDate = [System.DateTimeOffset]::new((Get-Date).AddDays(30)).ToUnixTimeSeconds() * 1000

    $harnessEventsEmail = Send-Update -type 1 -content "Retrieving Harness admin email" -run "gcloud secrets versions access latest --secret='HarnessEventsEmail' --project=$($script:config.AdminProjectId)"
    $harnessEventsPassword = Send-Update -type 1 -content "Retrieving Harness admin password" -run "gcloud secrets versions access latest --secret='HarnessEventsPassword' --project=$($script:config.AdminProjectId)"

    if (-not $harnessEventsEmail -or -not $harnessEventsPassword) {
        Send-Update -type 3 -content "Failed to retrieve Harness admin credentials from Secret Manager."
    }

    $credential = "$harnessEventsEmail`:$harnessEventsPassword"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($credential)
    $encodedText = [Convert]::ToBase64String($bytes)

    $bodyBearer = @{
        authorization = "Basic $encodedText"
    } | ConvertTo-Json

    $uriBearer = "https://app.harness.io/gateway/api/users/login"

    try {
        $response = Invoke-RestMethod -Method Post -Body $bodyBearer -Uri $uriBearer -ContentType 'application/json'
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq "Forbidden") {
            Send-Update -type 3 -content "Got 403 from Harness. Connect to VPN and try again."
        }
        Send-Update -type 3 -content "Failed to authenticate to Harness: $($_.Exception.Message)"
    }

    $accountList = $response.resource.accounts
    $managedAccountDetails = $accountList | Where-Object { $_.accountName -eq $accountName }

    if ($managedAccountDetails) {
        Set-Prefs -k "HarnessAccount" -v $managedAccountDetails.accountName
        Set-Prefs -k "HarnessAccountId" -v $managedAccountDetails.uuid
        Send-Update -type 1 -content "Account already exists. Using account id: $($managedAccountDetails.uuid)"

        if ($managedAccountDetails.status -ne "ACTIVE") {
            Send-Update -type 3 -content "Account exists but status is '$($managedAccountDetails.status)'."
        }
    }
    else {
        $uri = "https://admin.harness.io/api/accounts/v2"
        $body = @{
            accountName    = $accountName
            companyName    = $accountName
            adminUserEmail = $harnessEventsEmail
            accountStatus  = "ACTIVE"
            accountType    = "PAID"
            clusterType    = "PAID"
            clusterId      = "prod1"
            licenseUnits   = 100
            expiryTime     = $expirationDate
            nextGenEnabled = $true
        } | ConvertTo-Json

        if ($whatif) {
            Send-Update -type 1 -content "whatif prevented: creating account $accountName"
            return
        }

        Send-Update -type 1 -content "Creating account: $accountName"
        try {
            $accountObject = Invoke-RestMethod -Method Post -Body $body -Headers $script:harnessAdminHeaders -Uri $uri -ContentType 'application/json'
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq "Forbidden") {
                Send-Update -type 3 -content "Got 403 from admin.harness.io. Connect to VPN and try again."
            }
            Send-Update -type 3 -content "Failed to create account: $($_.Exception.Message)"
        }

        Set-Prefs -k "HarnessAccount" -v $accountObject.accountName
        Set-Prefs -k "HarnessAccountId" -v $accountObject.uuid
        Send-Update -type 1 -content "Created account id: $($accountObject.uuid)"
    }
}

function Create-HarnessPAT {
    if (-not $script:config.HarnessAccountId) {
        Send-Update -type 3 -content "HarnessAccountId is missing."
    }

    $harnessEventsEmail = Send-Update -type 1 -content "Retrieving Harness admin email" -run "gcloud secrets versions access latest --secret='HarnessEventsEmail' --project=$($script:config.AdminProjectId)"
    $harnessEventsPassword = Send-Update -type 1 -content "Retrieving Harness admin password" -run "gcloud secrets versions access latest --secret='HarnessEventsPassword' --project=$($script:config.AdminProjectId)"

    $credential = "$harnessEventsEmail`:$harnessEventsPassword"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($credential)
    $encodedText = [Convert]::ToBase64String($bytes)

    $bodyBearer = @{
        authorization = "Basic $encodedText"
    } | ConvertTo-Json

    $uriAccountBearer = "https://app.harness.io/gateway/api/users/login?accountId=$($script:config.HarnessAccountId)"
    Send-Update -type 1 -content "Retrieving bearer token for account: $($script:config.HarnessAccount)"

    try {
        $response = Invoke-RestMethod -Method Post -Body $bodyBearer -Uri $uriAccountBearer -ContentType 'application/json'
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq "Forbidden") {
            Send-Update -type 3 -content "Got 403 from Harness while fetching account bearer token. Connect to VPN and try again."
        }
        Send-Update -type 3 -content "Failed to retrieve account bearer token: $($_.Exception.Message)"
    }

    $bearerToken = $response.resource.token
    $parentIdentifier = $response.resource.uuid
    $startDate = [System.DateTimeOffset]::new((Get-Date)).ToUnixTimeSeconds() * 1000

    $headerApiKey = @{
        Authorization = "Bearer $bearerToken"
    }

    $tokenDeleteUri = "https://app.harness.io/gateway/ng/api/token/harnesseventstoken?routingId=$($script:config.HarnessAccountId)&accountIdentifier=$($script:config.HarnessAccountId)&apiKeyType=USER&parentIdentifier=$parentIdentifier&apiKeyIdentifier=harnesseventskey"

    try {
        Send-Update -type 0 -content "Deleting existing token if present"
        Invoke-RestMethod -Method Delete -Uri $tokenDeleteUri -Headers $headerApiKey | Out-Null
    }
    catch {
    }

    $bodyToken = @{
        identifier        = "harnesseventstoken"
        name              = "harnesseventstoken"
        description       = ""
        accountIdentifier = $script:config.HarnessAccountId
        apiKeyType        = "USER"
        apiKeyIdentifier  = "harnesseventskey"
        parentIdentifier  = $parentIdentifier
        expiry            = "-1"
        validTo           = 4102376400000
        validFrom         = $startDate
    } | ConvertTo-Json

    $headerToken = @{
        authorization = "Bearer $bearerToken"
    }

    $uriToken = "https://app.harness.io/ng/api/token?accountIdentifier=$($script:config.HarnessAccountId)"

    if ($whatif) {
        Send-Update -type 1 -content "whatif prevented: creating API token"
        return
    }

    Send-Update -type 1 -content "Creating API token"
    try {
        $responseToken = Invoke-RestMethod -Method Post -Body $bodyToken -Uri $uriToken -Headers $headerToken -ContentType 'application/json'
    }
    catch {
        Send-Update -type 3 -content "Failed to create API token: $($_.Exception.Message)"
    }

    Set-Prefs -k "HarnessPAT" -v $responseToken.data
}

function Test-Connectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$harnessToken
    )

    Send-Update -type 1 -content "Starting Harness connectivity check"

    $harnessSplit = $harnessToken.Split(".")
    if ($harnessSplit.Count -ne 4) {
        Send-Update -type 3 -content "Harness Platform token was malformed."
    }

    $harnessAccount = $harnessSplit[1]
    $testHarnessHeaders = @{
        "x-api-key" = $harnessToken
    }

    $uri = "https://app.harness.io/ng/api/accounts/$harnessAccount"
    try {
        $response = Invoke-RestMethod -Method Get -ContentType "application/json" -Uri $uri -Headers $testHarnessHeaders
    }
    catch {
        Send-Update -type 3 -content "Failed to connect to Harness API: $($_.Exception.Message)"
    }

    Set-Prefs -k "HarnessAccount" -v $response.data.companyName
    Set-Prefs -k "HarnessAccountId" -v $harnessAccount
    Set-Prefs -k "HarnessPAT" -v $harnessToken

    $fixEnv = $response.data.cluster.Replace("-", "")
    $correctEnv = $fixEnv.Substring(0,1).ToUpper() + $fixEnv.Substring(1)
    Set-Prefs -k "HarnessEnv" -v $correctEnv

    $script:HarnessHeaders = @{
        'x-api-key'    = $script:config.HarnessPAT
        'Content-Type' = 'application/json'
    }

    return $response
}

function Get-HarnessFFToken {
    if (-not $script:config.AdminProjectId) {
        Get-AdminProjectId | Out-Null
    }

    $HarnessFFToken = Send-Update -type 1 -content "Retrieving Harness FF token" -run "gcloud secrets versions access latest --secret='HarnessEventsFF' --project=$($script:config.AdminProjectId)"
    if (-not $HarnessFFToken) {
        Send-Update -type 3 -content "Failed to retrieve HarnessEventsFF secret."
    }

    Set-Prefs -k "HarnessFFToken" -v $HarnessFFToken
    $script:HarnessFFHeaders = @{
        'x-api-key'    = $script:config.HarnessFFToken
        'Content-Type' = 'application/json'
    }
}

function Get-FeatureFlagStatus {
    if (-not $script:config.HarnessEnv) {
        Send-Update -type 3 -content "HarnessEnv is missing."
    }
    if (-not $script:config.HarnessAccountId) {
        Send-Update -type 3 -content "HarnessAccountId is missing."
    }
    if (-not $script:HarnessFFHeaders) {
        Get-HarnessFFToken
    }

    $uri = "https://harness0.harness.io/cf/admin/features?accountIdentifier=l7B_kbSEQD2wjrM7PShm5w&projectIdentifier=FFOperations&orgIdentifier=PROD&environmentIdentifier=$($script:config.HarnessEnv)&targetIdentifierFilter=$($script:config.HarnessAccountId)&pageSize=10000"
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $script:HarnessFFHeaders

    $currentFlags = [pscustomobject]@{}
    foreach ($item in $response.features) {
        $value = $item.envProperties.variationMap |
            Where-Object { $_.targets.identifier -eq $script:config.HarnessAccountId } |
            Select-Object -ExpandProperty variation
        $currentFlags | Add-Member -MemberType NoteProperty -Name $item.identifier -Value $value -Force
    }

    return $currentFlags
}

function Update-FeatureFlag {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$flag,
        [Parameter(Mandatory = $true)][string]$value
    )

    if (-not $script:HarnessFFHeaders) {
        Get-HarnessFFToken
    }

    $body = @{
        instructions = @(
            @{
                kind       = "addTargetToFlagsVariationTargetMap"
                parameters = @{
                    features = @(
                        @{
                            identifier = $flag
                            variation  = $value
                        }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    $uri = "https://harness0.harness.io/cf/admin/targets/$($script:config.HarnessAccountId)?accountIdentifier=l7B_kbSEQD2wjrM7PShm5w&orgIdentifier=PROD&projectIdentifier=FFOperations&environmentIdentifier=$($script:config.HarnessEnv)"

    if ($whatif) {
        Send-Update -type 1 -content "whatif prevented: updating feature flag $flag -> $value"
        return $true
    }

    Send-Update -type 1 -content "Updating feature flag $flag with value '$value'"

    try {
        Invoke-RestMethod -Method Patch -ContentType "application/json" -Uri $uri -Headers $script:HarnessFFHeaders -Body $body | Out-Null
    }
    catch {
        $errorText = $_.Exception.Message
        Send-Update -type 2 -content "Feature flag update failed for ${flag}: $errorText"
        return $false
    }

    Send-Update -type 1 -content "Feature flag $flag variation set: $value"
    return $true
}

function Set-FeatureFlags {
    if (-not (Test-Path "./harnesseventsdata/config/featureflagsstart.json")) {
        Send-Update -type 3 -content "featureflagsstart.json not found at ./harnesseventsdata/config/featureflagsstart.json"
    }

    $featureFlagsStart = Get-Content -Path ./harnesseventsdata/config/featureflagsstart.json | ConvertFrom-Json
    $currentFlags = Get-FeatureFlagStatus

    $flagsNeeded = Compare-Object @($featureFlagsStart.PSObject.Properties) @($currentFlags.PSObject.Properties) -Property Name, Value |
        Where-Object { $_.SideIndicator -eq "<=" }

    Send-Update -type 1 -content "$($flagsNeeded.Count) feature flag(s) to update"

    foreach ($flag in $flagsNeeded) {
        $ffSuccess = Update-FeatureFlag -flag $flag.Name -value $flag.Value
        if (-not $ffSuccess) {
            Send-Update -type 2 -content "Removing failed feature flag $($flag.Name) from desired state."
            $featureFlagsStart.PSObject.Properties.Remove($flag.Name)
        }
    }

    do {
        Start-Sleep -Seconds 2
        $currentFlags = Get-FeatureFlagStatus
        $flagsNeeded = Compare-Object @($featureFlagsStart.PSObject.Properties) @($currentFlags.PSObject.Properties) -Property Name, Value |
            Where-Object { $_.SideIndicator -eq "<=" }
        Send-Update -type 1 -content "Waiting for $($flagsNeeded.Count) feature flag(s)..."
    } until (-not $flagsNeeded)
}

function Invoke-Create {
    $ErrorActionPreference = "Stop"

    if (-not $newAccount) {
        Send-Update -type 3 -content "You must provide -newAccount <AccountName>"
    }

    Get-AdminProjectId | Out-Null
    Get-HarnessAdminCredentials
    Add-Account -accountName $newAccount
    Create-HarnessPAT
    Test-Connectivity -harnessToken $script:config.HarnessPAT | Out-Null
    Get-HarnessFFToken
    Set-FeatureFlags
    Save-OutputVariables

    Send-Update -type 1 -content "Done."
    Send-Update -type 1 -content "HarnessAccount   : $($script:config.HarnessAccount)"
    Send-Update -type 1 -content "HarnessAccountId : $($script:config.HarnessAccountId)"
    Send-Update -type 1 -content "HarnessEnv       : $($script:config.HarnessEnv)"
    Send-Update -type 1 -content "HarnessPAT saved to config and environment."
}

# Main
Test-PreFlight
Get-Prefs($MyInvocation.MyCommand.Source)

switch ($action) {
    "create" { Invoke-Create }
    default  { Get-Help }
}
