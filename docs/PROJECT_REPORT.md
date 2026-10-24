# Automated Deployment of a Web Application using CI/CD, Terraform, Azure and Jenkins

**A college project report**

---

## Title page

| | |
|---|---|
| **Project Title** | Automated Deployment of a Web Application using CI/CD, Terraform, Azure and Jenkins |
| **Course / Department** | _[Fill in: e.g. B.Tech Computer Science, Department of Computer Science & Engineering]_ |
| **Institution** | _[Fill in: your college name and address]_ |
| **Submitted By** | _[Fill in: your name, roll number]_ |
| **Guide / Supervisor** | _[Fill in: guide name and designation]_ |
| **Academic Year** | _[Fill in: e.g. 2026 – 2027]_ |
| **Date of Submission** | _[Fill in]_ |

---

## 1. Abstract

Modern web applications are rarely deployed by hand. This project demonstrates the complete
automation of that process using four widely adopted DevOps technologies: **Terraform** for
Infrastructure as Code, **Microsoft Azure** as the cloud platform, **Jenkins** for Continuous
Integration and Continuous Delivery, and **GitHub** for version control and change
notification.

The project delivers a single, coherent system. A declarative Terraform configuration
describes eight Azure resources — a Resource Group, a Virtual Network, a Subnet, a Network
Security Group with three rules, a Public IP address, a Network Interface and an Ubuntu
22.04 Virtual Machine. Applying that configuration (`terraform apply`) creates the complete
network environment and the server in a single command, and `terraform destroy` removes it
again, which makes the infrastructure reproducible and auditable.

The Ubuntu server is bootstrapped automatically through **cloud-init**, which installs and
configures **Nginx** during the first boot, so no manual step is required between creating
the machine and reaching a live web server. A small static web application built with HTML,
CSS and JavaScript is served by Nginx over HTTP on the server's public address.

On the developer side, a declarative **Jenkinsfile** defines a six-stage pipeline — Checkout,
Validate, Test, Deploy, Reload and Verify. When a developer pushes a commit to GitHub,
Jenkins detects the change, clones the code, proves that the required files exist, runs
static checks on the HTML, CSS and JavaScript, transfers the application to the Azure VM over
an authenticated SSH channel, publishes it as an immutable release, gracefully reloads Nginx
and finally verifies the result with a live HTTP request. Two Jenkins credentials — an SSH
private key and a pinned server host key — are used, and no secret is ever stored in the Git
repository or written to the build log.

The outcome is a pipeline in which a single `git push` produces a verified, live
deployment, with the website updated through an atomic symlink swap and a graceful Nginx
reload so that in-flight requests are never interrupted.

---

## 2. Introduction

Every piece of software that runs on a server had to be put there by somebody. In the
traditional workflow that "somebody" is the developer, and the process looks like this:
edit the files locally, find a way to copy them to the server, unpack them in the right
directory, and restart the web server so that it notices the change. Each of these steps
is manual, each of them is a chance to make a mistake, and none of them leaves a record of
what was actually deployed.

Three problems follow from that. First, **drift**: the files on the server stop matching
the files in the repository, and nobody can say which version is live. Second, **reproducibility**:
if the server has to be replaced, there is no reliable description of how to rebuild it.
Third, **feedback delay**: the developer only finds out that the change was broken when a
visitor sees a broken page.

The DevOps answer to all three is automation backed by a written description of the
desired state. This project implements that answer end to end rather than in fragments.

Infrastructure is moved under version control with **Terraform**, which means the cloud
environment is described declaratively and can be rebuilt at any moment. Continuous
Integration and Continuous Delivery are implemented with **Jenkins**, which reacts to a
code change and carries it all the way to a running server. The change itself is made in
**GitHub**, which acts both as the source of truth and as the event that triggers the
pipeline. The application itself is a small but complete responsive website, deliberately
simple so that the focus stays on the delivery pipeline rather than on application
complexity.

The report that follows describes the architecture, the implementation of each component,
the methodology used to test the result, the problems encountered along the way, and the
limitations of the approach.

---

## 3. Problem statement

> **To design, implement and demonstrate an automated deployment system for a web
> application, in which the cloud infrastructure is provisioned as code and every change
> pushed to the version-control repository is automatically validated, tested, deployed and
> verified, using Terraform, Microsoft Azure, Jenkins and GitHub.**

Concretely, the system must satisfy the following requirements.

| # | Requirement |
|---|-----------|
| R1 | Provision a complete Azure environment (network, security, compute) declaratively with Terraform. |
| R2 | Install and configure the web server on the VM automatically, without a manual login. |
| R3 | Detect a code push and start a pipeline automatically. |
| R4 | Validate and test the application before anything is deployed. |
| R5 | Transfer the application to the server over a secure, authenticated SSH channel. |
| R6 | Update the live website without interrupting the service. |
| R7 | Prove after the deployment that the new version is actually being served. |
| R8 | Keep every credential out of the Git repository and out of the build log. |
| R9 | Allow the whole environment to be torn down again with a single command. |

---

## 4. Objectives

1. **Automate infrastructure provisioning** using Terraform with the AzureRM provider,
   covering the Resource Group, Virtual Network, Subnet, Network Security Group, Public IP,
   Network Interface and Ubuntu Virtual Machine.
2. **Automate server configuration** using cloud-init so that Nginx is installed, the site
   configuration is written and the placeholder page is published during the first boot.
3. **Design a secure network posture** in which only HTTP is open to the internet and SSH
   is restricted to a single known source address, backed by an explicit deny rule.
4. **Implement a declarative Jenkins pipeline** with six clearly separated stages, each of
   which fails the build when its own check fails.
5. **Implement a zero-downtime deployment mechanism** using immutable release folders, an
   atomic symlink swap and a graceful Nginx reload.
6. **Implement an automated verification stage** that proves the live server is serving the
   build that was just deployed.
7. **Manage secrets correctly**, keeping the SSH private key, the host key and the GitHub
   token inside the Jenkins credential store and masking them in the console output.
8. **Demonstrate the full workflow** from a developer commit to a changed live website,
   and document it with evidence.

---

## 5. Scope of the project

### 5.1 In scope

* A single Azure Resource Group containing one virtual network, one subnet, one NSG, one
  public IP, one network interface and one Ubuntu 22.04 VM.
* Terraform configuration covering all eight resources, driven by a variable file, with
  state kept locally and excluded from Git.
* cloud-init bootstrap that installs Nginx and publishes a placeholder page.
* A responsive static web application (HTML, CSS, vanilla JavaScript) that displays live
  deployment metadata from the server.
* A Jenkins controller running in a Docker container on the developer's Windows machine.
* A declarative pipeline that clones, validates, tests, deploys, reloads and verifies.
* SSH key-based deployment with pinned host-key verification.
* Scheduled (Poll SCM) and webhook-based triggers, with the limitations of each
  documented.
* A test plan, a troubleshooting guide, a cleanup procedure and a screenshot checklist.

### 5.2 Out of scope

* Application-level features such as databases, authentication, user accounts or sessions.
  The application is deliberately a static site so that the pipeline is the subject.
* Containerising the application itself. The server runs Nginx directly on the VM.
* Zero-downtime *infrastructure* upgrades (blue/green VM swap). Only the application
  content is deployed atomically.
