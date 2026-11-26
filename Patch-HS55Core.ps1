#requires -Version 5.1
<#
.SYNOPSIS
  Restores the HS55 WIRELESS CORE features Corsair left out of iCUE, and lets a
  Core headset pair with a standard HS55 WIRELESS receiver.

.DESCRIPTION
  Edits the manifests inside iCUE's Qt resource modules (*.rcc) in place:
    hs55_wireless_core.rcc   - feature keys + (optionally) accepted dongle pid
    hs55_wireless_dongle.rcc - accepted headset pid (standard receiver mode)
  Originals are backed up to %LOCALAPPDATA%\Corsair\hs55_patch_backup\stock
  before any change. Safe to re-run; already-applied edits are skipped.

.PARAMETER Status
  Report module state without changing anything.

.PARAMETER Restore
  Copy the backed-up originals back over the patched modules.

.PARAMETER DevicesDir
  Patch a different copy of the iCUE "devices" folder (testing). No elevation.

.PARAMETER NoReceiverPatch
  Only restore the Core's settings. Use this if you own a genuine Core
  receiver (USB 1B1C:0A95): skips the dongle module and keeps the Core
  module's expected receiver pid.

.EXAMPLE
  .\Patch-HS55Core.ps1            # apply (standard receiver mode)
  .\Patch-HS55Core.ps1 -Status    # report only
  .\Patch-HS55Core.ps1 -Restore   # undo
#>
[CmdletBinding()]
param(
  [switch]$Status,
  [switch]$Restore,
  [string]$DevicesDir,
  [switch]$NoReceiverPatch,
  [switch]$Elevated   # internal: set when re-launched with admin rights
)

$ErrorActionPreference = 'Stop'
$DefaultDevicesDir = "${env:ProgramFiles}\Corsair\Corsair iCUE5 Software\devices"
$BackupDir = "$env:LOCALAPPDATA\Corsair\hs55_patch_backup\stock"

$CoreFile    = 'hs55_wireless_core.rcc'
$DongleFile  = 'hs55_wireless_dongle.rcc'
$HeadsetFile = 'hs55_wireless.rcc'

# ---- big-endian helpers -----------------------------------------------------
function Get-U16BE([byte[]]$b,[int]$o){ ($b[$o] -shl 8) -bor $b[$o+1] }
function Get-U32BE([byte[]]$b,[int]$o){
  ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor
  ([uint32]$b[$o+2] -shl 8) -bor [uint32]$b[$o+3]
}
function Set-U32BE([byte[]]$b,[int]$o,[uint32]$v){
  $b[$o]=($v -shr 24) -band 0xff; $b[$o+1]=($v -shr 16) -band 0xff
  $b[$o+2]=($v -shr 8) -band 0xff; $b[$o+3]=$v -band 0xff
}

# ---- RCC v3 parsing ----------------------------------------------------------
# Header: 'qres' ver(4) treeOff(4) dataOff(4) namesOff(4) nameFlags(4)
# Entry (22 bytes): nameOff(4) flags(2)
#   dir : childCount(4)@6 firstChildIndex(4)@10 pad(8)
#   file: terr/lang(4)@6 dataOff(4)@10 lastmod(8)@14
# Name record: len(2) hash(4) utf16be chars
# Blob: len(4) bytes
function Read-Rcc([byte[]]$d, [switch]$NoBlobs){
  if($d.Length -lt 24 -or $d[0] -ne 0x71 -or $d[1] -ne 0x72 -or $d[2] -ne 0x65 -or $d[3] -ne 0x73){
    throw 'not an RCC file (bad magic)'
  }
  if((Get-U32BE $d 4) -ne 3){ throw ('unsupported RCC version ' + (Get-U32BE $d 4)) }
  $tree = [int](Get-U32BE $d 8); $data = [int](Get-U32BE $d 12); $names = [int](Get-U32BE $d 16)
  $count = [int](($d.Length - $tree) / 22)   # tree is the last section
  $list = New-Object System.Collections.ArrayList
  for($i=0; $i -lt $count; $i++){
    $o = $tree + 22*$i
    $nameOff = Get-U32BE $d $o
    $nl = Get-U16BE $d ($names+$nameOff)
    $sb = New-Object System.Text.StringBuilder
    for($c=0; $c -lt $nl; $c++){ [void]$sb.Append([char](Get-U16BE $d ($names+$nameOff+6+2*$c))) }
    $fl = Get-U16BE $d ($o+4)
    if($fl -band 2){
      [void]$list.Add([pscustomobject]@{Index=$i;Name=$sb.ToString();IsDir=$true;Flags=$fl})
    } else {
      $do = Get-U32BE $d ($o+10)
      if($NoBlobs){
        [void]$list.Add([pscustomobject]@{Index=$i;Name=$sb.ToString();IsDir=$false;Flags=$fl;DataOff=[uint32]$do;Len=0;Blob=$null})
      } else {
        $ln = Get-U32BE $d ($data+$do)
        $blob = New-Object byte[] $ln
        [Array]::Copy($d, $data+$do+4, $blob, 0, $ln)
        [void]$list.Add([pscustomobject]@{Index=$i;Name=$sb.ToString();IsDir=$false;Flags=$fl;DataOff=[uint32]$do;Len=$ln;Blob=$blob})
      }
    }
  }
  return $list
}

