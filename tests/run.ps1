#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in @('windows','network','report','hotspot')){. (Join-Path $root ('src\'+$file+'.ps1'))}
$script:Passed=0
function Check([bool]$Condition,[string]$Name){
    if(-not $Condition){throw $Name}
    $script:Passed++
    Write-Host ('PASS '+$Name)
}
function Throws([scriptblock]$Run,[string]$Text){
    try{& $Run}catch{return $_.Exception.Message.Contains($Text)}
    return $false
}
function Adapter($Name,$Id,$Index,$Type,$Hardware,$Virtual,$Status='Up',$Radio=$false){
    [pscustomobject]@{Name=$Name;Id=$Id;Index=$Index;Type=$Type;Hardware=$Hardware;Virtual=$Virtual;Status=$Status;Radio=$Radio;Description=$(if($Name -like 'Mihomo*'){'Meta Tunnel'}elseif($Virtual){'Microsoft Wi-Fi Direct Virtual Adapter'}else{$Name})}
}
function Fixture {
    [pscustomobject]@{
        Adapters=@(
            (Adapter '无线' '10000000-0000-0000-0000-000000000001' 16 71 $true $false 'Up' $true),
            (Adapter '有线' '10000000-0000-0000-0000-000000000002' 4 6 $true $false),
            (Adapter 'Mihomo' '10000000-0000-0000-0000-000000000003' 30 53 $false $true),
            (Adapter '热点' '10000000-0000-0000-0000-000000000004' 8 71 $false $true 'Disconnected')
        )
        Interfaces=@(
            [pscustomobject]@{Index=16;Family='IPv4';Metric=20;Forwarding='Disabled'},
            [pscustomobject]@{Index=4;Family='IPv4';Metric=10;Forwarding='Enabled'},
            [pscustomobject]@{Index=30;Family='IPv4';Metric=0;Forwarding='Disabled'},
            [pscustomobject]@{Index=8;Family='IPv4';Metric=25;Forwarding='Disabled'}
        )
        Addresses=@([pscustomobject]@{Index=16;IPAddress='10.20.30.40';PrefixLength=24},[pscustomobject]@{Index=4;IPAddress='192.168.1.2';PrefixLength=24})
        Routes=@([pscustomobject]@{Index=16;DestinationPrefix='0.0.0.0/0';RouteMetric=20},[pscustomobject]@{Index=4;DestinationPrefix='0.0.0.0/0';RouteMetric=5},[pscustomobject]@{Index=30;DestinationPrefix='0.0.0.0/0';RouteMetric=0})
    }
}

$data=Fixture
Check ((Select-Wifi $data '').Name -eq '无线') '自动选择无线网卡'
Check ((Select-Internet $data '').Name -eq '有线') '排除 TUN 默认路由'
$data.Routes[0].RouteMetric=0
$data.Interfaces[0].Metric=1
Check ((Select-Internet $data '').Name -eq '无线') '使用路由与接口的合计优先级'
$data=Fixture
$data.Adapters+=Adapter 'Mihomo-2' '10000000-0000-0000-0000-000000000005' 31 53 $false $true
Check (Throws {Select-Tun $data ''} '请选择') '多个 TUN 要求指定'
Check ((Select-Tun $data 'Mihomo-2').Index -eq 31) '按名称指定 TUN'
$data=Fixture
$data.Adapters+=Adapter '无线影子' '10000000-0000-0000-0000-000000000006' 40 71 $true $false
$data.Adapters[0].Status='Disconnected'
Check ((Select-Wifi $data '').Name -eq '无线') '优先真实无线设备'
$data=Fixture
$data.Adapters[3].Status='Up'
$data.Addresses+=[pscustomobject]@{Index=8;IPAddress='172.31.25.1';PrefixLength=24}
Check ((Select-HotspotInterface $data $data.Adapters[0].Id '172.31.25.1').Name -eq '热点') '识别自定义热点网段'
$data.Addresses=@([pscustomobject]@{Index=16;IPAddress='172.31.25.1';PrefixLength=24})
Check ((Select-HotspotInterface $data $data.Adapters[0].Id '172.31.25.1').Name -eq '无线') '识别 WDI 热点接口'
Check (Test-IPv4Subnet '172.31.25.8' '172.31.25.1' 24) 'IPv4 同网段'
Check (-not (Test-IPv4Subnet '172.31.26.8' '172.31.25.1' 24)) 'IPv4 网段边界'
$stream=New-Object IO.MemoryStream
foreach($part in @('{"mode":"规则"',',"tun":{"enable":true}}')){
    $bytes=[Text.Encoding]::UTF8.GetBytes($part)
    $header=[Text.Encoding]::ASCII.GetBytes($bytes.Length.ToString('X')+"`r`n")
    $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length)
    $tail=[Text.Encoding]::ASCII.GetBytes("`r`n");$stream.Write($tail,0,$tail.Length)
}
$end=[Text.Encoding]::ASCII.GetBytes("0`r`n`r`n");$stream.Write($end,0,$end.Length)
$decoded=Decode-ChunkedBody $stream.ToArray()
$decodedJson=[Text.Encoding]::UTF8.GetString($decoded)|ConvertFrom-Json
Check ($decodedJson.mode -eq '规则' -and $decodedJson.tun.enable) '控制接口 UTF-8 分块响应'