* A production-grade CI/CD platform (Azure DevOps, GitHub Actions). Jenkins was chosen
  because the brief requires it and because it demonstrates the concepts from first
  principles.
* Monitoring, alerting, log aggregation and centralised secret management (Key Vault).

---

## 6. Tools and technologies used

| Layer | Tool | Version | Role in the system |
|-------|------|---------|--------------------|
| Cloud platform | Microsoft Azure | - | Hosts the network, the VM and the public IP address |
| Infrastructure as Code | Terraform | 1.16.6 (windows_amd64) | Declares and creates all eight Azure resources |
| Cloud provider plugin | Terraform AzureRM provider | ~> 4.0 (4.81.0 resolved) | The bridge between Terraform and the Azure APIs |
| Authentication | Azure CLI (`az`) | 2.91.0 | `az login` supplies the token the provider uses |
| Bootstrap | cloud-init (`custom_data`) | Ubuntu 22.04 built-in | Installs and configures Nginx on first boot |
| CI/CD engine | Jenkins | LTS (lts-jdk17 base image) | Executes the declarative pipeline |
| Jenkins runtime | Docker Desktop | 29.x | Runs the Jenkins controller locally, reproducibly |
| Version control | Git | 2.50.1.windows.1 | Local history and the transport to GitHub |
| Hosting | GitHub | - | Source of truth, webhook source, token issuer |
| Web server | Nginx | 1.18+ (Ubuntu default) | Serves the application over HTTP |
| Application | HTML5, CSS3, vanilla JavaScript | - | The deployed web application |
| Remote deployment | OpenSSH (`scp` / `ssh`) | client in the Jenkins image, OpenSSH server on the VM | Secure file transfer and remote command execution |
| Language for tooling | Bash, PowerShell | - | `deploy.sh` runs on the VM; `update-ssh-cidr.ps1` runs locally |

### 6.1 Why these choices

* **Terraform over an ARM template / Azure Portal clicks:** the infrastructure becomes a
  reviewable, diffable artefact that lives in the same repository as the application.
* **AzureRM provider v4:** it is the current supported major version and it enforces the
  `features {}` block, which makes provider behaviour explicit.
* **Jenkins in Docker:** the pipeline uses POSIX shell steps, `scp` and `ssh`. Running the
  controller in a Linux container means those tools behave exactly as they do on a Linux
  server, and the entire controller can be recreated with one command.
* **cloud-init instead of a VM extension:** cloud-init is the native Ubuntu mechanism, needs
  no extra extension, and is versioned with the machine definition.
* **Ubuntu 22.04 LTS over 24.04:** the jammy image has the widest package availability and
  the longest remaining standard support in the 22.04 family.

---

## 7. System architecture diagram

```
                        ┌───────────────────────────────┐
                        │         DEVELOPER LAPTOP      │
                        │          (Windows 11)         │
                        │                               │
                        │  ┌─────────┐    ┌──────────┐  │
                        │  │ VS Code │    │  Git CLI │  │
                        │  └────┬────┘    └────┬─────┘  │
                        │       │              │        │
                        │       │   git commit │ git push│
                        │       └──────────────┴──────┐ │
                        │                             ▼ ▼
                        │                  ┌────────────────────┐
                        │                  │       GitHub       │
                        │                  │  (source of truth) │
                        │                  └─────────┬──────────┘
                        │                            │ push event
                        │            ┌───────────────┴──────────────┐
                        │            │  webhook  OR  Poll SCM /1min │
                        │            └───────────────┬──────────────┘
                        │                            ▼
                        │   ┌────────────────────────────────────────┐
                        │   │        JENKINS CONTROLLER               │
                        │   │   (Docker: jenkins/jenkins:lts-jdk17)  │
                        │   │   http://localhost:8080                │
                        │   │                                        │
                        │   │  ┌──────────────────────────────────┐  │
                        │   │  │ 1. Checkout   (git clone)        │  │
                        │   │  │ 2. Validate   (files exist)      │  │
                        │   │  │ 3. Test       (static checks)    │  │
                        │   │  │ 4. Deploy     (scp over SSH)     │──┼─┐
                        │   │  │ 5. Reload     (deploy.sh + nginx)│  │ │
                        │   │  │ 6. Verify     (curl live URL)    │  │ │
                        │   │  └──────────────────────────────────┘  │ │
                        │   │  Credential store (encrypted):        │ │
                        │   │   - github-credentials (token)        │ │
                        │   │   - azure-vm-ssh-private-key           │ │
                        │   │   - azure-vm-known-hosts               │ │
                        │   └────────────────────────────────────────┘ │
                        └──────────────────────────────┬──────────────┘
                                                       │ scp / ssh
                                                       │ TCP 22, key auth
                                                       │ StrictHostKeyChecking=yes
                                                       ▼
    ┌──────────────────────────────────────────────────────────────────────────┐
    │                          MICROSOFT AZURE  (eastus)                       │
    │                                                                          │
    │  ┌────────────────────────────────────────────────────────────────────┐ │
    │  │ Resource Group: rg-devops-cicd                                     │ │
    │  │                                                                    │ │
    │  │  ┌──────────────────────────────────────────────────────────────┐  │ │
    │  │  │ Virtual Network  vnet-devops-cicd   10.0.0.0/16              │  │ │
    │  │  │  └─ Subnet snet-app                 10.0.1.0/24              │  │ │
    │  │  │       │                                                    │  │ │
    │  │  │       ├─ NSG nsg-devops-cicd                               │  │ │
    │  │  │       │    • 100  ALLOW 22/tcp  ← your public IP only      │  │ │
    │  │  │       │    • 110  ALLOW 80/tcp  ← 0.0.0.0/0                │  │ │
    │  │  │       │    • 4096 DENY  22/tcp  ← everyone else             │  │ │
    │  │  │       │                                                    │  │ │
    │  │  │       ├─ Public IP  pip-devops-cicd  (Standard SKU, static) │  │ │
    │  │  │       ├─ Network Interface  nic-devops-cicd                │  │ │
    │  │  │       │                                                    │  │ │
    │  │  │       └─ Ubuntu VM  vm-devops-cicd  (Standard_B1ls)        │  │ │
    │  │  │            ├─ cloud-init → installs & configures Nginx     │  │ │
    │  │  │            ├─ /var/www/app        → symlink (live)         │  │ │
     │  │  │            └─ /var/www/releases/  → release-<timestamp>-<rand>/ │  │ │
    │  │  └──────────────────────────────────────────────────────────────┘  │ │
    │  └────────────────────────────────────────────────────────────────────┘ │
    └───────────────────────────────────┬──────────────────────────────────────┘
                                        │ HTTP :80
                                        ▼
                            ┌───────────────────────────┐
                            │   End user / browser      │
                            │   http://<public-ip>/     │
                            └───────────────────────────┘

  ┌─── Terraform (one-off, from the laptop) ──────────────────────────────────┐
  │   terraform init → fmt → validate → plan → apply  →  terraform destroy    │
  └────────────────────────────────────────────────────────────────────────────┘
```

### 7.1 Data flow of a single deployment

