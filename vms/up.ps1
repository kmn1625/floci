<#
.SYNOPSIS
  Real VMs + kubeadm Kubernetes + Argo CD for the floci lab (Windows: Hyper-V + Multipass).

.DESCRIPTION
  0. Needs the k8s-lab switch first: run vms/lab-network.ps1 once as administrator.
  1. Lab SSH key (vms/.keys, gitignored) and cloud-init with that key.
  2. Three Ubuntu 24.04 VMs: k8s-cp1 (control plane), k8s-w1, k8s-w2. Each gets a second NIC on k8s-lab with
     a fixed MAC and a static IP (k8s-cp1 10.77.0.10, workers .11 and up), which survives host restarts.
     cloud-init installs containerd + kubeadm/kubelet/kubectl 1.37.2 (vms/cloud-init).
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
  [string]$CpMemory = "4G",   # 2560M starved kube-controller-manager under load (DRILLS.md, 4 Nov)
  [string]$WorkerMemory = "2G",
  [int]$Cpus = 2,
  [string]$Disk = "15G",
  [string[]]$Workers = @("k8s-w1", "k8s-w2"),
  [string]$Switch = "k8s-lab",
  [int]$LaunchTimeout = 2400,   # cloud-init's apt installs took over 20 min on a slow Ubuntu mirror (15 Nov)
  [string]$IpPrefix = "10.77.0."
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$keys = Join-Path $here ".keys"
$cp = "k8s-cp1"

