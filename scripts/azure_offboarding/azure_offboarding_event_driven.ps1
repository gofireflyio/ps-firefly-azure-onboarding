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
        $err = $false
        Write-Host "Diagnostic settings found, removing..."
        foreach ($ds in $diagnosticSetting) {
            try {
                Remove-AzSubscriptionDiagnosticSetting -InputObject $ds
            } catch {
                $err = $true
                Write-Host "Failed to remove diagnostic setting, error: $_" -ForegroundColor Red
            }
        }
        if ($err) {
            return
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

function Remove-RoleAssignment {
    param(
        [string][ValidateNotNullOrEmpty()]$spId,
        [string][ValidateNotNullOrEmpty()]$roleName,
        [string]$scope
    )
    Write-Host "Checking if Role Assignment exists..."
    if ($scope) {
        Write-Host "Role assignment with scope: $scope"
        $scope = $scope.Trim()
        $roleAssignment = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $roleName -Scope $scope
        if ($roleAssignment -eq $null) {
            Write-Host "Role assignment $roleName does not exist, skipping deletion..."
            return
        }
        try {
            Write-Host "Role assignment found, removing..."
            $assignment = Remove-AzRoleAssignment -ObjectID $spId -RoleDefinitionName $roleName -Scope $scope
            if ($assignment -And $assignment.ObjectType -eq "Unknown") {
                Write-Host "Unable to remove $roleName role assignment. Continuing..." -ForegroundColor Red
                return
            }
        } catch {
            throw "Failed to remove role assignment, error: $_"
        }
    } else {
        Write-Host "Role assignment with $spId and $roleName"
        $roleAssignment = Get-AzRoleAssignment -ObjectId $spId -RoleDefinitionName $roleName
        if ($roleAssignment -eq $null) {
            Write-Host "Role assignment $roleName does not exist, skipping deletion..."
            return
        }
        try {
            Write-Host "Role assignment found, removing..."
            $assignment = Remove-AzRoleAssignment -ObjectID $spId -RoleDefinitionName $roleName
            if ($assignment -And $assignment.ObjectType -eq "Unknown") {
                Write-Host "Unable to remove $roleName role assignment. Continuing..." -ForegroundColor Red
                return
            }
        } catch {
            throw "Failed to remove role assignment, error: $_"
        }
    }
    Write-Host "Role assignment successfully removed"
}

function Remove-StorageAccount {
    param(
        [string][ValidateNotNullOrEmpty()]$resourceGroup,
        [string][ValidateNotNullOrEmpty()]$spId,
        [string][ValidateNotNullOrEmpty()]$storageAccountName
    )
    Write-Host "Checking if Storage Account exists..."
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName -ErrorAction SilentlyContinue
    if ($storageAccount -eq $null) {
        Write-Host "Storage Account $storageAccountName does not exist, skipping deletion..."
        return
    }

    Write-Host "Trying to remove EventGridSubscription..."
    try {
        Remove-EventGridSubscription -name "fireflyevents" -id $storageAccount.Id
    } catch {
        Write-Host "$_" -ForegroundColor Red
        Write-Host "Continuing..."
    }

    Write-Host "Trying to remove Storage Account Role Assignment..."
    $roleName = "Storage Blob Data Reader" 
    try {
        Remove-RoleAssignment -spId $spId -roleName $roleName -scope $storageAccount.Id.Trim()
    } catch {
        Write-Host "Failed to remove Role Assignment, continuing..." -ForegroundColor Red
    }

        
    Write-Host "Removing Storage Account..."
    try {
        Remove-AzStorageAccount -ResourceGroupName $resourceGroup -Name $storageAccountName -Force
    } catch {
        throw "Failed to remove Storage Account, error: $_"
    }
    Write-Host "Storage account successfully removed"
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
$context = Set-AzureContext -subscriptionId $subscriptionId

$appName = Set-AppNameParameter -appName $appName -subscriptionId $subscriptionId
$sp = Get-AzADServicePrincipal -DisplayName $appName

if (!$sp) {
    Write-Host "Service Principal not found. Aborting..."
    return
} 

$storageAccountName = ("firefly" + $subscriptionId -replace '-', '').Substring(0,[Math]::Min(("firefly-" + $subscriptionId -replace '-', '').Length, 23))

try {
    Remove-DiagnosticSetting -name “firefly”
} catch {
    Write-Host "$_" -ForegroundColor Red
    Write-Host "Continuing..."
}

try {
    Remove-StorageAccount -resourceGroup "firefly" -spId $sp.Id -storageAccountName $storageAccountName
} catch {
    Write-Host "$_" -ForegroundColor Red
    Write-Host "Continuing..."
}