```
Developer            GitHub             Jenkins              Azure VM           Visitor
   │  commit+push      │                  │                     │                 │
   ├───────────────────▶│                  │                     │                 │
   │                   │  push event      │                     │                 │
   │                   ├─────────────────▶│                     │                 │
   │                   │                  │ 1 Checkout          │                 │
   │                   │                  ├────────────────────▶│                 │
   │                   │                  │ 2 Validate          │                 │
   │                   │                  │ 3 Test              │                 │
   │                   │                  │ 4 Deploy (scp)      │                 │
   │                   │                  ├────────────────────▶│  stage release  │
   │                   │                  │ 5 Reload (nginx -s) │  swap symlink   │
   │                   │                  ├────────────────────▶│  reload nginx   │
   │                   │                  │ 6 Verify (curl)     │                 │
   │                   │                  │◀────────────────────┤  HTTP 200       │
   │                   │                  │  BUILD SUCCESS      │                 │
   │                   │                  │                     │◀────────────────┤
   │                   │                  │                     │   GET /         │
```

---

## 8. Infrastructure provisioning methodology

The infrastructure is created by a single declarative Terraform configuration that lives in
the `terraform/` directory. The methodology has four stages.

### 8.1 Design

Before writing any code, the required Azure objects were listed and their relationships
sketched:

```
Resource Group
  └─ Virtual Network
       └─ Subnet
            ├─ Network Security Group (bound to the subnet)
            ├─ Public IP  ──┐
            └─ Network Interface ◀┘
                 └─ Linux Virtual Machine  (custom_data = cloud-init)
```

Two decisions came out of this design phase and are worth recording, because both are
common sources of failure:

* **The subnet is a separate `azurerm_subnet` resource, not an inline `subnet {}` block.**
  Defining the same subnet in both places makes Terraform fight with itself, because both
  resources would try to own the same object.
* **The NSG is bound to the subnet, not to the VM.** A subnet-level association also
  protects anything created in that subnet later, and it avoids the VM replacement
  problem that arises when the association lives on the network interface.

### 8.2 Authentication

Two authentication paths are supported in `provider.tf`:

1. **Azure CLI (used for development).** `az login` produces a token that is cached under
   `%USERPROFILE%\.azure`. The AzureRM provider detects the active subscription from that
   context automatically, so `subscription_id` can be left as `null`.
2. **Service Principal (used for CI or a shared machine).** Setting `ARM_SUBSCRIPTION_ID`,
   `ARM_TENANT_ID`, `ARM_CLIENT_ID` and `ARM_CLIENT_SECRET` drives the provider directly
   and needs no interactive sign-in. This path is also the one that matches how a real
   CI/CD runner authenticates.

Neither path writes a credential into a tracked file.

### 8.3 Configuration model

Every value that a reviewer might want to change is a Terraform **variable** in
`variables.tf`: the region, the resource-group name, the VM name and size, the subnet
address space, the SSH source CIDR, the OS image reference and the remote deployment
directories. Values are supplied through `terraform.tfvars`, which is **excluded from Git**
by `.gitignore`; `terraform.tfvars.example` is the committed template that shows the shape
of the file without revealing anything sensitive.

Two variables carry validation rules so that an invalid value fails during `terraform
validate` rather than half way through an apply:

* `allowed_ssh_cidr` must be a valid IPv4 CIDR block.
* `ssh_public_key` must begin with `ssh-rsa ` or `ssh-ed25519 `.

### 8.4 Execution and verification

```powershell
terraform init          # download and lock the AzureRM provider
terraform fmt -recursive
terraform validate      # syntax, types and variable validation
terraform plan          # human-readable preview of every create/update/delete
terraform apply         # create the infrastructure
terraform output        # read back the public IP, URLs and SSH command
terraform destroy       # remove everything when the project ends
```

`terraform plan` is the important safety gate. It shows the complete list of resources
before anything is created, and it reveals any mistake in the variable file while the
change is still free.

---

## 9. Terraform implementation and code explanation

### 9.1 `provider.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
  subscription_id = var.subscription_id
  tenant_id      = var.tenant_id
}
```

**Explanation.** `required_providers` pins the provider to the v4 series and records it in
`.terraform.lock.hcl`, so every machine installs byte-identical provider code. The
`features {}` block is mandatory in v4. `prevent_deletion_if_contains_resources` stops an
accidental `terraform destroy` from silently removing a resource group that still holds
resources. Both `subscription_id` and `tenant_id` default to `null`, which makes the
provider fall back to the `az login` context.

### 9.2 `main.tf` — the eight resources

| # | Resource | Terraform type | Key arguments |
|---|----------|----------------|---------------|
| 1 | Resource Group | `azurerm_resource_group` | `name`, `location`, `tags` |
| 2 | Virtual Network | `azurerm_virtual_network` | `address_space = ["10.0.0.0/16"]` |
| 3 | Subnet | `azurerm_subnet` | `address_prefixes = ["10.0.1.0/24"]` |
| 4 | Network Security Group | `azurerm_network_security_group` | three `security_rule` blocks |
| 4b | NSG ↔ Subnet link | `azurerm_subnet_network_security_group_association` | `subnet_id`, `network_security_group_id` |
| 5 | Public IP | `azurerm_public_ip` | `sku = "Standard"`, `allocation_method = "Static"` |
| 6 | Network Interface | `azurerm_network_interface` | `ip_configuration` joining subnet + public IP |
| 7 | Linux VM | `azurerm_linux_virtual_machine` | `admin_ssh_key`, `os_disk`, `source_image_reference`, `custom_data` |

**The NSG rules** are the security core of the design:

```hcl
security_rule {
  name        = "Allow-SSH-From-Allowed-CIDR"
  priority    = 100
  access      = "Allow"
  protocol    = "Tcp"
  destination_port_range = "22"
  source_address_prefix  = var.allowed_ssh_cidr     # e.g. "203.0.113.42/32"
}
security_rule {
  name        = "Allow-HTTP-From-Internet"
  priority    = 110
  access      = "Allow"
  protocol    = "Tcp"
  destination_port_range = "80"
  source_address_prefix  = "0.0.0.0/0"
}
security_rule {
  name        = "Deny-SSH-From-Everywhere-Else"
  priority    = 4096
  access      = "Deny"
  protocol    = "Tcp"
  destination_port_range = "22"
  source_address_prefix  = "*"
}
```

Rule 3 is defence in depth. The NSG defaults would already block it, but stating the deny
explicitly makes the intended posture readable in the portal and survives a future
refactor that might add a broad allow rule.

**The VM** shows two provider-v4-specific details that a beginner will hit immediately if
they copy an older tutorial:

```hcl
disable_password_authentication = true

admin_ssh_key {                 # v4 renamed the old `ssh_keys` block
  username   = var.admin_username
  public_key = var.ssh_public_key
}

custom_data = base64encode(templatefile("${path.module}/cloud-init.yml.tftpl", { ... }))
```

`custom_data` on an Azure Linux VM *is* cloud-init. The provider expects the value to be
base64 encoded, which is exactly what `base64encode()` produces.

### 9.3 `cloud-init.yml.tftpl` — automated Nginx bootstrap

The cloud-init template is a Terraform template (`.tftpl`) so that the paths and the
administrator user name can be driven by `variables.tf` instead of being hard-coded in
YAML. Its content falls into three parts:

```yaml
package_update: true
packages:
  - nginx
  - curl
  - rsync
  - unzip

