#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups

<#
.SYNOPSIS
    Retrieves users, group memberships, and Azure RBAC role assignments (group and direct).
.DESCRIPTION
    Connects to Microsoft Graph to retrieve users and their group memberships.
    Then connects to Azure (Az module) to query RBAC role assignments for:
      - Each group (inherited access)
      - Each user directly (direct access)
    Outputs three CSVs:
      1. Group membership (GroupDisplayName, GroupId, MemberDisplayName, MemberUPN)
      2. Group Azure access (GroupDisplayName, GroupId, RoleName, Scope, ResourceName, etc.)
      3. User direct Azure access (UserDisplayName, UserUPN, RoleName, Scope, ResourceName, etc.)
.PARAMETER OutputPath
    Directory path for all output CSVs. Defaults to the script directory.
    Three files are created: UserGroupMemberships.csv, GroupAzureAccess.csv, UserDirectAzureAccess.csv.
.PARAMETER Filter
    Optional OData filter for the user query (e.g. "accountEnabled eq true").
.PARAMETER SubscriptionId
    Optional. Specific Azure subscription ID to scope the role assignment query.
    If omitted, all accessible subscriptions are queried.
.EXAMPLE
    .\Get-UserGroupMemberships.ps1
.EXAMPLE
    .\Get-UserGroupMemberships.ps1 -OutputPath "C:\Reports\memberships.csv" -Filter "accountEnabled eq true"
.EXAMPLE
    .\Get-UserGroupMemberships.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
#>

<#Pre-Req 
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups -Scope CurrentUser
Install-Module Az.Accounts, Az.Resources -Scope CurrentUser
#>

[CmdletBinding()]
param(
    [string]$OutputPath = $PSScriptRoot,
    [string]$Filter,
    [string]$TenantId,
    [string]$SubscriptionId
)

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Derive CSV paths from OutputPath directory
$MembershipCsvPath    = Join-Path $OutputPath "UserGroupMemberships.csv"
$AzureAccessCsvPath   = Join-Path $OutputPath "GroupAzureAccess.csv"
$UserDirectCsvPath    = Join-Path $OutputPath "UserDirectAzureAccess.csv"

# Disconnect any existing sessions and prompt for fresh auth
Write-Host "Connecting to Microsoft Graph..."
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes "User.Read.All", "GroupMember.Read.All", "Group.Read.All"

# Build user query parameters
$userParams = @{
    All            = $true
    Property       = "Id", "DisplayName", "UserPrincipalName"
    ConsistencyLevel = "eventual"
    CountVariable  = "userCount"
}
if ($Filter) {
    $userParams["Filter"] = $Filter
}

Write-Host "Retrieving users..."
$users = Get-MgUser @userParams
Write-Host "Found $($users.Count) users."

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$i = 0

foreach ($user in $users) {
    $i++
    Write-Progress -Activity "Processing users" -Status "$i of $($users.Count): $($user.DisplayName)" -PercentComplete (($i / $users.Count) * 100)

    try {
        $groups = Get-MgUserMemberOf -UserId $user.Id -All | Where-Object {
            $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.group'
        }

        foreach ($group in $groups) {
            $results.Add([PSCustomObject]@{
                GroupDisplayName   = $group.AdditionalProperties.displayName
                GroupId            = $group.Id
                MemberDisplayName  = $user.DisplayName
                MemberUPN          = $user.UserPrincipalName
            })
        }
    }
    catch {
        Write-Warning "Failed to get memberships for $($user.UserPrincipalName): $_"
    }
}

Write-Progress -Activity "Processing users" -Completed

if ($results.Count -gt 0) {
    $results | Sort-Object GroupDisplayName, MemberDisplayName | Export-Csv -Path $MembershipCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($results.Count) membership records to $MembershipCsvPath"
}
else {
    Write-Warning "No group memberships found."
}

# --- Azure RBAC Role Assignment Lookup ---

# Disconnect any existing Azure session and prompt for fresh auth
Write-Host "Connecting to Azure..."
Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
$connectParams = @{ ErrorAction = 'Stop' }
if ($TenantId) { $connectParams['TenantId'] = $TenantId }
Connect-AzAccount @connectParams

# Show current context for debugging
$azContext = Get-AzContext
Write-Host "Azure context: Account=$($azContext.Account), Tenant=$($azContext.Tenant.Id), Subscription=$($azContext.Subscription.Name)"

# Helper function to parse resource info from a scope string
function Get-ResourceInfoFromScope {
    param([string]$Scope, [string]$SubName)
    $resourceName = switch -Regex ($Scope) {
        '/providers/[^/]+/[^/]+$' { ($Scope -split '/')[-1] }
        '/resourceGroups/[^/]+$'  { ($Scope -split '/')[-1] }
        '/subscriptions/[^/]+$'   { $SubName }
        default                   { $Scope }
    }
    $resourceType = if ($Scope -match '/providers/(.+)/[^/]+$') { $Matches[1] } else { 'Subscription/ResourceGroup' }
    return @{ Name = $resourceName; Type = $resourceType }
}

