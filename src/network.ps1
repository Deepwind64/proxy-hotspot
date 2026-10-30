function Get-NetworkInventory {
    $physicalIds=@(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True'|Where-Object {$_.GUID}|ForEach-Object {([guid]$_.GUID).ToString()})
    [pscustomobject]@{
        Adapters=@(Get-NetAdapter -IncludeHidden|ForEach-Object {[pscustomobject]@{
            Name=$_.Name;Id=([guid]$_.InterfaceGuid).ToString();Index=$_.ifIndex;Description=$_.InterfaceDescription;
            Status=$_.Status.ToString();Hardware=[bool]$_.HardwareInterface;Radio=($_.InterfaceType -eq 71 -and ([guid]$_.InterfaceGuid).ToString() -in $physicalIds);Virtual=[bool]$_.Virtual;Type=[int]$_.InterfaceType;Driver=$_.DriverVersion
        }})
        Interfaces=@(Get-NetIPInterface|ForEach-Object {[pscustomobject]@{
            Index=$_.InterfaceIndex;Family=$_.AddressFamily.ToString();Forwarding=$_.Forwarding.ToString();Metric=$_.InterfaceMetric;State=$_.ConnectionState.ToString()
        }})
        Addresses=@(Get-NetIPAddress -AddressFamily IPv4|Select-Object @{n='Index';e={$_.InterfaceIndex}},IPAddress,PrefixLength)
        Routes=@(Get-NetRoute -AddressFamily IPv4|Where-Object {$_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1')}|
            Select-Object @{n='Index';e={$_.InterfaceIndex}},DestinationPrefix,NextHop,RouteMetric)
    }
}

function Select-Adapter($Candidates,[string]$Name,[string]$Kind){
    $rows=@($Candidates)
    if($Name){$rows=@($rows|Where-Object {$_.Name -eq $Name -or $_.Id -eq $Name})}
    if($rows.Count -eq 0){throw ('未找到'+$Kind)}
    if($rows.Count -gt 1){throw ('请选择'+$Kind+'：'+(($rows.Name)-join '、'))}
    return $rows[0]
}

function Select-Wifi($Inventory,[string]$Name){
    $candidates=@($Inventory.Adapters|Where-Object {$_.Hardware -and $_.Type -eq 71 -and $_.Status -in @('Up','Disconnected')})
    if(-not $Name){
        $radios=@($candidates|Where-Object {$_.Radio})
        if($radios.Count){$candidates=$radios}
        $up=@($candidates|Where-Object {$_.Status -eq 'Up'})
        if($up.Count -eq 1){return $up[0]}
    }
    return Select-Adapter $candidates $Name '无线网卡'
}

function Get-TunCandidates($Inventory){
    return @($Inventory.Adapters|Where-Object {
        $_.Status -eq 'Up' -and $_.Virtual -and
        ($_.Description -match '(?i)Meta Tunnel|Mihomo|Clash' -or ($_.Type -eq 53 -and $_.Name -match '(?i)Mihomo|Meta|Clash'))
    })
}

function Select-Tun($Inventory,[string]$Name){
    $candidates=if($Name){@($Inventory.Adapters|Where-Object {$_.Status -eq 'Up' -and $_.Virtual})}else{@(Get-TunCandidates $Inventory)}
    return Select-Adapter $candidates $Name 'Mihomo 虚拟网卡'
}

function Select-Internet($Inventory,[string]$Name){
    $candidates=@($Inventory.Adapters|Where-Object {$_.Hardware -and $_.Status -eq 'Up'})
    if($Name){return Select-Adapter $candidates $Name '上网网卡'}
    $routes=@(foreach($route in $Inventory.Routes|Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'}){
        $adapter=@($candidates|Where-Object {$_.Index -eq $route.Index})
        if($adapter.Count){
            $interface=$Inventory.Interfaces|Where-Object {$_.Index -eq $route.Index -and $_.Family -eq 'IPv4'}|Select-Object -First 1
            [pscustomobject]@{Adapter=$adapter[0];Metric=([int]$route.RouteMetric+[int]$interface.Metric)}
        }
    })
    if(-not $routes.Count){throw '未找到物理上网网卡'}
    $best=($routes|Measure-Object Metric -Minimum).Minimum
    $choices=@($routes|Where-Object {$_.Metric -eq $best}|ForEach-Object {$_.Adapter}|Sort-Object Id -Unique)
    return Select-Adapter $choices '' '上网网卡'
}

function Find-HotspotInterface($Inventory,[string]$WifiId){
    $key=Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters'
    $scope=$key.GetValue('ScopeAddress')
    return Select-HotspotInterface $Inventory $WifiId $scope
}

function Select-HotspotInterface($Inventory,[string]$WifiId,[string]$Scope){
    $addresses=@($Inventory.Addresses|Where-Object {$_.IPAddress -notmatch '^(127\.|169\.254\.)'})
    if($Scope){$addresses=@($addresses|Where-Object {$_.IPAddress -eq $Scope})}
    $candidates=@(foreach($address in $addresses){
        foreach($adapter in @($Inventory.Adapters|Where-Object {$_.Index -eq $address.Index -and $_.Status -eq 'Up' -and $_.Type -eq 71})){
            if($adapter.Virtual -or $adapter.Id -eq $WifiId){
                [pscustomobject]@{Name=$adapter.Name;Id=$adapter.Id;Index=$adapter.Index;Gateway=$address.IPAddress;PrefixLength=$address.PrefixLength}
            }
        }
    })
    $candidates=@($candidates|Sort-Object Id -Unique)
    if($candidates.Count -eq 1){return $candidates[0]}
    return $null
}

function Wait-HotspotInterface([string]$WifiId){
    for($attempt=0;$attempt -lt 20;$attempt++){
        $interface=Find-HotspotInterface (Get-NetworkInventory) $WifiId
        if($interface){return $interface}
        Start-Sleep -Milliseconds 500
    }
    throw '热点网卡未取得网关地址'
}

function Get-ForwardingSnapshot($Inventory,[string[]]$Ids){
    return @(foreach($adapter in $Inventory.Adapters|Where-Object {$_.Id -in $Ids}){
        foreach($interface in $Inventory.Interfaces|Where-Object {$_.Index -eq $adapter.Index}){
            [pscustomobject]@{Id=$adapter.Id;Family=$interface.Family;Forwarding=$interface.Forwarding}
        }
    })
}

function Test-IPv4Subnet([string]$Address,[string]$Gateway,[int]$PrefixLength){
    $a=[Net.IPAddress]::Parse($Address).GetAddressBytes()
    $b=[Net.IPAddress]::Parse($Gateway).GetAddressBytes()
    if($a.Length -ne 4 -or $b.Length -ne 4){return $false}
    for($i=0;$i -lt 4;$i++){
        $bits=[Math]::Min(8,[Math]::Max(0,$PrefixLength-8*$i))
        $mask=if($bits){(255 -shl (8-$bits)) -band 255}else{0}
        if(($a[$i] -band $mask) -ne ($b[$i] -band $mask)){return $false}
    }
    return $true
}
