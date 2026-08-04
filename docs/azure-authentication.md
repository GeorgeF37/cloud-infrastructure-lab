# Setting Up Azure Authentication (And Updating an Outdated Lab)

## Project Overview

This write-up documents how I modernised the Azure authentication examples from _PowerShell for Sysadmins_ while building my Cloud Infrastructure Lab.

Rather than simply reproducing the book's examples, I updated the implementation to work with the current Az modules and Microsoft Graph-backed authentication model, documenting the issues encountered and the reasoning behind each change.

---

**Technologies:**
- Azure
- PowerShell
- Az Module
- Microsoft Entra ID
- Service Principals

**Skills demonstrated:**
- Infrastructure automation
- Azure authentication
- Identity and access management
- PowerShell scripting
- Troubleshooting outdated implementations
- Secure credential handling

--- 

So I've been working through _PowerShell for Sysadmins_ while building out my own cloud infrastructure lab. The goal is to transition from IT support into infrastructure engineering, and I figured the best way to learn was to build and troubleshoot real systems rather than only consuming tutorials.

This write-up documents how I implemented Azure authentication using the current Az modules after discovering several examples in the book no longer worked as written. Although the overall approach was still valid, several cmdlets and parameters had changed since publication.

My objective wasn't simply to get authentication working. I wanted to understand not only which commands worked, but why the underlying authentication model was designed the way it is, so I could build repeatable infrastructure automation on top of it.

---

## First, What Even Is a Service Principal?

Before I get into the chaos, the concept that really made everything else fall into place was understanding what a service principal actually is.

When you automate stuff in Azure, you don't want your scripts authenticating as _you_. That's rarely appropriate outside testing because your personal account usually has far broader permissions than the automation actually requires. If the script is compromised, the attacker effectively inherits your identity.

A service principal is best thought of as a service account for your application or automation. It's a non-human identity that lives in Entra ID (formerly Azure AD). You give it only the permissions it needs to do its job, nothing more. This is the **least privilege principle** — a core security concept that basically means don't give anything more access than it actually needs.

So the goal was:

1. Create an app registration in Entra ID
2. Create a service principal from that app
3. Generate credentials for it
4. Assign it a role so it can actually do things
5. Connect to Azure _as_ that service principal instead of as me

Simple enough. Except the book had other ideas.

---

## When the Documentation No Longer Matches Reality

The first thing the book told me to do was this:

```powershell
$secPassword = ConvertTo-SecureString -AsPlainText -Force -String 'password'
$myApp = New-AzADApplication -DisplayName AppForServicePrincipal `
    -IdentifierUris 'http://someurl' -Password $secPassword
```

Ran it. Got this back:

```powershell
New-AzADApplication: Cannot process argument transformation on parameter 
'PasswordCredentials'. Cannot convert value "System.Security.SecureString" 
to type "IMicrosoftGraphPasswordCredential[]"
```

Right. So the book is using an old version of the Az module that predates Microsoft's switch to the MS Graph API. The `-Password` parameter flat out doesn't work like that anymore. Cloud platforms evolve much faster than printed material, so encountering outdated examples is simply part of working with cloud technologies. The valuable skill isn't memorising commands, it's understanding why something changed and adapting to the current implementation.

---

## What Actually Works (The Modern Approach)

Here's what I ended up doing instead:

```powershell
# Step 1 — Create the app registration
$myApp = New-AzADApplication -DisplayName 'wakanda-gfad-app'

# Step 2 — Create the service principal from the app
$sp = New-AzADServicePrincipal -ApplicationId $myApp.AppId

# Step 3 — Generate a credential separately (this is what changed)
$secCred = New-AzADAppCredential `
    -ApplicationId $myApp.AppId `
    -EndDate (Get-Date).AddYears(1)

# Step 4 — Grab the secret NOW — Azure won't show you this again
$secSecret = $secCred.SecretText
```

That last point is important. **Azure only displays the client secret once.** If you close the session without saving it, it's gone and you'll need to generate a new one. I found this out the slightly stressful way. Save it to a password manager immediately — I use a secure note.

---

## The Role Assignment Trap

Once the service principal existed, I needed to assign it a role so it could actually interact with Azure resources. The command for that is `New-AzRoleAssignment`.

Here's where I hit a classic gotcha.

```powershell
# This doesn't work
New-AzRoleAssignment -ApplicationId $myApp.Id -RoleDefinitionName "Contributor" `
    -Scope "/subscriptions/$subId"

# Error: 'PrincipalId' cannot be null.
```