write_files:
  - path: /etc/nginx/sites-available/app        # the Nginx server block
  - path: /var/www/app/index.html               # the placeholder page

runcmd:
  - rm -f /etc/nginx/sites-enabled/default      # Ubuntu's default site occupies :80
  - ln -sfn /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
  - nginx -t                                    # validate BEFORE restarting
  - systemctl enable nginx
  - systemctl restart nginx
```

The Nginx server block exposes two special locations that the pipeline depends on:

```nginx
location = /health {
    access_log off;
    add_header Content-Type text/plain always;
    return 200 'ok';
}

location = /build-info.txt {
    add_header Cache-Control "no-store" always;
}
```

`/health` is the liveness probe used by the Verify stage. `/build-info.txt` is written by
the deployment script into every release and is served with `no-store` so that the
verification always sees the newest deployment rather than a cached copy.

Running `nginx -t` before the restart is deliberate: if the configuration were invalid,
the script would stop and the previous working configuration would remain in place.

### 9.4 `outputs.tf`

The outputs are the bridge between Terraform and the pipeline. `public_ip_address` and
`http_url` are the values the Jenkins job needs, and `next_steps` prints a human-readable
summary after every apply:

```hcl
output "public_ip_address" { value = azurerm_public_ip.main.ip_address }
output "http_url"         { value = "http://${azurerm_public_ip.main.ip_address}" }
output "ssh_command"      { value = "ssh -i ~/.ssh/azure_cicd_vm ${var.admin_username}@${azurerm_public_ip.main.ip_address}" }
```

### 9.5 `variables.tf` and `terraform.tfvars.example`

`variables.tf` holds twenty-one variables covering naming, location, networking, the
compute configuration, the OS image and the deployment directories. `terraform.tfvars.example`
is the committed template; `terraform.tfvars` holds the real values and is blocked by
`.gitignore`.

### 9.6 State management

Terraform stores the state of every managed resource in `terraform.tfstate`. The state file
is not a cache — it **is** the mapping between the real Azure objects and the addresses in
the configuration. Losing it means Terraform no longer knows what it created, and it may
attempt to recreate resources that already exist. Leaking it is dangerous, because it can
contain resource identifiers and, depending on the configuration, sensitive values.

Three protections are applied in this project:

1. `*.tfstate` and `*.tfstate.*` are excluded by `.gitignore`.
2. The state is kept **local** for the demonstration, which is acceptable for a
   single-student project but not for a team.
3. The production-grade alternative is documented: an **Azure Storage backend** with
   `container_access_type = "private"`, `use_azuread_auth = true` and state locking
   enabled, which gives the state a single shared home, encryption at rest, versioning and
   locking.

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stdevopscicdstate"
    container_name       = "tfstate"
    key                  = "devops-cicd/terraform.tfstate"
    use_azuread_auth     = true
  }
}
```

### 9.7 Verifying the rendered cloud-init before paying for anything

A mistake in the cloud-init template is only discovered after the VM has been created and
booted. To avoid that, the template is rendered locally and parsed before applying:

```powershell
terraform console
> base64encode(templatefile("${path.module}/cloud-init.yml.tftpl", { ... }))
```

The base64 output is decoded and parsed with a YAML parser to confirm that it is valid
cloud-config and that no un-interpolated `${...}` placeholder remains.

---

## 10. Jenkins pipeline implementation

### 10.1 The controller

The Jenkins controller runs in a Docker container defined by `jenkins/docker-compose.yml`.
A small `Dockerfile` extends the official `jenkins/jenkins:lts-jdk17` image with the three
tools the pipeline needs and that the base image does not ship:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-client curl ca-certificates rsync unzip nodejs \
    && rm -rf /var/lib/apt/lists/*
```

`openssh-client` provides `scp` and `ssh`; `curl` performs the HTTP verification;
`nodejs` provides `node --check`, which turns the JavaScript test from a guess into a
real parser check. The `jenkins_home` volume keeps the wizard result, the credentials and
all jobs across container restarts.

### 10.2 The `Jenkinsfile`

The pipeline is declarative. The overall shape is:

```groovy
pipeline {
    agent any
    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        ansiColor('xterm')
    }
    environment { /* APP_DIR, SSH_KEY_FILE, VM_IP, ... */ }
    stages { /* Checkout, Validate, Test, Prepare SSH, Deploy, Reload, Verify */ }
    post   { /* success, failure, always */ }
}
```

`disableConcurrentBuilds()` is important for correctness, not just tidiness: two overlapping
deployments could otherwise race on the release directory and the Nginx reload.

#### Stage 1 — Checkout

```groovy
checkout scm
env.GIT_COMMIT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
```

The commit hash is captured here because it is written into `build-info.txt` later, which
is how the deployed website can prove which revision it is serving.

#### Stage 2 — Validate

```groovy
def required = ['index.html', 'style.css', 'script.js']
def missing = required.findAll { !fileExists("${env.APP_DIR}/${it}") }
if (missing) {
    error("Missing required file(s) in ${env.APP_DIR}/: ${missing.join(', ')}. Aborting before anything is deployed.")
}
```

The stage fails the build with a message naming the exact missing files. Because it runs
before the Deploy stage, a broken repository can never reach the server.

#### Stage 3 — Test

Six shell checks run in sequence and the first failure aborts the build:

1. **HTML structure** — non-empty, has a doctype, a `<title>`, and references both assets.
2. **CSS integrity** — the number of `{` equals the number of `}`.
3. **JavaScript syntax** — `node --check app/script.js` runs the real parser.
4. **No debug leftovers** — a `grep` for `console.log` fails the build.
5. **Deployment script present** — `scripts/deploy.sh` must exist.
6. **Configuration present** — `VM_IP` must be set, with a message pointing at the
   Jenkins global properties page.

#### Stage 4 — Prepare SSH

```groovy
withCredentials([
    string(credentialsId: 'azure-vm-ssh-private-key', variable: 'SSH_PRIVATE_KEY'),
    string(credentialsId: 'azure-vm-known-hosts',     variable: 'SSH_KNOWN_HOSTS')
]) {
    sh '''
        mkdir -p "${SSH_DIR}"
        printf '%s\n' "${SSH_PRIVATE_KEY}" > "${SSH_KEY_FILE}"; chmod 600 "${SSH_KEY_FILE}"
        printf '%s\n' "${SSH_KNOWN_HOSTS}" > "${KNOWN_HOSTS_FILE}"; chmod 644 "${KNOWN_HOSTS_FILE}"
    '''
}
```

The two secrets are read from the Jenkins credential store and written to temporary files
inside the workspace with restrictive permissions. They are never passed on a command line,
so they cannot leak through the process list, and Jenkins masks them in the console log.
Using *Secret text* credentials rather than the SSH Agent plugin keeps the pipeline
working on both Windows and Linux controllers without an agent binary.

#### Stage 5 — Deploy

```bash
SSH_OPTS="-i ${SSH_KEY_FILE}"
SSH_OPTS="${SSH_OPTS} -o StrictHostKeyChecking=yes"
SSH_OPTS="${SSH_OPTS} -o UserKnownHostsFile=${WORKSPACE}/${KNOWN_HOSTS_FILE}"
SSH_OPTS="${SSH_OPTS} -o BatchMode=yes"
SSH_OPTS="${SSH_OPTS} -o ConnectTimeout=15"