$mp = (Get-Command multipass -ErrorAction SilentlyContinue).Source
if (-not $mp) { $mp = "$env:ProgramFiles\Multipass\bin\multipass.exe" }
if (-not (Test-Path $mp)) { throw "Multipass not found. Install: winget install Canonical.Multipass (needs Hyper-V + reboot)." }
function Invoke-Multipass { & $mp @args; if ($LASTEXITCODE -ne 0) { throw "multipass $($args -join ' ') failed ($LASTEXITCODE)" } }
if (-not ((& $mp networks --format json | ConvertFrom-Json).list.name -contains $Switch)) {
  throw "Hyper-V switch $Switch not found. Run once as administrator: vms/lab-network.ps1"
}

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
$i = 10
foreach ($n in $nodes) { $n.ip = "$IpPrefix$i"; $n.mac = "52:54:00:77:00:{0:x2}" -f $i; $i++ }
# Static address on the k8s-lab NIC, matched by MAC; no gateway, internet stays on the Default Switch NIC.
# The netplan file takes effect at boot; the live address is added with `ip addr add`. Never `netplan apply` here:
# it re-DHCPs eth0, the link `multipass exec` runs over, and on 15 Nov the exec client then spun a host core for 8 h.
# Runs for kept VMs too, so a re-run repairs a node that lost or never got its address.
function Set-LabAddress($n) {
  $sh = @"
set -e
iface=`$(ip -o link | awk -v m='$($n.mac)' '`$0 ~ m { sub(":", "", `$2); print `$2; exit }')
[ -n "`$iface" ] || { echo 'no NIC with MAC $($n.mac)' >&2; exit 1; }
install -m 600 /dev/stdin /etc/netplan/60-k8s-lab.yaml <<'NETPLAN'
network:
  version: 2
  ethernets:
    k8s-lab:
      match:
        macaddress: "$($n.mac)"
      addresses: [$($n.ip)/24]
      dhcp4: false
      dhcp6: false
      link-local: []
NETPLAN
ip link set "`$iface" up
ip -4 -o addr show dev "`$iface" | grep -q ' $($n.ip)/24 ' || ip addr add $($n.ip)/24 dev "`$iface"
"@
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh.Replace("`r`n", "`n")))
  $p = Start-Process -FilePath $mp -NoNewWindow -PassThru `
         -ArgumentList "exec $($n.name) -- sudo bash -c `"echo $b64 | base64 -d | bash`""
  $null = $p.Handle   # without the cached handle, Windows PowerShell 5.1 leaves ExitCode empty
  if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "$($n.name): setting $($n.ip) timed out after 120 s" }
  if ($p.ExitCode -ne 0) { throw "$($n.name): setting $($n.ip) failed ($($p.ExitCode))" }
  Write-Host "[addr]   $($n.name) $($n.ip)"
}
foreach ($n in $nodes) {
  if ($existing -contains $n.name) {
    Write-Host "[keep]   $($n.name)"
    Invoke-Multipass start $n.name
  } else {
    Write-Host "[launch] $($n.name) ($Cpus CPU, $($n.mem), $Disk, $($n.ip))"
    Invoke-Multipass launch $Image --name $n.name --cpus $Cpus --memory $n.mem --disk $Disk --cloud-init $cloudInit `
      --network "name=$Switch,mode=manual,mac=$($n.mac)" --timeout $LaunchTimeout
  }
  Set-LabAddress $n
}
function ip($name) { ($nodes | Where-Object { $_.name -eq $name }).ip }

# 3. inventory + Ansible on the control plane -----------------------------------
$inv = @("[control_plane]", "$cp ansible_host=$(ip $cp)", "", "[workers]") +
       ($Workers | ForEach-Object { "$_ ansible_host=$(ip $_)" })
$inventory = Join-Path $keys "inventory.ini"
$inv -join "`n" | Set-Content -NoNewline -Encoding ascii $inventory
Write-Host ("[nodes]  " + (($nodes | ForEach-Object { "$($_.name)=$(ip $_.name)" }) -join "  "))

# A kept VM may still be in cloud-init (a launch that hit -LaunchTimeout keeps installing); Ansible needs it finished.
foreach ($w in $Workers) { Invoke-Multipass exec $w '--' bash -c "cloud-init status --wait >/dev/null; command -v kubeadm >/dev/null" }
Invoke-Multipass exec $cp '--' bash -c "cloud-init status --wait >/dev/null; command -v ansible-playbook >/dev/null || sudo apt-get install -y -qq ansible-core >/dev/null"
Invoke-Multipass exec $cp '--' bash -c "rm -rf ~/lab && mkdir -p ~/lab ~/.ssh"
Invoke-Multipass transfer --recursive (Join-Path $here "ansible") "${cp}:lab/"
Invoke-Multipass transfer $inventory "${cp}:lab/ansible/inventory.ini"
# The lab private key is on k8s-cp1 only while Ansible runs: left there, anyone who
# got into the control plane could SSH to every worker.
Invoke-Multipass transfer $key "${cp}:.ssh/lab_ed25519"
try {
  Invoke-Multipass exec $cp '--' bash -c "chmod 600 ~/.ssh/lab_ed25519 && cd ~/lab/ansible && ANSIBLE_FORCE_COLOR=1 ansible-playbook -i inventory.ini site.yml"
} finally {
  & $mp exec $cp -- rm -f /home/ubuntu/.ssh/lab_ed25519
}

# 4. kubeconfig for the host --------------------------------------------------
$kc = Join-Path $keys "kubeconfig"
# A file copy, not `exec sudo cat | Set-Content`: that pipe hung with the exec client spinning a core (15 Nov, twice).
Invoke-Multipass exec $cp '--' sudo install -m 600 -o ubuntu /etc/kubernetes/admin.conf /home/ubuntu/admin.conf
# On Windows transfer exits 2 after a good copy ("cannot set permissions for local file"), so check the file instead.
if (Test-Path $kc) { Remove-Item $kc }
try { & $mp transfer "${cp}:/home/ubuntu/admin.conf" $kc 2>$null }
finally { & $mp exec $cp -- rm -f /home/ubuntu/admin.conf }
if (-not (Test-Path $kc) -or -not (Select-String -Quiet -Path $kc -Pattern '^kind: Config')) { throw "kubeconfig copy from $cp failed" }
Write-Host ""
Write-Host "Cluster ready. kubectl --kubeconfig `"$kc`" get nodes"
Write-Host "Argo CD:  kubectl --kubeconfig `"$kc`" -n argocd port-forward svc/argocd-server 8443:443"
Write-Host "          admin password: kubectl --kubeconfig `"$kc`" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'"
