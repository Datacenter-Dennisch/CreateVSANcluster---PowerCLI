#checking PowerCLI modules
write-host "Checking PowerCLI modules" -NoNewline
if (!(get-module -Name VMware.* -ListAvailable)) {
    write-host -ForegroundColor red " - PowerCLI module not loaded, loading PowerCLI module"
    if (!(get-module -Name VMware.* -ListAvailable | Import-Module -ErrorAction SilentlyContinue)) {  
        # Error out if loading fails  
        Write-Error "ERROR: Cannot load the VMware Module. Is PowerCLI installed?"  
     }  
} else {
    write-host -ForegroundColor Yellow " - done"
    write-host -foregroundcolor Yellow "Using PowerCLI version: $(Get-Module -Name VMware.PowerCLI -ListAvailable | Select-Object -ExpandProperty Version)"
}

#checking vCenter connection
write-host "Checking vCenter connection" -NoNewline
do {
    if (!$global:DefaultVIServer) {
        write-host -ForegroundColor Yellow " - Not Connected to a vCenter server!"
        Connect-VIServer -Server (Read-Host "Enter vCenter Server hostname")
    } else {write-host -ForegroundColor Yellow " - done"}
} while (!$global:DefaultVIServer)

Write-host -ForegroundColor Yellow "Connected to vCenter server: $($global:DefaultVIServer.Name)"

#loading functions
function Convert-SubnetToCIDR ([IPaddress]$IP,[IPaddress]$SubnetMask) {
    $IPSubnet = ([IPAddress] (([IPAddress]$IP).Address -band ([IPAddress]$SubnetMask).Address)).IPAddressToString
    $Subnet = 0; $SubnetMask -split "\." | % {$Subnet = $Subnet * 256 + [Convert]::ToInt64($_)}
    return ($IPSubnet + "/" + [Convert]::ToString($Subnet,2).IndexOf('0'))
}

function IP-toINT64 () { 
  param ($ip) 
 
  $octets = $ip.split(".") 
  return [int64]([int64]$octets[0]*16777216 +[int64]$octets[1]*65536 +[int64]$octets[2]*256 +[int64]$octets[3]) 
} 
 
function INT64-toIP() { 
  param ([int64]$int) 

  return (([math]::truncate($int/16777216)).tostring()+"."+([math]::truncate(($int%16777216)/65536)).tostring()+"."+([math]::truncate(($int%65536)/256)).tostring()+"."+([math]::truncate($int%256)).tostring() )
} 

write-host "This script is used for creating VSAN (stretched cluster)"

#query stretched clustering
do {
    $answer = read-host "Must VSAN Cluster be stretched (y/n)"
    if ($answer -eq "y") {$stretchedclusterenabled = $true} else {$stretchedclusterenabled = $false}
}
while ($stretchedclusterenabled -eq $null)

if ($stretchedclusterenabled) {
    do {
        $answer = read-host "Must ""Witness networktraffic seperation"" be used (y/n)"
        if ($answer -eq "y") {$stretchedclusterwitnessisolation = $true} else {$stretchedclusterwitnessisolation = $false}
    }
    while ($stretchedclusterwitnessisolation -eq $null)
}

#review vmhost config VSAN cluster
write-host "Select non VSAN enabled vSphere cluster"
do {$vsancluster =  get-cluster | ? {$_.VsanEnabled -eq $false} | Out-GridView -Title "Select non-vsan cluster" -OutputMode Single
    $vsanvmhosts = $vsancluster | Get-VMHost
    write-host "$($vsancluster) - Cluster contains the following VMhosts:"
    $vsanvmhosts.Name | fl
    $continue = read-host "Continue with VSAN pre-checks (y/n)"
    if ($continue -eq "n") {exit}
}
while ($continue -ne "y")

if ($stretchedclusterenabled) {
    write-host "$($vsancluster) - stretched cluster requires a witness appliance"
    do {
        write-host "$($vsancluster) - select witness appliance"
        $vsanwitnessvmhost = get-vmhost | ? { $_.Model -eq "VMware Virtual Platform"}| Out-GridView -title "$($vsancluster) - select witness appliance" -OutputMode Single
    } while (!$vsanwitnessvmhost)
}
write-host -foreground yellow "$($vsancluster) - select VMhost $vsanwitnessvmhost.name as witness appliance for stretched VSAN cluster"

write-host "Running vSphere Cluster pre-checks" -NoNewline

do {
    if ($vsancluster.HAEnabled) {
        write-host -ForegroundColor red " - error"
        write-host -ForegroundColor red "HA is enabled on cluster, which prohibites the configuration of the VSAN cluster."
        $removeha = read-host "continue disabling vSphere HA on cluster $($vsancluster.name) (y/n/)"
        if ($removeha -eq "y") {
            write-host -ForegroundColor Yellow "Disabling vSphere HA on cluster $($vsancluster.name)"
            Set-Cluster -Cluster $vsancluster -HAEnabled:$false -confirm:$false
        }
    }
    $vsancluster = get-cluster $vsancluster
}
while ($vsancluster.HAEnabled)
write-host -foregroundcolor Yellow " - ready"

#checking vSphere ESXi versions
write-host "Running VMhost version compatibility pre-checks" -NoNewline
if (!($vsanvmhosts.version | select -Unique).count -eq 1) {write-host -ForegroundColor Red " - error"; Write-Host -ForegroundColor red "not all hosts have the same ESXi version installed, update to the same ESXi version and run this script again"; exit} else {write-host -ForegroundColor Yellow " - done"} 

