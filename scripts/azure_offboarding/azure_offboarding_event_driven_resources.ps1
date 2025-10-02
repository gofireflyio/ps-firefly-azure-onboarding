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

function Remove-DiagnosticSetting {
    param (
        [string][ValidateNotNullOrEmpty()]$name
    )
    Write-Host "Checking if diagnostic setting exists..."
    $diagnosticSetting = Get-AzSubscriptionDiagnosticSetting -Name $name -ErrorAction SilentlyContinue
    if ($diagnosticSetting -eq $null) {
        Write-Host "Diagnostic settings $name does not exist, skipping deletion..."
        return
    }
    if ($diagnosticSetting -is [array]) {
        Write-Host "Diagnostic settings found, removing..."
        foreach ($ds in $diagnosticSetting) {
            try {
                Remove-AzSubscriptionDiagnosticSetting -InputObject $ds
            } catch {
                throw "Failed to remove diagnostic setting, error: $_"
            }
        }
    } else {
        Write-Host "Diagnostic setting found, removing..."
        try {
            Remove-AzSubscriptionDiagnosticSetting -Name $name
        } catch {
            throw "Failed to remove diagnostic setting, error: $_"
        }
    }
    Write-Host "Diagnostic setting successfully removed"
}

function Remove-EventGridSubscription {
    param (
        [string][ValidateNotNullOrEmpty()]$name,
        [string][ValidateNotNullOrEmpty()]$id
    )
    $id = $id.Trim()
    Write-Host "Checking if subscription exists..."
    $eventGridSubscription = Get-AzEventGridSubscription -EventSubscriptionName $name -ResourceId $id -ErrorAction SilentlyContinue
    if ($eventGridSubscription -eq $null) {
        Write-Host "Eventgrid subscription $name does not exist, skipping deletion..."
        return
    }
    if ($eventGridSubscription -is [array]) {
        $err = $false
        Write-Host "Subscriptions found, removing..."
        foreach ($egs in $eventGridSubscription) {
            try {
                Remove-AzEventGridSubscription -ResourceId $egs.Topic -EventSubscriptionName $name
            } catch {
                $err = $true
                Write-Host "Failed to remove subscription, error: $_" -ForegroundColor Red
            }
        }
        if ($err) {
            return
        }
    } else {
        Write-Host "Subscription found, removing..."
        try {
            Remove-AzEventGridSubscription -ResourceId $eventGridSubscription.Topic -EventSubscriptionName $name
        } catch {
            throw "Failed to remove subscription, error: $_"
        }
    }
    Write-Host "Eventgrid subscription successfully removed"
}

function Remove-StorageAccount {
    param(
        [string][ValidateNotNullOrEmpty()]$resourceGroup,
        [string][ValidateNotNullOrEmpty()]$storageAccountName
    )
    Write-Host "Checking if Storage Account exists..."
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName -ErrorAction SilentlyContinue
    if ($storageAccount -eq $null) {
        Write-Host "Storage Account $storageAccountName does not exist, skipping deletion"
        return
    }

    $azModuleVersion = (Get-InstalledModule -Name Az -AllVersions).Version
    if ($azModuleVersion.StartsWith("11.")) {
        Write-Host "Trying to remove EventGrid Subscription..."
        try {
            Remove-EventGridSubscription -name "fireflyevents" -id $storageAccount.Id
        } catch {
            throw "Failed to remove EventGrid Subscription, error: $_"
        }
        Write-Host "EventGrid Subscription successfully removed"
    } else {
        $storageAccName = $storageAccount.StorageAccountName
    
        $existingTopics = Get-AzEventGridSystemTopic -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
        $topicName = ""
        Write-Host "Trying to remove EventGridSystemTopic..."
        foreach ($topic in $existingTopics) {
            if ($topic.Name.StartsWith($storageAccName)) {
                $topicName = $topic.Name
                break
            }
        }
        try {
            Remove-AzEventGridSystemTopicEventSubscription -EventSubscriptionName "firefly-events" -ResourceGroupName "firefly" -SystemTopicName $topicName
        } catch {
            throw "Failed to remove topic event subscription from $topicName topic, error: $_"
        }
        Write-Host "Topic Event Subscription successfully removed"

        try {
            Remove-AzEventGridSystemTopic -Name $topicName -ResourceGroupName "firefly"
        } catch {
            throw "Failed to remove topic $topicName, error: $_"
        }
        Write-Host "Topic successfully removed"
    }

    Write-Host "Checking if storage account has lock..."
    $lock = Get-AzResourceLock -ResourceGroupName $resourceGroup -ResourceType "microsoft.storage/storageAccounts" -ResourceName $storageAccountName
    if ($lock) {
        Write-Host "Lock found, attempting removal..."
        try{
            Remove-AzResourceLock -LockName $lock.Name -ResourceGroupName $resourceGroup -ResourceType "microsoft.storage/storageAccounts" -ResourceName $storageAccountName -Force
        } catch {
            throw "Failed to remove storate lock, error: $_"
        }
        Write-Host "Lock successfully removed"
    }
        
    Write-Host "Removing Storage Account..."
    try {
        Remove-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName -Force
    } catch {
        throw "Failed to remove Storage Account, error: $_"
    }
    Write-Host "Storage account and dependencies successfully removed"
}

function Remove-ResourceGroup {
    param(
        [string][ValidateNotNullOrEmpty()]$name
    )
    Write-Host "Checking if Resource Group exists..."
    $resourceGroup = Get-AzResourceGroup -Name $name -ErrorAction SilentlyContinue
    if (!$resourceGroup) {
        Write-Host "Resource Group $name does not exist, skipping deletion...."
        return
    }

    Write-Host "Trying to remove Resource Group..."
    try {
        Remove-AzResourceGroup -Name $name -Force
    } catch {
        throw "Failed to remove Resource group, error: $_"
    }
    Write-Host "Resource Group successfully removed"
}


Connect-AzureAD

if ([string]::IsNullOrEmpty($subscriptionId)) {
  Write-Host '$subscriptionId variable is empty. Aborting.' -ForegroundColor Red
  exit 1
}

$context = Set-AzureContext -subscriptionId $subscriptionId

try {
    Remove-DiagnosticSetting -name “firefly”
} catch {
    Write-Host "$_" -ForegroundColor Red
    Write-Host "Continuing..."
}

$storageAccountName = ("firefly" + $subscriptionId -replace '-', '').Substring(0,[Math]::Min(("firefly-" + $subscriptionId -replace '-', '').Length, 23))

try {
    Remove-StorageAccount -resourceGroup "firefly" -storageAccountName $storageAccountName
} catch {
    Write-Host "$_" -ForegroundColor Red
    Write-Host "Continuing..."
}

try {
    Remove-ResourceGroup -name "firefly"
} catch {
    Write-Host "$_" -ForegroundColor Red
}
