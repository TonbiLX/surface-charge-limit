<#
  SurfaceCharge.ps1  -  Surface Smart Charging (80% limit) control panel
  https://github.com/TonbiLX/surface-charge-limit   (MIT)

  Replicates the "Battery & charging" card of the Surface app for devices where
  that card is missing (app regression). Reads the battery firmware state and lets
  you unlock charging to 100% or restore the 80% limit.

  Interactive : SurfaceCharge.bat (EN) / SurfaceSarj.bat (TR) -> self-elevates, opens menu
  CLI         : SurfaceCharge.ps1 -Lang en|tr -Action status|unlock|limit80|default|pause|task-install|task-remove
#>
param(
  [ValidateSet('menu','status','screen','lib','unlock','limit80','default','pause','task-install','task-remove')]
  [string]$Action = 'menu',
  [ValidateSet('en','tr')] [string]$Lang = 'en'
)
$ErrorActionPreference = 'Stop'
$Dir      = Split-Path -Parent $PSCommandPath
$LogFile  = Join-Path $Dir 'surface-charge.log'
$TaskName = 'SurfaceCharge100'
$Version  = '1.0.0'

# ============================== Driver layer ==============================
# Extracted from the Surface app's Services\BatteryDm.dll (SDMA.Microservice.Cmd.Battery).
if (-not ('SurfBat' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SurfBat {
  [StructLayout(LayoutKind.Sequential)] struct DID { public int cbSize; public Guid g; public int Flags; public IntPtr R; }
  [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr h, int f);
  [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref DID did);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref DID did, IntPtr buf, int size, out int req, IntPtr dev);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inb, int ins, byte[] outb, int outs, out int ret, IntPtr ov);
  public const uint IOCTL = 0x00225C00; // CTL_CODE(0x22, 0x700, METHOD_BUFFERED, FILE_READ_ACCESS)
  public static List<string> Paths(Guid g) {
    var r = new List<string>();
    IntPtr s = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    if (s == new IntPtr(-1)) return r;
    try {
      for (int i = 0; ; i++) {
        var d = new DID(); d.cbSize = Marshal.SizeOf(d);
        if (!SetupDiEnumDeviceInterfaces(s, IntPtr.Zero, ref g, i, ref d)) break;
        int req; SetupDiGetDeviceInterfaceDetail(s, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
        IntPtr buf = Marshal.AllocHGlobal(req);
        try {
          Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
          if (SetupDiGetDeviceInterfaceDetail(s, ref d, buf, req, out req, IntPtr.Zero)) r.Add(Marshal.PtrToStringUni(buf + 4));
        } finally { Marshal.FreeHGlobal(buf); }
      }
    } finally { SetupDiDestroyDeviceInfoList(s); }
    return r;
  }
  public static byte[] Send(string path, byte cmd, byte[] data) {
    int n = 5 + (data == null ? 0 : data.Length);
    var p = new byte[n]; p[0] = (byte)n; p[1] = 3; p[2] = 0; p[3] = cmd; p[4] = 0;
    if (data != null) Array.Copy(data, 0, p, 5, data.Length);
    using (var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
      if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      var o = new byte[512]; int ret;
      if (!DeviceIoControl(h, IOCTL, p, n, o, o.Length, out ret, IntPtr.Zero))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      var r = new byte[ret]; Array.Copy(o, r, ret); return r;
    }
  }
}
'@
}
$CMD = @{ ProtPolicy = 5; BclStatus = 6; BclCountdown = 7; BclDisengage = 8; SetMode = 15; GetMode = 16 }

