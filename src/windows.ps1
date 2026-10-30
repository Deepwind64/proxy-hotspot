function Initialize-Windows {
    if($PSVersionTable.PSEdition -eq 'Core'){throw '请使用 hotspot.cmd'}
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows,ContentType=WindowsRuntime]
    [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows,ContentType=WindowsRuntime]
    $script:TetherResult=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult,Windows,ContentType=WindowsRuntime]
    $script:AsTask=[System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and
        $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    }|Select-Object -First 1
}

function Wait-Tethering($Operation){
    $task=$script:AsTask.MakeGenericMethod($script:TetherResult).Invoke($null,@($Operation))
    if(-not $task.Wait(30000)){
        $Operation.Cancel()
        try{$null=$task.Wait(10000)}catch{}
        throw '热点操作超时'
    }
    $result=$task.Result
    if($result.Status.ToString() -ne 'Success'){throw ('热点：'+$result.Status+' '+$result.AdditionalErrorMessage)}
}

function Get-ConnectionProfile([string]$AdapterId){
    $scores=@{InternetAccess=3;ConstrainedInternetAccess=2;LocalAccess=1;None=0}
    $profiles=@([Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles())
    if($AdapterId){$profiles=@($profiles|Where-Object {$_.NetworkAdapter.NetworkAdapterId -eq [guid]$AdapterId})}
    return ($profiles|Sort-Object @{Expression={$scores[$_.GetNetworkConnectivityLevel().ToString()]};Descending=$true}|Select-Object -First 1)
}

function Get-RuntimeAdapter([string]$AdapterId){
    $profile=Get-ConnectionProfile $AdapterId
    if($profile){return $profile.NetworkAdapter}
    $address=@([Windows.Networking.Connectivity.NetworkInformation]::GetHostNames()|Where-Object {
        $_.IPInformation -and $_.IPInformation.NetworkAdapter.NetworkAdapterId -eq [guid]$AdapterId
    }|Select-Object -First 1)
    if($address.Count){return $address[0].IPInformation.NetworkAdapter}
    return $null
}

function New-TetherManager($Profile,$PrivateAdapter){
    if(-not $Profile){throw '未找到网络连接配置'}
    if($PrivateAdapter){return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($Profile,$PrivateAdapter)}
    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($Profile)
}

function Get-TetherCapability($Profile){
    return [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapabilityFromConnectionProfile($Profile).ToString()
}

function Get-TetherManager {
    $profile=[Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if(-not $profile){$profile=Get-ConnectionProfile}
    return New-TetherManager $profile $null
}

function Stop-Tethering {
    $manager=Get-TetherManager
    $state=$manager.TetheringOperationalState.ToString()
    if($state -eq 'On'){Wait-Tethering ($manager.StopTetheringAsync())}
    elseif($state -ne 'Off'){throw ('热点状态：'+$state)}
}

function Get-SharingRows {
    $manager=New-Object -ComObject HNetCfg.HNetShare
    $rows=@()
    foreach($connection in $manager.EnumEveryConnection){
        $properties=$manager.NetConnectionProps($connection)
        $config=$manager.INetSharingConfigurationForINetConnection($connection)
        $rows+=[pscustomobject]@{Name=$properties.Name;Id=([guid]$properties.Guid).ToString();Enabled=[bool]$config.SharingEnabled;Role=$(if($config.SharingEnabled){[int]$config.SharingConnectionType}else{-1})}
    }
    return $rows
}

function Get-CoreControllers {
    $controllers=@()
    foreach($process in @(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^(mihomo|verge-mihomo|clash-meta)\.exe$'})){
        if($process.CommandLine -match '(?i)-ext-ctl-pipe\s+(?:"([^"]+)"|(\S+))'){
            $pipe=if($matches[1]){$matches[1]}else{$matches[2]}
            $prefix='\\.\pipe\'
            if($pipe.StartsWith($prefix)){$pipe=$pipe.Substring($prefix.Length)}
            $controllers+=[pscustomobject]@{ProcessId=$process.ProcessId;Name=$process.Name;Pipe=$pipe}
        }
    }
    return $controllers
}

function Decode-ChunkedBody([byte[]]$Bytes){
    $output=New-Object IO.MemoryStream
    $offset=0
    while($offset -lt $Bytes.Length){
        $end=$offset
        while($end+1 -lt $Bytes.Length -and -not ($Bytes[$end] -eq 13 -and $Bytes[$end+1] -eq 10)){$end++}
        $line=[Text.Encoding]::ASCII.GetString($Bytes,$offset,$end-$offset)
        $length=[Convert]::ToInt32(($line -split ';')[0],16)
        if($length -eq 0){break}
        $offset=$end+2
        $output.Write($Bytes,$offset,$length)
        $offset+=$length+2
    }
    return ,$output.ToArray()
}

function Invoke-Core($Controller,[string]$Path,[string]$Method='GET',[string]$Body=''){
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.', $Controller.Pipe, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try{
        $pipe.Connect(3000)
        $bodyBytes=[Text.Encoding]::UTF8.GetBytes($Body)
        $header=[Text.Encoding]::ASCII.GetBytes("$Method $Path HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`n`r`n")
        $pipe.Write($header,0,$header.Length)
        if($bodyBytes.Length){$pipe.Write($bodyBytes,0,$bodyBytes.Length)}
        $pipe.Flush()
        $output=New-Object IO.MemoryStream
        $buffer=New-Object byte[] 8192
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while($true){
            $read=$pipe.ReadAsync($buffer,0,$buffer.Length)
            $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
            if($remaining -le 0 -or -not $read.Wait($remaining)){throw '代理控制接口超时'}
            if($read.Result -eq 0){break}
            $output.Write($buffer,0,$read.Result)
        }
        $bytes=$output.ToArray()
        $text=[Text.Encoding]::UTF8.GetString($bytes)
        $split=$text.IndexOf("`r`n`r`n")
        $headers=$text.Substring(0,$split)
        $status=[int](($headers -split "`r`n")[0] -split ' ')[1]
        if($status -lt 200 -or $status -ge 300){throw ('代理控制接口 HTTP '+$status)}
        $bodyOffset=[Text.Encoding]::UTF8.GetByteCount($text.Substring(0,$split+4))
        [byte[]]$payload=if($bytes.Length -gt $bodyOffset){$bytes[$bodyOffset..($bytes.Length-1)]}else{@()}
        if($headers -match '(?i)Transfer-Encoding:\s*chunked'){$payload=Decode-ChunkedBody $payload}
        $json=[Text.Encoding]::UTF8.GetString($payload)
        if($json.Trim()){return $json|ConvertFrom-Json}
    }finally{$pipe.Dispose()}
}

function Set-CoreTun($Controller,[bool]$Enabled){
    $body=@{tun=@{enable=$Enabled}}|ConvertTo-Json -Compress
    $null=Invoke-Core $Controller '/configs' 'PATCH' $body
}

function Ensure-SharingServices([switch]$Repair){
    foreach($name in @('SharedAccess','icssvc')){
        $service=Get-Service $name
        if($service.StartType -eq 'Disabled'){throw ('服务已禁用：'+$name)}
        if($service.Status -ne 'Running'){Start-Service $name}
    }
    if($Repair){
        Write-Log '重启网络共享服务'
        Restart-Service SharedAccess
        (Get-Service SharedAccess).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
        Start-Service icssvc
    }
}
