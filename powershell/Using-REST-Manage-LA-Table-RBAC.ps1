# This short example uses the Az powershell module and PS7 to connect to the REST API and assign a custom role definitation to a user and table.
#https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access?tabs=portal#set-table-level-read-access

Connect-AzAccount 

$Headers=@{
  'authorization'="Bearer $((Get-AzAccessToken).Token)"
}

$api = "https://management.azure.com/batch?api-version=2020-06-01"

$subscription = "<yourSubIDgoeshere>"
$rg = "<yourResourceGroupNamegoeshere>"
$workspace = "<yourWorkspaceNamegoeshere>"
$tablename = "<yourTableNamegoeshere>"
$userId = "<yourUsersIDgoeshere>"
$roleId = "<yourRoleDefinitionIDgoeshere>"
$guid = "$(New-Guid)"
$guid2 = "$(New-Guid)"

$body = '
{
  "requests": [
      {
          "content": {
              "Id": "'+$($guid)+'",
              "Properties": {
                  "PrincipalId": "'+$($userId )+'",
                  "PrincipalType": "User",
                  "RoleDefinitionId": "'+$($roleId)+'",
                  "Scope": "/subscriptions/'+$($subscription)+'/resourceGroups/'+$($rg)+'/providers/Microsoft.OperationalInsights/workspaces/'+$($workspace)+'/Tables/'+$($tablename)+'",
                  "Condition": null,
                  "ConditionVersion": null
              }
          },
          "httpMethod": "PUT",
          "name": "'+$($guid2)+'",
          "requestHeaderDetails": {
              "commandName": "Microsoft_Azure_AD."
          },
          "url": "/subscriptions/'+$($subscription)+'/resourceGroups/'+$($rg)+'/providers/Microsoft.OperationalInsights/workspaces/'+$($workspace)+'/Tables/'+$($tablename)+'/providers/Microsoft.Authorization/roleAssignments/'+$($guid)+'?api-version=2020-04-01-preview"
      }
  ]
}'

$results = Invoke-RestMethod -uri $api -Method POST -Headers $Headers -Body $body -ContentType "application/json"

$results
