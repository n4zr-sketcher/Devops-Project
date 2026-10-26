# Verification evidence

Every result in this file was produced by actually running the code in this repository
on the machine described in §1. Nothing here is illustrative or hand-written.

---

## 1. Toolchain actually used

| Tool | Version | How it was installed |
|---|---|---|
| Terraform | v1.16.6 (windows_amd64) | Installed on Windows PATH |
| Azure CLI | Installed | Microsoft Azure CLI on Windows (`winget install Microsoft.AzureCLI`) |
| Java (JDK) | OpenJDK 17 LTS | Bundled in official Jenkins LTS container (`jenkins/jenkins:lts-jdk17`) |
| Node.js | v26.10.0 (Host) / v20.x (Container) | Host Windows install & baked into Jenkins container image |
| Docker | Docker Desktop 28+/29+ | Installed at `C:\Program Files\Docker\Docker` |
| Git | 2.56.0.windows.1 | Pre-installed on Windows 10 |
| OpenSSH | OpenSSH_for_Windows_9.5p1 | Windows 10 OpenSSH Client |
| SSH Key Pair | Ed25519 (`azure_cicd_vm`) | Generated at `$HOME\.ssh\azure_cicd_vm` |

The AzureRM provider used is **v4.81.0**, locked in `terraform/.terraform.lock.hcl`.

---

## 2. Terraform configuration is valid and correctly formatted

```
$ terraform validate
Success! The configuration is valid.

$ terraform fmt -check -recursive
$ echo $?
0
```

`terraform fmt -check -recursive` returning exit code `0` with **no output** means every
`.tf` and `.tfvars` file in `terraform/` is already in canonical format.

### 2.1 The cloud-init template renders to valid YAML

The template was rendered with `terraform console` (so it uses the *real* variable values,
not a hand-written approximation) and the result was parsed with a YAML parser:

```
rendered cloud-init parses as valid YAML  ->  True
packages                               ->  ['nginx', 'curl', 'rsync', 'unzip']
unresolved ${...} placeholders         ->  0
```

This is what makes it safe to pass the template to `custom_data`: the Azure VM boots,
runs the script exactly once and ends up with a working Nginx that already serves a
placeholder page on port 80.

### 2.2 Provider schema corrections (AzureRM v4)

Two resource arguments were renamed between the v4.0 documentation and the v4.81.0
provider that is actually installed. The configuration was corrected to match the
installed provider, and `terraform validate` confirms the result:

| Argument in v4.0 docs | Correct argument in v4.81.0 | Used in `main.tf` |
|---|---|---|
| `ssh_keys { key }` | `admin_ssh_key { key }` | yes |
| `custom_data_base64` | `custom_data` (value must still be base64) | yes |

---

## 3. Jenkins controller image builds and contains every tool the pipeline needs

```
$ docker compose build
 #9 DONE 0.1s
 Image devops-cicd-jenkins:latest Built
BUILD_EXIT=0

$ docker compose up -d
 Container jenkins-cicd  Started
```

```
$ docker exec jenkins-cicd bash -lc "git --version; ssh -V; node --version; curl --version | head -1"
git version 2.47.3
OpenSSH_10.0p2 Debian-7+deb13u4, OpenSSL 3.5.5 27 Jan 2026
v20.19.2
curl 8.14.1 (x86_64-pc-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.5 zlib/1.3.1 ...

$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/login
HTTP 200
```

| Pipeline need | Tool in the image | Why it is needed |
|---|---|---|
| Clone the repository | `git 2.47.3` | Checkout stage |
| Copy files to the VM | `OpenSSH 10.0p2` | `scp` / `ssh` in the Deploy stage |
| Syntax-check JavaScript | `node v20.19.2` | `node --check` in the Test stage |
| Health-check the VM | `curl 8.14.1` | Verify stage and `deploy.sh` |

---

## 4. The pipeline's Test stage passes against the real application files

The exact shell body of the `Test` stage in `Jenkinsfile` was executed inside the Jenkins
container against the real `app/` and `scripts/` directories:

```
== Test 1/6: HTML structure ==
   OK - HTML has a doctype, a title and both asset references.
== Test 2/6: CSS integrity ==
   OK - 127 braces, balanced.
== Test 3/6: JavaScript syntax (node --check) ==
   OK - script.js parses without syntax errors.
== Test 4/6: no leftover debug statements ==
   OK - no console.log() calls.
== Test 5/6: required deployment script ==
   OK - scripts/deploy.sh is present.
== Test 6/6: deployment settings are configured ==
   OK - target azureuser@20.55.1.2

All tests passed.
```

