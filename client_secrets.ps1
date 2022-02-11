## References
### Graph API: https://docs.microsoft.com/en-us/graph/api/resources/application?view=graph-rest-1.0

Param(
  [string]$source_client_id,
  [string]$source_tenant_id,

  [string]$target_tenant_id,
  [string]$target_application_id,
  [string]$target_application_secret,

  [array]$service_principal_id_collection,

  [string]$environment,
  [string]$product,
  [string]$prefix,

  [string]$keyVaultName 
)


$service_principal_id_collection_arr = $service_principal_id_collection.Split(',')
if ($service_principal_id_collection_arr.length -lt 1) {
  Write-Output "No Applications to process. $service_principal_id_collection"; 
  exit
}
else {
  Write-Output "there is Applications to process. $service_principal_id_collection"; 
}

#############################################################
###           Get Current Context                      ###
#############################################################

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process | Out-Null
 
# Connect using a Managed Service Identity
try {
  $sourceContext = (Connect-AzAccount -Identity -TenantId $source_tenant_id -AccountId $source_client_id ).context
}
catch {
  Write-Output "Cannot connect to the source Managed Identity $source_client_id in $source_tenant_id. Aborting."; 
  exit
}


#############################################################
###           Set Target Context                          ###
#############################################################

if ($null -eq $target_tenant_id -or $target_tenant_id -eq "") {

  $targetContext = $sourceContext
}
else {
  # Connect to target Tenant
  try {
    $password = ConvertTo-SecureString $target_application_secret -AsPlainText -Force
    $Credential = New-Object -TypeName System.Management.Automation.PSCredential ($target_application_id, $password)
    $targetContext = (Connect-AzAccount -ServicePrincipal -TenantId $target_tenant_id -Credential $Credential).context
  }
  catch {
    Write-Output "Failed to connect remote tenant. Aborting."; 
    Write-Error "Error: $($_)"; 
    exit
  }
}

$targetContext = Set-AzContext -Context $targetContext


#############################################################
###           Process Service Principals                  ###
#############################################################

try {
  $Applications = Get-AzADApplication -DefaultProfile $targetContext
  Write-Output "Applications Found:"
  foreach ($app in $Applications.DisplayName) {
    Write-Output "$app"
  }

  $expiringRangeDays = 30
  $expiryFromNowYears = 1

  Write-Output "Start Processing"
  foreach ($spId in $service_principal_id_collection_arr) {
  
    $containsApp = $Applications.ObjectId -contains $spId

    if ($containsApp) {

      try {
        $app = $Applications | Where-Object { $_.Id -eq $spId }

        $appName = $app.DisplayName
        $appId = $app.Id
        $secret = $app.PasswordCredentials

        $secretName = "$prefix-$product-$environment-$appName"
  
        Write-Host "Checking $appName has automated secrets"
  
        $secretExists = $($secret.DisplayName -like "$secretName*").length -gt 0
  
        if (!$secretExists) {
          Write-Host "Creating Secret $secretName"
          $params = @{
            PasswordCredential = @{
              DisplayName = "$secretName-$($(Get-Date).ToString('yyyyMMddhhmmss'))"
              EndDateTime = $(Get-Date).AddYears($expiryFromNowYears)
            }
          }
      
          $createdPassword = New-AzADAppCredential -ObjectId $appId -BodyParameter $params
  
          ## Add/Update Secret 
          $secretvalue = ConvertTo-SecureString $createdPassword.SecretText -AsPlainText -Force
          $secret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "$secretName-pwd" -SecretValue $secretvalue -DefaultProfile $sourceContext
          $secretvalue = ConvertTo-SecureString $appId -AsPlainText -Force
          $secret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "$secretName-id" -SecretValue $secretvalue -DefaultProfile $sourceContext
        }
        else {

          Write-Host "Recycling $appName Secrets"
      
          foreach ($s in $secret) {
            $keyName = $s.DisplayName 
            if ($keyName -like "$secretName*") {
              $keyId = $s.KeyId
              Write-Host "$appName Secret $keyName"
  
              $endDate = $s.EndDateTime
              $currentDate = Get-Date
              $expiringRangeDate = $(Get-Date).AddDays($expiringRangeDays)
      
              Write-Host "$keyName has expires $endDate"
              Write-Host "Expiry Date Range is $expiringRangeDate"
              if ($endDate -lt $currentDate) {
                Write-Host "$keyName has expired ($endDate). Removing Key"
                $params = @{
                  KeyId = $keyId
                }
        
                Remove-AzADAppCredential -ObjectId $appId -BodyParameter $params
              }
              elseif ($endDate -lt $expiringRangeDate) {
                Write-Host "$keyName will expire within $expiringRangeDays."
                $secretName = "$prefix-$product-$environment-$appName"
    
                Write-Host "Creating Secret $secretName"
                $params = @{
                  PasswordCredential = @{
                    DisplayName = "$secretName-$($(Get-Date).ToString('yyyyMMddhhmmss'))"
                    EndDateTime = $(Get-Date).AddYears($expiryFromNowYears)
                  }
                }
            
                $createdPassword = New-AzADAppCredential -ObjectId $appId -BodyParameter $params
    
                ## Add/Update Secret 
                $secretvalue = ConvertTo-SecureString $createdPassword.SecretText -AsPlainText -Force
                $secret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "$secretName-pwd" -SecretValue $secretvalue -DefaultProfile $sourceContext
            
              }
              else {
                Write-Host "$secretName secret is not exiring"
              }
            }
          }
        }
      }
      catch {
        Write-Output "Failed to update secret: $spId. Aborting."; 
        Write-Error "Error: $($_)"; 
        exit
      }
    
    }
    else {
      Write-Output "$spId is not found in the Application Collection."
    }
  }

}
catch {
  Write-Output "Failed to process secrets. Aborting."; 
  Write-Error "Error: $($_)"; 
  exit
}