#check VMhost configuration
$vsanvmhostsnonetwork = @()
foreach ($vsanvmhost in $vsanvmhosts) {

    #checking if vmhost is not already joined to an existing vsan cluster, removing the host from the vsan cluster if needed.
    $removeVSAN = $null
    write-host "$($vsanvmhost) - Running VSAN configuration pre-check" -NoNewline
    do {
        if ($vsanvmhost.ExtensionData.Config.VsanHostConfig.Enabled) {
            Write-Host -ForegroundColor Red "- host is already joined to a VSAN cluster"
            $removeVSAN = read-host "continue removing VMhost $($vsanvmhost.Name) from existing VSAN cluster (y/n/)"
            if ($removeVSAN -eq "y") {
                write-host -ForegroundColor Yellow "Removing VMhost $($vsanvmhost.Name) from existing VSAN cluster"
                $esxcli = get-esxcli -VMHost $vsanvmhost -V2
                $esxcli.vsan.cluster.leave.invoke()
            }
        }
        $vsanvmhost = get-vmhost $vsanvmhost
        }
    while ($vsanvmhost.ExtensionData.Config.VsanHostConfig.Enabled)
    write-host -ForegroundColor Yellow " - done"


    #checking if vsan is enabled on any VMK interface of not add to the no network vmhost list
    write-host "$($vsanvmhost) - Running VSAN network configuration prechecks" -NoNewline
    $VMKVSANEnabled = Get-VMHostNetworkAdapter -VMHost $vsanvmhost | ? {$_.VsanTrafficEnabled}
    $VMKVSANenabled = ($VMKVSANEnabled.count -ge 1)
    if (!$VMKVSANenabled) {
        $vsanvmhostsnonetwork += $vsanvmhost
        write-host -ForegroundColor Red " - error"
        write-host -ForegroundColor red "VMhost $($vsanvmhost) has no VSAN enabled VMkernel interfaces, will be configured in a later stage"
    } elseif ((Get-VMHostNetworkAdapter -VMHost $vsanvmhost | ? {$_.VsanTrafficEnabled}).IP -match "169.254.*") {
        $vsanvmhostsnonetwork += $vsanvmhost
        write-host -ForegroundColor Red " - error"
        write-host -ForegroundColor red "VMhost $($vsanvmhost) has VSAN enabled VMkernel interfaces configured with APIPA adress, will be configured in a later stage"
    } else {
        write-host -ForegroundColor Yellow " - done"
    
    }
}

#checking virtual switch configuration
write-host "$($vsancluster) - Running VSAN virtual switch configuration pre-check" -NoNewline
$vsandvswitch = Get-VirtualSwitch -Distributed -VMHost $vsanvmhosts -ErrorAction SilentlyContinue | select -Unique
if ($vsandvswitch.count -eq 0) {
    write-host -ForegroundColor Red " - error"
    write-host -ForegroundColor red "$($vsancluster.name) - VMhosts are not connected to a Distributed vSwitch!"
} elseif ($vsandvswitch.count -ge 2) {
    write-host -ForegroundColor Red " - error"
    write-host -ForegroundColor red "$($vsancluster.name) - VMhosts are  connected to multiple Distributed vSwitces"
    write-host -ForegroundColor red "$($vsancluster.name) - select Distributed vSwitch which must be used for VSAN traffic"
    $vsandvswitch = $vsandvswitch | Out-GridView -Title "Select DVS which must be used for VSAN traffic" -OutputMode Single
    if ($vsandvswitch.mtu -ne 9000) {
        write-host -ForegroundColor yellow "$(vsandvswitch.name) - Jumbo Frames is not enabled"
        write-host -ForegroundColor yellow "$(vsandvswitch.name) - enabling Jumbo Frames"
        $vsandvswitch | Set-VDSwitch -Mtu 9000 -Confirm:$false | Out-Null
    }
} else {
    if ($vsandvswitch.mtu -ne 9000) {
        write-host -ForegroundColor Red " - error"
        write-host -ForegroundColor yellow "$(vsandvswitch.name) - Jumbo Frames is not enabled"
        write-host -ForegroundColor yellow "$(vsandvswitch.name) - enabling Jumbo Frames"
        $vsandvswitch | Set-VDSwitch -Mtu 9000 -Confirm:$false | Out-Null
    } else {write-host -ForegroundColor Yellow " - done"}
}


