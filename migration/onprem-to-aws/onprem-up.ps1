<#
.SYNOPSIS
  One small VM that plays the on-prem server for migration drills: onprem1, 10.77.0.20.

.DESCRIPTION
  Needs the k8s-lab switch (vms/lab-network.ps1). The kubeadm cluster does not have to be running.
  Re-running keeps an existing VM.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migration/onprem-to-aws/onprem-up.ps1
#>
param(
  [string]$Name = "onprem1",
  [string]$Ip = "10.77.0.20",
  [string]$Mac = "52:54:00:77:00:14",
  [string]$Switch = "k8s-lab"
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repo = Resolve-Path (Join-Path $here "..\..")
$mp = (Get-Command multipass).Source

$cloudInit = Join-Path $env:TEMP "onprem1-cloud-init.yaml"
# Multipass forwards the Windows time zone, which Ubuntu 24.04 no longer ships (see vms/cloud-init).
"#cloud-config`ntimezone: Etc/UTC`n" | Set-Content -NoNewline -Encoding ascii $cloudInit

if ((& $mp list --format json | ConvertFrom-Json).list.name -contains $Name) {
  Write-Host "[keep]   $Name"
} else {
  Write-Host "[launch] $Name (2 CPU, 1536M, 10G, $Ip)"
  & $mp launch 24.04 --name $Name --cpus 2 --memory 1536M --disk 10G --cloud-init $cloudInit `
    --network "name=$Switch,mode=manual,mac=$Mac" --timeout 900
  if ($LASTEXITCODE -ne 0) { throw "launch failed" }
  # Same static address method as vms/up.ps1: matched by MAC, no gateway, internet stays on eth0.
  $netplan = "network:`n  version: 2`n  ethernets:`n    lab:`n      match:`n        macaddress: `"$Mac`"`n" +
             "      addresses: [$Ip/24]`n      dhcp4: false`n      dhcp6: false`n      link-local: []`n"
  & $mp exec $Name -- sudo bash -c "printf '%s' '$netplan' > /etc/netplan/60-lab.yaml && chmod 600 /etc/netplan/60-lab.yaml"
  & $mp restart $Name
  if ($LASTEXITCODE -ne 0) { throw "restart failed" }
}

Push-Location $repo
try {
  & $mp exec $Name -- mkdir -p shop
  foreach ($f in @("apps/shop/app.py", "apps/shop/requirements.txt", "apps/shop/schema.sql", "migration/onprem-to-aws/onprem-install.sh")) {
    & $mp transfer $f "${Name}:shop/"
    if ($LASTEXITCODE -ne 0) { throw "transfer $f failed" }
  }
} finally { Pop-Location }
& $mp exec $Name -- sudo bash shop/onprem-install.sh
if ($LASTEXITCODE -ne 0) { throw "install failed" }
Write-Host "onprem1 ready: http://$Ip/ready"
