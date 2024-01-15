# ps-firefly-azure-onboarding
Powershell script for onboarding Azure into Firefly

The script creates the application registration and service principal needed for firefly to scan the cloud.

The application registration itself is given the standard `Directory.Read.All` permission

The service principal is given the standard roles:
- `Reader`
- `Security Reader`
- `Billing Reader`

Also, a custom role with the following permissions is attached:
- `Microsoft.Storage/storageAccounts/listkeys/action`
- `Microsoft.DocumentDB/databaseAccounts/listConnectionStrings/action`
- `Microsoft.DocumentDB/databaseAccounts/listKeys/action`
- `Microsoft.DocumentDB/databaseAccounts/readonlykeys/action`
- `Microsoft.ContainerService/managedClusters/listClusterUserCredential/action`
- `Microsoft.Web/sites/config/list/Action`
- `Microsoft.Cache/redis/listKeys/action`

Inorder to read Terraform state files from blob storage, the role also has permissions to read blob objects with .tfstate suffix