#inventory VSAN Network
$VMKsVSANEnabled = Get-VMHostNetworkAdapter -VMHost $vsanvmhosts -ErrorAction SilentlyContinue | ? {$_.VsanTrafficEnabled}
$netwerkconfigok,$vsanportgroupsitea,$vsanportgroupsiteb = $null
if ($VMKsVSANEnabled.count -ge 1) {
    write-host "VSAN enabled VMkernel found, continueing with VSAN Network inventory"
    do {
        [System.Collections.ArrayList]$vsanportgroups = @()
        $vsanportgroups += ($VMKsVSANEnabled.PortGroupName | select -Unique)
        if ($stretchedclusterenabled) {
            #stretched cluster config selected, determine VSAN Networks
            if ($vsanportgroups.Count -eq 1) {
                #one VSAN network detected, but stretched VSAN cluster requisted.
                do {
                    write-host -ForegroundColor Yellow "$($vsanportgroups) - one VSAN network detected, please select site preference for VSAN network:"
                    write-host -ForegroundColor Yellow "$($vsanportgroups) - (P) for preferred site "
                    write-host -ForegroundColor Yellow "$($vsanportgroups) - (S) for secondary site "
                    $sitepreference = read-host "Select site preferences (P)referred- or (S)econdary-site (p/s)"
                } while (!(($sitepreference -ne "p") -xor ($sitepreference -ne "s")))
                switch ($sitepreference) {
                    "p" {
                        #Only one VSAN network detected, selecting secondary site
                        write-host -foregroundcolor yellow "$($vsanportgroups) - selected as preferred site"
                        write-host -foregroundcolor yellow "Stretched VSAN Cluster Configuration selected - one VSAN Networks found ($($vsanportgroups)), select secondary site VSAN Network from list"
                        $vsanportgroupsitea = $vsanportgroups
                        $vsanportgroupsiteb = Get-VDPortgroup -VDSwitch (Get-VDSwitch  -VMHost $vsanvmhosts) | Out-GridView -Title "Select VDPortGroup for VSAN Network (secondary site)" -OutputMode Single
                    }
                    "s" {
                        #Only one VSAN network detected, selecting secondary site
                        write-host -foregroundcolor yellow "$($vsanportgroups) - selected as secondary site"
                        write-host -foregroundcolor yellow "Stretched VSAN Cluster Configuration selected - one VSAN Networks found ($($vsanportgroups)), select preferred site VSAN Network from list"
                        $vsanportgroupsiteb = $vsanportgroups
                        $vsanportgroupsitea = Get-VDPortgroup -VDSwitch (Get-VDSwitch  -VMHost $vsanvmhosts) | Out-GridView -Title "Select VDPortGroup for VSAN Network (preferred site)" -OutputMode Single
                    }
                }
            } else {
                #multiple VSAN Networks found, selecting VSAN networks
                write-host "multiple VSAN Networks found, select preferred site VSAN Network"
                $vsanportgroupsitea = $vsanportgroups | Out-GridView -Title "Select Portgroup for preferred site" -OutputMode Single
                $vsanportgroups.Remove($vsanportgroupsitea)
                if ($vsanportgroups.Count -eq 1) {
                    write-host -ForegroundColor yellow  "Stretched VSAN Cluster Configuration selected - only one VSAN Network left: $($vsanportgroups) automatically selected for secondary site"
                    $vsanportgroupsiteb = $vsanportgroups
                } else {
                    write-host -ForegroundColor yellow  "Stretched VSAN Cluster Configuration selected - Multiple VSAN Networks found: selected VSAN Network for secondary site"
                    $vsanportgroupsiteb = $vsanportgroups | Out-GridView -Title "Select Portgroup for preferred site" -OutputMode Single
                    $vsanportgroups.Remove($vsanportgroupsiteb)
                }
            }
            write-host "VSAN Network selected for preferred site : $($vsanportgroupsitea)"
            write-host "VSAN Network selected for secondary site : $($vsanportgroupsiteb)"
        } else {
            if ($vsanportgroups.Count -gt 1) {
                write-host -ForegroundColor red "No stretched VSAN Cluster Selected, but multiple VSAN Networks found!"
                write-host -ForegroundColor Yellow "Network Configuration changed to stretched VSAN Cluster"
                $stretchedclusterenabled = $true
                $vsanportgroupsitea = $vsanportgroups | Out-GridView -Title "Select Portgroup for preferred site" -OutputMode Single
                $vsanportgroups.Remove($vsanportgroupsitea)
                if ($vsanportgroups.Count -eq 1) {
                    write-host -ForegroundColor yellow  "VSAN Network - Stretched Cluster is enabled ; only one VSAN Network left: $($vsanportgroups) automatically selected for secondary site"
                    $vsanportgroupsiteb = $vsanportgroups
                }
                write-host "VSAN Network selected for preferred site : $($vsanportgroupsitea)"
                write-host "VSAN Network selected for secondary site : $($vsanportgroupsiteb)"
            } else {
                $vsanportgroupsitea = $vsanportgroups
                write-host "VSAN Network selected : $($vsanportgroupsitea)"
            }
        }
        $netwerkconfigok = read-host "Continue with current VSAN Netwerk Configuration (y/n)"
    } 
    while ($netwerkconfigok -ne "y")
} else {
        write-host "NO VSAN enabled VMkernel found, continueing with VSAN Network creation"
        do {
            
            if ($vsandvswitch) {
                write-host -ForegroundColor Yellow "$($vsandvswitch) DVS found which is connect to all vmhosts"
                write-host "$($vsandvswitch) - Overview of VDPortGroups on DVS:"
                Get-VDPortgroup -VDSwitch (Get-VDSwitch $vsandvswitch)
                $dvsusage = read-host "Use existing portgroup on $($vsandvswitch) DVS? (y/n)"
                switch ($dvsusage) {
                    "y" {
                        if ($stretchedclusterenabled) {
                            write-host -ForegroundColor Yellow "$($vsandvswitch) - Select VSAN Portgroup for the preferred site"
                            $vsanportgroupsitea = Get-VDPortgroup -VDSwitch (Get-VDSwitch $vsandvswitch) | Out-GridView -Title "Select VDPortGroup for VSAN Network (preferred site)" -OutputMode Single
                            write-host -ForegroundColor Yellow "$($vsandvswitch) - Select VSAN Portgroup for the secondary site"
                            $vsanportgroupsiteb = Get-VDPortgroup -VDSwitch (Get-VDSwitch $vsandvswitch) | Out-GridView -Title "Select VDPortGroup for VSAN Network (secondary site)" -OutputMode Single
                            write-host "VSAN Network selected for preferred site : $($vsanportgroupsitea)"
                            write-host "VSAN Network selected for secondary site : $($vsanportgroupsiteb)"
                        } else {
                            write-host -ForegroundColor Yellow "$($vsandvswitch) - Select VSAN Portgroup"
                            $vsanportgroupsitea = Get-VDPortgroup -VDSwitch (Get-VDSwitch $vsandvswitch) | Out-GridView -Title "Select VDPortGroup for VSAN Network" -OutputMode Single
                            write-host "VSAN Network selected : $($vsanportgroupsitea)"
                        }
                    }
                    "n" {
                        if ($stretchedclusterenabled) {
                        write-host "$($vsandvswitch) - creating VSAN Network Portgroups"
                            $vsanportgroupsitea = New-VDPortgroup -VDSwitch (get-vdswitch $vsandvswitch) -Name (read-host "enter VSAN Portgroup name for preferred site") -VlanId (read-host "enter VSAN Portgroup VLAN id for preferred site (0-4095)")
                            $vsanportgroupsiteb = New-VDPortgroup -VDSwitch (get-vdswitch $vsandvswitch) -Name (read-host "enter VSAN Portgroup name for secondary site") -VlanId (read-host "enter VSAN Portgroup VLAN id for secondary site (0-4095)")
                            write-host "VSAN Network selected for preferred site : $($vsanportgroupsitea)"
                            write-host "VSAN Network selected for secondary site : $($vsanportgroupsiteb)"
                        } else {
                            $vsanportgroupsitea = New-VDPortgroup -VDSwitch (get-vdswitch $vsandvswitch) -Name (read-host "enter VSAN Portgroup name") -VlanId (read-host "enter VSAN Portgroup VLAN id (0-4095)")
                            write-host "VSAN Network selected : $($vsanportgroupsitea)"
                        }
                    }
                }
            } else {
                write-host -ForegroundColor Yellow "No DVS found which is connected to all VMhosts, add VMhosts manually to DVS"
                exit
            }
            $netwerkconfigok = read-host "Continue with current VSAN Network PortGroup Configuration (y/n)"
        }
        while ($netwerkconfigok -ne "y")
}

