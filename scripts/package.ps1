$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dist=Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force|Out-Null
$files=@('hotspot.cmd','hotspot.ps1','README.md','.gitignore','.gitattributes','tests/run.ps1','scripts/package.ps1')
$files+=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter *.ps1|ForEach-Object {'src/'+$_.Name})
$path=Join-Path $dist 'proxy-hotspot.zip'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
$zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
try{
    foreach($file in $files){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $root $file),('proxy-hotspot/'+$file))}
}finally{$zip.Dispose()}
Write-Host $path
