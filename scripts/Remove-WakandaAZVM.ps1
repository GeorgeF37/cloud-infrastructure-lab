
function Remove-WakandaAZVM {
<#
.SYNOPSIS
    Tears down an Azure lab environment by removing a Resource Group and all its contents.
.DESCRIPTION
    Remove-WakandaAZVM deletes an Azure Resource Group and every resource inside it
    including Virtual Machines, Disks, Network Interfaces, Public IPs, Virtual Networks,
    Subnets, and Network Security Groups.

    Before deleting, the script:
    - Validates the resource group exists
    - Lists all resources inside it so you know exactly what will be removed
    - Requires explicit confirmation by typing 'yes'

    Supports -WhatIf to preview what would be deleted without removing anything.

    This script is the counterpart to New-WakandaAZVM.ps1.
    Run it at the end of every lab session to avoid unnecessary Azure costs.
.PARAMETER ResourceGroupName
    The name of the Azure Resource Group to delete along with all its contents.
.EXAMPLE
    # Standard teardown with confirmation prompt
    Remove-WakandaAZVM -ResourceGroupName 'PowerShellForSysAdmins-RG'
.EXAMPLE
    # Preview what would be deleted without removing anything
    Remove-WakandaAZVM -ResourceGroupName 'PowerShellForSysAdmins-RG' -WhatIf
.EXAMPLE
    # Teardown using positional parameter
    Remove-WakandaAZVM 'PowerShellForSysAdmins-RG'
.NOTES
    Author:     George
    Project:    Wakanda Cloud Infrastructure Lab
    Requires:   Az PowerShell module, active Azure session (Connect-AzAccount)

    WARNING: This operation is irreversible. All resources in the group will be
    permanently deleted. Always review the resource list before confirming.

    The Public IP address accrues cost while it exists — running this script
    at the end of each session prevents unnecessary charges.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]
        $ResourceGroupName
    )

    # 1. Session validation - confirm we're actually signed in to Azure before
    # doing anything else, same check New-WakandaAZVM.ps1 starts with.
    $context = Get-AzContext
    if (-not $context) {
        throw "No Azure context found. Run Connect-AzAccount first."
    }
    Write-Host "Connected as: $($context.Account)" -ForegroundColor Green

    # 2. Confirm the target resource group actually exists - nothing to tear
    # down otherwise, so bail out early rather than erroring later.
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Warning "Resource Group '$ResourceGroupName' not found. Nothing to remove."
        return
    }

    # 3. Show exactly what's about to be deleted - resource group, location,
    # and every resource inside it - before asking for confirmation.
    Write-Host "`nThe following resource group and ALL resources inside it will be deleted:" -ForegroundColor Yellow
    Write-Host "  $ResourceGroupName ($($rg.Location))" -ForegroundColor Yellow

    # List contents so the user knows exactly what they're deleting
    Get-AzResource -ResourceGroupName $ResourceGroupName |
        Select-Object Name, ResourceType |
        Format-Table -AutoSize

    # 4. Require explicit confirmation - this is irreversible, so no implicit
    # "just run it" path even with -Confirm off.
    $confirm = Read-Host "Type 'yes' to confirm deletion"
    if ($confirm -ne 'yes') {
        Write-Host "Teardown cancelled." -ForegroundColor Green
        return
    }

    # 5. Delete the resource group - Azure cascades the deletion to every
    # resource inside it. Supports -WhatIf via ShouldProcess.
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Remove Resource Group and all contents')) {
        Write-Host "`nRemoving resource group '$ResourceGroupName'..." -ForegroundColor Cyan
        Remove-AzResourceGroup -Name $ResourceGroupName -Force | Out-Null
        Write-Host "Done. All resources deleted." -ForegroundColor Green
    }
}




<#
The nuclear option (recommended for a lab):
Everything lives in the resource group — delete that and Azure cascades the deletion to every resource inside it. One command, everything gone:
powershellRemove-AzResourceGroup -Name 'PowerShellForSysAdmins-RG' -Force

The surgical option (if you want to keep some resources):
If you ever want to tear down just the VM and chargeable resources but keep the network infrastructure, the order matters because of dependencies:

VM — remove first, it holds references to disk and NIC
Disk — can't delete while attached to a VM
NIC — references public IP and NSG
Public IP — can't delete while attached to a NIC
NSG — can't delete while attached to a NIC
VNet/Subnet — can't delete while NIC exists in the subnet
Resource Group — last, or skip if keeping it
#>
