$latestTLSVersion = "TLS1_2"

try {
    # Connect to Azure Account
    Connect-AzAccount
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    # Step 1: Select Subscription
    $subscriptions = Get-AzSubscription
    for ($i = 0; $i -lt $subscriptions.Count; $i++) {
        Write-Output "${i}: $($subscriptions[$i].Name) ($($subscriptions[$i].Id))"
    }
    $subscriptionIndex = [int](Read-Host "Enter the number corresponding to the Subscription you want to work with")
    $selectedSubscription = $subscriptions[$subscriptionIndex]
    $subId = $selectedSubscription.Id

    # Set context to the selected subscription
    Set-AzContext -SubscriptionId $subId

    # Step 2: Select Resource Group
    $rgList = Get-AzResourceGroup
    for ($i = 0; $i -lt $rgList.Count; $i++) {
        Write-Output "${i}: $($rgList[$i].ResourceGroupName)"
    }
    $rgIndex = [int](Read-Host "Enter the number corresponding to the Resource Group you want to work with")
    $resourceGroupName = $rgList[$rgIndex].ResourceGroupName

    # Step 3: Select Resource Type
    $userOption = Read-Host "Choose Resource to Check (1: Virtual Machine, 2: Storage Account, 3: Key Vault)"

    # Initialize an array to store report data
    $reportData = @()

    if ($userOption -eq 1) {
        # Virtual Machine Backup Check
        $vms = Get-AzVM -ResourceGroupName $resourceGroupName
        if ($vms.Count -eq 0) {
            Write-Host "No Virtual Machines found in Resource Group $resourceGroupName"
        } else {
            foreach ($vm in $vms) {
                Write-Host "Checking VM: $($vm.Name)"
                $vaults = Get-AzRecoveryServicesVault | Where-Object { $_.ResourceGroupName -eq $resourceGroupName }
                $backupEnabled = $false
                $backupItem = $null

                foreach ($vault in $vaults) {
                    try {
                        # Retrieve Backup Container
                        $container = Get-AzRecoveryServicesBackupContainer -VaultId $vault.ID -ContainerType "AzureVM" -FriendlyName $vm.Name -ErrorAction SilentlyContinue
                        if ($container -ne $null -and $container.Id) {
                            # Retrieve Backup Item
                            $backupItem = Get-AzRecoveryServicesBackupItem -VaultId $vault.ID -Container $container -WorkloadType "AzureVM" -ErrorAction SilentlyContinue
                            if ($backupItem) {
                                $backupEnabled = $true
                                break
                            }
                        }
                    } catch {
                        Write-Host "Error checking backup for VM: $($vm.Name)" -ForegroundColor Yellow
                    }
                }

                if ($backupItem) {
                    # Retrieve Backup Details
                    $backupStatus = $backupItem.ProtectionStatus
                    $lastBackupStatus = $backupItem.LastBackupStatus
                    $lastBackupTime = $backupItem.LastBackupTime
                    $isHealthy = if ($backupItem.ProtectionStatus -eq "Healthy") { "Yes" } else { "No" }

                    Write-Host "Backup is enabled for VM '$($vm.Name)'. Last Backup Status: $lastBackupStatus, Healthy: $isHealthy." -ForegroundColor Green

                    $reportEntry = [PSCustomObject]@{
                        "ResourceType"       = "VM"
                        "ResourceName"       = $vm.Name
                        "Backup Status"      = "Enabled"
                        "Last Backup Status" = $lastBackupStatus
                        "Last Backup Time"   = $lastBackupTime
                        "Healthy"            = $isHealthy
                    }
                } else {
                    Write-Host "Backup not enabled for VM: $($vm.Name)" -ForegroundColor Red
                    $reportEntry = [PSCustomObject]@{
                        "ResourceType"       = "VM"
                        "ResourceName"       = $vm.Name
                        "Backup Status"      = "Not Enabled"
                        "Last Backup Status" = "N/A"
                        "Last Backup Time"   = "N/A"
                        "Healthy"            = "No"
                    }
                }

                $reportData += $reportEntry
                Write-Output $reportEntry | Format-Table -AutoSize
            }
        }
        $reportPath = "VMBackupReport_$timestamp.csv"
    } elseif ($userOption -eq 2) {
        # Storage Account Compliance Check
        $storageAccList = Get-AzStorageAccount -ResourceGroupName $resourceGroupName
        if ($storageAccList.Count -eq 0) {
            Write-Host "No Storage Accounts found in Resource Group $resourceGroupName"
        } else {
            foreach ($storageAcc in $storageAccList) {
                try {
                    # Retrieve blob service properties for Soft Delete and Versioning
                    $blobServiceProperties = Get-AzStorageBlobServiceProperty -ResourceGroupName $resourceGroupName -AccountName $storageAcc.StorageAccountName

                    # Capture Soft Delete, Versioning, and TLS Version status
                    $softDeleteEnabled = $blobServiceProperties.DeleteRetentionPolicy.Enabled
                    $versioningEnabled = $blobServiceProperties.IsVersioningEnabled -eq $true
                    $currentTLSVersion = $storageAcc.MinimumTlsVersion

                    $reportEntry = [PSCustomObject]@{
                        "ResourceType"           = "Storage Account"
                        "ResourceName"           = $storageAcc.StorageAccountName
                        "Soft Delete Enabled"    = $softDeleteEnabled
                        "Versioning Enabled"     = $versioningEnabled
                        "TLS Version Status"     = if ($currentTLSVersion -eq $latestTLSVersion) {"Up-to-date"} else {"Outdated"}
                    }
                    $reportData += $reportEntry
                    Write-Output $reportEntry | Format-Table -AutoSize
                } catch {
                    Write-Host "Error processing storage account: $($storageAcc.StorageAccountName)" -ForegroundColor Yellow
                }
            }
        }
        $reportPath = "StorageAccountReport_$timestamp.csv"
    } elseif ($userOption -eq 3) {
        # Key Vault Compliance Check
        $keyVaults = Get-AzKeyVault -ResourceGroupName $resourceGroupName
        if ($keyVaults.Count -eq 0) {
            Write-Host "No Key Vaults found in Resource Group $resourceGroupName"
        } else {
            foreach ($kv in $keyVaults) {
                try {
                    # Use Get-AzResource to fetch Key Vault properties
                    $kvResource = Get-AzResource -ResourceId $kv.ResourceId
                    $properties = $kvResource.Properties

                    # Capture Soft Delete and Purge Protection statuses
                    $softDeleteEnabled = $properties.enableSoftDelete
                    $purgeProtectionEnabled = $properties.enablePurgeProtection

                    $reportEntry = [PSCustomObject]@{
                        "ResourceType"               = "Key Vault"
                        "ResourceName"               = $kv.VaultName
                        "Soft Delete Enabled"        = if ($softDeleteEnabled -eq $true) {"True"} else {"False"}
                        "Purge Protection Enabled"   = if ($purgeProtectionEnabled -eq $true) {"True"} else {"False"}
                    }
                    $reportData += $reportEntry
                    Write-Output $reportEntry | Format-Table -AutoSize
                } catch {
                    Write-Host "Error processing Key Vault: $($kv.VaultName)" -ForegroundColor Yellow
                }
            }
        }
        $reportPath = "KeyVaultReport_$timestamp.csv"
    } else {
        Write-Host "Invalid Option Selected"
    }

    # Export the report data to a CSV file
    if ($reportData.Count -gt 0) {
        $reportData | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
        Write-Host "Report generated at $reportPath"
    } else {
        Write-Host "No data to display in the report."
    }

} catch {
    Write-Host "An error has occurred."
    Write-Host $_
}
