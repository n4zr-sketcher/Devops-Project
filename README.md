# Automated Deployment of a Web Application using CI/CD, Terraform, Azure and Jenkins

A complete, end-to-end DevOps project. The infrastructure on Microsoft Azure is created
**as code** with Terraform, and a **Jenkins** pipeline automatically deploys a responsive
web application to an **Ubuntu** VM running **Nginx** every time code is pushed to **GitHub**.

> **Status:** the code in this repository is complete and ready to run. The sections marked
> *"Expected output"* show what a successful run looks like - they are illustrative
> examples, not captured results. Replace them with your own screenshots and console
> output as you execute each phase (see the *Screenshots checklist* at the end).

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Repository structure](#2-repository-structure)
3. [Prerequisites](#3-prerequisites)
4. [Phase A - Provision the Azure infrastructure with Terraform](#phase-a---provision-the-azure-infrastructure-with-terraform)
5. [Phase B - Preview the web application locally](#phase-b---preview-the-web-application-locally)
6. [Phase C - Install and configure Jenkins](#phase-c---install-and-configure-jenkins)
7. [Phase D - Configure GitHub and the Jenkins credentials](#phase-d---configure-github-and-the-jenkins-credentials)
8. [Phase E - Run the pipeline for the first time](#phase-e---run-the-pipeline-for-the-first-time)
9. [Phase F - Make the deployment automatic](#phase-f---make-the-deployment-automatic)
10. [Testing checklist](#testing-checklist)
11. [Troubleshooting](#troubleshooting)
12. [Cleaning up and stopping the cloud costs](#cleaning-up-and-stopping-the-cloud-costs)
13. [Security notes](#security-notes)
14. [Screenshots checklist](#screenshots-checklist)

---

## 1. Architecture

```
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  DEVELOPER LAPTOP (Windows)                                            │
   │                                                                         │
   │   Git ──push──▶ ┌──────────────────┐                                   │
   │                 │     GitHub        │  ◀── source of truth              │
   │                 └────────┬─────────┘                                   │
   │                          │                                             │
   │                          │ webhook  or  Poll SCM (every 1 min)         │
   │                          ▼                                             │
   │   ┌──────────────────────────────────────────────────────────────┐      │
   │   │  JENKINS CONTROLLER   (Docker container, localhost:8080)    │      │
   │   │                                                              │      │
   │   │  Checkout ▶ Validate ▶ Test ▶ Deploy ▶ Reload ▶ Verify        │      │
   │   │                                     │                        │      │
   │   │                            scp / ssh (TCP 22, key auth)     │      │
   │   └─────────────────────────────────┬────────────────────────────┘      │
   └─────────────────────────────────────┼───────────────────────────────────┘
                                         ▼
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  MICROSOFT AZURE   (created entirely by `terraform apply`)              │
   │                                                                         │
   │   Resource Group: rg-devops-cicd                                       │
   │   ├── Virtual Network  10.0.0.0/16                                     │
   │   │    └── Subnet      10.0.1.0/24                                     │
   │   │         ├── NSG:  22/tcp ← ONLY your public IP                      │
   │   │         │         80/tcp ← internet                                │
   │   │         │         22/tcp ← denied from everywhere else             │
   │   │         ├── Public IP (Standard SKU, static)                       │
   │   │         ├── Network Interface                                      │
   │   │         └── Ubuntu 22.04 VM  →  Nginx  →  /var/www/app  (live)      │
   │   │                                  └── /var/www/releases/  (history)  │
   │   └── (cloud-init installs + configures Nginx on first boot)           │
   └─────────────────────────────────┬───────────────────────────────────────┘
                                     ▼
                          ┌──────────────────────┐
                          │  Browser / visitor   │
                          │  http://<public-ip>  │
                          └──────────────────────┘
```

### How a single push travels through the system

| # | Location | What happens |
|---|----------|--------------|
| 1 | Your laptop | `git push` sends the commit to GitHub |
| 2 | GitHub | The repository stores the commit and notifies Jenkins (webhook or Poll SCM) |
| 3 | Jenkins | **Checkout** - clones the commit using a stored GitHub token |
| 4 | Jenkins | **Validate** - asserts `index.html`, `style.css`, `script.js` exist |
| 5 | Jenkins | **Test** - HTML structure, CSS brace balance, `node --check` on the JavaScript, no `console.log` |
| 6 | Jenkins → VM | **Deploy** - `scp` uploads `app/` and `scripts/deploy.sh` to `/tmp/cicd-build/build-<n>/` |
| 7 | Azure VM | **Reload** - `deploy.sh` stages a new release, validates `nginx -t`, swaps the symlink, reloads Nginx gracefully |
| 8 | Jenkins | **Verify** - HTTP request to the live URL must return 200 and the current build number |

---

## 2. Repository structure

```
azure-terraform-jenkins-cicd/
├── app/                                  # The web application (deployed to the VM)
│   ├── index.html
│   ├── style.css
│   └── script.js
├── terraform/                            # Infrastructure as Code
│   ├── provider.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── cloud-init.yml.tftpl              # Nginx bootstrap (Terraform template)
│   ├── terraform.tfvars.example          # safe template - committed
│   └── terraform.tfvars                   # real values - GIT IGNORED
├── scripts/
│   ├── deploy.sh                         # runs ON the VM to publish a release
│   └── update-ssh-cidr.ps1               # refreshes your IP in terraform.tfvars
├── jenkins/
│   ├── Dockerfile                        # Jenkins image + ssh/curl/node tools
│   └── docker-compose.yml                # controller on localhost:8080
├── docs/
│   └── PROJECT_REPORT.md                 # the college report
├── Jenkinsfile                           # the CI/CD pipeline
├── README.md                             # this file
└── .gitignore
```

---

## 3. Prerequisites

| Requirement | Version used | Notes |
|-------------|--------------|-------|
| Windows 11 / 10 | - | The developer machine |
| Git | 2.50+ | `git --version` |
| Terraform | 1.16.6 | `terraform version` |
| Azure CLI | 2.91.0 | `az version` |
| Java (JDK) | Temurin 17 | Only needed if you run Jenkins without Docker |
| Docker Desktop | 29.x | Runs the Jenkins controller |
| GitHub account | - | <https://github.com> |
| Azure subscription | - | <https://azure.microsoft.com/free/> or Azure for Students |

### Cost warning

The Azure Virtual Machine, its managed disk and the public IP are **billed continuously**
until you run `terraform destroy`. Everything else in this project (GitHub, Jenkins,
Terraform, the web app) is free. Keep the VM only for as long as you need the demo and
always finish with the cleanup steps in section 12.

---

## Phase A - Provision the Azure infrastructure with Terraform

> **Where:** Windows PowerShell on your laptop.

### A.1 Authenticate to Azure

```powershell
az login
az account list --output table
az account set --subscription "<Your Subscription Name>"
```

*Expected output* (example):

```
┌───────────────┬──────────────────────┬──────────────┬───────────┬────────┐
│    Name       │         Id           │    State    │ IsDefault │  Tenant │
├───────────────┼──────────────────────┼──────────────┼───────────┼────────┤
│ Azure for ... │ 00000000-0000-...    │ Enabled     │ True      │  ...    │
└───────────────┴──────────────────────┴──────────────┴───────────┴────────┘
```

### A.2 Create the real variable file and add your SSH key

```powershell
cd "C:\Users\abijo\OneDrive\Desktop\DEV_OPS_PROJECT\azure-terraform-jenkins-cicd\terraform"

Copy-Item .\terraform.tfvars.example .\terraform.tfvars
```

Generate the SSH key pair that Jenkins will use (**do this only once**):

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\azure_cicd_vm" -N '""' -C "azure-cicd-deploy"
```

> The empty passphrase (`-N '""'`) is deliberate: Jenkins then needs no SSH agent and no
> passphrase prompt. The **private** key stays in `%USERPROFILE%\.ssh\` and is never
> committed. The **public** key goes into `terraform.tfvars`.

Paste your public key into `terraform.tfvars`:

```powershell
$pub = Get-Content "$env:USERPROFILE\.ssh\azure_cicd_vm.pub" -Raw
(Get-Content .\terraform.tfvars -Raw) -replace 'ssh_public_key\s*=\s*"[^"]*"', ('ssh_public_key = "' + $pub.Trim() + '"') | Set-Content .\terraform.tfvars
```

Set the SSH source rule to your current public IP:

```powershell
powershell -ExecutionPolicy Bypass -File ..\scripts\update-ssh-cidr.ps1
```

### A.3 Run the Terraform lifecycle

```powershell
terraform init          # download the AzureRM provider
terraform fmt -recursive # normalise the formatting
terraform validate      # syntax and type check
terraform plan          # preview - READ THIS, it lists everything that will be created
terraform apply         # create the resources (this starts costing money)
```

*Expected output* (example, `terraform apply`):

```
azurerm_resource_group.main: Creating...
azurerm_virtual_network.main: Creating...
azurerm_network_security_group.main: Creating...
azurerm_public_ip.main: Creating...
azurerm_network_interface.main: Creating...
azurerm_linux_virtual_machine.main: Creating...
azurerm_linux_virtual_machine.main: Still creating... [10s elapsed]
...
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.
```

### A.4 Read the outputs

```powershell
terraform output
```

*Expected output* (example - your values will differ):

```
public_ip_address = "20.55.1.2"
http_url          = "http://20.55.1.2"
ssh_command       = "ssh -i ~/.ssh/azure_cicd_vm azureuser@20.55.1.2"
```

### A.5 Verify the VM

Open `http://<public_ip>/` in your browser - you should see the placeholder page
("Terraform bootstrap complete"). The health endpoint returns `ok`:

```powershell
curl.exe http://<public_ip>/health
```

If the page does not appear, the cloud-init script may still be running. Watch it with:

```powershell
ssh -i "$env:USERPROFILE\.ssh\azure_cicd_vm" azureuser@<public_ip> "sudo tail -n 40 /var/log/cloud-init-output.log"
```

---

## Phase B - Preview the web application locally

> **Where:** Windows PowerShell. Optional, but it lets you polish the design before
> you ever spend Azure credit.

```powershell
cd "C:\Users\abijo\OneDrive\Desktop\DEV_OPS_PROJECT\azure-terraform-jenkins-cicd\app"
python -m http.server 8000
```

Open <http://localhost:8000>. The "Deployment status" panel will show *Unavailable*,
because `/health` and `/build-info.txt` only exist on the server. That is expected and
it proves the status panel is really reading from the deployed server.

Stop the server with `Ctrl+C`.

---

## Phase C - Install and configure Jenkins

> **Where:** Windows PowerShell.

### C.1 Start the Jenkins controller

```powershell
cd "C:\Users\abijo\OneDrive\Desktop\DEV_OPS_PROJECT\azure-terraform-jenkins-cicd\jenkins"
docker compose up -d --build
docker compose logs -f
```

The first build downloads the base image (a few hundred MB) and takes several minutes.

### C.2 Open the setup wizard

Open <http://localhost:8080>. The log shows the initial administrator password:

```powershell
docker compose logs jenkins | Select-String "Initial admin password"
```

*Expected output* (example):

```
Jenkins is fully up and running
---------------------
Initial admin password: 3f8a1c92de7b4a5f
```

Paste that password into the wizard and continue. Install the **suggested plugins**,
then create your administrator account (a personal username and password - this is a
local demo, but do not reuse your real banking password).

### C.3 Optional but recommended plugins

Manage Jenkins → Plugins → Available plugins:

| Plugin | Why |
|--------|-----|
| `Pipeline` / `Pipeline: Stage View` | Already bundled; the stage view makes the pipeline readable in your demo |
| `Git` | Required to clone from GitHub |
| `Poll SCM` | Bundled - used for the scheduled trigger |
| `GitHub Branch Source` (optional) | Only needed for a Multibranch pipeline |
| `Timestamper` | Adds the timestamps you enabled in the Jenkinsfile |
| `AnsiColor` | Renders the colours used by `ansiColor('xterm')` |
| `Credentials Binding` | Already bundled - used by `withCredentials` |
| `SSH Agent` / `SSH Build Agents` | Optional. Our pipeline uses *Secret text* credentials instead, so it works without them |

### C.4 Set the global environment variables

Manage Jenkins → System → Global properties (this page is called *Environment
properties* in newer versions) → **Add Environment Variable**, four times:

| Name | Value | Example |
|------|-------|---------|
| `VM_IP` | the public IP of your Azure VM | `20.55.1.2` |
| `VM_USER` | the SSH user | `azureuser` |
| `REMOTE_TMP_DIR` | staging folder on the VM | `/tmp/cicd-build` |
| `REMOTE_APP_DIR` | live web root on the VM | `/var/www/app` |

---

## Phase D - Configure GitHub and the Jenkins credentials

### D.1 Push the project to GitHub

> **Where:** Windows PowerShell, in the project root.

```powershell
cd "C:\Users\abijo\OneDrive\Desktop\DEV_OPS_PROJECT\azure-terraform-jenkins-cicd"

git add .
git status                 # check that terraform.tfstate and *.tfvars are NOT listed
git commit -m "Initial commit: Terraform, web app, Jenkins pipeline"
git branch -M main
git remote add origin https://github.com/<your-username>/azure-terraform-jenkins-cicd.git
git push -u origin main
```

Create the empty repository on GitHub first (New repository → **do not** tick "Add a
README", or the push will be rejected).

### D.2 Create the three Jenkins credentials

Manage Jenkins → **Credentials** → System → Global credentials → Add Credentials.

**1) GitHub token (for cloning)**

* Kind: **Username with password**
* Username: `github` (any non-empty value)
* Password: a GitHub **Personal Access Token** (classic) with scope `repo`
* ID: `github-credentials`

Create the token at <https://github.com/settings/tokens>.

**2) SSH private key**

* Kind: **Secret text**
* Secret: the *entire contents* of `%USERPROFILE%\.ssh\azure_cicd_vm`
  (the file starting with `-----BEGIN OPENSSH PRIVATE KEY-----`)
* ID: `azure-vm-ssh-private-key`

Get it into the clipboard safely with:

```powershell
Get-Content "$env:USERPROFILE\.ssh\azure_cicd_vm" -Raw | Set-Clipboard
```

**3) SSH known hosts**

* Kind: **Secret text**
* Secret: the host key of the Azure VM (one line)
* ID: `azure-vm-known-hosts`

Build the line automatically:

```powershell
$ip = "<your-public-ip>"
$key = (ssh-keyscan -t ed25519 $ip 2>$null)
"${ip} ${key}" | Set-Clipboard
```

> `ssh-keyscan` fetches the VM's real host key over the network, so this is a
> *verified* value - not a blind `StrictHostKeyChecking=no`. The pipeline runs with
> `StrictHostKeyChecking=yes`, so a man-in-the-middle would abort the deployment.

### D.3 Create the pipeline job

Manage Jenkins → New Item → **Pipeline** → name `azure-cicd-deploy` → OK.

Under *Pipeline*, choose **Pipeline script from SCM**:

| Field | Value |
|-------|-------|
| SCM | Git |
| Repository URL | `https://github.com/<your-username>/azure-terraform-jenkins-cicd.git` |
| Credentials | `github-credentials` |
| Branch | `*/main` |
| Script Path | `Jenkinsfile` |

Click **Save**, then **Build Now**.

---

## Phase E - Run the pipeline for the first time

Watch the console output. A successful run looks like this (example):

```
[Pipeline] stage
+ Checkout
  Checked out branch 'main' at commit a1b2c3d
+ Validate
  Validation passed: index.html, style.css, script.js are present and the HTML looks sane.
+ Test
  == Test 1/6: HTML structure ==
     OK - HTML has a doctype, a title and both asset references.
  == Test 2/6: CSS integrity ==
     OK - 128 CSS rules, braces balanced.
  == Test 3/6: JavaScript syntax (node --check) ==
     OK - script.js parses without syntax errors.
  == Test 4/6: no leftover debug statements ==
     OK - no console.log() calls.
  == Test 5/6: required deployment script ==
     OK - scripts/deploy.sh is present.
  == Test 6/6: deployment settings are configured ==
     OK - target azureuser@20.55.1.2
+ Deploy
  Uploading app/ ...
  Uploading scripts/deploy.sh ...
+ Reload
  [deploy] staging release in /var/www/releases/release-20261022101430-4edd
  [deploy] validating nginx configuration
  nginx: configuration file /etc/nginx/nginx.conf test is successful
  [deploy] live symlink now -> /var/www/releases/release-20261022101430-4edd
  [deploy] reloading nginx (graceful, zero downtime)
  [deploy] DEPLOYMENT SUCCESSFUL
+ Verify
  == Verify 1/3: homepage returns HTTP 200 ==
     HTTP 200
  == Verify 2/3: health endpoint answers ==
     health: ok
  == Verify 3/3: the NEW build is the one being served ==
     build_number=1
     build_tag=azure-cicd-deploy
     git_commit=a1b2c3d
     deployed_at_utc=2026-10-22T10:14:31Z
+ PIPELINE SUCCESSFUL - the website is live and verified.
```

Refresh <http://<public-ip>/> - the "Deployment status" panel now shows the real build
number, commit and timestamp.

---

## Phase F - Make the deployment automatic

### F.1 Poll SCM (the default, always works)

The Jenkinsfile is declarative and contains no trigger definition, so add the trigger to
the **job**, not to the file:

1. Open the job `azure-cicd-deploy`
2. **Build Triggers** → tick **GitHub hook trigger for GITScm polling**
3. Click **Advanced...**
4. Tick **Trigger only if the SCM actually changed something**
5. Set the schedule to `* * * * *` (every minute)
6. Save

Now every push is picked up within one minute. This works from a laptop behind a
router, needs no extra software, and is the most reliable option.

### F.2 GitHub webhook (instant triggers)

A GitHub webhook posts to a URL that GitHub can reach from the internet. Your laptop
is not directly reachable, so pick one:

**Option 1 - ngrok (free, recommended for the demo)**

```powershell
winget install --id ngrok.ngrok --exact
ngrok config add-authtoken <YOUR_NGROK_AUTHTOKEN>
ngrok http 8080
```

ngrok prints a public URL such as `https://a1b2c3d4.ngrok-free.app`. Add the webhook:

* GitHub → your repository → **Settings** → **Webhooks** → **Add webhook**
* Payload URL: `https://a1b2c3d4.ngrok-free.app/github-webhook/`
* Content type: `application/json`
* Secret: any random string
* Events: **Just the push event**

Then enable the GitHub plugin inside Jenkins: Manage Jenkins → System → GitHub
Webhook Servers → *Enable GitHub hook trigger for GITScm polling*. Add the same
secret under GitHub → Settings → Webhooks.

**Option 2 - Cloudflare quick tunnel (free, no account)**

```powershell
winget install --id Cloudflare.cloudflared --exact
cloudflared tunnel --url http://localhost:8080
```

The URL changes every time the tunnel restarts, so you must update the webhook
afterwards. Useful for a single demo, not for a permanent setup.

**Option 3 - Run Jenkins on an Azure VM (production-style, costs money)**

Give the Jenkins VM a static public IP and point the webhook at
`http://<jenkins-ip>:8080/github-webhook/`. No tunnel is needed, but you pay for a
second VM.

> **Security note:** whichever option you pick, never expose the Jenkins UI to the
> internet without a firewall, a VPN or Cloudflare Access. A tunnel in front of a
> half-configured Jenkins is a well-known way to have your server taken over.

---

## Testing checklist

Tick each box as you verify it and capture the evidence.

| # | Test | How to verify | Expected result (example) |
|---|------|---------------|---------------------------|
| 1 | Terraform provisions the infrastructure | `terraform output` | 7 resources created, no errors |
| 2 | VM is reachable on SSH | `ssh -i ~/.ssh/azure_cicd_vm azureuser@<ip> "hostname"` | prints the host name |
| 3 | SSH is blocked from another IP | NSG rule 4096 | connection times out |
| 4 | Nginx serves the placeholder | `curl http://<ip>/` | HTTP 200, placeholder page |
| 5 | Health endpoint works | `curl http://<ip>/health` | `ok` |
| 6 | Jenkins can read GitHub | Jenkins job → Build Now | Checkout stage succeeds |
| 7 | Pipeline completes | Build history → green | all six stages green |
| 8 | A push triggers a new build | `git push` | a new build appears within a minute |
| 9 | The new content is live | `curl http://<ip>/` | contains the text you just pushed |
| 10 | Build metadata is published | `curl http://<ip>/build-info.txt` | `build_number=2`, your commit hash |
| 11 | A failed build is reported | temporarily break `app/index.html`, push | the build is red with a clear error; the live site still works |
| 12 | The site survives a failed build | `curl http://<ip>/` | still HTTP 200 with the previous content |
| 13 | No secrets in Git | `git ls-files \| Select-String "tfvars\|tfstate\|id_ed25519"` | no matches |
| 14 | No secrets in the console | search the build log for the key | the key appears as `****` |
| 15 | Zero-downtime reload | keep a browser tab open while deploying | the page never needs a manual refresh |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `az login` fails or the browser does not open | corporate proxy / firewall | try `az login --use-device-code`, or use a Service Principal (section below) |
| `Error: building AzureRM Provider: ... invalid version` | old Terraform | `terraform init -upgrade` |
| `Error: `custom_data` is not expected` | provider v3 vs v4 | this project targets AzureRM `~> 4.0`; run `terraform init -upgrade` |
| `ssh: connect to host <ip> port 22: Connection timed out` | your public IP changed | `powershell -ExecutionPolicy Bypass -File scripts\update-ssh-cidr.ps1` then `terraform apply` |
| `Permission denied (publickey)` | wrong key or wrong `known_hosts` | re-create the credentials in Jenkins; make sure the private key includes the `BEGIN`/`END` lines |
| `Host key verification failed` | the VM was rebuilt, so the host key changed | delete the `azure-vm-known-hosts` credential and recreate it with `ssh-keyscan` |
| `The website still shows the placeholder` | the Deploy stage never ran | open the build log, look for the failing stage |
| `curl: (7) Failed to connect` from the Verify stage | the NSG blocks port 80 from the Jenkins agent's IP | allow port 80 from `0.0.0.0/0` (rule `Allow-HTTP-From-Internet`) |
| Jenkins container cannot reach GitHub | proxy / DNS inside Docker | check `docker compose logs jenkins` for network errors |
| `nginx -t` fails on the VM | a broken site config | the deployment aborts *before* the live symlink is swapped, so the old site stays up |
| The site is slow | `Standard_B1ls` is small | change `vm_size` to `Standard_B2s` in `terraform.tfvars` and `terraform apply` |

### Using a Service Principal instead of `az login`

If `az login` cannot be used (blocked network, or you want the repeatable approach a
CI/CD system uses), create an App Registration in the Azure portal
(**Microsoft Entra ID → App registrations → New registration**), add a client secret,
and grant it **Contributor** on the resource group. Then export:

```powershell
$env:ARM_SUBSCRIPTION_ID = "<subscription id>"
$env:ARM_TENANT_ID       = "<tenant id>"
$env:ARM_CLIENT_ID       = "<application (client) id>"
$env:ARM_CLIENT_SECRET   = "<client secret>"
terraform plan
```

The provider picks these up automatically. Never commit them - set them in the shell
or in the Jenkins credential store only.

---

## Cleaning up and stopping the cloud costs

> **Where:** Windows PowerShell.

```powershell
cd "C:\Users\abijo\OneDrive\Desktop\DEV_OPS_PROJECT\azure-terraform-jenkins-cicd\terraform"

terraform destroy          # asks for confirmation - type "yes"
```

*Expected output* (example):

```
azurerm_linux_virtual_machine.main: Destroying... [2m10s]
azurerm_network_interface.main: Destroying... [1m2s]
azurerm_public_ip.main: Destroying... [30s]
azurerm_resource_group.main: Destroying... [2m4s]
Destroy complete! Resources: 7 destroyed.
```

Then confirm in the portal that the resource group `rg-devops-cicd` is gone. You can
also delete the whole resource group from the portal, but `terraform destroy` is
preferable because it also updates the local state file.

Stop Jenkins:

```powershell
cd ..\jenkins
docker compose down          # keeps the jenkins_home volume
docker compose down -v       # also deletes all jobs and credentials
```

---

## Security notes

| Secret | Where it lives | Where it must never go |
|--------|----------------|------------------------|
| SSH private key | `%USERPROFILE%\.ssh\azure_cicd_vm` + Jenkins credential `azure-vm-ssh-private-key` | Git, the Jenkinsfile, the console log |
| GitHub token | Jenkins credential `github-credentials` | Git, the Jenkinsfile, `terraform.tfvars` |
| `terraform.tfvars` | your laptop only | Git (it is in `.gitignore`) |
| `terraform.tfstate` | your laptop only | Git (it is in `.gitignore`) |

Additional measures used in this project:

* SSH is restricted to a single source IP by the Network Security Group, with an
  explicit deny rule for every other source.
* Password authentication is disabled on the VM (`disable_password_authentication = true`).
* The pipeline uses `StrictHostKeyChecking=yes` with a pinned host key.
* The pipeline uses `BatchMode=yes`, so it can never block waiting for a password.
* Secrets are bound with `withCredentials` and are automatically masked in the log.
* `nginx -t` is executed before the live symlink is switched, so a bad configuration
  can never take the website down.

---

## Screenshots checklist

Capture these for your submission:

1. Azure portal - empty subscription before `terraform apply`
2. Terminal - `terraform plan` output
3. Terminal - `terraform apply` output
4. Azure portal - the seven resources in the resource group
5. Azure portal - the Network Security Group rules
6. Browser - the placeholder page served by cloud-init
7. Docker - `docker compose ps` showing Jenkins running
8. Browser - the Jenkins setup wizard
9. Browser - the credentials list in Jenkins
10. Browser - the pipeline configuration (Pipeline script from SCM)
11. Browser - a green build showing all six stages
12. Browser - the console output of a successful build
13. Browser - the live website with the "Deployment status" panel populated
14. Browser - GitHub webhook settings, and the webhook delivery showing a 200 response
15. Browser - the Build history with two builds triggered by two pushes
16. Terminal - a failed build showing the error message, next to the still-working website
17. Terminal - `terraform destroy` output
18. Azure portal - the empty subscription after the cleanup