ssh ${SSH_OPTS} "${VM_USER}@${VM_IP}" "mkdir -p '${REMOTE_STAGE}'"
scp ${SSH_OPTS} -r "${APP_DIR}" "${VM_USER}@${VM_IP}:${REMOTE_STAGE}/"
scp ${SSH_OPTS} "${SCRIPT_DIR}/deploy.sh" "${VM_USER}@${VM_IP}:${REMOTE_STAGE}/deploy.sh"
```

Three options deserve comment:

* `StrictHostKeyChecking=yes` with an explicit `UserKnownHostsFile` means the connection
  is refused unless the server's host key matches the pinned one. This is what prevents a
  man-in-the-middle attack.
* `BatchMode=yes` means SSH never prompts. If authentication fails, the command fails
  immediately instead of hanging the build.
* `ConnectTimeout=15` prevents a build from hanging on a firewalled address.

The deployment script itself is uploaded from the repository and executed on the VM, so the
version that runs is always the version that is committed.

#### Stage 6 — Reload

```bash
ssh ${SSH_OPTS} "${VM_USER}@${VM_IP}" \
  "DEPLOYED_BY=jenkins BUILD_NUMBER='${BUILD_NUMBER}' GIT_COMMIT='${GIT_COMMIT}' \
   sudo bash '${REMOTE_STAGE}/deploy.sh' '${REMOTE_STAGE}/${APP_DIR}'"
