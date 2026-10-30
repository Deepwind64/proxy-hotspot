#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('start','stop','restore','status','collect')][string]$Action='start',
    [string]$Wifi,
    [string]$Tun,
    [string]$Internet,
    [switch]$Repair,
    [switch]$Elevated,
    [string]$RunId
)

$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetDirectoryName($PSCommandPath)
$dataRoot=Join-Path $projectRoot 'data'
New-Item -ItemType Directory -Path $dataRoot -Force|Out-Null
if(-not $RunId){$RunId=[guid]::NewGuid().ToString()}
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if($Action -ne 'status' -and -not $isAdmin){
    if($Elevated){Write-Host '需要管理员权限';exit 1}
    $command="& '"+$PSCommandPath.Replace("'","''")+"' -Action '$Action' -Elevated -RunId '$RunId'"
    foreach($pair in @(@('Wifi',$Wifi),@('Tun',$Tun),@('Internet',$Internet))){
        if($pair[1]){$command+=' -'+$pair[0]+" '"+$pair[1].Replace("'","''")+"'"}
    }
    if($Repair){$command+=' -Repair'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try{
        $child=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        $resultPath=Join-Path $dataRoot 'result.json'
        if(Test-Path -LiteralPath $resultPath){
            $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
            if($result.RunId -eq $RunId){Write-Host $result.Message;if($result.Report){Write-Host ('报告：'+$result.Report)}}
        }
        exit $child.ExitCode
    }catch{Write-Host $_.Exception.Message;exit 1}
}

. (Join-Path $projectRoot 'src\windows.ps1')
. (Join-Path $projectRoot 'src\network.ps1')
. (Join-Path $projectRoot 'src\report.ps1')
. (Join-Path $projectRoot 'src\hotspot.ps1')
$script:DataRoot=$dataRoot
$script:StatePath=Join-Path $dataRoot 'session.json'
$script:LogPath=Join-Path $dataRoot 'hotspot.log'
$script:OperationChanged=$false
$script:SessionCreated=$false
$reportPath=$null
$exitCode=0
try{
    Initialize-Windows
    switch($Action){
        'collect' {$reportPath=Save-Report (Get-Diagnostics);$message='采集完成'}
        'status' {$status=Get-HotspotStatus;$status|ConvertTo-Json -Depth 8|Write-Host;$message='状态已读取'}
        'start' {
            $reportPath=Save-Report (Get-Diagnostics)
            $status=Start-ProxyHotspot -WifiName $Wifi -TunName $Tun -InternetName $Internet -Repair:$Repair
            $reportPath=Save-Report (Get-Diagnostics) 'started'
            $message='热点已启动；'+$status.Verification
        }
        'stop' {Restore-Session;$reportPath=Save-Report (Get-Diagnostics) 'stopped';$message='热点已停止，原设置已恢复'}
        'restore' {Restore-Session -OriginalHotspot;$reportPath=Save-Report (Get-Diagnostics) 'restored';$message='原设置已恢复'}
    }
}catch{
    $errorRecord=$_
    $exitCode=1
    $message=$_.Exception.Message
    Write-Log $message
    if($Action -eq 'start' -and $script:OperationChanged){
        try{Restore-Session -OriginalHotspot;$message+='；原设置已恢复'}catch{$message+='；恢复失败：'+$_.Exception.Message}
    }elseif($Action -eq 'start' -and $script:SessionCreated){
        $session=Read-Session
        $session.Active=$false
        Save-Session $session
    }
    $failure=[ordered]@{Message=$message;HResult=('0x'+$errorRecord.Exception.HResult.ToString('X8'));Line=$errorRecord.InvocationInfo.ScriptLineNumber}
    try{$reportPath=Save-Report (Get-Diagnostics) 'failed' $failure}catch{Write-Host ('报告生成失败：'+$_.Exception.Message)}
}
[ordered]@{RunId=$RunId;Action=$Action;ExitCode=$exitCode;Message=$message;Report=$reportPath}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $dataRoot 'result.json') -Encoding UTF8
Write-Host $message
if($reportPath){Write-Host ('报告：'+$reportPath)}
exit $exitCode