# Windows 调用替身，流程测试只写 tests/tmp。
function Reset-Fixture([string]$Case){
    $script:Case=$Case
    $script:Inventory=Fixture
    $script:CoreTun=$true
    $script:Calls=New-Object System.Collections.Generic.List[string]
    $script:Manager=[pscustomobject]@{TetheringOperationalState='Off';ClientCount=0}
    $script:Manager|Add-Member ScriptMethod StartTetheringAsync {
        $script:Calls.Add('start')
        if($script:Case -eq 'start-failure'){return 'Failure'}
        $this.TetheringOperationalState='On'
        ($script:Inventory.Adapters|Where-Object {$_.Name -eq '热点'}).Status='Up'
        if(-not @($script:Inventory.Addresses|Where-Object {$_.Index -eq 8}).Count){$script:Inventory.Addresses+=[pscustomobject]@{Index=8;IPAddress='172.31.25.1';PrefixLength=24}}
        return 'Success'
    }
    $script:Manager|Add-Member ScriptMethod StopTetheringAsync {$script:Calls.Add('stop');$this.TetheringOperationalState='Off';return 'Success'}
    $script:RuntimePrivate=$null
    $script:Connections=@()
    $script:DataRoot=Join-Path $PSScriptRoot ('tmp\'+$Case+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:DataRoot -Force|Out-Null
    $script:StatePath=Join-Path $script:DataRoot 'session.json'
    $script:LogPath=Join-Path $script:DataRoot 'hotspot.log'
    $script:OperationChanged=$false
    $script:SessionCreated=$false
    if($Case -in @('auto-tun','core-failure')){
        $script:Inventory.Adapters=@($script:Inventory.Adapters|Where-Object {$_.Name -ne 'Mihomo'})
        $script:CoreTun=$false
    }
}
function Get-NetworkInventory {return $script:Inventory}
function Get-CoreControllers {return [pscustomobject]@{ProcessId=123;Name='mihomo.exe';Pipe='fixture'}}
function Invoke-Core($Controller,$Path,$Method='GET',$Body=''){
    if($Path -eq '/configs'){return [pscustomobject]@{tun=[pscustomobject]@{enable=$script:CoreTun}}}
    return [pscustomobject]@{connections=$script:Connections}
}
function Set-CoreTun($Controller,[bool]$Enabled){
    $script:Calls.Add('tun-'+$Enabled)
    if($Enabled -and $script:Case -eq 'core-failure'){throw '内核拒绝开启 TUN'}
    $script:CoreTun=$Enabled
    if($Enabled -and -not @($script:Inventory.Adapters|Where-Object {$_.Name -eq 'Mihomo'}).Count){$script:Inventory.Adapters+=Adapter 'Mihomo' '10000000-0000-0000-0000-000000000003' 30 53 $false $true}
    if(-not $Enabled){$script:Inventory.Adapters=@($script:Inventory.Adapters|Where-Object {$_.Name -ne 'Mihomo'})}
}
function Get-ConnectionProfile($AdapterId){return [pscustomobject]@{NetworkAdapter=[pscustomobject]@{NetworkAdapterId=$AdapterId}}}
function Get-RuntimeAdapter($AdapterId){return [pscustomobject]@{NetworkAdapterId=$AdapterId}}
function Get-TetherManager {return $script:Manager}
function Get-TetherCapability($Profile){return 'Enabled'}
function New-TetherManager($Profile,$PrivateAdapter){
    $script:RuntimePrivate=$PrivateAdapter.NetworkAdapterId
    if($script:Case -eq 'private-rejected' -and $script:RuntimePrivate -eq '10000000-0000-0000-0000-000000000004'){throw '接口不接受绑定'}
    return $script:Manager
}
function Wait-Tethering($Operation){if($Operation -ne 'Success'){throw '热点启动失败'}}
function Ensure-SharingServices([switch]$Repair){$script:Calls.Add('services')}
function Get-SharingRows {
    if($script:Manager.TetheringOperationalState -ne 'On'){return @()}
    $source=if($script:RuntimePrivate -eq '10000000-0000-0000-0000-000000000004'){'10000000-0000-0000-0000-000000000003'}else{'10000000-0000-0000-0000-000000000002'}
    return @([pscustomobject]@{Name='上游';Id=$source;Enabled=$true;Role=0},[pscustomobject]@{Name='热点';Id='10000000-0000-0000-0000-000000000004';Enabled=$true;Role=1})
}
function Find-HotspotInterface($Inventory,$WifiId){return Select-HotspotInterface $Inventory $WifiId '172.31.25.1'}
function Get-Service {[CmdletBinding()]param([string[]]$Name)
    foreach($item in $Name){[pscustomobject]@{Name=$item;Status='Running';StartType='Manual'}}
}
function Get-NetIPInterface {[CmdletBinding()]param([int]$InterfaceIndex,[string]$AddressFamily)
    return $script:Inventory.Interfaces|Where-Object {$_.Index -eq $InterfaceIndex -and $_.Family -eq $AddressFamily}
}
function Set-NetIPInterface {[CmdletBinding()]param([int]$InterfaceIndex,[string]$AddressFamily,[string]$Forwarding,[string]$PolicyStore)
    $script:Calls.Add('forward-'+$Forwarding)
    ($script:Inventory.Interfaces|Where-Object {$_.Index -eq $InterfaceIndex -and $_.Family -eq $AddressFamily}).Forwarding=$Forwarding
}

Reset-Fixture 'start-stop'
$wslPath=Join-Path $script:DataRoot '.wslconfig'
[IO.File]::WriteAllText($wslPath,"[wsl2]`r`nnetworkingMode=mirrored`r`nautoProxy=true`r`n")
$wslOptions=Get-WslOptions $wslPath
$wslJson=$wslOptions|ConvertTo-Json -Depth 12
Check ($wslOptions.networkingMode -eq 'mirrored' -and $wslOptions.autoProxy -eq 'true') '读取 WSL 网络选项'
Check ($wslJson.Length -lt 1024 -and $wslJson -notmatch 'PSDrive|PSProvider') 'WSL 报告只保存纯文本字段'
$status=Start-ProxyHotspot
Check ($status.Hotspot -eq 'On' -and $status.SharingRolesConfirmed) '启动并确认共享角色'
Check ($script:Inventory.Interfaces[1].Forwarding -eq 'Disabled') '关闭物理出口 IPv4 转发'
$script:Connections=@(
    [pscustomobject]@{metadata=[pscustomobject]@{sourceIP='172.31.25.8';type='Tun'};chains=@('node');download=128},
    [pscustomobject]@{metadata=[pscustomobject]@{sourceIP='172.31.25.1';type='Tun'};chains=@('node');download=128},
    [pscustomobject]@{metadata=[pscustomobject]@{sourceIP='10.20.30.40';type='Tun'};chains=@('node');download=128},
    [pscustomobject]@{metadata=[pscustomobject]@{sourceIP='172.31.25.9';type='Tun'};chains=@('DIRECT');download=128},
    [pscustomobject]@{metadata=[pscustomobject]@{sourceIP='172.31.25.10';type='HTTP'};chains=@('node');download=128},
    [pscustomobject]@{metadata=[pscustomobject]@{sourceIP='172.31.25.11';type='Tun'};chains=@('node');download=0}
)
$trafficStatus=Get-HotspotStatus
Check ($trafficStatus.ClientTraffic.ProxyConnections -eq 1 -and $trafficStatus.ClientTraffic.DirectConnections -eq 1) '只统计热点设备 TUN 流量'
Check ($trafficStatus.Verification -eq '已观察到热点设备代理流量') '按代理回包确认设备流量'
Restore-Session
Check ($script:Manager.TetheringOperationalState -eq 'Off' -and -not (Read-Session).Active) '停止会话'
Check ($script:Inventory.Interfaces[1].Forwarding -eq 'Enabled' -and $script:CoreTun) '恢复转发并保留原有 TUN'

Reset-Fixture 'auto-tun'
$null=Start-ProxyHotspot
Check ((Read-Session).AutoTun -and $script:CoreTun) '自动开启 TUN'
Restore-Session
Check (-not $script:CoreTun) '关闭脚本开启的 TUN'

Reset-Fixture 'start-failure'
Check (Throws {Start-ProxyHotspot} '热点启动失败') '传播热点启动错误'
Restore-Session -OriginalHotspot
Check (-not (Read-Session).Active -and $script:Manager.TetheringOperationalState -eq 'Off' -and $script:Inventory.Interfaces[1].Forwarding -eq 'Enabled') '启动失败恢复原状态'

Reset-Fixture 'core-failure'
Check (Throws {Start-ProxyHotspot} '内核拒绝') '传播 TUN 开启错误'
Restore-Session -OriginalHotspot
Check (-not $script:CoreTun -and -not (Read-Session).Active) 'TUN 失败恢复原状态'

Reset-Fixture 'private-rejected'
$status=Start-ProxyHotspot
Check ($status.Hotspot -eq 'On' -and -not $status.SharingRolesConfirmed -and $status.Verification -eq '等待手机验证代理路径') '绑定回退保留验证状态'
Restore-Session

Check (-not ((Get-Content -LiteralPath (Join-Path $root 'src\hotspot.ps1') -Raw) -match '\.EnableSharing\(')) '启动流程不写传统 COM 共享'
Write-Host ('通过 '+$script:Passed+' 项测试')