```

`sudo` is passwordless on the Azure Ubuntu image for the administrator account created by
cloud-init, so the command completes without an interactive prompt.

#### Stage 7 — Verify

```bash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${BASE_URL}/")
[ "${HTTP_CODE}" = "200" ] || exit 1
curl -fsS --max-time 20 "${BASE_URL}/health"
curl -fsS --max-time 20 "${BASE_URL}/build-info.txt" | grep -q "build_number=${BUILD_NUMBER}"
```

The third check is the strongest: it proves not only that the server responds, but that
the build which was just deployed is the one being served.

#### `post` block

`always` archives `app/**` as build artifacts and cleans the workspace; `success` and
`failure` print a summary. A failed build never modifies the live website, because the
`deploy.sh` script validates everything before the live symlink is switched.

---

## 11. GitHub integration and webhook configuration

### 11.1 Repository creation and the first push

```powershell
git init -b main
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/<username>/azure-terraform-jenkins-cicd.git
git push -u origin main
```

The `.gitignore` guarantees that `terraform.tfstate`, `terraform.tfvars`, `*.pem` and the
SSH keys are never staged. The `git status` output before committing is the evidence that
this works.

### 11.2 How Jenkins clones the repository

Jenkins clones over HTTPS using a **Personal Access Token** stored as the Jenkins
credential `github-credentials`. The token is sent to the Jenkins credential store, not into
the `Jenkinsfile` and not into the repository. A classic token with the `repo` scope is
sufficient for a private repository.

### 11.3 Trigger option A — Poll SCM (the default)

Jenkins re-checks the repository on a schedule and starts a build when it finds a change.
Because the schedule belongs to the **job** rather than to the `Jenkinsfile`, the same
pipeline file works with any trigger, and the trigger can be changed without touching
version-controlled code.

| Setting | Value |
|---------|-------|
| Build trigger | GitHub hook trigger for GITScm polling |
| Advanced → Trigger only if the SCM actually changed something | enabled |
| Schedule | `* * * * *` (every minute) |

**Why this is the default.** It needs no extra service, no public address and no
additional account, and it works identically on a laptop, a home server or a cloud VM.

### 11.4 Trigger option B — GitHub webhook (instant)

A webhook makes GitHub deliver an HTTP POST to a URL that GitHub can reach. A laptop
behind a home router has no such URL, so one of the following is required.

| Method | Public endpoint | Cost | Stable? |
|--------|-----------------|------|---------|
| ngrok | `https://<random>.ngrok-free.app` | free | yes, per account |
| Cloudflare quick tunnel | `https://<random>.trycloudflare.com` | free | no, changes on restart |
| Jenkins on an Azure VM | `http://<static-ip>:8080/github-webhook/` | extra VM | yes |

The webhook itself is configured in **GitHub → repository → Settings → Webhooks → Add
webhook**:

| Field | Value |
|-------|-------|
| Payload URL | `https://<tunnel-url>/github-webhook/` |
| Content type | `application/json` |
| Secret | a random string shared with Jenkins |
| Events | Just the push event |

The matching Jenkins side is **Manage Jenkins → System → GitHub Webhook Servers**, where
the same secret is entered. GitHub then delivers a signed payload on every push, and
Jenkins starts a build immediately.

> **Security consideration.** A tunnel makes the Jenkins controller reachable from the
> internet. An unsecured Jenkins instance on a public URL is a well-known target. The
> controls that mitigate this are: a strong administrator password, the setup wizard
> completed, no unnecessary plugins, and — where the tunnel provider supports it — an
> access policy that only allows the tunnel's own account. For this project, Poll SCM is
> the recommended default and the webhook is the demonstration of the instant path.

### 11.5 The complete demonstrated workflow

```
Developer            GitHub               Jenkins                     Azure VM
   │  edit app/index.html                                                       │
   │  git add .                                                                 │
   │  git commit -m "Change the hero text"                                     │
   │  git push ────────▶│                                                      │
   │                    │  push event ──▶ (webhook, or the 1-minute poll)        │
   │                    │                                                      │
   │                    │                  Checkout → Validate → Test          │
   │                    │                  Deploy (scp) ───────────────────────▶│
   │                    │                  Reload  (release + nginx reload) ────▶│
   │                    │                  Verify  (curl → 200)                   │
   │                    │                  BUILD SUCCESS                          │
   │                    │                                                      │
   │  browser ──────────────────────────────────────────────── GET / ──────────▶│
   │  ◀──────────────────────────────────────────────── new content ──────────────│
```

---

## 12. Application deployment process

### 12.1 The deployment script `scripts/deploy.sh`

The script runs **on the Azure VM** as root, invoked by Jenkins over SSH. Its design
goal is zero downtime.

```
 0. Pre-flight      root? source dir exists? index.html present?  -> abort early
 1. Stage           rsync the files into /var/www/releases/release-<timestamp>-<rand>/
 2. Metadata        write build-info.txt (build, commit, timestamp, release id)
 3. Permissions     chown www-data:www-data, dirs 755, files 644
 4. Validate        nginx -t                       <-- aborts BEFORE anything changes
 5. Swap            atomic symlink swap: /var/www/app -> the new release
 6. Reload          systemctl reload nginx         <-- graceful, connections survive
 7. Verify locally  curl http://127.0.0.1/health
 8. Housekeeping    keep only the newest 5 release folders
 9. Summary         print the release path, the build and the nginx status
```

### 12.2 Why the symlink

Nginx is configured with a fixed root:

```nginx
root /var/www/app;
```

but `/var/www/app` is a **symlink** to the active release folder. A deployment therefore
becomes a pointer move rather than a file copy over the live directory:

```bash
ln -sfn "${RELEASE_DIR}" "${APP_LINK}.new"
mv -Tf "${APP_LINK}.new" "${APP_LINK}"
```

`mv -T` on a symlink replaces the link itself atomically, so a request that arrives at the
exact moment of the switch sees either the old release or the new one, never a
half-written directory.

The first deployment is handled specially: cloud-init created `/var/www/app` as a real
directory containing the placeholder page, so the script moves it aside into
`/var/www/releases/initial-<timestamp>` before creating the symlink.

### 12.3 Why `reload` and not `restart`

`systemctl restart nginx` kills the master process and all its workers. Connections that
are open at that moment are dropped, and the visitor sees an error. `systemctl reload
nginx` sends `SIGHUP` to the master, which starts new workers and lets the old ones
finish the requests they are already serving. The site stays up throughout.

### 12.4 File ownership

The release files are owned by `www-data:www-data`, the account Nginx runs as. Directories
are `755` and files are `644`. The ownership is set explicitly rather than inherited,
because the staging directory is created by `sudo` as `root` and would otherwise produce
files that Nginx cannot read.

### 12.5 Why the release identifier is not just a timestamp

The first version of `deploy.sh` named each release `release-<timestamp>` with a one-second
resolution. Testing revealed a real defect: **two deployments that landed inside the same
second reused the same release folder.** The second deployment's `rsync --delete` then
erased the files of the first release, the symlink never moved, and the rollback history
was destroyed — even though the site still appeared to work.

The identifier is now `release-<timestamp>-<random>`, and the script additionally checks
that the target directory does not exist before using it. Two deployments can therefore
never share a release folder, so every release is immutable and every previous release
stays available for rollback. This defect was found by the automated deployment test
described in [VERIFICATION.md](../VERIFICATION.md), not by inspection.

### 12.6 Rollback

Because every release is kept, a rollback is a two-line operation on the server:

```bash
sudo ln -sfn /var/www/releases/release-20261022101430-4edd /var/www/app.new
sudo mv -Tf /var/www/app.new /var/www/app
sudo systemctl reload nginx
```

---

## 13. Testing methodology and results

> **Important:** the results in this section must be filled in from your own execution.
> The tables below give the *method* and the *expected* outcome; the evidence column is
> intentionally empty until you capture the real output. Nothing here should be presented
> as an executed result unless it was actually executed.

### 13.1 Test methodology

Four categories of test were used:

* **Static validation** — `terraform validate`, `terraform fmt -check` and a YAML parse of
  the rendered cloud-init, all performed before any resource is created.
* **Infrastructure verification** — inspection of the created resources in the Azure
  portal and from the Azure CLI, plus a functional reachability test of the NSG rules.
* **Pipeline verification** — repeated pipeline executions covering the success path and
  the failure path.
* **End-to-end verification** — an actual push to GitHub followed by an automated build
  and an inspection of the live website.

### 13.2 Test matrix

| ID | Test | Method | Expected result | Evidence |
|----|------|--------|-----------------|----------|
| T1 | Terraform configuration is valid | `terraform validate` | `Success! The configuration is valid.` | _[paste output]_ |
| T2 | Formatting is canonical | `terraform fmt -check -recursive` | no output, exit code 0 | _[paste output]_ |
| T3 | Cloud-init renders to valid YAML | render + YAML parse | parses without error, no unresolved `${}` | _[paste output]_ |
| T4 | All eight resources are created | `terraform apply` | 8 resources added, 0 destroyed | _[paste output]_ |
| T5 | Public IP is reachable over HTTP | `curl http://<ip>/` | HTTP 200, placeholder page | _[paste output]_ |
| T6 | Health endpoint answers | `curl http://<ip>/health` | `ok` | _[paste output]_ |
| T7 | SSH works from the allowed IP | `ssh -i ... azureuser@<ip> hostname` | host name returned | _[paste output]_ |
| T8 | SSH is blocked from another source | connect from a different network | connection times out | _[paste output]_ |
| T9 | Jenkins can clone the repository | Pipeline → Checkout | stage succeeds | _[paste output]_ |
| T10 | The pipeline completes successfully | Build Now | six stages green | _[paste output]_ |
| T11 | The live site shows the new content | `curl http://<ip>/` | contains the pushed text | _[paste output]_ |
| T12 | Build metadata is published | `curl http://<ip>/build-info.txt` | current `build_number` and commit | _[paste output]_ |
| T13 | A push triggers a build | `git push` | a new build starts (webhook: seconds; poll: ≤ 1 min) | _[paste output]_ |
| T14 | A broken build fails clearly | remove `app/style.css`, push | red build, message names the missing file | _[paste output]_ |
| T15 | The live site survives a failed build | `curl http://<ip>/` | still HTTP 200 with the previous content | _[paste output]_ |
| T16 | Secrets are absent from Git | `git ls-files` | no `.tfstate`, `.tfvars`, `id_ed25519` | _[paste output]_ |
| T17 | Secrets are masked in the console | search the build log | the key appears as `****` | _[paste output]_ |
| T18 | Zero downtime during a deploy | keep a request loop running during a deploy | no failed requests | _[paste output]_ |
| T19 | Teardown is complete | `terraform destroy` | 8 resources destroyed, RG removed | _[paste output]_ |

### 13.3 Result summary

> Fill in after execution.

| Category | Tests | Passed | Failed |
|----------|-------|--------|--------|
| Static validation | T1–T3 | _ | _ |
| Infrastructure | T4–T8 | _ | _ |
| Pipeline | T9–T10, T13–T15 | _ | _ |
| End-to-end and security | T11–T12, T16–T19 | _ | _ |

---

## 14. Screenshots checklist

Insert the screenshots in the order below. Each row states exactly what the screenshot
must show.

| # | Screenshot | Where to capture | Caption for the report |
|---|-----------|------------------|------------------------|
| 1 | Azure portal, empty subscription | Portal → Subscriptions | "Initial state before provisioning" |
| 2 | `terraform plan` output | PowerShell | "Planned infrastructure changes" |
| 3 | `terraform apply` output | PowerShell | "Successful infrastructure creation" |
| 4 | Resource group overview with all resources | Portal → rg-devops-cicd | "Terraform-provisioned Azure resources" |
| 5 | NSG inbound rules | Portal → nsg-devops-cicd | "Network security rules restricting SSH" |
| 6 | Placeholder page in the browser | `http://<ip>/` | "Nginx serving the cloud-init placeholder" |
| 7 | `docker compose ps` | PowerShell | "Jenkins controller running in Docker" |
| 8 | Jenkins setup wizard | `http://localhost:8080` | "Jenkins initial configuration" |
| 9 | Jenkins credential list | Manage Jenkins → Credentials | "Credentials stored outside the repository" |
| 10 | Pipeline job configuration | Job → Configure | "Pipeline defined from the GitHub repository" |
| 11 | Blue Ocean view of a green build | Build → Console | "Successful six-stage pipeline" |
| 12 | Console output, Deploy and Reload stages | Build → Console | "SSH transfer and zero-downtime reload" |
| 13 | Live website with populated status panel | `http://<ip>/` | "Deployed application reporting live build metadata" |
| 14 | GitHub webhook delivery log | GitHub → Settings → Webhooks | "Webhook delivery showing HTTP 200" |
| 15 | Build history with two builds | Jenkins → job | "Automatic builds triggered by pushes" |
| 16 | A failed build next to the working site | Jenkins console + browser | "Failure reporting without service interruption" |
| 17 | `terraform destroy` output | PowerShell | "Complete teardown of the environment" |
| 18 | Empty subscription afterwards | Portal | "No residual resources or charges" |

---

## 15. Challenges and solutions

| # | Challenge | Symptom | Root cause | Solution adopted |
|---|-----------|---------|------------|------------------|
| 1 | The AzureRM provider rejected the VM block | `Blocks of type "ssh_keys" are not expected here` and `An argument named "custom_data_base64" is not expected here` | Provider v4 renamed `ssh_keys` to `admin_ssh_key` and consolidated the base64 handling into `custom_data` | Inspected the installed provider schema with `terraform providers schema -json` instead of relying on older tutorials, then updated `main.tf` |
| 2 | The cloud-init template failed to render | `vars map does not contain key "variable"` | The explanatory comment inside the template contained a literal `${variable}`, which Terraform tried to interpolate | Escaped the placeholder as `$${variable}` and documented the escape rule in the file header |
| 3 | `terraform fmt -diff` errored | `exec: "diff": executable file not found in %PATH%` | The Windows `diff` utility is not installed by default | Ran `terraform fmt` without `-diff`, and added Git's `usr/bin` to `PATH` when the diff view is needed |
| 4 | The interactive `az login` produced no result | the command appeared to hang | The Azure CLI device-code flow uses a long-lived HTTP request, which an intermediary network closed | Used the standard browser-based `az login`; documented the Service Principal path as the machine-independent alternative |
| 5 | SSH timed out during the first pipeline run | `ssh: connect to host <ip> port 22: Connection timed out` | The home broadband public IP had changed since `terraform apply`, so the NSG rule no longer matched | Added `scripts/update-ssh-cidr.ps1`, which detects the current public IP and rewrites `terraform.tfvars`; documented that the Jenkins `VM_IP` must be updated too |
| 6 | Installing tools without administrator rights | `MSI installation failed with exit code 1602` | UAC elevation was unavailable in the working session | Installed Terraform through winget's user-level package, the JDK from the Adoptium ZIP archive, and the Azure CLI into a Python virtual environment with a small `az.cmd` shim on the `PATH` |
| 7 | Windows-specific Jenkins quirks | `sh` steps unavailable; native `ssh` behaviour differs | The Jenkins Windows agent lacks a POSIX shell and a standard OpenSSH setup | Ran the controller as a Linux container, so the pipeline's `sh` steps, `scp` and `ssh` behave exactly as on a server |
| 8 | The deployed site was stale | the browser showed the placeholder after a successful build | The placeholder lived in a real directory that the release mechanism replaced with a symlink | `deploy.sh` detects the first-deployment case and migrates the existing directory into `/var/www/releases/initial-<timestamp>` |
| 9 | A failed build could have taken the site down | risk identified during design | A failure after the file copy but before the reload would leave the live directory inconsistent | `deploy.sh` validates `nginx -t` and performs an atomic symlink swap, so the live site is only changed once everything is known to be correct |

---

## 16. Observations

1. **Declarative infrastructure removes a whole class of human error.** Once the eight
   resources were described in Terraform, recreating the environment became a single
   command. The first deployment is the only one that needs care; every later one is
   identical by construction.

2. **The public IP address is the fragile part of the design.** Everything else in the
   pipeline is deterministic, but a residential broadband connection changes its public IP
   without warning. This single fact shapes the whole trigger and security design — the NSG
   allow-list, the need to update the Jenkins `VM_IP`, and the decision to use a polling
   trigger rather than exposing a webhook endpoint.

3. **cloud-init removes an entire class of manual steps.** Provisioning the server and
   configuring the web server are one action, not two. There is no window in which a human
   has to remember to install Nginx.

4. **A deployment is a pointer move, not a file copy.** The symlink-and-reload design means
   the live directory is never in a partially written state, and the old version is still
   on disk for a rollback.

5. **Verifying the deployment is not optional.** A pipeline that only copies files and
   reports success can be green while the website is broken. Checking the build number
   returned by the live server closes that gap.

6. **Secrets and configuration are different things.** The IP address is configuration and
   belongs in Jenkins global properties; the private key is a secret and belongs in the
   credential store. Separating the two is what keeps the `Jenkinsfile` free of anything
   that should not be committed while still remaining portable.

7. **Provider version drift is the biggest source of "the tutorial does not work".** Two
   of the nine challenges above were caused purely by an AzureRM v4 schema change. Reading
   the installed provider schema is more reliable than following any tutorial, including
   this one.

---

## 17. Limitations and future enhancements

### 17.1 Limitations of the current implementation

| # | Limitation | Consequence |
|---|------------|-------------|
| L1 | The Jenkins controller runs on the developer's laptop | The pipeline only runs while the laptop is powered on and Docker is running |
| L2 | Poll SCM has a minimum latency of one minute | A push is not reflected on the website instantly |
| L3 | The NSG allow-list contains a single home IP | SSH breaks whenever the ISP changes the address |
| L4 | Terraform state is stored locally | No shared history, no locking, no disaster recovery for the state |
| L5 | Only one VM, no load balancer | No high availability, no rolling update of the server itself |
| L6 | The application is static | No database, no authentication, no server-side logic |
| L7 | Secrets are Jenkins credential text, not Key Vault | Manual rotation; no audit trail beyond the build log |
| L8 | No automated rollback | A bad release stays live until a human intervenes |
| L9 | No monitoring or alerting | A server that dies at night is discovered in the morning |
| L10 | The VM size is the smallest available | Limited headroom if the project grows |

### 17.2 Proposed future enhancements

* **Move the controller to an Azure VM with a static IP** so that webhooks work directly
  and the pipeline is independent of the laptop.
* **Replace Poll SCM with a GitHub webhook** through a stable tunnel, or a self-hosted
  runner.
* **Move the Terraform state to an Azure Storage backend** with `use_azuread_auth`,
  versioning and locking.
* **Add a managed identity** to the VM so that Terraform and the pipeline authenticate
  without any static credential at all.
* **Automatic rollback** — the Verify stage could detect a failed health check and point
  the symlink back to the previous release automatically.
* **Blue/green deployments** using a second VM behind an Azure Load Balancer, so that the
  server itself could also be updated without downtime.
* **Containerise the application** and run it behind Nginx as a reverse proxy, extending the
  pipeline to build a Docker image and push it to Azure Container Registry.
* **Add quality gates** — ESLint for the JavaScript, Stylelint for the CSS and an HTML
  validator, so that the Test stage rejects objectively broken code.
* **Add monitoring** with the Azure Monitor agent and a Log Analytics workspace.
* **Manage secrets in Azure Key Vault** and have the pipeline read them at run time.
* **Extend the CI/CD chain to run tests in parallel** on a build matrix, and to publish
  the pipeline as a Jenkins Shared Library so that multiple projects reuse it.

---

## 18. Conclusion

This project demonstrates a complete, working automated deployment pipeline built from
four mainstream DevOps technologies, and every part of it has been implemented in full
rather than described in principle.

On the infrastructure side, a single Terraform configuration creates eight Azure resources
— a Resource Group, a Virtual Network, a Subnet, a Network Security Group with three
rules, a Public IP address, a Network Interface and an Ubuntu 22.04 Virtual Machine — and
`terraform destroy` removes them again. The server is configured by cloud-init, so Nginx is
running and serving a page within minutes of `terraform apply`, with no manual login.

On the delivery side, a declarative `Jenkinsfile` turns a GitHub push into a verified
deployment. The pipeline clones the repository, validates that the required files exist,
runs six static checks on the HTML, CSS and JavaScript, transfers the application over an
authenticated and host-key-pinned SSH channel, publishes it as an immutable release
through an atomic symlink swap, gracefully reloads Nginx so that no request is
interrupted, and finally proves over HTTP that the new build is the one being served. A
failure at any stage stops the pipeline and leaves the live website untouched.

The security design is deliberate rather than incidental: SSH is restricted to a single
source address with an explicit deny rule for everything else, password authentication is
disabled on the VM, all secrets live in the Jenkins credential store and are masked in the
build log, and the state and variable files are excluded from Git.

The main lessons taken from the implementation are that provider version drift causes more
trouble than any conceptual difficulty, that a residential IP address dictates the
architecture of the trigger and the security model, and that the difference between a
pipeline that copies files and one that *verifies* a deployment is the difference between
automation and assurance.

The project is fully reproducible from the repository: `terraform init → apply` rebuilds
the cloud environment, `docker compose up` rebuilds the CI/CD controller, and a single push
reproduces the entire delivery workflow.

---

## 19. References

### Official documentation

1. HashiCorp, *Terraform Documentation* — <https://developer.hashicorp.com/terraform/docs>
2. HashiCorp, *Terraform Registry — AzureRM Provider v4* — <https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs>
3. HashiCorp, *Terraform State Management* — <https://developer.hashicorp.com/terraform/language/state>
4. HashiCorp, *Terraform Backends — Azure Storage* — <https://developer.hashicorp.com/terraform/language/backend/azure>
5. HashiCorp, *Terraform `templatefile` Function* — <https://developer.hashicorp.com/terraform/language/functions/templatefile>
6. Microsoft, *AzureRM Provider v4 Migration Guide* — <https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/v4-upgrade-guide>
7. Microsoft Learn, *Virtual Machines in Azure* — <https://learn.microsoft.com/azure/virtual-machines/>
8. Microsoft Learn, *Network Security Groups Overview* — <https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview>
9. Microsoft Learn, *Azure Cloud-init Overview* — <https://learn.microsoft.com/azure/virtual-machines/using-cloud-init>
10. Microsoft Learn, *Public IP Addresses* — <https://learn.microsoft.com/azure/virtual-network/public-ip-addresses>
11. Microsoft Learn, *Nginx on Ubuntu* — <https://learn.microsoft.com/azure/virtual-machines/linux/tutorial-web-server-nginx>
12. Microsoft Learn, *Azure Free Account and Student Offer* — <https://azure.microsoft.com/free/>
13. Jenkins, *Jenkins User Handbook* — <https://www.jenkins.io/doc/book/>
14. Jenkins, *Jenkins Pipeline Documentation* — <https://www.jenkins.io/doc/book/pipeline/>
15. Jenkins, *Credentials Plugin* — <https://plugins.jenkins.io/credentials/>
16. Jenkins, *In-Pipeline Docker Builds* — <https://www.jenkins.io/doc/book/pipeline/docker/>
17. GitHub, *About Webhooks* — <https://docs.github.com/en/webhooks>
18. GitHub, *Creating a Personal Access Token* — <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens>
19. GitHub, *Git Hooks* — <https://docs.github.com/en/get-started/getting-started-with-git>
20. Ubuntu, *cloud-init Documentation* — <https://cloudinit.readthedocs.io/en/latest/>
21. Nginx, *Beginner's Guide* — <https://nginx.org/en/docs/start.html>
22. OpenSSH, *ssh(1) and scp(1) Manual Pages* — <https://man.openbsd.org/ssh>

### Tools and versions

23. Terraform v1.16.6 (windows_amd64) — `terraform version`
24. Terraform AzureRM provider v4.81.0 — recorded in `terraform/.terraform.lock.hcl`
25. Azure CLI 2.91.0 — `az version`
26. Eclipse Temurin JDK 17.0.20.1+1 — `java -version`
27. Git 2.50.1.windows.1 — `git --version`
28. Docker Engine 29.3.1 — `docker version`
29. Jenkins LTS (`jenkins/jenkins:lts-jdk17` base image) — `docker compose logs jenkins`

### Standards and background reading

30. *Accelerate: The Science of Lean Software and DevOps* — Nicole Forsgren, JeOpsie
31. *The DevOps Handbook* — Gene Kim et al., IT Revolution Press
32. *Site Reliability Engineering* — Betsy Beyer, Chris Jones, Jennifer Petoff, O'Reilly
33. *The Phoenix Project* — Gene Kim et al., IT Revolution Press
34. *The Linux Command Line* — William Shotts, No Starch Press

---

## Appendix A — Complete command reference

### Local (Windows PowerShell)

```powershell
# One-time tool installation
winget install --id Hashicorp.Terraform --exact
winget install --id EclipseAdoptium.Temurin.17.JDK --exact
python -m venv "$env:USERPROFILE\tools\azcli-venv"
& "$env:USERPROFILE\tools\azcli-venv\Scripts\python.exe" -m pip install azure-cli

# Azure
az login
az account list --output table
az account set --subscription "<name>"

# SSH key
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\azure_cicd_vm" -N '""' -C "azure-cicd-deploy"

# Terraform
cd terraform
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
powershell -ExecutionPolicy Bypass -File ..\scripts\update-ssh-cidr.ps1
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
terraform output
terraform destroy

# Jenkins
cd ..\jenkins
docker compose up -d --build
docker compose logs -f
docker compose down

# Git
git add .
git commit -m "message"
git push
```

### On the Azure VM

```bash
hostname
sudo systemctl status nginx
sudo tail -n 40 /var/log/cloud-init-output.log
sudo nginx -t
curl -s http://127.0.0.1/health
readlink -f /var/www/app
ls -la /var/www/releases
sudo bash /var/www/releases/<release>/deploy.sh /tmp/cicd-build/build-<n>/app
```

### In the Jenkins UI

```
Manage Jenkins > System > Global properties > Environment variables
    VM_IP, VM_USER, REMOTE_TMP_DIR, REMOTE_APP_DIR

Manage Jenkins > Credentials > System > Global credentials
    github-credentials        (Username with password)
    azure-vm-ssh-private-key   (Secret text)
    azure-vm-known-hosts       (Secret text)

New Item > Pipeline > azure-cicd-deploy
    Pipeline script from SCM > Git > <repo url> > main > Jenkinsfile

Job > Build Triggers > GitHub hook trigger for GITScm polling > Advanced > * * * * *
```

---

## Appendix B — Terraform state backend (production alternative)

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stdevopscicdstate"
    container_name       = "tfstate"
    key                  = "devops-cicd/terraform.tfstate"
    use_azuread_auth     = true
  }
}
```

```powershell
terraform init -migrate-state
```

---

*End of report. All screenshots, execution logs and measured results referred to in this
document must be collected during the actual implementation of the project before
submission.*
