$ErrorActionPreference = "Stop"

function Set-AzureContext {
    param (
        [string]$subscriptionId
    )
    if ($subscriptionId -and $subscriptionId.Length -gt 0) {
        Write-Host "Setting context by subscription id: $subscriptionId"
        return Set-AzContext -Subscription $subscriptionId
    }
    Write-Host "Setting the default context"
    return (Get-AzContext)
}

function Set-EventDrivenParameter {
    param (
        $isEventDriven
    )
    if ($null -eq $isEventDriven) {
        Write-Host "Working on an Event Driven integration as default..."
        return $true
    }
    if ($isEventDriven -is [bool] -and $isEventDriven) {
        Write-Host "Working on an Event Driven integration..."
        return $true
    }
    Write-Host "Working on non Event Driven integration..."
    return $false
}

function Set-ADAppPermsissionParameter {
    param (
        $enableActiveDirectory
    )
    if ($null -eq $enableActiveDirectory) {
        Write-Host "Working on an Active Directory Enabled integration as default..."
        return $true
    }
    if ($enableActiveDirectory -is [bool] -and $enableActiveDirectory) {
        Write-Host "Working on an Active Directory Enabled integration..."
        return $true
    }
    Write-Host "Working on an Active Directory Disabled integration..."
    return $false
}

function Get-BuiltInRolePermisions {
    param (
        $enableCostOptimization,
        $enableSecurityCenterResources
    )

    $roles = @('Reader')
    if ($null -eq $enableActiveDirectory) {
        $roles += 'Billing Reader'
    }
    if ($enableCostOptimization -is [bool] -and $enableCostOptimization) {
        $roles += 'Billing Reader'
    }
    if ($null -eq $enableSecurityCenterResources) {
        $roles += 'Security Reader'
    }
    if ($enableSecurityCenterResources -is [bool] -and $enableSecurityCenterResources) {
        $roles += 'Security Reader'
    }

    return $roles
}

function Set-AppNameParameter {
    param (
        [string]$appName,
        [string]$subscriptionId
    )
    if ($appName -and $appName.Length -gt 0) {
        Write-Host "Received AppName as parameter: $appName"
        return $appName
    }
    return "firefly-" + $subscriptionId
}

function Set-ExistingServicePrincipaCreds {
    param (
        [string][ValidateNotNullOrEmpty()]$appName
    )

    Write-Host "Start setting credentials for existing application $appName..."

    $creds = [Microsoft.Azure.PowerShell.Cmdlets.Resources.MSGraph.Models.ApiV10.MicrosoftGraphPasswordCredential]@{
        StartDateTime = Get-Date
        EndDateTime = (Get-Date).AddYears(2)
    }
    $sp = New-AzADAppCredential -ApplicationId $sp.AppId -PasswordCredentials $creds
    if ($sp -eq $null) {
        throw "Error in setting service principal $appName"
    }

    Write-Host "Done setting credentials for existing application $appName..."

    return $sp
}

function New-ServicePrincipal {
    param (
        [string][ValidateNotNullOrEmpty()]$appName
    )
    $creds = [Microsoft.Azure.PowerShell.Cmdlets.Resources.MSGraph.Models.ApiV10.MicrosoftGraphPasswordCredential]@{
        StartDateTime = Get-Date
        EndDateTime = (Get-Date).AddYears(2)
    }
    Write-Host "Start creating service principal $appName..."

    $sp = New-AzADServicePrincipal -DisplayName $appName -PasswordCredentials $creds
    if ($sp -eq $null) {
        throw "Error in creating service principal"
    }

    Write-Host "Done creating service principal $appName ..."

    return $sp
}

