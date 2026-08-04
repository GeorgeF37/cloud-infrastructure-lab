
function New-WakandaAZVM {
    <#
    .SYNOPSIS
        Deploys a Windows Server VM in Azure with all required dependencies.

    .DESCRIPTION
        New-WakandaAZVM provisions a complete Azure lab environment from scratch including:
        a Resource Group, Virtual Network, Subnet, Network Security Group, Public IP,
        Network Interface, and a Windows Server 2022 VM.

        The script automatically checks VM size availability across multiple regions.
        If a preferred location is specified but unavailable, the user has 10 seconds
        to cancel before the script falls back to automatic region selection.

        Supports -WhatIf to preview what would be created without deploying anything.

    .PARAMETER ResourceGroupName
        The name of the Azure Resource Group to create or use.

    .PARAMETER Location
        Optional. Preferred Azure region (e.g. 'eastus', 'uksouth').
        If not specified or unavailable, the script selects the first available region.

    .PARAMETER SubnetName
        Name for the subnet within the Virtual Network.

    .PARAMETER SubnetAddressPrefix
        CIDR address range for the subnet. e.g. '10.0.0.0/24'

    .PARAMETER VNetName
        Name for the Virtual Network.

    .PARAMETER VNetAddressPrefix
        CIDR address range for the Virtual Network. e.g. '10.0.0.0/16'

    .PARAMETER PublicIPName
        Name for the Public IP Address resource.

    .PARAMETER AllocationMethod
        IP allocation method. Use 'Static' for Standard SKU public IPs.

    .PARAMETER VNICName
        Name for the Network Interface Card resource.

    .PARAMETER VMName
        Name for the Virtual Machine. Must be 15 characters or fewer (Windows limit).

    .PARAMETER VMCredential
        PSCredential object for the local administrator account on the VM.
        Use: $cred = Get-Credential

    .EXAMPLE
        # Basic deployment — script finds best available region automatically
        $cred = Get-Credential
        New-WakandaAZVM `
            -ResourceGroupName  'WakandaLab-RG' `
            -SubnetName         'WakandaLab-Subnet' `
            -SubnetAddressPrefix '10.0.0.0/24' `
            -VNetName           'WakandaLab-vNet' `
            -VNetAddressPrefix  '10.0.0.0/16' `
            -PublicIPName       'WakandaLab-PubIp' `
            -AllocationMethod   'Static' `
            -VNICName           'WakandaLab-vNIC' `
            -VMName             'WakandaVM' `
            -VMCredential       $cred

    .EXAMPLE
        # Deployment with preferred region specified
        $cred = Get-Credential
        New-WakandaAZVM `
            -ResourceGroupName  'WakandaLab-RG' `
            -Location           'uksouth' `
            -SubnetName         'WakandaLab-Subnet' `
            -SubnetAddressPrefix '10.0.0.0/24' `
            -VNetName           'WakandaLab-vNet' `
            -VNetAddressPrefix  '10.0.0.0/16' `
            -PublicIPName       'WakandaLab-PubIp' `
            -AllocationMethod   'Static' `
            -VNICName           'WakandaLab-vNIC' `
            -VMName             'WakandaVM' `
            -VMCredential       $cred

    .EXAMPLE
        # Preview what would be created without deploying anything
        $cred = Get-Credential
        New-WakandaAZVM `
            -ResourceGroupName  'WakandaLab-RG' `
            -VMName             'WakandaVM' `
            -VMCredential       $cred `
            -WhatIf

    .NOTES
        Author:     George
        Project:    Wakanda Cloud Infrastructure Lab
        Requires:   Az PowerShell module, active Azure session (Connect-AzAccount)
        
        Run Remove-WakandaAZVM.ps1 after each session to avoid unnecessary costs.
        The Public IP address is billed while it exists — tear down when done.
    #>
    
    [CmdletBinding(SupportsShouldProcess)]
    param (
        # Resource Group Name
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        # Location for VM and dependancies
        [Parameter()]
        [string]
        $Location,

        # Subnet Name
        [Parameter(Mandatory)]
        [string]
        $SubnetName,

        # Subnet Address Prefix e.g. "'10.0.0.0/24'"
        [Parameter(Mandatory)]
        [string]
        $SubnetAddressPrefix,

        # Virtual Network Name
        [Parameter(Mandatory)]
        [string]
        $VNetName,

        # Virtual Network Address Prefix e.g. "'10.0.0.0/16'"
        [Parameter(Mandatory)]
        [string]
        $VNetAddressPrefix,

        # Public IP Name
        [Parameter(Mandatory)]
        [string]
        $PublicIPName,

        # Allocation Method type either static or dynamic
        [Parameter(Mandatory)]
        [string]
        $AllocationMethod,

        # Virtual NIC Name
        [Parameter(Mandatory)]
        [string]
        $VNICName,

        # VM Name Config 
        [Parameter(Mandatory)]
        [string]
        $VMName,

        # Get Credentials for the local account created on the VM 
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]
        $VMCredential

    )

    # Session validation
    # Validate context at the start of every script
    $context = Get-AzContext
    if (-not $context) {
        throw "No Azure context found. Run Connect-AzAccount first."
    }
    
    Write-Host "Connected as: $($context.Account)" -ForegroundColor Green
    Write-Host "Subscription: $($context.Subscription.Name)" -ForegroundColor Green

    if ($VMName.Length -gt 15) {
        throw "VMName '$VMName' exceeds the 15 character Windows computer name limit."
    }

    # Collect available sizes across regions    
    # Check availability and find first available region and size
    $regions = @('uksouth', 'ukwest', 'eastus', 'eastus2', 'westus', 'westus2', 
             'westus3', 'northeurope', 'westeurope', 'canadacentral', 
             'australiaeast', 'southeastasia')

    # If user specified a location, check it first
    if ($Location) {
        Write-Host "Preferred region '$Location' specified - checking availability..." -ForegroundColor Cyan
        
        $preferredFound = Get-AzComputeResourceSku -Location $Location | 
            Where-Object { 
                $_.ResourceType -eq 'virtualMachines' -and 
                $_.Restrictions.Count -eq 0 -and
                ($_.Name -eq 'Standard_B1s' -or
                $_.Name -eq 'Standard_B2s' -or
                $_.Name -eq 'Standard_B1ms' -or
                $_.Name -eq 'Standard_DS1_v2' -or
                $_.Name -eq 'Standard_D2s_v3')
            } | Select-Object -First 1

        if ($preferredFound) {
            # Preferred region is available — use it directly, no need to search further
            $selectedRegion = $Location
            $selectedSize   = $preferredFound.Name
            Write-Host "Preferred region '$selectedRegion' is available. Using '$selectedSize'." -ForegroundColor Green

        } else {
            # Preferred region unavailable — ask the user what to do
            Write-Host "Preferred region '$Location' has no available VM sizes." -ForegroundColor Yellow
            Write-Host "Waiting 10 seconds — press N then Enter to cancel, or just wait to continue with automatic region selection..." -ForegroundColor Yellow

            $userInput = $null
            $deadline  = (Get-Date).AddSeconds(10)

            while ((Get-Date) -lt $deadline -and -not $userInput) {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'N') {
                        $userInput = 'N'
                    }
                }
                Start-Sleep -Milliseconds 200
            }

            if ($userInput -eq 'N') {
                throw "Deployment cancelled by user. Preferred region '$Location' unavailable."
            }

            Write-Host "No input received — proceeding with automatic region selection..." -ForegroundColor Cyan

            # Fall through to the normal region search below
            $regions = $regions | Where-Object { $_ -ne $Location }
        }
    }

    # Only run the full search if we haven't already found a region above
    if (-not $selectedRegion) {
        foreach ($region in $regions) {
            $found = Get-AzComputeResourceSku -Location $region | 
                Where-Object { 
                    $_.ResourceType -eq 'virtualMachines' -and 
                    $_.Restrictions.Count -eq 0 -and
                    ($_.Name -eq 'Standard_B1s' -or
                    $_.Name -eq 'Standard_B2s' -or
                    $_.Name -eq 'Standard_B1ms' -or
                    $_.Name -eq 'Standard_DS1_v2' -or
                    $_.Name -eq 'Standard_D2s_v3')
                } | Select-Object -First 1

            if ($found) {
                $selectedRegion = $region
                $selectedSize   = $found.Name
                Write-Host "Found available size '$selectedSize' in '$selectedRegion'." -ForegroundColor Green
                break
            } else {
                Write-Host "$region - nothing available" -ForegroundColor Red
            }
        }
    }

    # Stop the script if nothing found anywhere
    if (-not $selectedRegion) {
        throw "No available VM sizes found across any target region. Try again later."
    }


    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create Lab Environment')) {
    # all your creation code here
        # 1. Creates a new Resource Group 
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-Host "Creating resource group '$ResourceGroupName'..." -ForegroundColor Cyan
            New-AzResourceGroup -Name $ResourceGroupName -Location $selectedRegion | Out-Null
        } else {
            Write-Host "Resource group '$ResourceGroupName' already exists. Using existing." -ForegroundColor Yellow
        }

        # 2. Creates the Subnet 
        $subnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix

        # 3. Virtual Network (VNet) - The network that everything connects to. Needs the resource group to exist first.
        # Step 3 — VNet with idempotency check
        $vNet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

        if (-not $vNet) {
            Write-Host "Creating VNet '$VNetName'..." -ForegroundColor Cyan
            $vNet = New-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -Location $selectedRegion -AddressPrefix $VNetAddressPrefix -Subnet $subnet
        } else {
            Write-Host "VNet '$VNetName' already exists. Using existing." -ForegroundColor Yellow
        }

        # 4. Network Security Group (NSG) - Defines the firewall rules. Needs the resource group but not the VNet — however you associate it with the subnet so build it before the NIC.
        $nsg = Get-AzNetworkSecurityGroup -Name "$ResourceGroupName-NSG" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $nsg) {
            Write-Host "Creating NSG..." -ForegroundColor Cyan
            $nsg = New-AzNetworkSecurityGroup -Location $selectedRegion -Name "$ResourceGroupName-NSG" -ResourceGroupName $ResourceGroupName
            # Add RDP inbound traffic rule for the NSG
            $nsg | Add-AzNetworkSecurityRuleConfig -Name 'Allow-RDP' -Protocol 'Tcp' -Direction 'Inbound' -Priority 1000 -SourceAddressPrefix 'Internet' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389 -Access 'Allow' | Set-AzNetworkSecurityGroup | Out-Null 
        } else {
            Write-Host "NSG already exists. Using existing." -ForegroundColor Yellow
        }

        # 5. Public IP Address - Standalone resource but gets attached to the NIC. Build it before the NIC so you have the ID ready.
        $publicIp = Get-AzPublicIpAddress -Name $PublicIPName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $publicIp) {
            Write-Host "Creating Public IP..." -ForegroundColor Cyan
            $publicIp = New-AzPublicIpAddress -Name $PublicIPName -ResourceGroupName $ResourceGroupName -AllocationMethod $AllocationMethod -Location $selectedRegion -Sku 'Standard'
        } else {
            Write-Host "Public IP already exists. Using existing." -ForegroundColor Yellow
        }

        # 6. Network Interface (NIC) - Needs the subnet, NSG, and public IP to already exist because it references all three when created.
        $vNic = Get-AzNetworkInterface -Name $VNICName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $vNic) {
            Write-Host "Creating NIC..." -ForegroundColor Cyan
            $vNic = New-AzNetworkInterface -Name $VNICName -ResourceGroupName $ResourceGroupName -Location $selectedRegion -SubnetId $vNet.Subnets[0].Id -PublicIpAddressId $publicIp.Id -NetworkSecurityGroupId $nsg.Id
        } else {
            Write-Host "NIC already exists. Using existing." -ForegroundColor Yellow
        }

        # 7. VM Config - This is just a local PowerShell object — nothing gets created in Azure yet. It's the blueprint you build up in memory before deployment. No Azure dependencies, but logically build it after the NIC so you have the NIC ID ready to attach.
        $vmConfig = New-AzVMConfig -VMName $VMName -VMSize $selectedSize
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VMName -Credential $VMCredential -EnableAutoUpdate
        $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2022-datacenter-azure-edition' -Version 'latest'
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name "$ResourceGroupName-Disk" -CreateOption 'FromImage' -StorageAccountType 'Standard_LRS'
        $vmConfig = Set-AZVMSecurityProfile -VM $vmConfig -SecurityType 'Standard'
        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
        $vmConfig = add-AzVMNetworkInterface -VM $vmConfig -Id $vNic.Id

        try {
            # 8. New-AzVM - The actual deployment. Sends the completed blueprint to Azure and builds the VM. Everything above must exist first.
            New-AzVM -ResourceGroupName $ResourceGroupName -Location $selectedRegion -VM $vmConfig -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

            # Displays setup info to the screen before the script ends so you know and can provide fo the teardown script etc
            Write-Host "============================================" -ForegroundColor Green
            Write-Host " Lab Environment Ready" -ForegroundColor Green
            Write-Host "============================================" -ForegroundColor Green
            Write-Host " VM Name:    $VMName"
            Write-Host " Public IP:  $($publicIp.IpAddress)"
            Write-Host " RDP:        mstsc /v:$($publicIp.IpAddress)"
            Write-Host " Location:   $selectedRegion"
            Write-Host " Started:    $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            Write-Host "============================================" -ForegroundColor Green
            Write-Host " Remember to run Remove-WakandaAZVM.ps1 when done!" -ForegroundColor Yellow
        } catch {
            Write-Host "VM deployment failed: $_" -ForegroundColor Red
            Write-Host "Partial resources may exist — run Remove-WakandaAZVM.ps1 to clean up." -ForegroundColor Yellow
        }

    }

}