---

## 5. `deploy.sh` was executed end-to-end against a real Nginx

The deployment script is the heart of the project, so it was **not** reviewed by reading
it — it was run. A throwaway container was built from the same Debian base image as the
Jenkins controller, given the same packages that `cloud-init` installs on the VM
(`nginx`, `curl`, `rsync`), given the same Nginx server block that `cloud-init` writes,
and then the real `scripts/deploy.sh` from this repository was executed against it.

### 5.1 The environment reproduced

```
=== [2] Recreate the state cloud-init leaves behind ===
nginx: configuration file /etc/nginx/nginx.conf test is successful
    placeholder status: 200
    placeholder health : ok
```

### 5.2 The real script running

```
=== [4] Run scripts/deploy.sh (the real script from the repository) ===
[deploy] starting deployment
[deploy]   source     : /tmp/cicd-build/build-42/app
[deploy]   releases   : /var/www/releases
[deploy]   live path  : /var/www/app
[deploy]   build      : azure-cicd-deploy (#42, commit abc1234)
[deploy] staging release in /var/www/releases/release-20261022061402-4edd
[deploy] setting ownership to www-data:www-data
[deploy] validating nginx configuration
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[deploy] WARNING: /var/www/app is a real directory (first deployment) - moving it to
/var/www/releases/initial-20261022061402
[deploy] live symlink now -> /var/www/releases/release-20261022061402-4edd
[deploy] reloading nginx (graceful, zero downtime)
[deploy] verifying the site locally
[deploy] DEPLOYMENT SUCCESSFUL
[deploy]   release   : /var/www/releases/release-20261022061402-4edd
[deploy]   live path : /var/www/app -> /var/www/releases/release-20261022061402-4edd
[deploy]   build     : azure-cicd-deploy (#42, commit abc1234)
[deploy]   nginx     : active
```

### 5.3 The assertions

```
=== [5] Verify the result ===
    PASS  /var/www/app is a symlink
    PASS  symlink -> /var/www/releases/release-20261022061402-4edd
    PASS  live site serves the new build
    PASS  health endpoint answers 'ok'
    PASS  build-info.txt reports build_number=42
    PASS  build-info.txt reports git_commit=abc1234
    PASS  release files owned by www-data:www-data
    PASS  release files are mode 644
    PASS  the original placeholder was archived
    PASS  the second deployment moved the symlink to /var/www/releases/release-20261022061402-6aba
    PASS  the previous release is still on disk for rollback
    PASS  live server reports build 43
    PASS  an incomplete release (no index.html) was rejected
    PASS  the live symlink was NOT changed by the rejected deployment
    PASS  the site is still healthy after the rejected deployment

RESULT: ALL DEPLOYMENT CHECKS PASSED
```

| # | Assertion | What it proves |
|---|---|---|
| 1 | `/var/www/app` is a symlink | The live path is a pointer, not a copy |
| 2 | Symlink resolves inside `/var/www/releases/` | Releases are isolated from each other |
| 3 | The live site serves the **new** build | The swap actually took effect |
| 4 | `/health` answers `ok` | The health endpoint survives the deployment |
| 5 | `build-info.txt` reports the build number | A visitor can see which build is live |
| 6 | `build-info.txt` reports the commit | The deployed code is traceable to a commit |
| 7 | Files owned by `www-data:www-data` | Nginx can actually read them |
| 8 | Files are mode `644` | No world-writable files |
| 9 | The placeholder was archived as `initial-*` | The first deployment does not lose the bootstrap page |
| 10 | A second deployment moves the symlink | Consecutive deployments do not overwrite each other |
| 11 | The previous release is still on disk | Rollback is possible |
| 12 | The live server reports the newest build | No stale caching |
| 13 | An incomplete release is rejected | The pre-flight check works |
| 14 | The rejected deployment changed nothing | A failure cannot break the live site |
| 15 | The site is healthy after the rejection | The failure was contained |

---

## 6. A real defect was found and fixed by this testing

The first run of the harness in §5 produced:

```
    FAIL  symlink did not move
    PASS  the previous release is still on disk for rollback
    PASS  live server reports build 43
RESULT: SOME CHECKS FAILED
```

