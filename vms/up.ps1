<#
.SYNOPSIS
  Real VMs + kubeadm Kubernetes + Argo CD for the floci lab (Windows: Hyper-V + Multipass).

.DESCRIPTION
  1. Lab SSH key (vms/.keys, gitignored) and cloud-init with that key.
  2. Three Ubuntu 24.04 VMs: k8s-cp1 (control plane), k8s-w1, k8s-w2.
     cloud-init installs containerd + kubeadm/kubelet/kubectl 1.36.6 (vms/cloud-init).
  3. Ansible (vms/ansible) runs ON k8s-cp1: kubeadm init, Calico, worker join,
     Argo CD, and the GitOps root app that syncs k8s/argocd/apps from GitHub.
  4. Copies the admin kubeconfig to vms/.keys/kubeconfig.

  Re-running is safe: existing VMs are kept and Ansible skips finished steps.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File vms/up.ps1
  powershell -ExecutionPolicy Bypass -File vms/up.ps1 -CpMemory 3G -WorkerMemory 2G
#>
param(
  [string]$Image = "24.04",
  [string]$CpMemory = "2560M",
  [string]$WorkerMemory = "2G",
  [int]$Cpus = 2,
  [string]$Disk = "15G",
  [string[]]$Workers = @("k8s-w1", "k8s-w2")
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$keys = Join-Path $here ".keys"
$cp = "k8s-cp1"

$mp = (Get-Command multipass -ErrorAction SilentlyContinue).Source
if (-not $mp) { $mp = "$env:ProgramFiles\Multipass\bin\multipass.exe" }
if (-not (Test-Path $mp)) { throw "Multipass not found. Install: winget install Canonical.Multipass (needs Hyper-V + reboot)." }
function Invoke-Multipass { & $mp @args; if ($LASTEXITCODE -ne 0) { throw "multipass $($args -join ' ') failed ($LASTEXITCODE)" } }

# 1. key + cloud-init ---------------------------------------------------------
New-Item -ItemType Directory -Force $keys | Out-Null
$key = Join-Path $keys "lab_ed25519"
if (-not (Test-Path $key)) {
  ssh-keygen -q -t ed25519 -N '""' -C "floci-lab" -f $key
  if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }
}
$pub = (Get-Content "$key.pub" -Raw).Trim()
$cloudInit = Join-Path $keys "k8s-node.rendered.yaml"
(Get-Content (Join-Path $here "cloud-init\k8s-node.yaml") -Raw).Replace("__SSH_PUBLIC_KEY__", $pub) |
  Set-Content -NoNewline -Encoding utf8 $cloudInit

# 2. VMs ----------------------------------------------------------------------
$existing = (& $mp list --format json | ConvertFrom-Json).list.name
$nodes = @(@{ name = $cp; mem = $CpMemory }) + ($Workers | ForEach-Object { @{ name = $_; mem = $WorkerMemory } })
foreach ($n in $nodes) {
  if ($existing -contains $n.name) { Write-Host "[keep]   $($n.name)"; continue }
  Write-Host "[launch] $($n.name) ($Cpus CPU, $($n.mem), $Disk)"
  Invoke-Multipass launch $Image --name $n.name --cpus $Cpus --memory $n.mem --disk $Disk --cloud-init $cloudInit --timeout 1200
}

$info = (& $mp info --format json ($nodes | ForEach-Object { $_.name }) | ConvertFrom-Json).info
function ip($name) { ($info.$name.ipv4 | Select-Object -First 1) }

# 3. inventory + Ansible on the control plane -----------------------------------
$inv = @("[control_plane]", "$cp ansible_host=$(ip $cp)", "", "[workers]") +
       ($Workers | ForEach-Object { "$_ ansible_host=$(ip $_)" })
$inventory = Join-Path $keys "inventory.ini"
$inv -join "`n" | Set-Content -NoNewline -Encoding ascii $inventory
Write-Host ("[nodes]  " + (($nodes | ForEach-Object { "$($_.name)=$(ip $_.name)" }) -join "  "))

Invoke-Multipass exec $cp '--' bash -c "cloud-init status --wait >/dev/null; command -v ansible-playbook >/dev/null || sudo apt-get install -y -qq ansible-core >/dev/null"
Invoke-Multipass exec $cp '--' bash -c "rm -rf ~/lab && mkdir -p ~/lab ~/.ssh"
Invoke-Multipass transfer --recursive (Join-Path $here "ansible") "${cp}:lab/"
Invoke-Multipass transfer $inventory "${cp}:lab/ansible/inventory.ini"
Invoke-Multipass transfer $key "${cp}:.ssh/lab_ed25519"
Invoke-Multipass exec $cp '--' bash -c "chmod 600 ~/.ssh/lab_ed25519 && cd ~/lab/ansible && ANSIBLE_FORCE_COLOR=1 ansible-playbook -i inventory.ini site.yml"

# 4. kubeconfig for the host --------------------------------------------------
$kc = Join-Path $keys "kubeconfig"
& $mp exec $cp -- sudo cat /etc/kubernetes/admin.conf | Set-Content -Encoding ascii $kc
Write-Host ""
Write-Host "Cluster ready. kubectl --kubeconfig `"$kc`" get nodes"
Write-Host "Argo CD:  kubectl --kubeconfig `"$kc`" -n argocd port-forward svc/argocd-server 8443:443"
Write-Host "          admin password: kubectl --kubeconfig `"$kc`" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'"
