> **Sanitized for public repo:** the original terminal output below showed the
> real Azure account email used for this lab and the real public IP address
> that got assigned to the VM during the session. Both are replaced with
> `[placeholder]` values here — swap in your own account email and whatever
> IP your own deployment gets assigned, not the originals from this repo.

# Building a VM in Azure (Updating an Outdated Lab Along the Way)

## Project Overview

This write-up documents the development of _New-WakandaAZVM.ps1_, showing how I modernised the Azure VM deployment chapter from _PowerShell for Sysadmins_ to reflect current Azure practices.

Although the overall workflow described in the book remains valid, Azure and the Az PowerShell modules have evolved considerably since the book was published. This project updates the deployment process to reflect current Azure practices while documenting the engineering decisions made along the way.

---

**Technologies:**
- Azure
- PowerShell
- Az PowerShell
- Microsoft Entra ID
- Azure Virtual Networking
- Windows Server 2022

**Skills demonstrated:**
- Infrastructure automation
- Infrastructure as Code principles
- Azure networking
- PowerShell scripting
- Idempotent script design
- Cost optimisation
- Troubleshooting cloud infrastructure

---

So. Authentication was done. Service principal existed. Scripts were clean. I had momentum, a book, and the unearned confidence of someone who hadn't yet tried to provision a VM in Azure using a 2020 textbook in 2025.

"How hard can spinning up a VM be?"

Reader. I was not prepared.

---

## The Plan (Before Reality Intervened)

The book laid it out like a recipe. Follow the steps, get a VM. Straightforward infrastructure work.

What followed was roughly four sessions, seventeen failed attempts, five distinct Azure error types I'd never seen before, a deprecated parameter, a storage account I didn't need and couldn't create anyway, a capacity crisis affecting multiple continents, and one very satisfying moment when the summary block finally printed a real public IP address.

But first — I needed to understand what I was actually building.

---

## The Dependency Chain (The Thing the Book Glossed Over)

Before Azure will give you a VM, you have to build an entire neighbourhood for it. You can't just go "here's a VM, put it somewhere" — it wants to know exactly where it's going, what network it's on, who it's allowed to talk to, what its name is, and how big its disk is before it'll even consider booting Windows.

I worked out the correct order of operations *before* running anything — which, after previous sessions of running things in the wrong order and watching errors cascade, felt like genuine progress:

1. **Resource Group** — the container. Free. Delete it and everything inside dies with it. Very useful design feature.
2. **Subnet Config** — define the address range before the network exists. This is just a local PowerShell object at this point, nothing in Azure yet.
3. **Virtual Network** — the actual network. References the subnet config.
4. **Network Security Group** — the firewall. Needs at least one rule or your VM exists in Azure and is completely unreachable, which is impressive in its own way.
5. **Public IP Address** — so you can actually connect to the thing.
6. **Network Interface** — wires together the subnet, NSG, and public IP. The VM plugs into this.
7. **VM Config** — a local PowerShell object describing what you want. Nothing deployed yet. Just a blueprint.
8. **New-AzVM** — the actual deployment. Send the blueprint, wait, hope.

The book had steps 2 and 3 swapped. It also didn't mention the NSG. It also required a storage account that no longer needs to exist. Good book, though.

---

## The Storage Account That Wasn't Needed

The book's VM creation required a storage account — specifically to store the VM disk as a VHD blob file. This was how Azure worked in 2020. You needed somewhere to store the virtual hard drive.

Tried to create one. Got `NotFound`. Tried seventeen different names — `powershellforsysadmins`, `powershellforsysadmins-gf`, `gf-wakanda-e_us`, variations of every combination I could think of. Got `NotFound` seventeen times. Checked the resource group — fine. Checked the context — fine. Checked my sanity — inconclusive.

Eventually ran `Get-AzStorageAccountNameAvailability` to test if the name was taken. Got `NotFound` on that too — which meant the problem wasn't the name at all. It was a resource provider registration issue.

Fixed the provider registration. Still couldn't create it.

At which point I learned that **managed disks exist** and the entire storage account step is completely unnecessary. Azure manages the disk for you now. Has done since roughly 2017.

The book just hadn't caught up.

Deleted all the failed storage account attempts, removed the step entirely from the build sequence, moved on. Vindicated and slightly annoyed simultaneously.

---

## The Public IP That Costs Money While You're Asleep

Next discovery: the book specified `-AllocationMethod 'Dynamic'` for the public IP. Azure returned:

```
Standard SKU publicIp must have AllocationMethod set to Static.
```