#inventory and setting VSAN Network IP details
write-host "VSAN Network IP Inventory stage"
$VMKs = Get-VMHostNetworkAdapter -VMHost $vsanvmhosts -ErrorAction SilentlyContinue 
do {
    if ($stretchedclusterenabled) {
        $vsansiteaipdetails = $VMKs | ? {($_.PortGroupName -eq $vsanportgroupsitea) -and !($_.IP -match "169.254.*")} | select-object IP,SubnetMask  -First 1
        if ($vsansiteaipdetails.ip -match "169.254.*") {$vsansiteaipdetails = $null}#filter APIPA addresses
        if ($vsansiteaipdetails) {
            $vsanportgroupsiteaIP = [IPaddress](([IPaddress]$vsansiteaipdetails.IP).Address -band ([IPaddress]$vsansiteaipdetails.SubnetMask).Address)
            $vsanportgroupsiteaSubnet = [IPaddress]$vsansiteaipdetails.SubnetMask
            $vsanportgroupsiteaCIDR = Convert-SubnetToCIDR -IP $vsanportgroupsiteaIP -SubnetMask $vsanportgroupsiteaSubnet
        } else {
            Write-Host -ForegroundColor Yellow "$($vsanportgroupsitea) - No IP Details found"
            $vsanportgroupsiteaIP = [IPaddress](read-host "$($vsanportgroupsitea) - Enter IP Subnet(for example 192.168.1.0)")
            $vsanportgroupsiteaSubnet = [IPaddress](read-host "$($vsanportgroupsitea) - Enter IP SubnetMask(for example 255.255.255.0)")
            $vsanportgroupsiteaCIDR = Convert-SubnetToCIDR -IP $vsanportgroupsiteaIP -SubnetMask $vsanportgroupsiteaSubnet
        }
        write-host "$($vsanportgroupsitea) - CIDR is $($vsanportgroupsiteaCIDR)"
        $vsanportgroupsiteaGW = read-host "$($vsanportgroupsitea) - Enter Default Gateway IP"

        $VSANsiteaIPs = $VMKs | ? {($_.PortGroupName -eq $vsanportgroupsitea) -and !($_.IP -match "169.254.*")} | select-object IP 
        if ($VSANsiteaIPs) {
            
            $VSANsiteaIPPoolstartip = [ipaddress]($VSANsiteaIPs.ip | Sort-Object | select -First 1)
            write-host -ForegroundColor Yellow "$($vsanportgroupsitea) - Starting Host IP determined based on existing VMKs $($VSANsiteaIPPoolstartip)"
            do {
                $acceptautoVSANsiteaIPPoolstartip = read-host -Prompt "$($vsanportgroupsitea) - Accept automatically determined IP Pool starting ip $($VSANsiteaIPPoolstartip) (y/n)"
            } while (!($acceptautoVSANsiteaIPPoolstartip -in "y","n"))
            if ($acceptautoVSANsiteaIPPoolstartip -eq "n") {$VSANsiteaIPPoolstartip = [ipaddress](Read-Host "$($vsanportgroupsitea) - Enter Starting Host IP ($($VSANsiteaIPPoolstartip)) manually")}
        } else {
            write-host -ForegroundColor Yellow "$($vsanportgroupsitea) - No Starting Host IP could be determined automatically"
            $VSANsiteaIPPoolstartip = [ipaddress](Read-Host "$($vsanportgroupsitea) - Enter Starting Host IP (192.168.1.100) manually")
        }
        $VSANsiteaIPPoolendip =  [IPaddress]($vsanportgroupsiteaIP.Address -bor ( -bnot ([IPaddress]$vsanportgroupsiteaSubnet).Address -band [UInt32]::MaxValue))
        $IPpoolstart = IP-toINT64 -ip $VSANsiteaIPPoolstartip.IPAddressToString
        $IPpoolend = IP-toINT64 -ip $VSANsiteaIPPoolendip.IPAddressToString 
        $VSANsiteaIPpool = @()
        foreach ($IPint in $IPpoolstart..$IPpoolend) {
            $IP = INT64-toIP -int $IPint
            $hostname = (($VMKs | ? {$_.IP -eq $IP}).VMHost)
            if ($hostname) { $assignment = "static"} else {$assignment = "undetermined"}
            $VSANsiteaIPPoolEntry = New-Object psobject -property @{
                hostname = $hostname.Name 
                IP = $IP
                assignment = $assignment
            }
            $VSANsiteaIPpool += $VSANsiteaIPPoolEntry
        }

        $vsansitebipdetails = $VMKs | ? {($_.PortGroupName -eq $vsanportgroupsiteb) -and !($_.IP -match "169.254.*")} | select-object IP,SubnetMask  -First 1
        if ($vsansitebipdetails) {
            $vsanportgroupsitebIP = [IPaddress](([IPaddress]$vsansitebipdetails.IP).Address -band ([IPaddress]$vsansitebipdetails.SubnetMask).Address)
            $vsanportgroupsitebSubnet = [IPaddress]$vsansitebipdetails.SubnetMask
            $vsanportgroupsitebCIDR = Convert-SubnetToCIDR -IP $vsanportgroupsitebIP -SubnetMask $vsanportgroupsitebSubnet
        } else {
            Write-Host -ForegroundColor Yellow "$($vsanportgroupsiteb) - No IP Details found"
            $vsanportgroupsitebIP = [IPaddress](read-host "$($vsanportgroupsiteb) - Enter IP Subnet (for example 192.168.2.0)")
            $vsanportgroupsitebSubnet = [IPaddress](read-host "$($vsanportgroupsiteb) - Enter IP SubnetMask (for example 255.255.255.0)")
            $vsanportgroupsitebCIDR = Convert-SubnetToCIDR -IP $vsanportgroupsitebIP -SubnetMask $vsanportgroupsitebSubnet
        }
        write-host "$($vsanportgroupsiteb) - CIDR is $($vsanportgroupsitebCIDR)"
        $vsanportgroupsitebGW = read-host "$($vsanportgroupsiteb) - Enter Default Gateway IP"
        $VSANsitebIPs = $VMKs | ? {($_.PortGroupName -eq $vsanportgroupsiteb) -and !($_.IP -match "169.254.*")} | select-object IP
        if ($VSANsitebIPs) {
            $VSANsitebIPPoolstartip = [ipaddress]($VSANsitebIPs.ip | Sort-Object | select -First 1)
            write-host -ForegroundColor Yellow "$($vsanportgroupsiteb) - Starting Host IP determined based on existing VMKs $($VSANsitebIPPoolstartip)"
            do {
                $acceptautoVSANsitebIPPoolstartip = read-host -Prompt "$($vsanportgroupsiteb) - Accept automatically determined IP Pool starting ip $($VSANsitebIPPoolstartip) (y/n)"
            } while (!($acceptautoVSANsitebIPPoolstartip -in "y","n"))
            if ($acceptautoVSANsitebIPPoolstartip -eq "n") {$VSANsitebIPPoolstartip = [ipaddress](Read-Host "$($vsanportgroupsiteb) - Enter Starting Host IP ($($VSANsitebIPPoolstartip)) manually")}
        } else {
            write-host -ForegroundColor Yellow "$($vsanportgroupsiteb) - No Starting Host IP could be determined automatically"
            $VSANsitebIPPoolstartip = [IPaddress](Read-Host "$($vsanportgroupsiteb) - Enter Starting Host IP (192.168.1.100) manually")
        }
        $VSANsitebIPPoolendip =  [IPaddress]($vsanportgroupsitebIP.Address -bor ( -bnot ([IPaddress]$vsanportgroupsitebSubnet).Address -band [UInt32]::MaxValue))
        $IPpoolstart = IP-toINT64 -ip $VSANsitebIPPoolstartip.IPAddressToString
        $IPpoolend = IP-toINT64 -ip $VSANsitebIPPoolendip.IPAddressToString 
        $VSANsitebIPpool = @()
        foreach ($IPint in $IPpoolstart..$IPpoolend) {
            $IP = INT64-toIP -int $IPint
            $hostname = (($VMKs | ? {$_.IP -eq $IP}).VMHost)
            if ($hostname) {$assignment = "static"} else {$assignment = "undetermined"}
            $VSANsitebIPPoolEntry = New-Object psobject -property @{
                hostname = $hostname.Name 
                IP = $IP
                assignment = $assignment
            }
            $VSANsitebIPpool += $VSANsitebIPPoolEntry
        }

        write-host "$($vsanportgroupsitea) - CIDR $($vsanportgroupsiteaCIDR), GW $($vsanportgroupsiteaGW), VMhost IP Pool ($($VSANsiteaIPPoolstartip)-$($VSANsiteaIPPoolendip))"
        write-host "$($vsanportgroupsiteb) - CIDR $($vsanportgroupsitebCIDR), GW $($vsanportgroupsitebGW), VMhost IP Pool ($($VSANsitebIPPoolstartip)-$($VSANsitebIPPoolendip))"

    } else {
        $vsansiteaipdetails = $VMKs | ? {($_.PortGroupName -eq $vsanportgroupsitea) -and !($_.IP -match "169.254.*")} | select-object IP,SubnetMask  -First 1
        if ($vsansiteaipdetails) {
            $vsanportgroupsiteaIP = [IPaddress](([IPaddress]$vsansiteaipdetails.IP).Address -band ([IPaddress]$vsansiteaipdetails.SubnetMask).Address)
            $vsanportgroupsiteaSubnet = $vsansiteaipdetails.SubnetMask
            $vsanportgroupsiteaCIDR = Convert-SubnetToCIDR -IP $vsanportgroupsiteaIP -SubnetMask $vsanportgroupsiteaSubnet
        } else {
            Write-Host -ForegroundColor Yellow "$($vsanportgroupsitea) - No IP Details found"
            $vsanportgroupsiteaIP = read-host "$($vsanportgroupsitea) - Enter IP Subnet(for example 192.168.1.0)"
            $vsanportgroupsiteaSubnet = read-host "$($vsanportgroupsitea) - Enter IP SubnetMask(for example 255.255.255.0)"
            $vsanportgroupsiteaCIDR = Convert-SubnetToCIDR -IP $vsanportgroupsiteaIP -SubnetMask $vsanportgroupsiteaSubnet
        }
        write-host "$($vsanportgroupsitea) - CIDR is $($vsanportgroupsiteaCIDR)"
        $vsanportgroupsiteaGW = read-host "$($vsanportgroupsitea) - Enter Default Gateway IP"

        $VSANsiteaIPs = $VMKs | ? {($_.PortGroupName -eq $vsanportgroupsitea) -and !($_.IP -match "169.254.*")} | select-object IP 
        if ($VSANsiteaIPs) {
            $VSANsiteaIPPoolstartip = [ipaddress]($VSANsiteaIPs.ip | Sort-Object | select -First 1)
            write-host -ForegroundColor Yellow "$($vsanportgroupsitea) - Starting Host IP determined based on existing VMKs $($VSANsiteaIPPoolstartip)"
            do {
                $acceptautoVSANsiteaIPPoolstartip = read-host -Prompt "$($vsanportgroupsitea) - Accept automatically determined IP Pool starting ip $($VSANsiteaIPPoolstartip) (y/n)"
            } while (!($acceptautoVSANsiteaIPPoolstartip -in "y","n"))
            if ($acceptautoVSANsiteaIPPoolstartip -eq "n") {$VSANsiteaIPPoolstartip = [ipaddress](Read-Host "$($vsanportgroupsitea) - Enter Starting Host IP ($($VSANsiteaIPPoolstartip)) manually")}
        } else {
            write-host -ForegroundColor Yellow "$($vsanportgroupsitea) - No Starting Host IP could be determined automatically"
            $VSANsiteaIPPoolstartip = [ipaddress](Read-Host "$($vsanportgroupsitea) - Enter Starting Host IP (192.168.1.100) manually")
        }
        $VSANsiteaIPPoolendip =  [IPaddress]($vsanportgroupsiteaIP.Address -bor ( -bnot ([IPaddress]$vsanportgroupsiteaSubnet).Address -band [UInt32]::MaxValue))
        $IPpoolstart = IP-toINT64 -ip $VSANsiteaIPPoolstartip.IPAddressToString
        $IPpoolend = IP-toINT64 -ip $VSANsiteaIPPoolendip.IPAddressToString 
        $VSANsiteaIPpool = @()
        foreach ($IPint in $IPpoolstart..$IPpoolend) {
            $IP = INT64-toIP -int $IPint
            $hostname = (($VMKs | ? {$_.IP -eq $IP}).VMHost)
            if ($hostname) { $assignment = "static"} else {$assignment = "undetermined"}
            $VSANsiteaIPPoolEntry = New-Object psobject -property @{
                hostname = $hostname.Name 
                IP = $IP
                assignment = $assignment
            }
            $VSANsiteaIPpool += $VSANsiteaIPPoolEntry
        }

        write-host "$($vsanportgroupsitea) - CIDR $($vsanportgroupsiteaCIDR), GW $($vsanportgroupsiteaGW), VMhost IP Pool ($($VSANsiteaIPPoolstartip)-$($VSANsiteaIPPoolendip))"
    }
    $VSANnetworkConfigOk = read-host  "Continue with current VSAN Network IP Configuration (y/n)"
} while ($VSANnetworkConfigOk -ne "y")