# ============================== i18n ==============================
$T = @{
 en = @{
  title='Smart Charging Control Panel'; subtitle=':: unlock / restore the 80% limit'
  hBat='BATTERY'; hFw='SMART CHARGING (FIRMWARE)'; hTask='WATCHDOG TASK'
  plugYes='Connected'; plugNo='Not connected'; stChg='Charging'; stIdle='Not charging (plugged in)'; stBatt='On battery'
  flowChg='+{0} W (charging)'; flowDis='-{0} W (draining)'; flow0='0 W'
  rPlug='Power'; rState='State'; rFlow='Power flow'; rCap='Capacity'; rFull='Full in'; rLeft='Time left'; rHealth='Health'
  fwNoAdmin='Unreadable - administrator required (open with the .bat)'; fwErr='ERROR: {0}'
  rBcl='Smart Charging'; bclOff='OFF  -> charges to 100%'; bclOn='ON   -> stops at 80%'; bclUnk='Unknown ({0})'
  rCd='Countdown'; cdFmt='{0} s left (cannot pause meanwhile)'
  rMode='Charge mode'; rPrev='Previous'; rSupp='Supported'; m0='Adaptive (factory)'; m1='Fixed limit'; m2='Unlimited (timed)'
  rTask='Task'; taskNoAdmin='Unreadable - administrator required'; taskNo='Not installed (firmware may re-enable the limit)'
  taskLast='Last run'; taskNext='Next'; taskNever='never run'; taskWarn='Task points to an old script -> press [1] to reinstall'
  sumLimit="FIXED LIMIT: battery stops at {0}%"; sum100keep='100% MODE ACTIVE and PERSISTENT (watchdog on)'
  sum100='100% allowed - but no watchdog, firmware may re-enable it'; sum80='80% LIMIT ACTIVE'; sumUnknown='State unknown'
  mUnlock='UNLOCK 100%'; mUnlockD='disable Smart Charging + install watchdog (persistent)'
  mLimit='SET 80% LIMIT'; mLimitD='apply a fixed 80% cap + remove watchdog'
  mDefault='FACTORY'; mDefaultD='back to Adaptive + remove watchdog (Microsoft default)'
  mOnce='PAUSE ONCE'; mOnceD='disengage now, do not install the watchdog'
  mLive='LIVE VIEW'; mLiveD='refresh the panel every 5 s (press a key to exit)'
  mLog='LOG'; mLogD='show the last 25 actions'; mReadme='READ ME'; mReadmeD='open README.md'
  mRefresh='REFRESH'; mExit='EXIT'; prompt='Your choice: '
  doUnlock='Unlocking 100% mode...'; doLimit='Applying fixed 80% limit...'; doDefault='Reverting to factory (Adaptive)...'
  limitCleared='Fixed limit removed (Adaptive) -> {0}'; taskInstalled="Watchdog task '{0}' installed (startup +2 min, hourly)."; taskRemoved='Watchdog task removed.'
  modeSet='Charge mode -> {0} : {1}'; mFixed='Fixed 80%'; mAdaptive='Adaptive'
  defNote='Note: Smart Charging will now kick in at 80% on its own (long time plugged in / warm).'
  disResult='Force disengage -> {0}'; disCountdown='Firmware is counting down; if the task exists it retries within an hour.'
  rsp0='Success'; rsp1='Unknown error'; rsp2='Mode not supported'; rsp3='Invalid setting'
  dis0='Disengaged successfully'; dis1='CountdownInProgress'; dis2='NotEngaged (already off)'
  anyKey='Press any key to continue...'; live='LIVE'; liveExit='press a key to exit'; noLog='No log.'
  notAdmin='! Not administrator: firmware cannot be read/changed. Open with the .bat.'
  noIface='Surface battery interface not found. This tool is for Surface Pro 12" (SBCD driver) only.'
  chg=' >>> charging'; idle=' ||  plugged in, idle'; batt=' <<< on battery'; mark80='^ 80% limit'
 }
 tr = @{
  title='Akilli Sarj Kontrol Paneli'; subtitle=':: %80 sinirini ac / geri koy'
  hBat='PIL'; hFw='AKILLI SARJ (FIRMWARE)'; hTask='OTOMATIK GOREV'
  plugYes='Takili'; plugNo='Takili degil'; stChg='Sarj oluyor'; stIdle='Sarj olmuyor (prizde)'; stBatt='Pilden calisiyor'
  flowChg='+{0} W (sarj)'; flowDis='-{0} W (tuketim)'; flow0='0 W'
  rPlug='Priz'; rState='Durum'; rFlow='Guc akisi'; rCap='Kapasite'; rFull='Tam dolum'; rLeft='Kalan sure'; rHealth='Pil sagligi'
  fwNoAdmin='Okunamadi - yonetici gerekli (.bat ile acin)'; fwErr='HATA: {0}'
  rBcl='Akilli Sarj'; bclOff='KAPALI -> %100e kadar sarj'; bclOn='AKTIF  -> %80de durur'; bclUnk='Bilinmiyor ({0})'
  rCd='Geri sayim'; cdFmt='{0} sn kaldi (bu surede duraklatilamaz)'
  rMode='Sarj modu'; rPrev='Onceki'; rSupp='Desteklenen'; m0='Adaptif (fabrika)'; m1='Sabit sinir'; m2='Limitsiz (sureli)'
  rTask='Gorev'; taskNoAdmin='Okunamadi - yonetici gerekli'; taskNo='Kurulu degil (firmware siniri geri acabilir)'
  taskLast='Son calisma'; taskNext='Sonraki'; taskNever='henuz calismadi'; taskWarn='Gorev eski betigi gosteriyor -> [1] ile yeniden kur'
  sumLimit="SABIT SINIR: pil %{0}de durur"; sum100keep='%100 MODU AKTIF ve KALICI (bekci gorevi acik)'
  sum100='%100 serbest - ama gorev yok, firmware tekrar acabilir'; sum80='%80 SINIRI AKTIF'; sumUnknown='Durum belirsiz'
  mUnlock='%100 AC'; mUnlockD='Akilli Sarji kapat + bekci gorevi kur (kalici)'
  mLimit='%80 KAPAT'; mLimitD='sabit %80 sinir koy + gorevi sil'
  mDefault='FABRIKA'; mDefaultD='Adaptif moda don + gorevi sil (Microsoft varsayilani)'
  mOnce='TEK SEFER'; mOnceD='sadece simdi duraklat, gorev kurma'
  mLive='CANLI IZLE'; mLiveD='paneli 5 sn''de bir yenile (bir tusa bas = cik)'
  mLog='LOG'; mLogD='son 25 islemi goster'; mReadme='BENI OKU'; mReadmeD='README.md''yi ac'
  mRefresh='YENILE'; mExit='CIKIS'; prompt='Secimin: '
  doUnlock='%100 modu aciliyor...'; doLimit='Sabit %80 sinir uygulaniyor...'; doDefault='Fabrika (Adaptif) moda donuluyor...'
  limitCleared='Sabit sinir kaldirildi (Adaptif) -> {0}'; taskInstalled="Otomatik gorev '{0}' kuruldu (acilis +2 dk, saatte bir)."; taskRemoved='Otomatik gorev silindi.'
  modeSet='Sarj modu -> {0} : {1}'; mFixed='Sabit %80'; mAdaptive='Adaptif'
  defNote='Not: Akilli Sarj artik firmware kararina gore (uzun sure prizde/sicak) %80de devreye girer.'
  disResult='Force disengage -> {0}'; disCountdown='Firmware geri sayimda; gorev kuruluysa en gec 1 saat icinde tekrar dener.'
  rsp0='Basarili'; rsp1='Bilinmeyen hata'; rsp2='Mod desteklenmiyor'; rsp3='Gecersiz ayar'
  dis0='Basariyla duraklatildi'; dis1='Geri sayim suruyor'; dis2='Zaten kapaliydi'
  anyKey='Devam icin bir tusa bas...'; live='CANLI'; liveExit='cikmak icin bir tusa bas'; noLog='Log yok.'
  notAdmin='! Yonetici degil: firmware okunamaz/degistirilemez. .bat ile acin.'
  noIface='Surface pil arayuzu bulunamadi. Bu arac yalniz Surface Pro 12" (SBCD surucusu) icindir.'
  chg=' >>> sarj oluyor'; idle=' ||  prizde, beklemede'; batt=' <<< pilden calisiyor'; mark80='^ %80 siniri'
 }
}
$L = $T[$Lang]
$ModeName = @($L.m0, $L.m1, $L.m2)