Because Microsoft changed the default SKU for public IPs from Basic to Standard sometime after the book was printed. Basic accepted Dynamic. Standard doesn't. The help documentation shows both as valid options — because they are, just not for the same SKU.

Fix: add `-Sku 'Standard'` and change to `'Static'`.

After a bit of digging, I realised another implication of that change: a Standard Static public IP **costs money whether the VM is running or not**. Azure is holding that IP address reserved for you. The meter runs the whole time.

This led directly to a design decision I'm proud of: **make the whole lab ephemeral**. No persistent public IPs sitting around. No idle costs between sessions. Build script provisions everything including the IP. Teardown script nukes the resource group. Nothing exists between sessions.

The build script prints a reminder at the end:
```
Remember to run **Remove-WakandaAZVM.ps1** when done!
```

Cost management as a design principle, not an afterthought.

---

## TrustedLaunch and the Image Wars

With networking sorted, it was time to actually deploy the VM. The book suggested Windows Server 2012 R2 Datacenter.

2012 R2. Which reached end of support in October 2023. Which has had no security patches since then. Which I'd be connecting to over the public internet with RDP exposed.

That wasn't a route I wanted to take.

Switched to Windows Server 2022 Datacenter. Azure immediately complained that TrustedLaunch wasn't supported for that image. Switched to a Gen2 SKU. Azure complained about TrustedLaunch again, differently. Tried removing the security profile entirely. Azure applied TrustedLaunch anyway because it's now the default and apparently quite committed to it.

Eventually registered the `UseStandardSecurityType` feature on the subscription, which unlocked the ability to explicitly set `SecurityType 'Standard'` — telling Azure to stop being clever about security settings and just build the VM I asked for.

The image that actually worked: `2022-datacenter-azure-edition`. The version of Server 2022 specifically optimised for Azure. The one I probably should have started with six attempts ago.

---

## The Capacity Crisis (Or: Azure Ran Out of Small VMs)

With every parameter correct, the right image selected, the security profile sorted, and the network fully configured, I ran `New-AzVM`.

```
The requested VM size 'Standard_B1s' is currently not available in location 'eastus'.
```

Checked UK South. Nothing. East US 2. Nothing. North Europe, West Europe, West US. Nothing. Ran a loop across twelve regions checking every small B-series size.

Every B-series VM. Every region. Restricted.

Azure had simply run out of small VMs. Across multiple regions. Simultaneously. This is apparently a thing that happens — cloud capacity is finite, free-tier sizes are popular, and sometimes the answer is just "try again later."

The correct engineering response — rather than refreshing and hoping — was to build the availability check into the script itself. Before deploying anything, the function now:

1. Checks the preferred region first if one was specified
2. If unavailable, waits 10 seconds with a cancel prompt
3. If no input, falls back to automatic region selection across a wider list
4. Hard stops with a clear error if nothing is available anywhere

```
Waiting 10 seconds — press N to cancel, or just wait to continue...
```

No input? Carries on automatically. Running unattended in a pipeline? Carries on. You're there and you specifically need that region? Press N and it stops cleanly.

That's a real automation design pattern — unattended by default, human override when present. Not a hack.

The size that eventually worked when capacity returned: `Standard_D2s_v3` in `ukwest`. Not free tier, but about £0.30 for a full lab session — acceptable to unblock the project and validate the scripts.

---

## The Script That Almost Worked (And Then Actually Did)

First real deployment attempt with the complete script hit a new problem: the VNet already existed in `eastus` from a previous session. The script tried to create another VNet with the same name in ukwest, and Azure quite rightly rejected it.

```
A resource with the same name cannot be created in location 'ukwest'.
```

That one error caused three downstream failures in sequence: `$vNet` was null, so `$vNet.Subnets[0].Id` was null, so the NIC failed, so `$vNic` was null, so the VM had no network profile. The summary block printed anyway — because the errors were non-terminating and PowerShell just kept going — reporting a successful deployment that hadn't happened.

Classic error cascade. One failure, three consequences, misleading output.

The fix was idempotency checks on every resource — the same pattern used on the resource group from the start:

```powershell
$vNet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $vNet) {
    Write-Host "Creating VNet '$VNetName'..." -ForegroundColor Cyan
    $vNet = New-AzVirtualNetwork ...
} else {
    Write-Host "VNet '$VNetName' already exists. Using existing." -ForegroundColor Yellow
}
```

Same pattern for NSG, Public IP, and NIC. If it exists, use it. If it doesn't, create it. Safe to run against a fresh environment or a partially built one.