if ($stretchedclusterenabled) {
    write-host "Inventory Site Placement based on VSAN Network configuration" -NoNewline
    #determine VMhost-site placement inventory
    [System.Collections.ArrayList]$vmhostprefferedsite = @()
    [System.Collections.ArrayList]$vmhostsecondarysite = @()
    $vmhostsiteaffinityok = $null
    foreach ($vsanvmhost in $vsanvmhosts) {
        $VMKVSANEnabled = Get-VMHostNetworkAdapter -VMHost $vsanvmhost | ? {$_.VsanTrafficEnabled}
        if ($VMKVSANEnabled.PortGroupName -eq $vsanportgroupsiteb) {$vmhostsecondarysite += $vsanvmhost}
        else {$vmhostprefferedsite += $vsanvmhost}
    }
    write-host -ForegroundColor Yellow " - done"
    do {
        write-host "Stretched Cluster Configuration enabled - Preferred Site VMhosts:"
        $vmhostprefferedsite.name
        write-host "Stretched Cluster Configuration enabled - Secondary Site VMhosts:"
        $vmhostsecondarysite.name
        $vmhostsiteaffinityok = read-host "Continue with current VMhost to site placement (y/n)"
        if ($vmhostsiteaffinityok -eq "n") {
            write-host -ForegroundColor red "Moving VMhosts to other site is NOT recommended!"
            $movehosts = $vsanvmhosts | Out-GridView -Title "Select VMhost to move to other site" -passthru  
            foreach ($movehost in $movehosts) {
                if ($vmhostprefferedsite.contains($movehost)) {
                    $vmhostprefferedsite.remove($movehost)
                    $vmhostsecondarysite.add($movehost)
                } else {
                    $vmhostprefferedsite.add($movehost)
                    $vmhostsecondarysite.remove($movehost)
                }
            }
        }
    }
    while ($vmhostsiteaffinityok -ne "y")
}