function Add-AppPermissions {
    param (
        [string][ValidateNotNullOrEmpty()]$appName
    )
    $app = Get-AzADApplication -DisplayName $appName
    if ($app.Count -ne 1) {
        throw "Could not find exactly one application with the name $appName, but found $( $app.Count ). Aborting now."
    }

    $apiId = "00000003-0000-0000-c000-000000000000" # Microsoft Graph API ID
    $permissionId = "06da0dbc-49e2-44d2-8312-53f166ab848a" # Directory.Read.All permission ID

    #check whether the app already has the required permissions
    $permissions = Get-AzADAppPermission -ObjectId $app.Id
    $existingPermissions = $permissions | Where-Object {
        $_.ApiId -eq $apiId -and $_.Id -eq $permissionId
    }
    if ($existingPermissions) {
        Write-Host "App $appName already has the permissions, skipping adding..."
        return
    }

    Write-Host "Start adding permissions to $appName registration application..."

    Add-AzADAppPermission -ApiId $apiId -PermissionId $permissionId -ObjectId $app.Id -Type Scope

    # Verify the application permissioms
    $permissions = Get-AzADAppPermission -ObjectId $app.Id
    $requiredPermission = $permissions | Where-Object {
        $_.ApiId -eq $apiId -and $_.Id -eq $permissionId
    }
    if (!$requiredPermission) {
        throw "Failed to find app permissions, aborting now."
    }

    Write-Host "Done verifying adding permissions to $appName registration application..."
}

function New-AppRoleAssignments {
    param (
        [string][ValidateNotNullOrEmpty()]$spId,
        [string][ValidateNotNullOrEmpty()]$subscriptionId,
        $enableCostOptimization,
        $enableSecurityCenterResources
    )
    Write-Host "Start assigning roles to registration application..."
    $roles = Get-BuiltInRolePermisions -enableCostOptimization $enableCostOptimization -enableSecurityCenterResources $enableSecurityCenterResources
    foreach ($role in $roles) {
        $existing = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $role
        if ($existing) {
            Write-Host "Role assignment for $role already exist, skipping creation..."
            continue
        }

        Write-Host "Start assigning $role role to registration application..."
        New-AzRoleAssignment -PrincipalId $spId -RoleDefinitionName $role
        # Verify the role assignment creation
        $ra = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $role
        if (!$ra -Or $ra.ObjectType -eq "Unknown") {
            throw "Failed to find created role assignment: $role, aborting now."
        }
        Write-Host "Done verifying assigning $role role to registration application..."
    }

    $ffRoleName = 'Firefly-'+$subscriptionId
    New-FireflyCustomRole -ffRoleName $ffRoleName -subscriptionId $subscriptionId
    $existing = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $ffRoleName
    if ($existing) {
        if ($existing.ObjectType -eq "Unknown") {
            throw "Existing role assignment for $ffRoleName is invalid, aborting now."
        }
        Write-Host "Role assignment for $ffRoleName already exist, skipping creation..."
        return
    }
    New-AzRoleAssignment -PrincipalId $spId -RoleDefinitionName $ffRoleName -Condition "(
        (
         !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'} AND NOT
       SubOperationMatches{'Blob.List'})
        )
        OR
        (
         @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike '*state'
        )
       )"
    # Verify the role assignment creation
    $ra = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $ffRoleName
    if (!$ra -Or $ra.ObjectType -eq "Unknown") {
        throw "Failed to find created role assignment: $ffRoleName, aborting now."
    }

    Write-Host "Done verifying adding role assignments $ffRoleName to $appName registration application..."
}

function New-FireflyCustomRole {
    param (
        [string][ValidateNotNullOrEmpty()]$ffRoleName,
        [string][ValidateNotNullOrEmpty()]$subscriptionId
    )
    $existing = Get-AzRoleDefinition -Name $ffRoleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Firefly custom role $ffRoleName already exist, skipping creation..."
        return
    }

    Write-Host "Start Creating $ffRoleName custom role definition..."
    $role = [Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition]::new()
    $role.Name = $ffRoleName
    $role.Description = 'Firefly custom role definition.'
    $role.IsCustom = $true
    $role.Actions =  "Microsoft.Storage/storageAccounts/listkeys/action",
                    "Microsoft.DocumentDB/databaseAccounts/listConnectionStrings/action",
                    "Microsoft.DocumentDB/databaseAccounts/listKeys/action",
                    "Microsoft.DocumentDB/databaseAccounts/readonlykeys/action",
                    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
                    "Microsoft.Web/sites/config/list/Action",
                    "Microsoft.Cache/redis/listKeys/action"
    $role.DataActions = "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"
    $role.AssignableScopes = '/subscriptions/'+$subscriptionId
    New-AzRoleDefinition -Role $role

    # Verify the role definition creation
    Read-FireflyCustomRoleExists -ffRoleName $ffRoleName
}

