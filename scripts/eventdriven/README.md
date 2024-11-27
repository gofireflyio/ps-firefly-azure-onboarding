# Firefly Azure Onboarding
Powershell script for eventdriven completion

Execute the following command in the Azure Cloud Shell to onboard the Azure subscription to the Firefly platform
```
$subscriptionId = "<subscription-id>"
$spDisplayName = "<app-registration-display-name>"
$scriptPath ="https://infralight-templates-public.s3.amazonaws.com/azure_onboarding_eventdriven.ps1"
$script = (New-Object System.Net.WebClient).DownloadString($scriptPath);
$scriptBlock = [Scriptblock]::Create($script);Invoke-Command -ScriptBlock $scriptBlock;
```
