#An adaption of an existing script with some additional error handling and the creation of a single CSV file. Parameterized. 
# The script is intended to use Azure Powershell  to connect to your Sentinel instances workspace and collect all the analytic rules and then parse them to extract the table


[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $tenantId,
    [Parameter()]
    [string]
    $subscriptionId,
    [Parameter()]
    [string]
    $resourceGroupName,
    [Parameter()]
    [string]
    $workspaceName,
    [Parameter()]
    [string]
    $CSVExportPath = "$($env:TEMP)"

)


#Install or update the required module

if(!(Get-Module -Name Az.SecurityInsights)){
    Import-Module -Name Az.SecurityInsights -ErrorVariable $modulefailed -ErrorAction SilentlyContinue
 
    if($modulefailed){
        Write-Host "Installing Az.SecurityInsights module..."
        Install-Module -Name Az.SecurityInsights -Force -AllowClobber
        Import-Module -Name Az.SecurityInsights -ErrorAction Stop
    }
}

#Authenticate to Azure
Connect-AzAccount 

#Set your context
if($tenantId){
    Set-AzContext -TenantId $tenantId
}else{
    Set-AzContext -SubscriptionId $subscriptionId
}

if(!(Get-AzContext)){
    Write-Host "No Azure context found. Please authenticate and set the context."
    exit
}

#Get all analytics rules
$rules = Get-AzSentinelAlertRule -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName

#Filter and export scheduled rules
$scheduledRules = $rules | Where-Object { $_.Kind -eq "Scheduled" }
$export = $scheduledRules | Select-Object `
    @{Name="RuleName"; Expression={$_.DisplayName}}, `
    @{Name="RuleId"; Expression={$_.Name}}, `
    @{Name="Kind"; Expression={$_.Kind}}, `
    @{Name="Enabled"; Expression={$_.Enabled}}, `
    @{Name="Severity"; Expression={$_.Severity}}, `
    @{Name="Query"; Expression={$_.Query}}, `
    @{Name="Tactics"; Expression={($_.Tactics -join ", ")}}
$export | Export-Csv -Path "$($CSVExportPath)\SentinelAnalyticsRules.csv" -NoTypeInformation


# Load the exported CSV
$importedrules = Import-Csv -Path "$($CSVExportPath)\SentinelAnalyticsRules.csv"
# Function to extract table names from KQL query
function Get-TableNamesFromKQL {
    param (
        [string]$query
    )
    $pattern = '(?m)^\s*([A-Za-z0-9_]+)\s*(\||$)'  # Matches table names at start of line before a pipe or end
    $ismatch = [regex]::Matches($query, $pattern)
    $tables = @()
    foreach ($match in $ismatch) {
        $table = $match.Groups[1].Value
        if ($table -notin @('let', 'where', 'project', 'summarize', 'join', 'extend', 'search', 'union', 'datatable', 'range')) {
            $tables += $table
        }
    }
    return ($tables | Sort-Object -Unique) -join ', '
}
# Process each rule and extract table names
$results = foreach ($rule in $importedrules) {
    $tables = Get-TableNamesFromKQL -query $rule.Query
    [PSCustomObject]@{
        RuleName = $rule.DisplayName
        RuleId   = $rule.Name
        Severity = $rule.Severity
        Enabled  = $rule.Enabled
        Tactics  = $rule.Tactics
        Query    = $rule.Query
        Tables   = $tables
    }
}
# Export the results
$results | Export-Csv -Path "$($CSVExportPath)\SentinelAnalyticsRules.csv" -NoTypeInformation
Write-Host "✅ Table extraction complete. Output saved to $($CSVExportPath)\SentinelAnalyticsRules.csv"

# Open the Table Mapping CSV from PS
Invoke-Item -Path "$($CSVExportPath)\SentinelAnalyticsRules.csv"
