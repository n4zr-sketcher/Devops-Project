# 🚀 End-to-End DevOps CI/CD Guide for Windows 10 (Local Docker & Azure)

This comprehensive guide walks you through setting up and running the entire DevOps CI/CD pipeline step-by-step on your **Windows 10 laptop**.

---

## 🏗️ Architecture Overview

You have two operating modes available:
1. **Local Docker Mode (100% Free - Recommended for local testing & demos)**:
   Runs Jenkins and a simulated Ubuntu 22.04 VM (`web-vm`) with Nginx and SSH locally via Docker Compose.
2. **Cloud Mode (Microsoft Azure + Terraform)**:
   Provisions a real Ubuntu VM in Azure using Terraform, where Jenkins deploys over the public internet.

```
                         ┌──────────────────────────────────────────────┐
                         │      DEVELOPER LAPTOP (Windows 10)           │
                         │                                              │
                         │  1. Edit Code in app/                        │
                         │  2. git push origin main                     │
                         └──────────────────────┬───────────────────────┘
                                                │
                                                ▼
                         ┌──────────────────────────────────────────────┐
                         │          GitHub Repository                   │
                         │   https://github.com/n4zr-sketcher/          │
                         │             Devops-Project.git               │
                         └──────────────────────┬───────────────────────┘
                                                │
                                                ▼ (Webhook or Poll SCM)
                         ┌──────────────────────────────────────────────┐
                         │   Jenkins Controller (localhost:8080)        │
                         │   Pipeline Stages:                           │
                         │   [Checkout] ➔ [Validate] ➔ [Test]           │
                         │   ➔ [Deploy] ➔ [Reload]   ➔ [Verify]         │
                         └──────────────────────┬───────────────────────┘
                                                │
                                                ▼ (SSH / SCP deployment)
                         ┌──────────────────────────────────────────────┐
                         │       Target Machine (Nginx Web Server)      │
                         │                                              │
                         │  LOCAL:  web-vm container (localhost:8000)   │
                         │  AZURE:  Azure Ubuntu VM  (http://<pip>:80)  │
                         └──────────────────────────────────────────────┘
```

---

## 💻 System Status & Tech Stack Checklist

The required dependencies on your Windows 10 machine:

| Component | Status on your Laptop | Version / Path |
| :--- | :---: | :--- |
| **Git** | ✅ Installed | `2.56.0.windows.1` |
| **Node.js** | ✅ Installed | `v26.10.0` (used for pipeline JS checks) |
| **Python** | ✅ Installed | `3.13.14` |
| **Terraform** | ✅ Installed | `v1.16.6` (in WindowsApps & user PATH) |
| **OpenSSH** | ✅ Installed | `OpenSSH_for_Windows_9.5p1` |
| **SSH Key Pair** | ✅ Generated | `$env:USERPROFILE\.ssh\azure_cicd_vm` |
| **GitHub Remote** | ✅ Configured | `https://github.com/n4zr-sketcher/Devops-Project.git` |
| **Docker Desktop** | ⏳ Installed | Installed at `C:\Program Files\Docker\Docker` (requires launch) |
| **Azure CLI** | ⏳ Optional (Cloud) | Installed via `winget install Microsoft.AzureCLI` |

---

---

## ⚡ STEP-BY-STEP EXECUTION GUIDE

> [!TIP]
> ### 🚀 Recommended: 1-Click Zero-Touch Automation
> You can skip all manual steps! Open PowerShell in the project directory and run:
> ```powershell
> cd "c:\Users\Dell\OneDrive\Desktop\Devops Project\Devops-Project-backup"
> powershell -ExecutionPolicy Bypass -File .\automate.ps1
> ```
> This automatically checks Docker, starts `jenkins-cicd` and `web-vm`, seeds admin credentials, creates the pipeline, triggers Build #1, and opens `http://localhost:8000` when complete!
>
> If you prefer to set up and inspect each component manually, follow the manual steps below.

---

### MODE A: LOCAL DOCKER MODE (MANUAL REFERENCE)

### Step 0: Start Docker Desktop on Windows 10

1. Open the Windows Start menu, search for **Docker Desktop**, and launch it (or run in PowerShell):
   ```powershell
   Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"
   ```
2. Wait for Docker Desktop to reach the **"Engine running"** state (green status icon in the bottom-left of Docker Desktop).
3. Verify that the Docker CLI responds:
   ```powershell
   docker ps
   ```
   *(If you see table headers `CONTAINER ID   IMAGE   COMMAND ...`, Docker engine is ready!)*

> [!TIP]
> **WSL 2 note:** If Docker prompts that the WSL 2 kernel is missing, open an **Administrator PowerShell** window and run:
> ```powershell
> wsl --update
> ```
> Then restart Docker Desktop.

---

### Step 1: Start the Local CI/CD Environment

In PowerShell, navigate to the `jenkins` directory and launch the containers:

```powershell
cd "c:\Users\Dell\OneDrive\Desktop\Devops Project\Devops-Project-backup\jenkins"
# (or cd "c:\Users\Dell\OneDrive\Desktop\Devops Project\Devops-Project\jenkins")
docker compose up -d --build
```

#### Verify Containers:
```powershell
docker ps
```
You will see two running containers:
- `jenkins-cicd` listening on port **8080**
- `web-vm` listening on port **8000** (mapped to internal port 80)

Test the web server placeholder right away in your browser:
👉 **[http://localhost:8000](http://localhost:8000)** (or health check: **[http://localhost:8000/health](http://localhost:8000/health)**)

---

### Step 2: Unlock and Set Up Jenkins

1. Retrieve the Jenkins initial administrator password directly from the container:
   ```powershell
   docker exec jenkins-cicd cat /var/jenkins_home/secrets/initialAdminPassword
   ```
2. Open your browser to: **[http://localhost:8080](http://localhost:8080)**
3. Paste the password into the **Administrator password** field and click **Continue**.
4. Choose **"Install suggested plugins"** and let the plugins install.
5. In **"Create First Admin User"**:
   - **Username**: `admin`
   - **Password**: `admin123` (or any password you prefer)
   - **Full Name**: `Dell Devops Admin`
   - **E-mail**: `admin@example.com`
6. Click **Save and Continue** ➔ Leave URL as `http://localhost:8080/` ➔ Click **Save and Finish** ➔ **Start using Jenkins**.

---

### Step 3: Configure Jenkins Global Environment Variables

Jenkins needs to know where to deploy the web application:

1. In Jenkins, go to: **Manage Jenkins** ➔ **System** (under System Configuration).
2. Scroll down to the **Global properties** section.
3. Check the box for **Environment variables**.
4. Click **Add** 4 times to configure these 4 variables:

| Name | Value | Description |
| :--- | :--- | :--- |
| `VM_IP` | `web-vm` | Docker network hostname of the Ubuntu VM |
| `VM_USER` | `azureuser` | SSH deployment user created in web-vm |
| `REMOTE_TMP_DIR` | `/tmp/cicd-build` | Staging directory on the target server |
| `REMOTE_APP_DIR` | `/var/www/app` | Live web root served by Nginx |

5. Click **Save** at the bottom of the page.

---

### Step 4: Add the 3 Credentials to Jenkins

Go to: **Manage Jenkins** ➔ **Credentials** ➔ **System** ➔ **Global credentials (unrestricted)** ➔ Click **Add Credentials**.

Add the following three credentials:

---

#### 1) GitHub Personal Access Token (`github-credentials`)
*Allows Jenkins to clone your repository:*
- **Kind**: `Username with password`
- **Username**: `n4zr-sketcher`
- **Password**: Your GitHub Personal Access Token (PAT).
  > If you don't have one, generate a token at [github.com/settings/tokens](https://github.com/settings/tokens) (Classic) with the **`repo`** scope checked.
- **ID**: `github-credentials`
- Click **Create**.

---

#### 2) SSH Private Key (`azure-vm-ssh-private-key`)
*Allows Jenkins to securely copy files and execute `deploy.sh` on the VM over SSH:*
- In PowerShell, copy your generated private key to your clipboard:
  ```powershell
  Get-Content "$HOME\.ssh\azure_cicd_vm" -Raw | Set-Clipboard
  ```
- In Jenkins Add Credentials:
  - **Kind**: `Secret text`
  - **Secret**: Paste the copied key (ensure it includes `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----`)
  - **ID**: `azure-vm-ssh-private-key`
- Click **Create**.

---

#### 3) SSH Known Hosts Entry (`azure-vm-known-hosts`)
*Enforces strict SSH host key verification:*
- In PowerShell, retrieve the host key from `web-vm`:
  ```powershell
  docker exec web-vm sh -c 'echo "web-vm $(cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d\" \" -f1,2)"'
  ```
  *(Or copy the line below if you used the pre-built image):*
  ```text
  web-vm ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMo2ulb1igMDnvRJy28hyJnZ2GAKPqPx09hy2OvllcD
  ```
- In Jenkins Add Credentials:
  - **Kind**: `Secret text`
  - **Secret**: Paste the one-line `web-vm ssh-ed25519 ...` string
  - **ID**: `azure-vm-known-hosts`
- Click **Create**.

---

### Step 5: Create and Configure the Pipeline Job

1. From the Jenkins dashboard, click **New Item** (top left).
2. Enter the name: `devops-project-pipeline`
3. Select **Pipeline** and click **OK**.
4. In the job configuration page, scroll down to the **Pipeline** section:
   - **Definition**: Select **`Pipeline script from SCM`**
   - **SCM**: Select **`Git`**
   - **Repository URL**: `https://github.com/n4zr-sketcher/Devops-Project.git`
   - **Credentials**: Select `github-credentials`
   - **Branch Specifier**: `*/main`
   - **Script Path**: `Jenkinsfile`
   - Uncheck "Lightweight checkout" (if present).
5. Click **Save**.

---

### Step 6: Run Your First Pipeline Build!

1. In the left menu of the job, click **Build Now**.
2. Click on build `#1` under **Build History** ➔ Click **Console Output**.
3. Watch each of the 6 stages succeed:
   - ✅ **Checkout**: Clones the repo from GitHub
   - ✅ **Validate**: Confirms required files (`index.html`, `style.css`, `script.js`) exist
   - ✅ **Test**: Checks HTML structure, CSS brace balance, and runs `node --check`
   - ✅ **Deploy**: Stages release to `web-vm` via SSH & SCP
   - ✅ **Reload**: Runs `deploy.sh` to validate `nginx -t`, atomic symlink swap, and reloads Nginx
   - ✅ **Verify**: Tests HTTP 200, `/health` response, and build metadata
4. Once the build completes with `FINISHED: SUCCESS`, visit:
   👉 **[http://localhost:8000](http://localhost:8000)**

You will see the fully deployed responsive web application with a live **Deployment Status Card**:
- **Build Number**: `#1`
- **Git Commit**: Your latest commit hash
- **Status**: Verified live & running!

---

### Step 7: Enable Automatic CI/CD on Git Push

1. Open your Jenkins job ➔ click **Configure**.
2. Scroll to **Build Triggers** and check **Poll SCM**.
3. Set the schedule to:
   ```text
   * * * * *
   ```
   *(This tells Jenkins to check GitHub every minute for new commits).*
4. Click **Save**.

#### Test the Automated CI/CD:
1. Make a small edit in `app/index.html` (e.g. edit the hero subtitle).
2. Commit and push the change from your laptop:
   ```powershell
   git add app/index.html
   git commit -m "Update homepage hero subtitle"
   git push origin main
   ```
3. Within 60 seconds, Jenkins detects the commit, automatically starts build `#2`, and publishes it to [http://localhost:8000](http://localhost:8000) without manual intervention!

---

## ☁️ OPTION B: CLOUD MODE (MICROSOFT AZURE + TERRAFORM)

When you are ready to deploy to a real Azure cloud Virtual Machine:

### 1. Install Azure CLI (if not already installed)
In an elevated PowerShell window:
```powershell
winget install Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
```

### 2. Login to Azure
```powershell
az login
```

### 3. Configure Terraform Variables
```powershell
cd "c:\Users\Dell\OneDrive\Desktop\Devops Project\Devops-Project-backup\terraform"
# (or cd "c:\Users\Dell\OneDrive\Desktop\Devops Project\Devops-Project\terraform")
Copy-Item terraform.tfvars.example terraform.tfvars
```
Run the helper script to auto-fill your public IP into `terraform.tfvars`:
```powershell
powershell -ExecutionPolicy Bypass -File ..\scripts\update-ssh-cidr.ps1
```
Set your public SSH key in `terraform/terraform.tfvars`:
```powershell
$pub = Get-Content "$HOME\.ssh\azure_cicd_vm.pub" -Raw
(Get-Content terraform.tfvars) -replace 'ssh-ed25519 AAAA.*', $pub | Set-Content terraform.tfvars
```

### 4. Deploy Infrastructure
```powershell
terraform init
terraform plan
terraform apply -auto-approve
```
Terraform will output the VM public IP (e.g., `20.55.1.2`).

### 5. Update Jenkins VM_IP
1. In Jenkins: **Manage Jenkins** ➔ **System** ➔ **Global properties**.
2. Change `VM_IP` from `web-vm` to your Azure Public IP.
3. Update `azure-vm-known-hosts` credential with the Azure VM host key:
   ```powershell
   ssh-keyscan -t ed25519 <AZURE_VM_PUBLIC_IP>
   ```
4. Click **Build Now** in Jenkins! Your app is now live on the public internet at `http://<AZURE_VM_PUBLIC_IP>/`.

### 6. Clean Up Azure to Stop Costs
When done, always destroy the cloud resources:
```powershell
cd terraform
terraform destroy -auto-approve
```

---

## 🛠️ Management & Troubleshooting Commands

### Stop & Restart Local Containers
- **Stop containers**:
  ```powershell
  cd jenkins
  docker compose stop
  ```
- **Start containers**:
  ```powershell
  cd jenkins
  docker compose up -d
  ```
- **Rebuild containers after Dockerfile modifications**:
  ```powershell
  cd jenkins
  docker compose up -d --build
  ```
- **Completely remove containers and volumes**:
  ```powershell
  cd jenkins
  docker compose down -v
  ```

### View Live Logs
- **Jenkins logs**:
  ```powershell
  docker logs -f jenkins-cicd
  ```
- **Web VM / Nginx logs**:
  ```powershell
  docker logs -f web-vm
  ```

### Manual SSH into Simulated Web VM
To inspect the web VM container directly:
```powershell
docker exec -it web-vm bash
```
Or over SSH using your generated key:
```powershell
ssh -i "$HOME\.ssh\azure_cicd_vm" -p 8000 azureuser@localhost
```