The fix was one property name. `$myApp.Id` is the internal object ID of the _app registration_. What Azure wants for a role assignment is the object ID of the _service principal_ — which is a different thing. Easy to mix up, and a useful reminder that similar-looking object IDs in Azure don't always represent the same thing.

The correct approach:

```powershell
# Get the service principal's object ID explicitly
$spObjectId = (Get-AzADServicePrincipal -ApplicationId $myApp.AppId).Id
$subId = (Get-AzContext).Subscription.Id

New-AzRoleAssignment `
    -ObjectId            $spObjectId `
    -RoleDefinitionName  'Contributor' `
    -Scope               "/subscriptions/$subId"
```

Contributor gives the service principal the ability to create and manage resources without being able to change access permissions. Good enough for a lab. In a real environment you'd be more specific about scope.

---

## Actually Connecting as the Service Principal

With all of that done, the test connection looks like this:

```powershell
$tenantId = (Get-AzContext).Tenant.Id

$cred = New-Object System.Management.Automation.PSCredential(
    $myApp.AppId,
    (ConvertTo-SecureString $secSecret -AsPlainText -Force)
)

Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId
```

When it comes back showing `AccountType: ServicePrincipal`, that's it. That's the whole thing. The script is now authenticating as its own identity, not mine — which is exactly what you want for any kind of automated, unattended execution.

---

## Handling Secrets Securely

Persisting secrets to disk may be acceptable for demonstrating a concept in a controlled lab, but I wouldn't recommend it for real-world automation.

```powershell
# What the book says to do
$secPassword | ConvertFrom-SecureString | Out-File -FilePath C:\AzureAppPassword.txt
```

Writing credentials to a plain text file on disk is the kind of thing that gets you a very uncomfortable conversation with your security team.

|Option|When to use it|
|---|---|
|Password manager|Personal lab — this is what I do|
|Environment variable|Local dev scripts|
|Azure Key Vault|Production automation|
|Plain text file|Avoid where possible|

The `$env:AZURE_CLIENT_SECRET` environment variable approach is what my `azureAuthentication.ps1` script uses — the script reads the secret from the environment at runtime, so nothing sensitive is ever hardcoded or sitting in a file somewhere.

---

## The Final Script

All of this got packaged into `azureAuthentication.ps1` — split into two regions:

- **One-time setup** — create the app, service principal, credentials, role assignment. Run once, comment out, never run again.
- **Reusable auth block** — what goes at the top of any script that needs an authenticated Azure session. Reads from environment variables, builds the credential object, connects.

By the time I'd finished the chapter, I'd updated several parts of the implementation to reflect the current Az modules and modern security practices. That included adapting the authentication flow for the Microsoft Graph-backed Az modules, correcting deprecated cmdlets and property usage, and replacing plaintext secret storage with environment variable-based authentication.

---

## Key Concepts Worth Remembering

|Term|What it actually is|
|---|---|
|**App Registration**|An identity object in Entra ID — like creating a user account for your script|
|**Service Principal**|The security entity that gets permissions — the "local instance" of the app in your tenant|
|**Client Secret**|The password the service principal uses to authenticate|
|**Tenant ID**|Your Azure organisation's unique ID|
|**Subscription ID**|The billing/resource container you're working in|
|**Least Privilege**|Only give something the permissions it actually needs. Then less than that.|

---

## Lessons Learned

Building this wasn't just about making Azure authentication work. It reinforced several lessons that apply well beyond this project:

- Cloud tooling changes frequently, so understanding concepts matters more than memorising commands.
- Identity is a core part of infrastructure automation and should be designed using least-privilege principles.
- Secure credential management should be considered from the beginning, even in personal projects.
- Good automation is repeatable, predictable, and documented well enough that someone else can understand and maintain it.

---

## What's Next

This authentication layer became the foundation for the rest of the lab. Every subsequent automation script authenticates using the same service principal, allowing infrastructure to be provisioned securely without embedding personal credentials or requiring interactive logins.

The goal of this project isn't simply to build a collection of PowerShell scripts—it's to develop the habits I'd use in production: repeatable automation, secure authentication, clear documentation, and infrastructure that's easy to maintain and extend.

The next stage is expanding the lab with VM deployment, networking, infrastructure validation, and eventually Terraform as I move from imperative scripting towards declarative infrastructure management.

On to the next challenge...

---

_Part of the [Cloud Infrastructure Lab](https://github.com/GeorgeF37/cloud-infrastructure-lab) project — building real infrastructure automation skills from IT support to infrastructure engineer._