# Get unique groups from the membership results
$uniqueGroups = $results | Select-Object GroupDisplayName, GroupId -Unique
Write-Host "Querying Azure RBAC role assignments for $($uniqueGroups.Count) groups and $($users.Count) users..."

# Determine which subscriptions to query
if ($SubscriptionId) {
    $subscriptions = @(Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop)
}
else {
    Write-Host "Enumerating subscriptions..."
    $subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
}

if ($subscriptions.Count -eq 0) {
    Write-Warning "No accessible subscriptions found. Check that your account has Reader or higher access on at least one subscription."
    Write-Warning "You can try: Connect-AzAccount -TenantId '<your-tenant-id>' to target a specific tenant."
    return
}

Write-Host "Scanning $($subscriptions.Count) accessible subscription(s)..."

$azureAccess = [System.Collections.Generic.List[PSCustomObject]]::new()
$userDirectAccess = [System.Collections.Generic.List[PSCustomObject]]::new()
$s = 0

foreach ($sub in $subscriptions) {
    $s++
    Write-Progress -Activity "Scanning subscriptions" -Status "$s of $($subscriptions.Count): $($sub.Name)" -PercentComplete (($s / $subscriptions.Count) * 100)

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        # --- Group role assignments ---
        foreach ($group in $uniqueGroups) {
            try {
                $assignments = Get-AzRoleAssignment -ObjectId $group.GroupId -ErrorAction SilentlyContinue

                foreach ($assignment in $assignments) {
                    $resInfo = Get-ResourceInfoFromScope -Scope $assignment.Scope -SubName $sub.Name

                    $azureAccess.Add([PSCustomObject]@{
                        GroupDisplayName = $group.GroupDisplayName
                        GroupId          = $group.GroupId
                        RoleName         = $assignment.RoleDefinitionName
                        Scope            = $assignment.Scope
                        ResourceName     = $resInfo.Name
                        ResourceType     = $resInfo.Type
                        SubscriptionName = $sub.Name
                        SubscriptionId   = $sub.Id
                    })
                }
            }
            catch {
                Write-Warning "Failed to get role assignments for group '$($group.GroupDisplayName)' in subscription '$($sub.Name)': $_"
            }
        }

        # --- Direct user role assignments ---
        $u = 0
        foreach ($user in $users) {
            $u++
            if ($s -eq 1) {
                # Only show user-level progress on first subscription to avoid noise
                Write-Progress -Id 1 -Activity "Checking direct user assignments" -Status "$u of $($users.Count): $($user.DisplayName)" -PercentComplete (($u / $users.Count) * 100)
            }

            try {
                $userAssignments = Get-AzRoleAssignment -ObjectId $user.Id -ErrorAction SilentlyContinue |
                    Where-Object { $_.ObjectType -eq 'User' }

                foreach ($assignment in $userAssignments) {
                    $resInfo = Get-ResourceInfoFromScope -Scope $assignment.Scope -SubName $sub.Name

                    $userDirectAccess.Add([PSCustomObject]@{
                        UserDisplayName  = $user.DisplayName
                        UserUPN          = $user.UserPrincipalName
                        UserId           = $user.Id
                        RoleName         = $assignment.RoleDefinitionName
                        Scope            = $assignment.Scope
                        ResourceName     = $resInfo.Name
                        ResourceType     = $resInfo.Type
                        SubscriptionName = $sub.Name
                        SubscriptionId   = $sub.Id
                    })
                }
            }
            catch {
                Write-Warning "Failed to get direct role assignments for '$($user.UserPrincipalName)' in subscription '$($sub.Name)': $_"
            }
        }
        Write-Progress -Id 1 -Activity "Checking direct user assignments" -Completed
    }
    catch {
        Write-Warning "Failed to set context for subscription '$($sub.Name)': $_"
    }
}

Write-Progress -Activity "Scanning subscriptions" -Completed

# Export group Azure access
if ($azureAccess.Count -gt 0) {
    $azureAccess | Sort-Object GroupDisplayName, SubscriptionName, RoleName | Export-Csv -Path $AzureAccessCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($azureAccess.Count) group Azure RBAC records to $AzureAccessCsvPath"
}
else {
    Write-Warning "No Azure RBAC role assignments found for any groups."
}

# Export direct user Azure access
if ($userDirectAccess.Count -gt 0) {
    $userDirectAccess | Sort-Object UserDisplayName, SubscriptionName, RoleName | Export-Csv -Path $UserDirectCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($userDirectAccess.Count) direct user Azure RBAC records to $UserDirectCsvPath"
}
else {
    Write-Warning "No direct user Azure RBAC role assignments found."
}
