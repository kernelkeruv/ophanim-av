Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$version = if ($env:OPHANIM_AV_VERSION) { $env:OPHANIM_AV_VERSION } else { "0.1.0" }
$distRoot = Join-Path $root "dist\windows"
$pyDistRoot = Join-Path $root "dist\OphanimAV"

python -m pip install --upgrade pip
python -m pip install pyinstaller

dotnet tool install --global wix --version 5.0.0
$env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
wix extension add WixToolset.UI.wixext

if (Test-Path $distRoot) { Remove-Item -Recurse -Force $distRoot }
if (Test-Path $pyDistRoot) { Remove-Item -Recurse -Force $pyDistRoot }
New-Item -ItemType Directory -Path $distRoot | Out-Null

pyinstaller `
  --noconfirm `
  --windowed `
  --name OphanimAV `
  --add-data "$root\assets;assets" `
  "$root\src\player.py"

$exeName = "ophanimav-$version-windows-x64.exe"
Copy-Item (Join-Path $pyDistRoot "OphanimAV.exe") (Join-Path $distRoot $exeName) -Force

$wxsPath = Join-Path $root "dist\windows\Product.wxs"
$installDirId = "INSTALLFOLDER"
$componentRefs = New-Object System.Collections.Generic.List[string]
$componentXml = New-Object System.Collections.Generic.List[string]
$fileIndex = 0

Get-ChildItem -Path $pyDistRoot -Recurse -File | ForEach-Object {
  $file = $_
  $fileIndex++
  $componentId = "Cmp$fileIndex"
  $fileId = "Fil$fileIndex"
  $guid = [guid]::NewGuid().ToString().ToUpper()
  $relative = $file.FullName.Substring($pyDistRoot.Length + 1).Replace("\", "\\")
  $componentRefs.Add("        <ComponentRef Id=`"$componentId`" />")
  $componentXml.Add(@"
      <Component Id="$componentId" Guid="$guid" Directory="$installDirId">
        <File Id="$fileId" Name="$($file.Name)" Source="$($file.FullName)" />
      </Component>
"@)
}

$wxs = @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="OphanimAV" Manufacturer="OphanimAV" Version="$version" UpgradeCode="$( [guid]::NewGuid().ToString().ToUpper() )" Language="1033">
    <MajorUpgrade DowngradeErrorMessage="A newer version of OphanimAV is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="$installDirId" Name="OphanimAV" />
    </StandardDirectory>
    <Feature Id="MainFeature" Title="OphanimAV" Level="1">
$(($componentRefs -join "`n"))
    </Feature>
    <Fragment>
      <DirectoryRef Id="$installDirId">
$(($componentXml -join "`n"))
      </DirectoryRef>
    </Fragment>
  </Package>
</Wix>
"@

Set-Content -Path $wxsPath -Encoding UTF8 -Value $wxs

$msiPath = Join-Path $distRoot "ophanimav-$version-windows-x64.msi"
wix build $wxsPath -o $msiPath

Write-Host "Windows artifacts:"
Get-ChildItem -Path $distRoot | Format-Table -AutoSize