# ============================== Helpers ==============================
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Write-Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $env:USERNAME, $m) -Encoding utf8 } catch {} }
function Get-Path { foreach ($g in '31076642-1572-4FBB-A5DD-4B879B515476','54F596C1-3B0D-40F2-97A4-FCBCFD253D3B') { $p = [SurfBat]::Paths([guid]$g); if ($p.Count) { return $p[0] } }; return $null }
function Send-Cmd([byte]$c, [byte[]]$d = $null) { $p = Get-Path; if (-not $p) { throw $L.noIface }; return [SurfBat]::Send($p, $c, $d) }
function Set-Mode([byte]$mode, [byte]$pct = 0) { $d = New-Object byte[] 25; $d[0] = $mode; if ($mode -eq 1) { $d[1] = $pct }; $r = Send-Cmd $CMD.SetMode $d; if ($r -and $r.Length -ge 1) { return [int]$r[0] } else { return 0 } }
function Rsp($v) { @($L.rsp0, $L.rsp1, $L.rsp2, $L.rsp3)[$v] }
function Dur($ts) { if (-not $ts) { return '-' }; if ($ts.TotalHours -ge 1) { '{0}h {1:00}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes } else { '{0}m' -f [int][math]::Ceiling($ts.TotalMinutes) } }

# ============================== State ==============================
function Get-State {
  $s = [ordered]@{}
  $w = Get-CimInstance Win32_Battery -EA SilentlyContinue
  $b = Get-CimInstance -Namespace root\wmi BatteryStatus -EA SilentlyContinue | Select-Object -First 1
  $full = (Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity -EA SilentlyContinue | Select-Object -First 1).FullChargedCapacity
  $des  = (Get-CimInstance -Namespace root\wmi BatteryStaticData -EA SilentlyContinue | Select-Object -First 1).DesignedCapacity
  $cyc  = (Get-CimInstance -Namespace root\wmi BatteryCycleCount -EA SilentlyContinue | Select-Object -First 1).CycleCount
  $s.Pct = [int]$w.EstimatedChargeRemaining; $s.Plug = [bool]$b.PowerOnline; $s.Chg = [bool]$b.Charging; $s.Dis = [bool]$b.Discharging
  $s.ChgW = [math]::Round($b.ChargeRate / 1000, 1); $s.DisW = [math]::Round($b.DischargeRate / 1000, 1)
  $s.Rem = [int]$b.RemainingCapacity; $s.Full = [int]$full; $s.Des = [int]$des; $s.Cyc = $cyc
  $s.Health = if ($des -gt 0) { [math]::Round(100 * $full / $des, 1) } else { $null }
  $s.ToFull = if ($s.Chg -and $b.ChargeRate -gt 0) { [TimeSpan]::FromHours(($full - $b.RemainingCapacity) / $b.ChargeRate) } else { $null }
  $s.ToEmpty = if (-not $s.Plug -and $b.DischargeRate -gt 0) { [TimeSpan]::FromHours($b.RemainingCapacity / $b.DischargeRate) } else { $null }
  $s.Admin = Test-Admin
  $s.Bcl = $null; $s.Cd = $null; $s.Mode = $null; $s.Prev = $null; $s.Pct80 = $null; $s.Mask = $null; $s.Err = $null
  if ($s.Admin) {
    try {
      $s.Bcl = [int](Send-Cmd $CMD.BclStatus)[0]
      $s.Cd = [BitConverter]::ToUInt32((Send-Cmd $CMD.BclCountdown), 0)
      $r = Send-Cmd $CMD.GetMode; $s.Mask = [BitConverter]::ToUInt32($r, 0); $s.Mode = [int]$r[4]; $s.Prev = [int]$r[5]
      if ($s.Mode -eq 1) { $s.Pct80 = [int]$r[6] }
    } catch { $s.Err = $_.Exception.Message }
  }
  $s.Task = $null; $s.TLast = $null; $s.TNext = $null; $s.TRes = $null; $s.TArg = $null
  try { $t = Get-ScheduledTask -TaskName $TaskName -EA Stop; $i = $t | Get-ScheduledTaskInfo; $s.Task = [string]$t.State; $s.TLast = $i.LastRunTime; $s.TNext = $i.NextRunTime; $s.TRes = $i.LastTaskResult; $s.TArg = ($t.Actions | Select-Object -First 1).Arguments } catch {}
  return [pscustomobject]$s
}

# ============================== UI ==============================
function C($t, $c = 'Gray', [switch]$n) { if ($n) { Write-Host $t -ForegroundColor $c -NoNewline } else { Write-Host $t -ForegroundColor $c } }
function Line($c = 'DarkCyan') { C ('  ' + ('=' * 72)) $c }
function Row($k, $v, $c = 'White') { C ('  {0,-20}' -f $k) 'DarkGray' -n; C $v $c }

function BoxLine($ic, $segs) {
  C '        |' 'DarkGray' -n
  $used = 0; foreach ($s in $segs) { C $s.t $s.c -n; $used += $s.t.Length }
  $pad = $ic - $used; if ($pad -gt 0) { C (' ' * $pad) 'DarkGray' -n }
  C '|' 'DarkGray'
}
function Banner {
  Clear-Host; C ''
  C '     _____             __                      _____ _                           ' 'Cyan'
  C '    / ____|           / _|                    / ____| |                          ' 'Cyan'
  C '   | (___  _   _ _ __| |_ __ _  ___ ___      | |    | |__   __ _ _ __ __ _  ___   ' 'Cyan'
  C '    \___ \| | | | ''__|  _/ _` |/ __/ _ \     | |    | ''_ \ / _` | ''__/ _` |/ _ \  ' 'DarkCyan'
  C '    ____) | |_| | |  | || (_| | (_|  __/     | |____| | | | (_| | | | (_| |  __/  ' 'DarkCyan'
  C '   |_____/ \__,_|_|  |_| \__,_|\___\___|      \_____|_| |_|\__,_|_|  \__, |\___|  ' 'Blue'
  C '                                                                      __/ |       ' 'Blue'
  C '                                                                     |___/        ' 'Blue'
  $ic = 66
  C ('        .' + ('-' * $ic) + '.') 'DarkGray'
  BoxLine $ic @(@{t = '  '; c = 'DarkGray' }, @{t = $L.title; c = 'Yellow' }, @{t = '  ' + $L.subtitle; c = 'Gray' })
  BoxLine $ic @(@{t = '  Surface Pro 12" Snapdragon  ::  v' + $Version; c = 'DarkGray' })
  C ('        ''' + ('-' * $ic) + '''') 'DarkGray'; C ''
}

function Draw-Bar($s) {
  $w = 40; $fill = [int][math]::Round($w * [math]::Min(100, $s.Pct) / 100)
  $c = if ($s.Pct -ge 80) { 'Green' } elseif ($s.Pct -ge 40) { 'Yellow' } elseif ($s.Pct -ge 20) { 'DarkYellow' } else { 'Red' }
  $m80 = [int]($w * 0.8); $tag = if ($s.Chg) { $L.chg } elseif ($s.Plug) { $L.idle } else { $L.batt }
  C ('        .' + ('-' * ($w + 2)) + '.') 'DarkGray'
  C '        | ' 'DarkGray' -n
  for ($i = 0; $i -lt $w; $i++) { if ($i -lt $fill) { C '#' $c -n } elseif ($i -eq $m80) { C '|' 'DarkRed' -n } else { C '.' 'DarkGray' -n } }
  C ' |' 'DarkGray' -n; C ('  {0,3}%' -f $s.Pct) $c -n; C $tag $(if ($s.Chg) { 'Green' } else { 'Gray' })
  C ('        ''' + ('-' * ($w + 2)) + '''') 'DarkGray'
  C ((' ' * (10 + $m80)) + $L.mark80) 'DarkRed'
}

function Draw-Panel($s) {
  Draw-Bar $s; C ''
  Line; C ('   ' + $L.hBat) 'Cyan'; Line
  $flow = if ($s.Chg) { $L.flowChg -f $s.ChgW } elseif ($s.Dis) { $L.flowDis -f $s.DisW } else { $L.flow0 }
  Row $L.rPlug $(if ($s.Plug) { $L.plugYes } else { $L.plugNo }) $(if ($s.Plug) { 'Green' } else { 'Yellow' })
  Row $L.rState $(if ($s.Chg) { $L.stChg } elseif ($s.Plug) { $L.stIdle } else { $L.stBatt }) $(if ($s.Chg) { 'Green' } elseif ($s.Plug) { 'Yellow' } else { 'Gray' })
  Row $L.rFlow $flow
  Row $L.rCap ('{0:N0} / {1:N0} mWh' -f $s.Rem, $s.Full)
  if ($s.ToFull) { Row $L.rFull ('~' + (Dur $s.ToFull)) 'Green' }
  if ($s.ToEmpty) { Row $L.rLeft ('~' + (Dur $s.ToEmpty)) 'Yellow' }
  if ($s.Health) { Row $L.rHealth ('{0}%  (design {1:N0} mWh, cyc {2})' -f $s.Health, $s.Des, $(if ($null -ne $s.Cyc) { $s.Cyc } else { '?' })) $(if ($s.Health -ge 80) { 'Green' } else { 'Yellow' }) }
  C ''
  Line; C ('   ' + $L.hFw) 'Cyan'; Line
  if (-not $s.Admin) { Row 'Firmware' $L.fwNoAdmin 'Red' }
  elseif ($s.Err) { Row 'Firmware' ($L.fwErr -f $s.Err) 'Red' }
  else {
    switch ($s.Bcl) { 0 { Row $L.rBcl $L.bclOff 'Green' } 1 { Row $L.rBcl $L.bclOn 'Red' } default { Row $L.rBcl ($L.bclUnk -f $s.Bcl) 'Yellow' } }
    if ($s.Cd -gt 0) { Row $L.rCd ($L.cdFmt -f $s.Cd) 'Yellow' }
    $mt = $ModeName[$s.Mode]; if ($s.Mode -eq 1) { $mt += " ($($s.Pct80)%)" }
    Row $L.rMode $mt $(if ($s.Mode -eq 1) { 'Yellow' } else { 'White' })
    Row $L.rPrev $ModeName[$s.Prev] 'DarkGray'
    $dm = @(); 0..2 | ForEach-Object { if ($s.Mask -band (1 -shl $_)) { $dm += $ModeName[$_] } }; Row $L.rSupp ($dm -join ', ') 'DarkGray'
  }
  C ''
  Line; C ('   ' + $L.hTask) 'Cyan'; Line
  if (-not $s.Admin) { Row $L.rTask $L.taskNoAdmin 'DarkGray' }
  elseif ($s.Task) {
    Row $L.rTask ("{0}  ({1})" -f $TaskName, $s.Task) 'Green'
    Row $L.taskLast $(if ($s.TLast -and $s.TLast.Year -gt 2000) { '{0:dd.MM.yyyy HH:mm}  ({1})' -f $s.TLast, $(if ($s.TRes -eq 0) { 'OK' } else { '0x{0:X}' -f $s.TRes }) } else { $L.taskNever })
    Row $L.taskNext $(if ($s.TNext) { '{0:dd.MM.yyyy HH:mm}' -f $s.TNext } else { '-' })
    if ($s.TArg -and $s.TArg -notlike "*$PSCommandPath*") { Row '!' $L.taskWarn 'Yellow' }
  } else { Row $L.rTask $L.taskNo 'Yellow' }
  C ''
  $col = 'Yellow'; $sum = $L.sumUnknown
  if ($s.Admin -and -not $s.Err) {
    if ($s.Mode -eq 1) { $sum = $L.sumLimit -f $s.Pct80; $col = 'Yellow' }
    elseif ($s.Bcl -eq 0 -and $s.Task) { $sum = $L.sum100keep; $col = 'Green' }
    elseif ($s.Bcl -eq 0) { $sum = $L.sum100; $col = 'Yellow' }
    elseif ($s.Bcl -eq 1) { $sum = $L.sum80; $col = 'Red' }
  }
  C '  >> ' 'DarkGray' -n; C $sum $col
}

function Draw-Menu {
  C ''; Line 'DarkGray'
  C '   [1] ' 'Green' -n; C ('{0,-16}' -f $L.mUnlock) 'White' -n; C $L.mUnlockD 'DarkGray'
  C '   [2] ' 'Red' -n; C ('{0,-16}' -f $L.mLimit) 'White' -n; C $L.mLimitD 'DarkGray'
  C '   [3] ' 'Yellow' -n; C ('{0,-16}' -f $L.mDefault) 'White' -n; C $L.mDefaultD 'DarkGray'
  C '   [4] ' 'Cyan' -n; C ('{0,-16}' -f $L.mOnce) 'White' -n; C $L.mOnceD 'DarkGray'
  C '   [5] ' 'Cyan' -n; C ('{0,-16}' -f $L.mLive) 'White' -n; C $L.mLiveD 'DarkGray'
  C '   [6] ' 'Cyan' -n; C ('{0,-16}' -f $L.mLog) 'White' -n; C $L.mLogD 'DarkGray'
  C '   [7] ' 'Cyan' -n; C ('{0,-16}' -f $L.mReadme) 'White' -n; C $L.mReadmeD 'DarkGray'
  C '   [R] ' 'Gray' -n; C ('{0,-16}' -f $L.mRefresh) 'White'
  C '   [0] ' 'DarkGray' -n; C $L.mExit 'White'
  Line 'DarkGray'; C ('   ' + $L.prompt) 'Yellow' -n
}

# ============================== Actions ==============================
function Do-Pause([switch]$Quiet) {
  $r = Send-Cmd $CMD.BclDisengage; $v = [BitConverter]::ToUInt32($r, 0)
  $t = @($L.dis0, $L.dis1, $L.dis2)[$v]; if (-not $t) { $t = "0x{0:X}" -f $v }
  Write-Log ("pause -> {0} {1}" -f $v, $t)
  if (-not $Quiet) { C ('   ' + ($L.disResult -f $t)) $(if ($v -eq 0 -or $v -eq 2) { 'Green' } else { 'Yellow' }); if ($v -eq 1) { C ('   ' + $L.disCountdown) 'Yellow' } }
  return $v
}
function Install-Task {
  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Action pause"
  $t1 = New-ScheduledTaskTrigger -AtStartup; $t1.Delay = 'PT2M'
  $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
  $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
  Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t1, $t2 -Principal $p -Settings $st -Description 'Surface Smart Charging 100% watchdog (surface-charge-limit)' -Force | Out-Null
  Write-Log 'task installed'
}
function Remove-Task { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -EA SilentlyContinue; Write-Log 'task removed' }

function Act-Unlock {
  C ''; C ('   ' + $L.doUnlock) 'Cyan'
  if ((Get-State).Mode -eq 1) { $v = Set-Mode 0; C ('   ' + ($L.limitCleared -f (Rsp $v))) 'Green'; Write-Log "mode->0: $(Rsp $v)" }
  [void](Do-Pause); Install-Task; C ('   ' + ($L.taskInstalled -f $TaskName)) 'Green'
}
function Act-Limit { C ''; C ('   ' + $L.doLimit) 'Cyan'; Remove-Task; C ('   ' + $L.taskRemoved) 'Gray'; $v = Set-Mode 1 80; C ('   ' + ($L.modeSet -f $L.mFixed, (Rsp $v))) $(if ($v -eq 0) { 'Green' } else { 'Red' }); Write-Log "mode->1/80: $(Rsp $v)" }
function Act-Default { C ''; C ('   ' + $L.doDefault) 'Cyan'; Remove-Task; C ('   ' + $L.taskRemoved) 'Gray'; $v = Set-Mode 0; C ('   ' + ($L.modeSet -f $L.mAdaptive, (Rsp $v))) $(if ($v -eq 0) { 'Green' } else { 'Red' }); Write-Log "mode->0: $(Rsp $v)"; C ('   ' + $L.defNote) 'DarkGray' }
function Pause-Key { C ''; C ('   ' + $L.anyKey) 'DarkGray'; [void][Console]::ReadKey($true) }

# ============================== CLI mode ==============================
if ($Action -eq 'lib') { return }   # dot-source only: defines functions, no UI
if ($Action -ne 'menu') {
  switch ($Action) {
    'pause'        { try { [void](Do-Pause -Quiet) } catch { Write-Log "pause ERR: $($_.Exception.Message)"; exit 1 } }
    'status'       { Banner; Draw-Panel (Get-State) }
    'screen'       { Banner; if (-not (Test-Admin)) { C ('   ' + $L.notAdmin) 'Red'; C '' }; Draw-Panel (Get-State); Draw-Menu; C '' }
    'unlock'       { Act-Unlock }
    'limit80'      { Act-Limit }
    'default'      { Act-Default }
    'task-install' { Install-Task; 'Task installed.' }
    'task-remove'  { Remove-Task; 'Task removed.' }
  }
  return
}

# ============================== Interactive menu ==============================
try {
  $Host.UI.RawUI.WindowTitle = 'Surface Charge Control'
  $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray'
  $ws = $Host.UI.RawUI.WindowSize
  if ($ws.Width -lt 84) { $Host.UI.RawUI.BufferSize = New-Object Management.Automation.Host.Size(84, 3000); $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size(84, [math]::Max($ws.Height, 52)) }
} catch {}

if (-not (Get-Path)) { Banner; C ('   ' + $L.noIface) 'Red'; Pause-Key; return }

while ($true) {
  Banner
  if (-not (Test-Admin)) { C ('   ' + $L.notAdmin) 'Red'; C '' }
  Draw-Panel (Get-State); Draw-Menu
  $k = [Console]::ReadKey($true).KeyChar.ToString().ToUpper(); C $k 'White'
  try {
    switch ($k) {
      '1' { Act-Unlock; Start-Sleep 2; Pause-Key }
      '2' { Act-Limit; Start-Sleep 2; Pause-Key }
      '3' { Act-Default; Start-Sleep 2; Pause-Key }
      '4' { C ''; [void](Do-Pause); Pause-Key }
      '5' { while (-not [Console]::KeyAvailable) { Banner; Draw-Panel (Get-State); C ''; C ('   ' + $L.live + '  ' + (Get-Date -Format HH:mm:ss) + '  - ' + $L.liveExit) 'Magenta'; for ($i = 0; $i -lt 50 -and -not [Console]::KeyAvailable; $i++) { Start-Sleep -Milliseconds 100 } }; [void][Console]::ReadKey($true) }
      '6' { C ''; Line; if (Test-Path $LogFile) { Get-Content $LogFile -Tail 25 | ForEach-Object { C "   $_" $(if ($_ -match 'ERR|HATA') { 'Red' } elseif ($_ -match 'success|Basari|installed|kuruldu|disengag|duraklat') { 'Green' } else { 'Gray' }) } } else { C ('   ' + $L.noLog) 'DarkGray' }; Pause-Key }
      '7' { $rd = Join-Path (Split-Path $Dir) 'README.md'; if (-not (Test-Path $rd)) { $rd = Join-Path $Dir 'README.md' }; if (Test-Path $rd) { Start-Process notepad.exe $rd } }
      'R' { }
      '0' { Clear-Host; return }
      default { }
    }
  } catch { C ('   ' + ($L.fwErr -f $_.Exception.Message)) 'Red'; Write-Log "ERR ($k): $($_.Exception.Message)"; Pause-Key }
}