#IP addressing
write-host "Determine IP addressing for VMhosts (if applicable)" 
foreach ($vsanvmhost in $vsanvmhosts) {
    if ($stretchedclusterenabled) {
        if ($vmhostprefferedsite.contains($vsanvmhost)) {
            if (!($VSANsiteaIPpool | where-object {($_.hostname -eq $vsanvmhost) -and ($_.assignment = "static")})) {
                $VSANsiteaIPpoolselection = ($VSANsiteaIPpool | where {$_.assignment -eq "undetermined"} | Select-Object -First 1)
                $key = $VSANsiteaIPpool.IP.IndexOf($VSANsiteaIPpoolselection.ip)
                $VSANsiteaIPpool[$key].assignment = "dynamic"
                $VSANsiteaIPpool[$key].hostname = $vsanvmhost
                write-host -ForegroundColor Yellow "$($vsanvmhost) - IP address not pre-provisioned"
                write-host -ForegroundColor Yellow "$($vsanvmhost) - assigning IP address $($VSANsiteaIPpoolselection.ip)"
            } else {
                write-host -ForegroundColor Yellow "$($vsanvmhost) - IP address already assigned"
            }
        } elseif ($vmhostsecondarysite.contains($vsanvmhost)) {
            if (!($VSANsitebIPpool | where-object {($_.hostname -eq $vsanvmhost) -and ($_.assignment = "static")})) {
                $VSANsitebIPpoolselection = ($VSANsitebIPpool | where {$_.assignment -eq "undetermined"} | Select-Object -First 1)
                $key = $VSANsitebIPpool.IP.IndexOf($VSANsitebIPpoolselection.ip)
                $VSANsitebIPpool[$key].assignment = "dynamic"
                $VSANsitebIPpool[$key].hostname = $vsanvmhost
                write-host -ForegroundColor Yellow "$($vsanvmhost) - IP address not pre-provisioned"
                write-host -ForegroundColor Yellow "$($vsanvmhost) - assigning IP address $($VSANsitebIPpoolselection.ip)"
            } else {
                write-host -ForegroundColor Yellow "$($vsanvmhost) - IP address already assigned"
            }
        }
    } else {
        if (!($VSANsiteaIPpool | where-object {($_.hostname -eq $vsanvmhost) -and ($_.assignment = "static")})) {
            $VSANsiteaIPpoolselection = ($VSANsiteaIPpool | where {$_.assignment -eq "undetermined"} | Select-Object -First 1)
            $key = $VSANsiteaIPpool.IP.IndexOf($VSANsiteaIPpoolselection.ip)
            $VSANsiteaIPpool[$key].assignment = "dynamic"
            $VSANsiteaIPpool[$key].hostname = $vsanvmhost
            write-host -ForegroundColor Yellow "$($vsanvmhost) - IP address not pre-provisioned"
            write-host -ForegroundColor Yellow "$($vsanvmhost) - assigning IP address $($VSANsiteaIPpoolselection.ip)"
        } else {
            write-host -ForegroundColor Yellow "$($vsanvmhost) - IP address already assigned"
        }
    }
}