function Get-Manifest([byte[]]$d){
  $m = (Read-Rcc $d) | Where-Object { -not $_.IsDir -and $_.Name -match 'manifest.*cuebmf$' } | Select-Object -First 1
  if(-not $m){ throw 'no uncompressed manifest inside the RCC' }
  if($m.Flags -band 1){ throw 'manifest is compressed; not supported' }
  return $m
}

# ---- RCC rebuild: swap the manifest blob, shift later data offsets ----------
function Set-Manifest([byte[]]$d, $manEntry, [byte[]]$newBlob){
  $dataBase = [int](Get-U32BE $d 12); $treeBase = [int](Get-U32BE $d 8)
  $manStart = $dataBase + [int]$manEntry.DataOff
  $manEnd = $manStart + 4 + $manEntry.Len
  $delta = $newBlob.Length - $manEntry.Len

  $ms = New-Object System.IO.MemoryStream
  $ms.Write($d, 0, $manStart)
  $lenBuf = New-Object byte[] 4
  Set-U32BE $lenBuf 0 ([uint32]$newBlob.Length)
  $ms.Write($lenBuf, 0, 4)
  $ms.Write($newBlob, 0, $newBlob.Length)
  $ms.Write($d, $manEnd, $d.Length - $manEnd)
  $new = $ms.ToArray()

  # shift every section base that sits after the manifest blob
  foreach($f in 8,12,16){
    $base = Get-U32BE $d $f
    if($base -gt $manStart){ Set-U32BE $new $f ($base + $delta) }
  }
  # locate the tree inside the new buffer and shift file data offsets
  $newTree = $treeBase; if($treeBase -gt $manStart){ $newTree += $delta }
  # data has already moved but entry offsets are still old: read metadata only
  $entries = Read-Rcc $new -NoBlobs
  foreach($e in ($entries | Where-Object { -not $_.IsDir })){
    if($e.DataOff -gt $manEntry.DataOff){
      Set-U32BE $new ($newTree + 22*$e.Index + 10) ($e.DataOff + $delta)
    }
  }

  # verify: re-parse; every blob must match its original except the manifest
  $final = Read-Rcc $new
  $orig = Read-Rcc $d
  foreach($o in ($orig | Where-Object { -not $_.IsDir })){
    $n = $final | Where-Object { $_.Index -eq $o.Index }
    if(-not $n){ throw ('rebuild lost entry ' + $o.Name) }
    $expected = if($o.Index -eq $manEntry.Index){ $newBlob } else { $o.Blob }
    if($n.Blob.Length -ne $expected.Length -or
       -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$n.Blob,[byte[]]$expected)){
      throw ('rebuild verification failed for ' + $o.Name)
    }
  }
  return $new
}

# ---- manifest text edits -----------------------------------------------------
function Remove-JsonMember([string]$json, [string]$member){
  # member is literal '"key":value' (no comma)
  if($json.Contains($member + ',')){ return $json.Replace($member + ',', '') }
  if($json.Contains(',' + $member)){ return $json.Replace(',' + $member, '') }
  if($json.Contains($member)){ return $json.Replace($member, '') }
  return $json
}

# exact fragments as deployed and verified
$CoreAdds = @(
  '"BatteryGaugeAvailable":true,',
  '"BatteryStatusThresholds":{"100":"Charged","15":"CriticalLow","30":"Low","50":"Medium","97":"High"},',
  '"MicrophoneControl":"OnDevice",',
  '"PowerPerformance":["SleepMode_StoreInDevice","SleepMode_99min10_AutoShutOffName","ControllerType_Bragi"],',
  '"PresetPropertyType":"Unlimited",',
  '"SdkDeviceType":"Headset",',
  '"SubScreensListData":[{"info":{"memoryMode":"Software"},"type":"Equalizer"}],',
  '"SupportedSensorTypes":["BatterySensor"],',
  '"SupportsCriticalBatteryLightingPopup":true,',
  '"SupportsMicBoom":true,',
  '"SupportsMicVolume":true,'
)
$CoreRemovals = @(
  '"DisablesWidget":true',
  '"SupportsAudioFeatures":false',
  '"SupportsSettingsOnly":true'
)