function Read-FireflyCustomRoleExists{
    param (
        [string][ValidateNotNullOrEmpty()]$ffRoleName
    )
    $maxRetries = 3
    $retryInterval = 5
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        try {
            # Verify the role definition creation
            $ffRole = Get-AzRoleDefinition -Name $ffRoleName
            if ($ffRole) {
                break
            }else{
                throw "Failed to find custom role: $ffRoleName, aborting now."
            }
        } catch {
            Write-Host "Attempt $retryCount failed: $_"
            $retryCount++

            if ($retryCount -eq $maxRetries) {
                throw "Role definition $ffRoleName does not exist yet, aborting now. Please contact firefly support"
            }

            Start-Sleep -Seconds $retryInterval
        }
    }
}

function Get-DomainName {
    $domain = Get-AzureADDomain | Select-Object -First 1 -ExpandProperty Name
    return $domain
}

function Set-EndpointParameter {
    param (
        [string]$endpoint
    )
    if ($endpoint -and $endpoint.Length -gt 0) {
        Write-Host "Received endpoint as parameter: $endpoint"
        return $endpoint
    }
    return "https://azureevents.gofirefly.io"
}

function New-ResourceGroup {
    param (
        [string][ValidateNotNullOrEmpty()]$name,
        [string][ValidateNotNullOrEmpty()]$location
    )

    Write-Host "Start creating $name resource group..."

    $existingResourceGroup = Get-AzResourceGroup -Name $name -ErrorAction SilentlyContinue

    if (-Not $existingResourceGroup) {
        $rg = New-AzResourceGroup -Name $name -Location $location
        if (!$rg) {
            throw "Failed creating $name resource group, aborting now."
        }
        Write-Host "Done creating $name resource group..."
    }
    else {
        Write-Host "Resource group $name already exists, skipping creation.."
    }
}

function New-FireflyStorageAccount {
    param (
        [string][ValidateNotNullOrEmpty()]$subscriptionId,
        [string][ValidateNotNullOrEmpty()]$resourceGroup,
        [string][ValidateNotNullOrEmpty()]$location
    )

    # Generate storage account name
    $name = ("firefly" + $subscriptionId -replace '-', '').Substring(0,[Math]::Min(("firefly-" + $subscriptionId -replace '-', '').Length, 23))
    Write-Host "Start creating $name storage account..."

    # Check if the storage account already exists
    $existingStorageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $name -ErrorAction SilentlyContinue
    if (-Not $existingStorageAccount) {
        # Create new storage account
        Register-AzResourceProvider -ProviderNamespace Microsoft.Storage
        $sa = New-AzStorageAccount -ResourceGroupName $resourceGroup -Name $name -Location $location -SkuName Standard_LRS
        if (!$sa) {
            throw "Error creating $name storage account in $resourceGroup resource group, aborting now."
        }
    } else {
        # Storage account already exists
        Write-Host "Storage account $name already exists, skipping creation..."
    }

    # Verify the storage account creation
    Read-FireflyStorageAccountIsReady -resourceGroup $resourceGroup -storageName $name

    $storageAccountId = (Get-AzStorageAccount -ResourceGroupName $resourceGroup -AccountName $name).Id

    Write-Host "Done creating $name storage account..."

    # Return the trimmed storage account ID
    return $storageAccountId.Trim()
}

function Read-FireflyStorageAccountIsReady{
    param (
        [string][ValidateNotNullOrEmpty()]$resourceGroup,
        [string][ValidateNotNullOrEmpty()]$storageName
    )
    $maxRetries = 3
    $retryInterval = 2
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        try {
            # Verify the storage account creation
            $storageState = (Get-AzStorageAccount -ResourceGroupName $resourceGroup -AccountName $storageName).ProvisioningState
            if ($storageState -eq "Succeeded") {
                Write-Host "Firefly storage account is ready."
                break
            } else {
                throw "Firefly storage account is not ready."
            }
        } catch {
            Write-Host "Attempt $retryCount failed: $_"
            $retryCount++

            if ($retryCount -eq $maxRetries) {
                throw "Storage account $storageName is not ready, aborting now. Please contact firefly support"
            }

            Start-Sleep -Seconds $retryInterval
        }
    }
}