if ($vsanvmhostsnonetwork) {
    write-host -ForegroundColor Yellow "Misconfigured vmhost(s) encountered, start with configure VMhost VSAN Network configuration"
    foreach ($vsanvmhostnonetwork in $vsanvmhostsnonetwork) {
        switch ($stretchedclusterenabled) {
            $false {
                $VMKVSANDisabled = Get-VMHostNetworkAdapter -PortGroup $vsanportgroupsitea -VMHost $vsanvmhostnonetwork -ErrorAction SilentlyContinue
                
                do {
                    if ($VMKVSANDisabled) {
                        if ($VMKVSANDisabled.ip -match "169.254.*") {
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - $($VMKVSANDisabled.Name) found connected to VSAN network (same as other VSAN hosts)."
                            $vmkip = ($VSANsiteaIPpool | where {$_.hostname -eq $vsanvmhostnonetwork}).ip
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - Enabling VSAN on $($VMKVSANDisabled.Name) and configuring IP $($vmkip)"
                            $VMKVSANDisabled | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$true -Mtu 9000 -Confirm:$false -IP $vmkip -SubnetMask $vsanportgroupsiteaSubnet| out-null
                        } else {
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - $($VMKVSANDisabled.Name) found connected to VSAN network (same as other VSAN hosts)."
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - Enabling VSAN on $($VMKVSANDisabled.Name)."
                            $VMKVSANDisabled | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$true -Mtu 9000 -Confirm:$false | out-null
                        }
                    } else {
                        write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - no VMK interface found which is connect to VSAN network"
                        $vmkip = ($VSANsiteaIPpool | where {$_.hostname -eq $vsanvmhostnonetwork}).ip
                        write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - creating VMK interface on VSAN network with IP $($vmkip)"
                        New-VMHostNetworkAdapter -VMHost $vsanvmhostnonetwork -PortGroup $vsanportgroupsitea -VirtualSwitch $vsandvswitch -Mtu 9000 -VsanTrafficEnabled:$true -Confirm:$false -IP $vmkip -SubnetMask $vsanportgroupsiteaSubnet | out-null
                    }

                    $VMKVSANEnabled = Get-VMHostNetworkAdapter -VMHost $vsanvmhostnonetwork | ? {$_.VsanTrafficEnabled}

                }
                while ($VMKVSANEnabled.count -eq "0")
            }
            $true {
                
                if ($vmhostprefferedsite.contains($vsanvmhostnonetwork)) {$VMKVSANDisabled = Get-VMHostNetworkAdapter -PortGroup $vsanportgroupsitea -VMHost $vsanvmhostnonetwork -ErrorAction SilentlyContinue
                } else {$VMKVSANDisabled = Get-VMHostNetworkAdapter -PortGroup $vsanportgroupsiteb -VMHost $vsanvmhostnonetwork -ErrorAction SilentlyContinue}
                
                do {
                    if ($VMKVSANDisabled) {
                        if ($VMKVSANDisabled.ip -match "169.254.*") {
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - $($VMKVSANDisabled.Name) found connected to VSAN network (same as other VSAN hosts)."
                            if ($vmhostprefferedsite.contains($vsanvmhostnonetwork)) {
                                $vmkip = ($VSANsiteaIPpool | where {$_.hostname -eq $vsanvmhostnonetwork}).ip
                                write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - Enabling VSAN on $($VMKVSANDisabled.Name) and configuring IP $($vmkip)"
                                $VMKVSANDisabled | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$true -Mtu 9000 -Confirm:$false -IP $vmkip -SubnetMask $vsanportgroupsiteaSubnet| out-null
                            } else {
                                $vmkip = ($VSANsitebIPpool | where {$_.hostname -eq $vsanvmhostnonetwork}).ip
                                write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - Enabling VSAN on $($VMKVSANDisabled.Name) and configuring IP $($vmkip)"
                                $VMKVSANDisabled | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$true -Mtu 9000 -Confirm:$false -IP $vmkip -SubnetMask $vsanportgroupsitebSubnet| out-null
                            }
                        } else {
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - $($VMKVSANDisabled.Name) found connected to VSAN network (same as other VSAN hosts)."
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - Enabling VSAN on $($VMKVSANDisabled.Name)."
                            $VMKVSANDisabled | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$true -Mtu 9000 -Confirm:$false | out-null
                        }
                    } else {
                        write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - no VMK interface found which is connect to VSAN network"
                        if (
                        $vmhostprefferedsite.contains($vsanvmhostnonetwork)) {
                            $vmkip = ($VSANsiteaIPpool | where {$_.hostname -eq $vsanvmhostnonetwork}).ip
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - creating VMK interface on VSAN network with IP $($vmkip)"
                            New-VMHostNetworkAdapter -VMHost $vsanvmhostnonetwork -PortGroup (get-vdportgroup $vsanportgroupsitea) -VirtualSwitch $vsandvswitch -Mtu 9000 -VsanTrafficEnabled:$true -Confirm:$false -IP $vmkip -SubnetMask $vsanportgroupsiteaSubnet | Out-Null
                        } else {
                            $vmkip = ($VSANsitebIPpool | where {$_.hostname -eq $vsanvmhostnonetwork}).ip
                            write-host -ForegroundColor Yellow "$($vsanvmhostnonetwork) - creating VMK interface on VSAN network with IP $($vmkip)"
                            New-VMHostNetworkAdapter -VMHost $vsanvmhostnonetwork -PortGroup (get-vdportgroup $vsanportgroupsiteb) -VirtualSwitch $vsandvswitch -Mtu 9000 -VsanTrafficEnabled:$true -Confirm:$false -IP $vmkip -SubnetMask $vsanportgroupsitebSubnet | Out-Null
                        }
                    }

                    $VMKVSANEnabled = Get-VMHostNetworkAdapter -VMHost $vsanvmhostnonetwork | ? {$_.VsanTrafficEnabled} #check if all vmhost are connected to VSAN networks
                    
                }
                while ($VMKVSANEnabled.count -eq "0")
            }
        }
    }
}



#mtu check on VMKs
$VSANVMKs = $vsanvmhosts | Get-VMHostNetworkAdapter | ? {$_.VsanTrafficEnabled}
foreach ($VSANVMK in $VSANVMKs) {
    if ($VSANVMK.Mtu -ne 9000) {
        write-host -ForegroundColor yellow "$($VSANVMK.VMhost) - Jumbo frames is not enabled on $($VSANVMK.name)"
        write-host -ForegroundColor yellow "$($VSANVMK.VMhost) - enabling Jumbo Frames on $($VSANVMK.name)"
        $VSANVMK | Set-VMHostNetworkAdapter -Mtu 9000 -Confirm:$false | Out-Null
    }  
}

#connectivity routes check
if ($stretchedclusterenabled) {
    if (!$stretchedclusterwitnessisolation) {
        $witnessvmk = $vsanwitnessvmhost | Get-VMHostNetworkAdapter| ? {$_.VsanTrafficEnabled -eq $True} 
        $vsanportgroupsitecCIDR = Convert-SubnetToCIDR -IP $witnessvmk.IP -SubnetMask $witnessvmk.SubnetMask
    }
    
    foreach ($vsanvmhost in $vsanvmhosts) {
        $vmhostgw = $vsanvmhost.ExtensionData.Config.Network.IpRouteConfig.DefaultGateway
        $vsanvmk = Get-VMHostNetworkAdapter -VMHost $vsanvmhost | ? {$_.VsanTrafficEnabled -eq $True}
        $vsanIP = [IPaddress]$vsanvmk.IP
        $vsansubnet = [IPaddress]$vsanvmk.SubnetMask

        $vsanlocalsubnet = ([IPAddress] (([IPAddress] $vsanvmk.IP).Address -band ([IPAddress] $vsanvmk.SubnetMask).Address)).IPAddressToString

        $vmhostroutes = Get-VMHostRoute -VMHost $vsanvmhost 
        $vmhostipv4routes = $vmhostroutes.Where({$_.Gateway -like "*.*"})
        $vmhostipv4routes = $vmhostipv4routes.Where({$_.Gateway -ne "0.0.0.0"})
        $vmhostunknownroutes = $vmhostipv4routes.Where({$_.Gateway -ne $vmhostgw})
        $vsanremotesubnets = @()
        foreach ($route in $vmhostunknownroutes) {
            $routegw = [IPaddress]$route.Gateway.Address
            if (($routegw.Address -band $vsansubnet.Address) -eq ($vsanip.Address -band $vsansubnet.Address)) {$vsanremotesubnets += $route}
        }
        
         #write-host $vmhost "has the following vsan (remote) routes: "$vsanremotesubnets

        if ($vmhostprefferedsite.contains($vsanvmhost)) {
            if ($vsanremotesubnets.Destination -eq [IPaddress]$vsanportgroupsitebCIDR.Split("/")[0]) {
                write-host -ForegroundColor Yellow "$($vsanvmhost) - Manual added route found for connectivity to secondary site"
            } else {
                write-host -ForegroundColor red "$($vsanvmhost) - NO route found for connectivity to secondary site"
                write-host -ForegroundColor Yellow "$($vsanvmhost) - Adding route to secondary site"
                New-VMHostRoute -VMHost $vsanvmhost -Destination $vsanportgroupsitebCIDR.Split("/")[0] -PrefixLength $vsanportgroupsitebCIDR.Split("/")[1] -Gateway $vsanportgroupsiteaGW -Confirm:$false | out-null
            }
        } else {
            if ($vsanremotesubnets.Destination -eq [IPaddress]$vsanportgroupsiteaCIDR.Split("/")[0]) {
                write-host -ForegroundColor Yellow "$($vsanvmhost) - Manual added route found for connectivity to secondary site"
            } else {
                write-host -ForegroundColor red "$($vsanvmhost) - NO route found for connectivity to secondary site"
                write-host -ForegroundColor Yellow "$($vsanvmhost) - Adding route to secondary site"
                New-VMHostRoute -VMHost $vsanvmhost -Destination $vsanportgroupsiteaCIDR.Split("/")[0] -PrefixLength $vsanportgroupsiteaCIDR.Split("/")[1] -Gateway $vsanportgroupsitebGW -Confirm:$false | out-null
            }
        }
        if (!$stretchedclusterwitnessisolation) {
            if ($vsanremotesubnets.Destination -eq [IPaddress]$vsanportgroupsitecCIDR.Split("/")[0]) {
                write-host  -ForegroundColor Yellow "$($vsanvmhost) - Manual added route found for connectivity to secondary site"
            } else {
                write-host -ForegroundColor red "$($vsanvmhost) - NO route found for connectivity to secondary site"
                write-host -ForegroundColor Yellow "$($vsanvmhost) - Adding route to secondary site"
                New-VMHostRoute -VMHost $vsanvmhost -Destination $vsanportgroupsitecCIDR.Split("/")[0] -PrefixLength $vsanportgroupsitecCIDR.Split("/")[1] -Gateway $vsanportgroupsitebGW -Confirm:$false | out-null
            }
        } else {
            $esxcli = get-esxcli -v2 -VMHost $vsanvmhost
            $vsanvmhostnetworklist = $esxcli.vsan.network.list.invoke()
            if (($vsanvmhostnetworklist.Where({$_.Traffictype -eq "witness"}).count) -ge 1) {
                write-host -ForegroundColor Yellow "$($vsanvmhost) - Traffictype Witness already added to VMK0 interface"
            } else {
                write-host -ForegroundColor red "$($vsanvmhost) - Traffictype Witness not implemented VMK0 interface"
                write-host -ForegroundColor yellow "$($vsanvmhost) - Enabling traffictype Witness on VMK0 interface"
                $esxcli.vsan.network.ip.add.invoke(@{interfacename="vmk0";traffictype="witness"})
            }
        }
    }
}