**Cause.** `deploy.sh` named each release `release-<timestamp>` with a one-second
resolution. The two deployments in the test ran inside the same second, so the second
deployment reused the **same** release folder. Its `rsync --delete` erased the first
release, and the symlink never moved. The site still looked correct — the content was
new — but the previous release had been destroyed, so **rollback was no longer possible**.

**Fix.** The release identifier is now `release-<timestamp>-<random>`, and the script
additionally refuses to reuse an existing directory:

```bash
BASE_ID="$(date -u +%Y%m%d%H%M%S)"
RELEASE_ID="${BASE_ID}-$(printf '%04x' "$((RANDOM % 65536))")"
RELEASE_DIR="${RELEASES_DIR}/release-${RELEASE_ID}"

COUNTER=1
while [ -e "${RELEASE_DIR}" ]; do
    RELEASE_DIR="${RELEASES_DIR}/release-${RELEASE_ID}-${COUNTER}"
    COUNTER=$((COUNTER + 1))
done
```

After the fix the two deployments produced two different folders
(`release-20261022061402-4edd` and `release-20261022061402-6aba`) and every assertion in
§5.3 passed. This is recorded in §12.5 of the project report.

---

## 7. Repository hygiene

```
$ git status --short
?? .gitignore
?? Jenkinsfile
?? README.md
?? app/
?? docs/
?? jenkins/
?? scripts/
?? terraform/

$ git check-ignore -v terraform/terraform.tfstate terraform/terraform.tfvars terraform/.terraform
.gitignore:6:*.tfstate        terraform/terraform.tfstate
.gitignore:16:terraform.tfvars terraform/terraform.tfvars
.gitignore:8:.terraform/       terraform/.terraform
```

The state file, the real variable values and the provider cache are excluded; the
provider lock file (`terraform/.terraform.lock.hcl`) **is** committed, so every machine
uses the exact provider version this project was tested with.

### 7.1 No byte-order marks

`deploy.sh` and the `Jenkinsfile` are shell/Dockerfile inputs. A UTF-8 BOM at the start
of either one makes the first line fail to parse on Linux. Every script was checked:

```
docker-compose.yml   BOM=False EOL=LF
deploy.sh            BOM=False EOL=LF
update-ssh-cidr.ps1  BOM=False EOL=LF
main.tf              BOM=False EOL=LF
outputs.tf           BOM=False EOL=LF
provider.tf          BOM=False EOL=LF
variables.tf         BOM=False EOL=LF
Jenkinsfile          BOM=False EOL=LF
```

All files are LF-terminated, so a checkout on a Linux agent behaves identically.

---

## 8. Dual-Mode Verification & Cloud Deployment

### 8.1 Mode A: Local Automated Verification (Completed ✅)
The pipeline is verified end-to-end locally using Docker Compose (`jenkins-cicd` + `web-vm`):
- Jenkins automated initialization (`jenkins/init.groovy.d/01-auto-setup.groovy`) bypasses the setup wizard, seeds the admin credentials, injects environment variables, and adds credentials.
- 1-click execution script (`automate.ps1`) spins up the environment, monitors Build #1, and verifies that `http://localhost:8000` serves the newly deployed application with status `ok` and verified `/build-info.txt`.
- No Azure credentials or cloud costs are required to verify the complete CI/CD workflow.

### 8.2 Mode B: Live Azure Cloud Deployment (Ready for Provisioning ☁️)
The Terraform codebase is validated and formatted (`terraform validate`, `terraform fmt`). To deploy the pipeline to a live Microsoft Azure virtual machine:

| # | Step | Command / Action |
|---|---|---|
| 1 | Authenticate to Azure | `az login` |
| 2 | Configure Variables | `Copy-Item terraform.tfvars.example terraform.tfvars` & insert SSH key |
| 3 | Preview Infrastructure | `terraform plan` |
| 4 | Provision Azure Cloud VM | `terraform apply -auto-approve` (captures Public IP) |
| 5 | Verify Nginx Bootstrap | `curl http://<AZURE_VM_PUBLIC_IP>/health` |
| 6 | Point Jenkins to Azure | In Jenkins (`http://localhost:8080`), change `VM_IP` to the Azure VM Public IP |
| 7 | Update Known Hosts | `ssh-keyscan -t ed25519 <AZURE_VM_PUBLIC_IP>` into `azure-vm-known-hosts` |
| 8 | Trigger Pipeline Build | Run pipeline or `git push origin main` |
| 9 | Teardown Infrastructure | `terraform destroy -auto-approve` (destroys VM to stop cloud billing) |