The VM creation itself was wrapped in try/catch with `-ErrorAction Stop` — so if `New-AzVM` fails, it fails loudly and immediately rather than silently continuing to the success summary.

---

## What the Final Output Looks Like

After all of that — the outdated book, the deprecated parameters, the storage accounts, the TrustedLaunch saga, the capacity crisis, the cascade errors — here's what the script produces when it works:

```
Connected as: [YOUR_AZURE_ACCOUNT_EMAIL]
Subscription: Azure subscription 1
Preferred region 'ukwest' specified - checking availability...
Preferred region 'ukwest' is available. Using 'Standard_D2s_v3'.
Creating resource group 'PowerShellForSysAdmins-RG'...
Creating VNet 'PowerShellForSysAdmins-vNet'...
Creating NSG...
Creating Public IP...
Creating NIC...
============================================
 Lab Environment Ready
============================================
 VM Name:    WakandaVM
 Public IP:  [YOUR_VM_PUBLIC_IP]
 RDP:        mstsc /v:[YOUR_VM_PUBLIC_IP]
 Location:   ukwest
 Started:    2026-05-09 15:09
============================================
 Remember to run **Remove-WakandaAZVM.ps1** when done!
```

And the teardown:

```
Connected as: [YOUR_AZURE_ACCOUNT_EMAIL]
The following resource group and ALL resources inside it will be deleted:
  PowerShellForSysAdmins-RG (ukwest)

Name                           ResourceType
----                           ------------
PowerShellForSysAdmins-vNet    Microsoft.Network/virtualNetworks
PowerShellForSysAdmins-RG-NSG  Microsoft.Network/networkSecurityGroups
PowerShellForSysAdmins-PubIp   Microsoft.Network/publicIPAddresses
PowerShellForSysAdmins-vNIC    Microsoft.Network/networkInterfaces
WakandaVM                      Microsoft.Compute/virtualMachines
PowerShellForSysAdmins-RG-Disk Microsoft.Compute/disks

Type 'yes' to confirm deletion: yes
Removing resource group 'PowerShellForSysAdmins-RG'...
Done. All resources deleted.
```

Clean. Deliberate. Nothing left running.

---

## What Actually Got Built

**`New-WakandaAZVM.ps1`**
Provisions a complete Azure lab environment. Validates session context, checks VM size availability across multiple regions with user override support, creates all dependencies idempotently, deploys the VM, suppresses noise, prints a clean connection summary. Supports `-WhatIf` for dry runs. The script is designed to be safely re-run, making iterative lab development possible without requiring manual cleanup between executions.

**`Remove-WakandaAZVM.ps1`**
Tears it all down. Lists exactly what will be deleted, requires typing `yes`, removes the resource group and everything in it. One command, clean slate, zero idle cost. Also supports `-WhatIf`.

Both have full comment-based help. `Get-Help New-WakandaAZVM -Full` and `Get-Help New-WakandaAZVM -Examples` both work properly.

---

## What This Phase Actually Taught Me

Every error was Azure pointing me towards the current implementation rather than the implementation described in the book. The book shows you how things worked in 2020. The errors show you how things work now. The skill is reading the error, understanding why the thing changed, and finding the right answer — not just copying the next line from the book.

The things that changed since the book was printed:
- `-Password` on app registration → `New-AzADAppCredential` separately  
- Dynamic public IPs → Static + Standard SKU (with cost implications)
- VHD blobs in storage accounts → managed disks (storage account not needed)
- Windows Server 2012 R2 → 2022 Azure Edition (security matters)
- Hardcoded VM size → availability check across regions
- `Get-Credential` inline → typed `PSCredential` parameter
- Non-terminating errors → `try/catch` with `-ErrorAction Stop`
- Single resource creation → idempotent checks throughout

None of those are in the book. All of them are now in the script, with comments explaining why.

The lab is ephemeral by design, cost-conscious by necessity, idempotent throughout, and documented well enough that I can explain every engineering decision in an interview without needing to refer back to the code.

Which is, honestly, the whole point.

---

## What's Next

The infrastructure layer is in place. Next comes the operational automation: health checks, service monitoring, log parsing, and patch compliance reporting. The scripts that make the VM useful rather than just the scripts that make the VM exist.

On to the next challenge...

---

*Part of the [Cloud Infrastructure Lab](https://github.com/GeorgeF37/cloud-infrastructure-lab) — building real infrastructure automation skills, one Azure error message at a time.*