function Edit-CoreManifest([string]$json, [bool]$patchDongleRef, [ref]$changes){
  $ch = New-Object System.Collections.ArrayList
  foreach($m in $CoreRemovals){
    if($json.Contains($m)){ $json = Remove-JsonMember $json $m; [void]$ch.Add("removed $m") }
  }
  if($patchDongleRef){
    if($json -match '"NativeDongle":\[\{"pid":2709'){
      $json = $json -replace '"NativeDongle":\[\{"pid":2709', '"NativeDongle":[{"pid":2703'
      [void]$ch.Add('NativeDongle pid 2709 -> 2703 (standard receiver)')
    } elseif($json -match '"NativeDongle":\[\{"pid":2703'){
      [void]$ch.Add('NativeDongle pid already 2703')
    } else {
      throw 'unexpected NativeDongle block in Core manifest; refusing to guess'
    }
  }
  $anchor = $json.IndexOf('"common":{')
  if($anchor -lt 0){ throw 'no "common" object in Core manifest' }
  $pos = $anchor + '"common":{'.Length
  foreach($frag in $CoreAdds){
    $key = $frag.Substring(0, $frag.IndexOf('":') + 1)   # includes both quotes
    if($json -notmatch [regex]::Escape($key) + '\s*:'){
      $json = $json.Substring(0,$pos) + $frag + $json.Substring($pos)
      $pos += $frag.Length
      [void]$ch.Add('added ' + $key)
    }
  }
  $changes.Value = $ch
  return $json
}

function Edit-DongleManifest([string]$json, [ref]$changes){
  $ch = New-Object System.Collections.ArrayList
  if($json -match '"NativeSubDevices":\[\{"pid":2702'){
    $json = $json -replace '"NativeSubDevices":\[\{"pid":2702', '"NativeSubDevices":[{"pid":2708'
    [void]$ch.Add('NativeSubDevices pid 2702 -> 2708 (Core headset)')
  } elseif($json -match '"NativeSubDevices":\[\{"pid":2708'){
    [void]$ch.Add('NativeSubDevices pid already 2708')
  } else {
    throw 'unexpected NativeSubDevices block in dongle manifest; refusing to guess'
  }
  $changes.Value = $ch
  return $json
}

