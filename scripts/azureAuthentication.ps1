<#
.SYNOPSIS
    Sets up and reuses a Service Principal for non-interactive Azure authentication.

.DESCRIPTION
    Two-part script:
    - The "One-time setup" region creates an App Registration, a Service
      Principal for it, a client secret, and a Contributor role assignment
      scoped to the current subscription. Run it once interactively, save
      the printed credentials to a password manager, then comment it out.
    - The "Reusable authentication" region is the part meant to actually live
      in automation scripts (e.g. before calling New-WakandaAZVM.ps1) — it
      signs in non-interactively as the Service Principal, reading its
      credentials from environment variables rather than hardcoding them.

.NOTES
    Author:     George
    Project:    Wakanda Cloud Infrastructure Lab
    Requires:   Az PowerShell module.

    Before using the reusable block, set on your machine once:
        $env:AZURE_APP_ID        = '<your-app-id>'
        $env:AZURE_TENANT_ID     = '<your-tenant-id>'
        $env:AZURE_SUB_ID        = '<your-subscription-id>'
        $env:AZURE_CLIENT_SECRET = '<your-secret>'

    Never commit real values for these — env vars only.
#>

#region One-time setup — run this block once manually, then comment it out
# -----------------------------------------------------------------------
# 1. Sign in interactively as yourself — this is the identity that will
# create the app registration and grant it a role below
Connect-AzAccount

# 2. Create the app registration — this is the identity automation will run as
$myApp = New-AzADApplication -DisplayName 'wakanda-gfad-app'

# 3. Create the service principal tied to that app registration
$sp = New-AzADServicePrincipal -ApplicationId $myApp.AppId

# 4. Generate a client secret credential for the service principal
$secCred = New-AzADAppCredential `
    -ApplicationId $myApp.AppId `
    -EndDate (Get-Date).AddYears(1)

# 5. Capture the secret — displayed once, save to your password manager NOW
Write-Host "=== SAVE THESE TO YOUR PASSWORD MANAGER ===" -ForegroundColor Yellow
Write-Host "App ID:          $($myApp.AppId)"
Write-Host "Tenant ID:       $((Get-AzContext).Tenant.Id)"
Write-Host "Subscription ID: $((Get-AzContext).Subscription.Id)"
Write-Host "Client Secret:   $($secCred.SecretText)"
Write-Host "==========================================" -ForegroundColor Yellow

# 6. Grant the service principal Contributor at subscription scope, so it can
# provision/tear down lab resources unattended
$spObjectId = (Get-AzADServicePrincipal -ApplicationId $myApp.AppId).Id
$subId      = (Get-AzContext).Subscription.Id

New-AzRoleAssignment `
    -ObjectId            $spObjectId `
    -RoleDefinitionName  'Contributor' `
    -Scope               "/subscriptions/$subId"

# -----------------------------------------------------------------------
#endregion


#region Reusable authentication — this is what goes in your automation scripts
# -----------------------------------------------------------------------

# Pull values from environment variables (set these on your machine once)
# In your terminal run:
#   $env:AZURE_APP_ID       = '<your-app-id>'
#   $env:AZURE_TENANT_ID    = '<your-tenant-id>'
#   $env:AZURE_SUB_ID       = '<your-subscription-id>'
#   $env:AZURE_CLIENT_SECRET = '<your-secret>'

# 1. Load the service principal's identity/secret from environment variables
# — never hardcode these
$azureAppId     = $env:AZURE_APP_ID
$tenantId       = $env:AZURE_TENANT_ID
$subscriptionId = $env:AZURE_SUB_ID

# 2. Build a PSCredential from the app ID + secret, the shape Connect-AzAccount expects
$azureAppCred = New-Object System.Management.Automation.PSCredential(
    $azureAppId,
    (ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force)
)

# 3. Sign in non-interactively as the service principal — this is the call
# your automation scripts actually run
Connect-AzAccount `
    -ServicePrincipal `
    -SubscriptionId $subscriptionId `
    -TenantId       $tenantId `
    -Credential     $azureAppCred

# -----------------------------------------------------------------------
#endregion
