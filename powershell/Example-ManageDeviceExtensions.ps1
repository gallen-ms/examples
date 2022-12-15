<#This script performs two functions, function 1 is to extract a list of devices into a CSV for later use
 Function 2 is to import a CSV back into Azure AD to update the list of extensionAttributes for devices. 
 Run function 1 to get a list of devices, updated the extensionAttribute fields and then run function 2 to import the changed attributes to the devices. 
./Example-ManageDeviceExtensions.ps1 -createcsv -csvpath "C:\Temp" -csvfilename "MyDevices.csv"
 ./Example-ManageDeviceExtensions.ps1 -updatefrom -csvpath "C:\Temp" -csvfilename "MyDevices.csv"

 Created 15/12/2022 - By Gemma Allen
#>
[CmdletBinding()]
param (
        [Parameter(Mandatory = $false)]
        [switch]
        $createcsv,
        [Parameter(Mandatory = $false)]
        [switch]
        $updatefromcsv,
        [Parameter(Mandatory = $false)]
        [string]
        $csvpath="$($env:TEMP)",
        [Parameter(Mandatory = $false)]
        [string]
        $csvfilename="AADDeviceList$(Get-Date –Format yyyyMMddhhmm).csv"
        )

#Uses the Graph API module. 
Import-Module Microsoft.Graph.Identity.DirectoryManagement


If($createcsv){

    Connect-MgGraph -Scopes "Device.Read.All"
    #Directory.AccessAsUser.All needed to add open extensions to device.  https://learn.microsoft.com/en-us/graph/api/opentypeextension-post-opentypeextension?view=graph-rest-1.0&tabs=http#permissions
    #https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.identity.directorymanagement/get-mgdevice?view=graph-powershell-1.0
    $devices = Get-MgDevice | Select-Object -Property Id,DisplayName,OperatingSystem,OperatingSystemVersion,OnPremisesLastSyncDateTime @{Name="createdDateTime";Expression={$_.AdditionalProperties.extensionAttributes.createdDateTime}},@{Name="managementType";Expression={$_.AdditionalProperties.extensionAttributes.managementType}},
    @{Name="extensionAttribute1";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute1}},@{Name="extensionAttribute2";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute2}} ,
    @{Name="extensionAttribute3";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute3}} , @{Name="extensionAttribute4";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute4}} ,
    @{Name="extensionAttribute5";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute5}} ,@{Name="extensionAttribute6";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute6}} ,
    @{Name="extensionAttribute7";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute7}} ,@{Name="extensionAttribute8";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute8}} , 
    @{Name="extensionAttribute9";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute9}},@{Name="extensionAttribute10";Expression={$_.AdditionalProperties.extensionAttributes.extensionAttribute10}} 


    Add-Content -Path "$($csvpath)\$($csvfilename)" -Value ($devices | ConvertTo-Csv -Delimiter "," -UseQuotes AsNeeded)
}

if($updatefromcsv){

Connect-MgGraph -Scopes "Device.Read.All","Directory.ReadWrite.All","Directory.AccessAsUser.All"

$updateddevices = Get-Content -Path "$($csvpath)\$($csvfilename)" -Raw | ConvertFrom-Csv -Delimiter ","

    foreach ($device in $updateddevices){

        $device.Id
        $device.DisplayName
        $device.extensionAttribute2
    
        $scriptstring = "`$extensionattributes = @{`"extensionAttributes`"=@{"
        for($i = 1; $i -le 10; $i++){
            $scriptstring += "`"extensionAttribute$($i)`"=`"`$(`$device.extensionAttribute$($i))`";"
        }
        $scriptstring = "$($scriptstring.Substring(0,$scriptstring.Length-1))}}"
        $scriptblock = [scriptblock]::Create($scriptstring)
        . $scriptblock

        Update-MgDevice -DeviceId "$($device.id)" -BodyParameter $extensionattributeS

    }

}



<#
This script uses the GraphAPI powershell module. 
#Find-MgGraphCommand -Uri /devices/0d0df35a-3f91-45d2-9b67-1f72c34b41b2/extensions |
#Find-MgGraphCommand -command New-MgDeviceExtension | Select -First 1 -ExpandProperty Permissions
#https://learn.microsoft.com/en-us/graph/api/opentypeextension-post-opentypeextension?view=graph-rest-1.0&tabs=http
#>