# ---- helpers ------------------------------------------------------------------
function Test-Admin{
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-JsonParses([string]$json){
  try { $null = $json | ConvertFrom-Json -ErrorAction Stop; return $true } catch { return $false }
}
function Patch-OneFile([string]$path, [scriptblock]$edit, [object[]]$editArgs, [bool]$needsBackup){
  $bytes = [IO.File]::ReadAllBytes($path)
  $m = Get-Manifest $bytes
  $origJson = [Text.Encoding]::UTF8.GetString($m.Blob)
  $changes = $null
  $newJson = & $edit $origJson @editArgs ([ref]$changes)
  if($newJson -eq $origJson){
    Write-Host ("  {0}: already patched, nothing to do" -f (Split-Path $path -Leaf))
    return
  }
  $stockParsed = Test-JsonParses $origJson
  if($stockParsed -and -not (Test-JsonParses $newJson)){
    throw "edited manifest no longer parses as JSON - refusing to write $path"
  }
  if(-not $stockParsed){ Write-Warning 'stock manifest did not parse as JSON; skipping JSON validation' }
  $newBytes = Set-Manifest $bytes $m ([Text.Encoding]::UTF8.GetBytes($newJson))
  if($needsBackup){
    $bk = Join-Path $BackupDir (Split-Path $path -Leaf)
    if(-not (Test-Path $bk)){
      New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
      Copy-Item $path $bk
      Write-Host ("  backed up original -> {0}" -f $bk)
    }
  }
  [IO.File]::WriteAllBytes($path, $newBytes)
  Write-Host ("  {0}: patched ({1})" -f (Split-Path $path -Leaf), ($changes -join '; '))
}

# ---- entry point ---------------------------------------------------------------
$isRealDir = -not $DevicesDir
if(-not $DevicesDir){ $DevicesDir = $DefaultDevicesDir }
if(-not $isRealDir){ $BackupDir = Join-Path $DevicesDir 'patch-backup' }

if(-not (Test-Path $DevicesDir)){
  Write-Error "devices folder not found: $DevicesDir`nIs Corsair iCUE 5 installed? Override with -DevicesDir if it lives elsewhere."
}

# --- status report ---
if($Status){
  foreach($f in @($CoreFile,$DongleFile,$HeadsetFile)){
    $p = Join-Path $DevicesDir $f
    if(-not (Test-Path $p)){ Write-Host ("{0,-28} MISSING" -f $f); continue }
    try {
      $m = Get-Manifest ([IO.File]::ReadAllBytes($p))
      $j = [Text.Encoding]::UTF8.GetString($m.Blob)
      if($f -eq $CoreFile){
        $feat = if($j.Contains('"PowerPerformance"')){'features ON'}else{'features off (stock)'}
        $pidm = [regex]::Match($j,'"NativeDongle":\[\{"pid":(\d+)')
        $recv = if($pidm.Success){'accepts dongle pid ' + $pidm.Groups[1].Value}else{'NativeDongle ?'}
        Write-Host ("{0,-28} {1}, {2}" -f $f,$feat,$recv)
      } elseif($f -eq $DongleFile){
        $pidm = [regex]::Match($j,'"NativeSubDevices":\[\{"pid":(\d+)')
        $sub = if($pidm.Success){'accepts headset pid ' + $pidm.Groups[1].Value}else{'NativeSubDevices ?'}
        Write-Host ("{0,-28} {1}" -f $f,$sub)
      } else {
        Write-Host ("{0,-28} present (never patched by this script)" -f $f)
      }
    } catch { Write-Host ("{0,-28} unreadable: {1}" -f $f, $_.Exception.Message) }
  }
  return
}

# --- restore ---
if($Restore){
  if($isRealDir -and (Get-Process iCUE -ErrorAction SilentlyContinue)){
    Write-Error 'iCUE is running. Quit it from the tray first, then re-run -Restore.'
  }
  if($isRealDir -and -not (Test-Admin) -and -not $Elevated){
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Restore','-Elevated')
    if($NoReceiverPatch){ $args += '-NoReceiverPatch' }
    Start-Process powershell -Verb RunAs -ArgumentList $args -Wait
    return
  }
  $restored = 0
  foreach($f in @($CoreFile,$DongleFile)){
    $bk = Join-Path $BackupDir $f
    $dst = Join-Path $DevicesDir $f
    if(Test-Path $bk){
      Copy-Item $bk $dst -Force
      Write-Host "restored $f"
      $restored++
    } else {
      Write-Warning "no backup for $f - nothing to restore"
    }
  }
  if($restored -eq 0){ Write-Host 'No backups found; nothing restored.' }
  if($Elevated){ Read-Host 'Done - press Enter to close' }
  return
}

# --- apply ---
if($isRealDir -and (Get-Process iCUE -ErrorAction SilentlyContinue)){
  Write-Error 'iCUE is running. Quit it from the system tray first, then re-run.'
}
if($isRealDir -and -not (Test-Admin) -and -not $Elevated){
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Elevated')
  if($NoReceiverPatch){ $args += '-NoReceiverPatch' }
  Start-Process powershell -Verb RunAs -ArgumentList $args -Wait
  return
}

$corePath = Join-Path $DevicesDir $CoreFile
if(-not (Test-Path $corePath)){
  Write-Error "$CoreFile not found. In iCUE, connect the HS55 WIRELESS CORE once (USB cable) so iCUE installs its device module, then re-run."
}

$doReceiver = -not $NoReceiverPatch
if($doReceiver){
  $donglePath = Join-Path $DevicesDir $DongleFile
  if(-not (Test-Path $donglePath)){
    Write-Error "$DongleFile not found. Standard receiver support is required to pair a Core headset to a regular HS55 WIRELESS receiver. Plug the receiver in with iCUE running (or install HS55 WIRELESS device support), then re-run. Or use -NoReceiverPatch if you own the real Core receiver."
  }
  if(-not (Test-Path (Join-Path $DevicesDir $HeadsetFile))){
    Write-Warning "$HeadsetFile not found - pairing may still work, but install HS55 WIRELESS device support in iCUE if the wizard misbehaves."
  }
}

Write-Host "Patching modules in $DevicesDir"
Patch-OneFile $corePath ${function:Edit-CoreManifest} @($doReceiver) $true
if($doReceiver){
  Patch-OneFile $donglePath ${function:Edit-DongleManifest} @() $true
}
Write-Host ''
Write-Host 'Done. Start iCUE with the headset on in RF mode to use it.'
if($Elevated){ Read-Host 'Press Enter to close' }
