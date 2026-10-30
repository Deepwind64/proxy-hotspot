function Read-Optional([scriptblock]$Read){
    try{return & $Read}catch{return [pscustomobject]@{Error=$_.Exception.Message}}
}

function Get-WslOptions([string]$Path){
    $options=[ordered]@{Present=[IO.File]::Exists($Path)}
    if($options.Present){
        foreach($line in [IO.File]::ReadAllLines($Path)){
            if($line -match '^\s*(networkingMode|dnsTunneling|autoProxy)\s*=\s*([^#;\s]+)'){$options[$matches[1]]=$matches[2]}
        }
    }
    return [pscustomobject]$options
}

function Get-ClientProxyTraffic($Controller,$Private){
    $result=[pscustomobject]@{ProxyConnections=0;DirectConnections=0}
    if(-not $Controller -or -not $Private){return $result}
    $connections=Invoke-Core $Controller '/connections'
    foreach($connection in @($connections.connections)){
        $source=$connection.metadata.sourceIP
        if(-not $source -or $source.Contains(':') -or $source -eq $Private.Gateway){continue}
        if($connection.metadata.type -ne 'Tun' -or -not (Test-IPv4Subnet $source $Private.Gateway $Private.PrefixLength)){continue}
        $chain=@($connection.chains)
        if($chain -contains 'DIRECT'){$result.DirectConnections++}
        elseif($chain.Count -and $connection.download -gt 0){$result.ProxyConnections++}
    }
    return $result
}

function Get-HotspotStatus($Inventory=$null){
    if(-not $Inventory){$Inventory=Get-NetworkInventory}
    $session=Read-Session
    $manager=Get-TetherManager
    $tun=if($session){$Inventory.Adapters|Where-Object {$_.Id -eq $session.TunId}|Select-Object -First 1}else{Get-TunCandidates $Inventory|Select-Object -First 1}
    $wifiId=if($session){$session.WifiId}else{
        $choices=@($Inventory.Adapters|Where-Object {$_.Hardware -and $_.Type -eq 71 -and $_.Status -in @('Up','Disconnected')})
        if($choices.Count -eq 1){$choices[0].Id}else{''}
    }
    $private=Find-HotspotInterface $Inventory $wifiId
    $sharingRead=Read-Optional {Get-SharingRows}
    $sharing=@($sharingRead|Where-Object {$_.Id})
    $sharingError=($sharingRead|Where-Object {$_.Error}|ForEach-Object {$_.Error}) -join '; '
    $upstream=@($sharing|Where-Object {$_.Enabled -and $_.Role -eq 0})
    $downstream=@($sharing|Where-Object {$_.Enabled -and $_.Role -eq 1})
    $rolesConfirmed=($tun -and $private -and $upstream.Count -eq 1 -and $upstream[0].Id -eq $tun.Id -and $downstream.Count -eq 1 -and $downstream[0].Id -eq $private.Id)
    $controllers=@(Get-CoreControllers)
    $controller=if($session -and $session.Controller){$controllers|Where-Object {$_.ProcessId -eq $session.Controller.ProcessId -and $_.Pipe -eq $session.Controller.Pipe}|Select-Object -First 1}elseif($controllers.Count -eq 1){$controllers[0]}else{$null}
    $traffic=Read-Optional {Get-ClientProxyTraffic $controller $private}
    $verification=if($traffic.ProxyConnections -gt 0){'已观察到热点设备代理流量'}elseif($rolesConfirmed){'共享上游已确认，等待手机测试'}else{'等待手机验证代理路径'}
    [pscustomobject]@{
        Hotspot=$manager.TetheringOperationalState.ToString();Clients=$manager.ClientCount;Tun=$tun.Name;
        Private=$private;SharingRolesConfirmed=[bool]$rolesConfirmed;SharingError=$sharingError;ClientTraffic=$traffic;Verification=$verification
    }
}

function Get-Diagnostics {
    Write-Log '采集网卡'
    $inventory=Get-NetworkInventory
    $os=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $controllers=@(Get-CoreControllers)
    Write-Log '采集控制接口'
    $core=if($controllers.Count -eq 1){Read-Optional {
        $config=Invoke-Core $controllers[0] '/configs'
        $config|Select-Object mode,'allow-lan','mixed-port','socks-port',tun
    }}else{$null}
    $wsl=Read-Optional {Get-WslOptions (Join-Path $env:USERPROFILE '.wslconfig')}
    Write-Log '采集热点'
    $hotspot=Read-Optional {Get-HotspotStatus $inventory}
    Write-Log '采集共享'
    $sharing=Read-Optional {Get-SharingRows}
    [ordered]@{
        Schema=1;CollectedAt=(Get-Date -Format o);Windows=$os.ProductName;Build=($os.CurrentBuildNumber+'.'+$os.UBR);
        Network=$inventory;Hotspot=$hotspot;
        Sharing=$sharing;Controllers=$controllers;Core=$core;
        Dns=@(Get-DnsClientServerAddress|Where-Object {$_.ServerAddresses.Count}|Select-Object InterfaceAlias,InterfaceIndex,AddressFamily,ServerAddresses);
        Services=@(Get-Service SharedAccess,icssvc,WlanSvc,hns,EventSystem,Netman -ErrorAction SilentlyContinue|Select-Object Name,@{n='Status';e={$_.Status.ToString()}},@{n='StartType';e={$_.StartType.ToString()}});
        Wsl=$wsl
    }
}

function Save-Report($Data,[string]$Label='collected',$Failure=$null){
    Write-Log '写入报告'
    $folder=Join-Path $script:DataRoot 'reports'
    New-Item -ItemType Directory -Path $folder -Force|Out-Null
    $path=Join-Path $folder ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$Label+'.txt')
    $report=[ordered]@{Report=$Data;Failure=$Failure}
    $text="代理热点诊断`r`n"+($report|ConvertTo-Json -Depth 12)
    [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($true)))
    return $path
}
