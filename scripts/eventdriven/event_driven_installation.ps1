$ErrorActionPreference = "Stop"
$FireflyEndpoint = "https://azure-events.firefly.ai"
$FormatEnumerationLimit = -1

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
        Write-Host "Done creating $name storage account..."
    } else {
        # Storage account already exists
        Write-Host "Storage account $name already exists, skipping creation..."
    }

    # Verify the storage account creation
    Read-FireflyStorageAccountIsReady -resourceGroup $resourceGroup -storageName $name

    $storageAccountId = (Get-AzStorageAccount -ResourceGroupName $resourceGroup -AccountName $name).Id | Out-String
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
    if ($storageId.Contains(" ")) {
        $tmp = $storageId.Trim().Split(" ")
        $storageId = $tmp[-1]
    }
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
        [string][ValidateNotNullOrEmpty()]$storageId,
        [string][ValidateNotNullOrEmpty()]$resourceGroupName
    )
    $eventSubscriptionName = 'fireflyevents'
    if ($storageId.Contains(" ")) {
        $tmp = $storageId.Trim().Split(" ")
        $storageId = $tmp[-1]
    }
    $id = $storageId.Trim()

    Write-Host "Starting event grid setup..."

    # Register and get Event Grid resource provider
    Register-AzResourceProvider -ProviderNamespace Microsoft.EventGrid
    $rp = Get-AzResourceProvider -ProviderNamespace Microsoft.EventGrid
    if (!$rp) {
        throw "Failed getting Event Grid resource provider, aborting now."
    }

    $azModuleVersion = (Get-InstalledModule -Name Az -AllVersions).Version

    if ($azModuleVersion.StartsWith("11.")) {
        $existing = Get-AzEventGridSubscription -EventSubscriptionName $eventSubscriptionName -ResourceId $id -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Eventgrid subscription $eventSubscriptionName already exist, skipping creation..."
            return
        }
    
        # Create new Event Grid subscription
        New-AzEventGridSubscription -EventSubscriptionName $eventSubscriptionName -Endpoint $endpoint -ResourceId $id  -IncludedEventType 'Microsoft.Storage.BlobCreated'
    
        # Verify success creation of the Event Grid subscription
        $eventSubscription = Get-AzEventGridSubscription -EventSubscriptionName $eventSubscriptionName -ResourceId $id
        if (!$eventSubscription) {
            throw "Failed to find created eventgrid subscription on storage: $id."
        }    
    } else {
        $storageIdSplit = $id.Split("/")
        $storageAccName = $storageIdSplit[$storageIdSplit.Length-1]
    
        $existingTopics = Get-AzEventGridSystemTopic -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
        $topicName = ""
        foreach ($topic in $existingTopics) {
            if ($topic.Name.StartsWith($storageAccName)) {
                $topicName = $topic.Name
                break
            }
        }
    
        if (!$topicName) {
            $guid = New-Guid
            $guid = $guid.ToString()
            $topicName = $storageAccName+"-"+$guid
            $topic = New-AzEventGridSystemTopic -Name $topicName -ResourceGroupName $resourceGroupName -Location eastus -Source $id -TopicType "microsoft.storage.storageaccounts"
            if (!$topic) {
                throw "Failed creating new event grid System Topic, aborting now."
            } 
        } else {
            Write-Host "Event grid topic $topicName already exists, skipping creation"
        }
    
        $subscription = Get-AzEventGridSystemTopicEventSubscription -EventSubscriptionName $eventSubscriptionName -ResourceGroupName $resourceGroupName -SystemTopicName $topicName -ErrorAction SilentlyContinue
        if ($subscription) {
            Write-Host "Event grid subscription $eventSubscriptionName already exist, skipping creation"
            return
        }
    
        $destinationObj = New-AzEventGridWebHookEventSubscriptionDestinationObject -EndpointUrl $endpoint
        # Create new Event Grid subscription
        New-AzEventGridSystemTopicEventSubscription -EventSubscriptionName $eventSubscriptionName -ResourceGroupName $resourceGroupName -SystemTopicName $topicName -FilterIncludedEventType "Microsoft.Storage.BlobCreated" -Destination $destinationObj
    
        # Verify success creation of the Event Grid subscription
        $subscription = Get-AzEventGridSystemTopicEventSubscription -EventSubscriptionName $eventSubscriptionName -ResourceGroupName $resourceGroupName -SystemTopicName $topicName
        if (!$subscription) {
            throw "Failed to find created eventgrid subscription on storage $id, aborting now."
        }
    }

    Write-Host "Done event grid setup"
}

function CreateDiagnosticSettings {
    param (
        [string][ValidateNotNullOrEmpty()]$storageId
    )
    $diagnosticSettingsName = 'firefly'
    $id = $storageId.Trim()

    Register-AzResourceProvider -ProviderNamespace Microsoft.Insights
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
    "Microsoft.Cache/redis/listKeys/action",
    "Microsoft.AppConfiguration/configurationStores/ListKeys/action",
    "Microsoft.Devices/iotHubs/listkeys/Action",
    "Microsoft.Maps/accounts/listKeys/action",
    "Microsoft.Search/searchServices/listAdminKeys/action"
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
        OR
        (
         @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike '*.tfstateenv:*'
        )
       )"
    # Verify the role assignment creation
    $ra = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $ffRoleName
    if (!$ra -Or $ra.ObjectType -eq "Unknown") {
        throw "Failed to find created role assignment: $ffRoleName, aborting now."
    }

    Write-Host "Done verifying adding role assignments $ffRoleName to $appName registration application..."
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

    if ($storageId.Contains(" ")) {
        $tmp = $storageId.Trim().Split(" ")
        $storageId = $tmp[-1]
    }

    New-StorageAccountRoleAssignments -spId $spId -storageId $storageId -subscriptionId $subscriptionId -resourceGroup $resourceGroup

    CreateEventGridSubscription -endpoint $endpoint -storageId $storageId -resourceGroupName $resourceGroup

    CreateDiagnosticSettings -storageId $storageId

    Write-Host "Done creating event driven resources..."
}

try {
    Connect-AzureAD
    $context = Set-AzContext -Subscription $subscriptionId
    $subscriptionId = $context.Subscription.Id
    $sp = Get-AzADServicePrincipal -DisplayName $spDisplayName
    if ($sp) {
        $spId = $sp.Id
        Write-Host "Found service principal Id $spId"
    }else{
        Write-Host "Could not find service principal Id for ${spDisplayName}"
        throw "Service principal not found, aborting now."
    }
    New-EventDrivenResources -endpoint $FireflyEndpoint -subscriptionId $subscriptionId -spId $spId
    New-AppRoleAssignments -spId $spId -subscriptionId $subscriptionId -enableCostOptimization $enableCostOptimization -enableSecurityCenterResources $enableSecurityCenterResources

}
catch {
    Write-Host "An error occurred: $_"  -ForegroundColor Red
    Write-Host "Please Contact Firefly Support."  -ForegroundColor Red
    Read-Host "Press Enter to continue..."
}