function New-StorageAccountRoleAssignments {
    param (
        [string][ValidateNotNullOrEmpty()]$spId,
        [string][ValidateNotNullOrEmpty()]$storageId,
        [string][ValidateNotNullOrEmpty()]$subscriptionId,
        [string][ValidateNotNullOrEmpty()]$resourceGroup
    )
    $id = $storageId.Trim()

    $existing = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName "Storage Blob Data Reader" -Scope $id
    if ($existing) {
        if ($existing.ObjectType -ne "Unknown") {
        Write-Host "Role assignment for Storage Blob Data Reader on $id already exist, skipping creation..."
        return
        } else {
            throw "Invalid role assignment for storage account, aborting now."
        }
    }

    Write-Host "Start assigning Storage Blob Data Reader on $id to registration application..."
    New-AzRoleAssignment -ObjectID $spId -RoleDefinitionName "Storage Blob Data Reader" -Scope $id

    # Verify success of Assign Blob Reader role to registration app
    $blobAssignmnet = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName "Storage Blob Data Reader" -Scope $id
    if (!$blobAssignmnet -Or $blobAssignment.ObjectType -eq "Unknown") {
        throw "Failed to find created role assignment: Storage Blob Data Reader, aborting now."
    }
    Write-Host "Done assigning role Storage Blob Data Reader..."
}

function CreateEventGridSubscription {
    param (
        [string][ValidateNotNullOrEmpty()]$endpoint,
        [string][ValidateNotNullOrEmpty()]$storageId
    )
    $eventSubscriptionName = 'fireflyevents'
    $id = $storageId.Trim()

    $existing = Get-AzEventGridSubscription -EventSubscriptionName $eventSubscriptionName -ResourceId $id -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Eventgrid subscription $eventSubscriptionName already exist, skipping creation..."
        return
    }

    Write-Host "Start event grid setup..."

    # Register and get Event Grid resource provider
    Register-AzResourceProvider -ProviderNamespace Microsoft.EventGrid
    $rp = Get-AzResourceProvider -ProviderNamespace Microsoft.EventGrid
    if (!$rp) {
        throw "Failed getting Event Grid resource provider, aborting now."
    }

    # Create new Event Grid subscription
    New-AzEventGridSubscription -EventSubscriptionName $eventSubscriptionName -Endpoint $endpoint -ResourceId $id  -IncludedEventType 'Microsoft.Storage.BlobCreated'

    # Verify success creation of the Event Grid subscription
    $eventSubscription = Get-AzEventGridSubscription -EventSubscriptionName $eventSubscriptionName -ResourceId $id
    if (!$eventSubscription) {
        throw "Failed to find created eventgrid subscription on storage: $id."
    }

    Write-Host "Done event grid setup.."
}

function CreateDiagnosticSettings {
    param (
        [string][ValidateNotNullOrEmpty()]$storageId
    )
    $diagnosticSettingsName = 'firefly'
    $id = $storageId.Trim()

    $existing = Get-AzSubscriptionDiagnosticSetting -Name $diagnosticSettingsName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Diagnostic settings $diagnosticSettingsName already exist, skipping creation..."
        return
    }

    Write-Host "Start creating diagnostic settings..."

    # Create log settings
    $log = @()
    $log += New-AzDiagnosticSettingSubscriptionLogSettingsObject -Category Administrative -Enabled $true

    # Create new subscription diagnostic setting with the log settings
    New-AzSubscriptionDiagnosticSetting -Name $diagnosticSettingsName -StorageAccountId $id -Log $log

    # Verify success creation of the Diagnostic Settings
    $ds = Get-AzSubscriptionDiagnosticSetting -Name $diagnosticSettingsName
    if (!$ds) {
        throw "Failed to find diagnostic settings $diagnosticSettingsName, aborting now"
    }

    Write-Host "Done creating diagnostic settings..."
}

