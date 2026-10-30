function Write-Log([string]$Message){
    $line='['+(Get-Date -Format 'HH:mm:ss')+'] '+$Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Read-Session {
    if(Test-Path -LiteralPath $script:StatePath){return Get-Content -LiteralPath $script:StatePath -Raw|ConvertFrom-Json}
    return $null
}

function Save-Session($Session){
    $Session|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function New-Session($Inventory,$Wifi,$Internet){
    $manager=Get-TetherManager
    $hotspotState=$manager.TetheringOperationalState.ToString()
    if($hotspotState -notin @('On','Off')){throw ('热点状态：'+$hotspotState)}
    $sharing=@(Get-SharingRows|Where-Object {$_.Enabled})
    $tunIds=@(Get-TunCandidates $Inventory|ForEach-Object {$_.Id})
    $allowedPublic=@($Wifi.Id,$Internet.Id)+$tunIds
    foreach($row in $sharing){
        $adapter=$Inventory.Adapters|Where-Object {$_.Id -eq $row.Id}|Select-Object -First 1
        if($hotspotState -eq 'Off' -or ($row.Role -eq 0 -and $row.Id -notin $allowedPublic) -or ($row.Role -eq 1 -and $adapter.Type -ne 71)){
            throw '存在其他网络共享'
        }
    }
    $originalPublic=$sharing|Where-Object {$_.Role -eq 0}|Select-Object -First 1
    $originalPrivate=$sharing|Where-Object {$_.Role -eq 1}|Select-Object -First 1
    $ids=@($Wifi.Id,$Internet.Id)+$tunIds+@($Inventory.Adapters|Where-Object {$_.Virtual -and $_.Type -eq 71}|ForEach-Object {$_.Id})
    [pscustomobject]@{
        Version=1;Active=$true;CreatedAt=(Get-Date -Format o);WifiId=$Wifi.Id;InternetId=$Internet.Id;TunId=$null;PrivateId=$null;
        OriginalHotspot=($hotspotState -eq 'On');OriginalPublicId=$(if($originalPublic){$originalPublic.Id}else{$Internet.Id});OriginalPrivateId=$(if($originalPrivate){$originalPrivate.Id}else{$Wifi.Id});
        Forwarding=@(Get-ForwardingSnapshot $Inventory $ids);ManagedIds=@($Wifi.Id,$Internet.Id);AutoTun=$false;Controller=$null;
        Services=@(Get-Service SharedAccess,icssvc|Select-Object Name,@{n='Status';e={$_.Status.ToString()}})
    }
}

function Resolve-StartupTun($Session,[string]$Name){
    $inventory=Get-NetworkInventory
    $existing=@(if($Name){$inventory.Adapters|Where-Object {$_.Virtual -and $_.Status -eq 'Up' -and ($_.Name -eq $Name -or $_.Id -eq $Name)}}else{Get-TunCandidates $inventory})
    if($existing.Count){return Select-Adapter $existing '' 'Mihomo 虚拟网卡'}
    $controllers=@(Get-CoreControllers)
    if($controllers.Count -ne 1){throw '请在代理客户端开启虚拟网卡'}
    $controller=$controllers[0]
    $config=Invoke-Core $controller '/configs'
    $Session.Controller=$controller
    $Session.AutoTun=-not [bool]$config.tun.enable
    Save-Session $Session
    $script:OperationChanged=$true
    Write-Log '开启 Mihomo 虚拟网卡'
    Set-CoreTun $controller $true
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do{
        $inventory=Get-NetworkInventory
        $existing=@(if($Name){$inventory.Adapters|Where-Object {$_.Virtual -and $_.Status -eq 'Up' -and ($_.Name -eq $Name -or $_.Id -eq $Name)}}else{Get-TunCandidates $inventory})
        if($existing.Count){return Select-Adapter $existing '' 'Mihomo 虚拟网卡'}
        Start-Sleep -Milliseconds 500
    }while([DateTime]::UtcNow -lt $deadline)
    throw '虚拟网卡未启动，请以管理员身份运行代理客户端'
}

function Start-ProxyHotspot([string]$WifiName,[string]$TunName,[string]$InternetName,[switch]$Repair){
    $inventory=Get-NetworkInventory
    $wifi=Select-Wifi $inventory $WifiName
    $internet=Select-Internet $inventory $InternetName
    Write-Log ('无线网卡：'+$wifi.Name+'；上网网卡：'+$internet.Name)
    $session=Read-Session
    if($session -and $session.Active){
        if($session.WifiId -ne $wifi.Id -or $session.InternetId -ne $internet.Id){throw '请先停止上一次热点'}
    }else{
        $session=New-Session $inventory $wifi $internet
        Save-Session $session
        $script:SessionCreated=$true
    }
    $tun=Resolve-StartupTun $session $TunName
    $session.TunId=$tun.Id
    $session.ManagedIds=@(@($session.ManagedIds)+$tun.Id|Select-Object -Unique)
    Save-Session $session
    if(-not $session.Controller){
        $controllers=@(Get-CoreControllers)
        if($controllers.Count -eq 1){$session.Controller=$controllers[0];Save-Session $session}
    }
    $profile=Get-ConnectionProfile $tun.Id
    if(-not $profile){throw '虚拟网卡连接配置尚未生成'}
    $capability=Get-TetherCapability $profile
    if($capability -ne 'Enabled'){throw ('热点能力：'+$capability)}
    $script:OperationChanged=$true
    Stop-Tethering
    Ensure-SharingServices -Repair:$Repair
    $radio=Get-RuntimeAdapter $wifi.Id
    if(-not $radio -and @($inventory.Adapters|Where-Object {$_.Hardware -and $_.Type -eq 71 -and $_.Status -in @('Up','Disconnected')}).Count -gt 1){throw '所选无线网卡没有连接配置'}
    Write-Log ('启动热点，上游：'+$tun.Name)
    $manager=New-TetherManager $profile $radio
    Wait-Tethering ($manager.StartTetheringAsync())
    $private=Wait-HotspotInterface $wifi.Id
    $privateAdapter=Get-RuntimeAdapter $private.Id
    if($privateAdapter){
        Stop-Tethering
        try{
            $manager=New-TetherManager (Get-ConnectionProfile $tun.Id) $privateAdapter
            Wait-Tethering ($manager.StartTetheringAsync())
        }catch{
            Write-Log '使用无线网卡绑定'
            Stop-Tethering
            $manager=New-TetherManager (Get-ConnectionProfile $tun.Id) $radio
            Wait-Tethering ($manager.StartTetheringAsync())
        }
        $private=Wait-HotspotInterface $wifi.Id
    }
    $session.PrivateId=$private.Id
    $session.ManagedIds=@(@($session.ManagedIds)+$private.Id|Select-Object -Unique)
    Save-Session $session
    $forward=Get-NetIPInterface -InterfaceIndex $internet.Index -AddressFamily IPv4
    if($forward.Forwarding.ToString() -ne 'Disabled'){
        Set-NetIPInterface -InterfaceIndex $internet.Index -AddressFamily IPv4 -Forwarding Disabled -PolicyStore ActiveStore
    }
    if($manager.TetheringOperationalState.ToString() -ne 'On'){throw '热点未保持开启'}
    Write-Log ('热点网卡：'+$private.Name+'；网关：'+$private.Gateway)
    return Get-HotspotStatus
}

function Restore-Session([switch]$OriginalHotspot){
    $session=Read-Session
    if(-not $session -or -not $session.Active){throw '没有运行中的会话'}
    $inventory=Get-NetworkInventory
    if(-not @($inventory.Adapters|Where-Object {$_.Id -eq $session.WifiId}).Count){throw '会话对应的无线网卡不存在'}
    Stop-Tethering
    if($OriginalHotspot -and $session.OriginalHotspot){
        $profile=Get-ConnectionProfile $session.OriginalPublicId
        $private=Get-RuntimeAdapter $session.OriginalPrivateId
        if(-not $private){$private=Get-RuntimeAdapter $session.WifiId}
        $manager=New-TetherManager $profile $private
        Wait-Tethering ($manager.StartTetheringAsync())
    }
    foreach($saved in @($session.Forwarding|Where-Object {$_.Id -in $session.ManagedIds})){
        $adapter=$inventory.Adapters|Where-Object {$_.Id -eq $saved.Id}|Select-Object -First 1
        if(-not $adapter){continue}
        $current=Get-NetIPInterface -InterfaceIndex $adapter.Index -AddressFamily $saved.Family -ErrorAction SilentlyContinue
        if($current -and $current.Forwarding.ToString() -ne $saved.Forwarding){
            Set-NetIPInterface -InterfaceIndex $adapter.Index -AddressFamily $saved.Family -Forwarding $saved.Forwarding -PolicyStore ActiveStore
        }
    }
    if($session.AutoTun){
        $controller=@(Get-CoreControllers|Where-Object {$_.ProcessId -eq $session.Controller.ProcessId -and $_.Pipe -eq $session.Controller.Pipe})
        if($controller.Count -eq 1){Set-CoreTun $controller[0] $false}
    }
    foreach($saved in @($session.Services)){
        if($saved.Status -eq 'Stopped' -and (Get-Service $saved.Name).Status -eq 'Running'){Stop-Service $saved.Name}
    }
    $session.Active=$false
    Save-Session $session
    Write-Log '会话已恢复'
}