#enable VSAN on cluster
write-host "$($vsancluster) - enabling VSAN" -NoNewline
$vsancluster | Set-Cluster -VsanEnabled:$true -VsanDiskClaimMode Manual -Confirm:$false
write-host -ForegroundColor Yellow " - Done"

if ($stretchedclusterenabled) {
    write-host -foregroundcolor Yellow "$($vsancluster) - Configuring stretched cluster"
    if ($stretchedclusterwitnessisolation) {
        write-host "$($vsanwitnessvmhost) - Configuring Witness appliance for Witness network traffic seperation"
        $vsanwitnessvmhost |Get-VMHostNetworkAdapter -Name vmk0 | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$true -Confirm:$false | out-null
        $vsanwitnessvmhost |Get-VMHostNetworkAdapter -Name vmk1 | Set-VMHostNetworkAdapter -VsanTrafficEnabled:$false -Confirm:$false | out-null
        write-host -ForegroundColor Yellow " - Done"
    }
    write-host "$($vsancluster) - Configuring fault domains" -NoNewline
    if (Get-VsanFaultDomain -Cluster $vsancluster) {
        write-host -ForegroundColor red " - Error"
        write-host -ForegroundColor Yellow "Existing fault domains found -> will automatically be removed and re-created"
        $oldVsanFaultDomains = Get-VsanFaultDomain -Cluster $vsancluster | Remove-VsanFaultDomain -Confirm:$false
    }
    $VSANPreferredsite = New-VsanFaultDomain -Name "Preferred Site" -VMHost $vmhostprefferedsite -Confirm:$false
    $VSANSecondarysite = New-VsanFaultDomain -Name "Secondary Site" -VMHost $vmhostsecondarysite -Confirm:$false
    write-host -ForegroundColor Yellow " - Done"
    write-host "$($vsancluster) - Configuring VSAN Stretched Cluster" -NoNewline
    Get-VsanClusterConfiguration -Cluster $vsancluster | Set-VsanClusterConfiguration -StretchedClusterEnabled:$true -PreferredFaultDomain $VSANPreferredsite -WitnessHost $vsanwitnessvmhost -WitnessHostCacheDisk "mpx.vmhba1:C0:T2:L0" -WitnessHostCapacityDisk "mpx.vmhba1:C0:T1:L0" -Confirm:$false | Out-Null
    write-host -ForegroundColor Yellow " - Done"
    write-host "$($vsancluster) - Enabling vSphere HA" -NoNewline
    $vsancluster | Set-Cluster -HAEnabled:$true -HAAdmissionControlEnabled:$true -Confirm:$false | out-null
    write-host -ForegroundColor Yellow " - Done"
    write-host "$($vsancluster) - Configuring vSphere HA for VSAN stretched cluster" -NoNewline
    $spec = New-Object VMware.Vim.ClusterConfigSpec
    $spec.DasConfig = New-Object VMware.Vim.ClusterDasConfigInfo
    $spec.DasConfig.AdmissionControlPolicy = New-Object VMware.Vim.ClusterFailoverResourcesAdmissionControlPolicy
    $spec.DasConfig.AdmissionControlPolicy.AutoComputePercentages = $false
    $spec.DasConfig.AdmissionControlPolicy.CpuFailoverResourcesPercent = 50
    $spec.DasConfig.AdmissionControlPolicy.MemoryFailoverResourcesPercent = 50
    $vsancluster.ExtensionData.ReconfigureCluster($spec,$true)
    New-AdvancedSetting -Entity $vsancluster -Type ClusterHA -Name 'das.usedefaultisolationaddress' -Value false -Confirm:$false | out-null
    New-AdvancedSetting -Entity $vsancluster -Type ClusterHA -Name 'das.isolationaddress0' -Value $vsanportgroupsiteaGW -Confirm:$false | out-null
    New-AdvancedSetting -Entity $vsancluster -Type ClusterHA -Name 'das.isolationaddress1' -Value $vsanportgroupsitebGW -Confirm:$false | out-null
    write-host -ForegroundColor Yellow " - Done"
} else { 
}

write-host -ForegroundColor Yellow "Creation of VSAN cluster completed!"
    