function New-EventDrivenResources {
    param (
        [string][ValidateNotNullOrEmpty()]$endpoint,
        [string][ValidateNotNullOrEmpty()]$subscriptionId,
        [string][ValidateNotNullOrEmpty()]$spId
    )
    Write-Host "Start creating Event Driven resources..."

    $location = "eastus"
    $resourceGroup = "firefly"

    New-ResourceGroup -name $resourceGroup -location $location

    $storageId = New-FireflyStorageAccount -subscriptionId $subscriptionId -resourceGroup $resourceGroup -location $location

    New-StorageAccountRoleAssignments -spId $spId -storageId $storageId -subscriptionId $subscriptionId -resourceGroup $resourceGroup

    CreateEventGridSubscription -endpoint $endpoint -storageId $storageId

    CreateDiagnosticSettings -storageId $storageId

    Write-Host "Done creating event driven resources..."
}

function Output-IDsAndSecret {
    param (
        [string][ValidateNotNullOrEmpty()]$tenantId,
        [string][ValidateNotNullOrEmpty()]$appId,
        [string][ValidateNotNullOrEmpty()]$clientSecret,
        [string]$domain
    )

    # Output IDs and Secret
    Write-Host "Firefly Powershell finished sucessfully, just 2 more steps to finish: " -ForegroundColor Cyan
    Write-Host "        1. Copy the outputs below and paste them into the Firefly wizard:" -ForegroundColor Cyan
    Write-Host "                - Tenant Id: $tenantId" -ForegroundColor Green
    Write-Host "                - Client Id: $appId" -ForegroundColor Green
    Write-Host "                - Client Secret: $clientSecret" -ForegroundColor Green
    Write-Host "                - Directory Domain: $domain" -ForegroundColor Green
    Write-Host "         Remember to save these values. The Client Secret cannot be retrieved later.`n" -ForegroundColor Cyan
    Write-Host "        2. Grant admin consent for the Firefly app at this link:" -ForegroundColor Cyan
    Write-Host "        [Grant Admin Consent]https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$( $sp.AppId )/isMSAApp~/false"  -ForegroundColor Green
}

try {
    Connect-AzureAD
    $context = Set-AzureContext -subscriptionId $subscriptionId
    $subscriptionId = $context.Subscription.Id
    $tenantId = (Get-AzureADTenantDetail).ObjectId
    Write-Host "Working on context of tenant: $tenantId and subscription: $subscriptionId"

    $appName = Set-AppNameParameter -appName $appName -subscriptionId $subscriptionId

    $sp = Get-AzADServicePrincipal -DisplayName $appName -ErrorAction SilentlyContinue
    if ($sp) {
        $spCreds = Set-ExistingServicePrincipaCreds -appName $appName
        $clientSecret = $spCreds.secretText
    }else{
        $sp = New-ServicePrincipal -appName $appName
        $clientSecret = $sp.passwordCredentials.secretText
    }
    $appId = $sp.AppId
    $spId = $sp.Id

    $enableActiveDirectory = Set-ADAppPermsissionParameter -enableActiveDirectory $enableActiveDirectory
    if ($enableActiveDirectory) {
        Add-AppPermissions -app $appName
    }

    New-AppRoleAssignments -spId $spId -subscriptionId $subscriptionId -enableCostOptimization $enableCostOptimization -enableSecurityCenterResources $enableSecurityCenterResources

    $domain = Get-DomainName

    $isEventDriven = Set-EventDrivenParameter -isEventDriven $isEventDriven
    if ($isEventDriven) {
        $endpoint = Set-EndpointParameter -endpoint $endpoint
        New-EventDrivenResources -endpoint $endpoint -subscriptionId $subscriptionId -spId $spId
    }

    Output-IDsAndSecret -tenantId $tenantId -appId $appId -clientSecret $clientSecret -domain $domain
}
catch {
    Write-Host "An error occurred: $_"  -ForegroundColor Red
    Write-Host "Please Contact Firefly Support."  -ForegroundColor Red
    Read-Host "Press Enter to continue..."
}
