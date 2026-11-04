<#
.SYNOPSIS
  Static IPs for the lab VMs: an internal Hyper-V switch with a fixed subnet (run once, as administrator).

.DESCRIPTION
  The Default Switch hands out new IPs (and sometimes a new subnet) after a host restart, and the
  cluster's certificates and kubeconfigs name the control plane by IP. This switch keeps its subnet:
  the host is 10.77.0.1 and the VMs get static addresses on a second NIC (k8s-cp1 .10, k8s-w1 .11,
  k8s-w2 .12, set by netplan in the VM). The Default Switch NIC stays for internet and multipass.

  10.77.0.0/24 avoids the pod range (192.168.0.0/16), the Service range (10.96.0.0/12) and the
  172.16.0.0/12 ranges Windows picks for the Default Switch and WSL.

  Safe to re-run: existing pieces are kept.

.EXAMPLE
  Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File vms\lab-network.ps1'
#>
#Requires -RunAsAdministrator
param(
  [string]$Switch = "k8s-lab",
  [string]$HostIp = "10.77.0.1",
  [int]$Prefix = 24,
  [string[]]$Vms = @("k8s-cp1", "k8s-w1", "k8s-w2"),
  [string]$Log
)
$ErrorActionPreference = "Stop"
if ($Log) { Start-Transcript -Path $Log -Force | Out-Null }
try {
  if (-not (Get-VMSwitch -Name $Switch -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $Switch -SwitchType Internal | Out-Null
    Write-Host "[create] switch $Switch"
  } else { Write-Host "[keep]   switch $Switch" }

  $if = "vEthernet ($Switch)"
  if (-not (Get-NetIPAddress -InterfaceAlias $if -IPAddress $HostIp -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $if -IPAddress $HostIp -PrefixLength $Prefix | Out-Null
    Write-Host "[create] host address $HostIp/$Prefix on $if"
  } else { Write-Host "[keep]   host address $HostIp" }

  # Existing VMs get a second NIC (hot-add works on running generation 2 VMs). New VMs get it from
  # `multipass launch --network $Switch` in up.ps1.
  foreach ($vm in $Vms) {
    if (-not (Get-VM -Name $vm -ErrorAction SilentlyContinue)) { Write-Host "[skip]   $vm (no such VM)"; continue }
    $nic = Get-VMNetworkAdapter -VMName $vm | Where-Object SwitchName -eq $Switch
    if (-not $nic) {
      Add-VMNetworkAdapter -VMName $vm -SwitchName $Switch -Name $Switch
      $nic = Get-VMNetworkAdapter -VMName $vm | Where-Object SwitchName -eq $Switch
      Write-Host "[create] $vm NIC on $Switch"
    }
    # netplan in the VM matches this NIC by MAC, so the MAC must not change. Hyper-V can only pin it while
    # the VM is off: run the script again with the VMs stopped.
    if ($nic.DynamicMacAddressEnabled) {
      if ((Get-VM -Name $vm).State -eq "Off") {
        Set-VMNetworkAdapter -VMNetworkAdapter $nic -StaticMacAddress $nic.MacAddress
        Write-Host "[pin]    $vm MAC $($nic.MacAddress)"
      } else { Write-Host "[warn]   $vm MAC $($nic.MacAddress) is dynamic: stop the VM and re-run to pin it" }
    } else { Write-Host "[keep]   $vm MAC $($nic.MacAddress) (static)" }
  }
} finally {
  if ($Log) { Stop-Transcript | Out-Null }
}
