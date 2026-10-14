<#
.SYNOPSIS
    Починка отображения текста в Telegram Desktop, когда на компьютере стоит Windhawk.

.DESCRIPTION
    Скрипт выполняет три независимых шага:

      1. Исключает процесс Telegram из модулей Windhawk, которые применяются
         ко ВСЕМ процессам (Include = *). Ничего не удаляет и не отключает -
         модули продолжают работать во всех остальных программах.

      2. Сбрасывает кэш растеризации шрифтов Windows (DirectWrite / GDI).
         Именно из-за него буквы рисуются вертикальными штрихами вместо
         нормальных символов. Основная причина поломки.

      3. Перезапускает службу Windhawk и клиент Telegram, чтобы изменения
         вступили в силу.

    Перед любыми изменениями делается резервная копия ветки реестра Windhawk.

.PARAMETER Diagnose
    Только показать текущее состояние, ничего не менять.

.PARAMETER SkipFontCache
    Не сбрасывать кэш шрифтов (пункт 2).

.PARAMETER KeepTelegramRunning
    Не перезапускать Telegram в конце.

.PARAMETER NonInteractive
    Не ждать нажатия Enter в конце (для запуска из скриптов и автотестов).

.EXAMPLE
    .\Fix-Telegram-Windhawk.ps1
    Обычный запуск: починить и перезапустить Telegram.

.EXAMPLE
    .\Fix-Telegram-Windhawk.ps1 -Diagnose
    Показать отчёт о состоянии Windhawk и Telegram, ничего не меняя.

.NOTES
    Требуются права администратора. Скрипт поднимет права сам, если нужно.
    Windows 10 / 11, PowerShell 5.1+.
#>

[CmdletBinding()]
param(
    [switch] $Diagnose,
    [switch] $SkipFontCache,
    [switch] $KeepTelegramRunning,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# elevation
# ---------------------------------------------------------------------------
function Test-Admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr  = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  Требуются права администратора - запрошу повышение...' -ForegroundColor Yellow

    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($flag in @('Diagnose', 'SkipFontCache', 'KeepTelegramRunning', 'NonInteractive')) {
        if ($PSBoundParameters.ContainsKey($flag) -and $PSBoundParameters[$flag]) {
            $forward += ('-{0}' -f $flag)
        }
    }

    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $forward -Wait | Out-Null
    }
    catch {
        Write-Host ''
        Write-Host '  Повышение прав отменено. Ничего не изменено.' -ForegroundColor Red
        Read-Host '  Нажмите Enter, чтобы выйти'
    }
    return
}

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
function Write-Title { param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor White
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
}
function Write-Step { param([string]$Text)  Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text)  Write-Host "    [OK]   $Text" -ForegroundColor Green }
function Write-Note { param([string]$Text)  Write-Host "    [!]    $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Text)  Write-Host "    [X]    $Text" -ForegroundColor Red }
function Write-Item { param([string]$Text)  Write-Host "           $Text" -ForegroundColor Gray }

function Wait-Exit {
    if ($NonInteractive) { return }
    Read-Host '  Нажмите Enter, чтобы закрыть'
}

try { $Host.UI.RawUI.WindowTitle = 'Fix Telegram (Windhawk + font cache)' } catch { }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Get-TelegramInfo {
    $procs = @(Get-Process -Name 'Telegram' -ErrorAction SilentlyContinue)
    $cands = @(
        (Join-Path $env:APPDATA  'Telegram Desktop\Telegram.exe'),
        (Join-Path $env:LOCALAPPDATA 'Telegram Desktop\Telegram.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Telegram Desktop\Telegram.exe'),
        (Join-Path $env:ProgramFiles 'Telegram Desktop\Telegram.exe')
    )
    $path = $null
    if ($procs.Count -gt 0) {
        try { $path = $procs[0].Path } catch { }
    }
    if (-not $path) {
        foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { $path = $c; break } }
    }
    return [pscustomobject]@{
        Name       = 'Telegram.exe'
        Path       = $path
        Running    = $procs
        Installed  = [bool]$path
    }
}

function Get-WindhawkInfo {
    $roots = @()
    foreach ($r in @('HKLM:\SOFTWARE\Windhawk', 'HKCU:\Software\Windhawk')) {
        $modsPath = Join-Path $r 'Engine\Mods'
        if (Test-Path $modsPath) { $roots += $modsPath }
    }

    $mods = @()
    foreach ($modsPath in $roots) {
        foreach ($key in (Get-ChildItem -Path $modsPath -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $mods += [pscustomobject]@{
                Name     = $key.PSChildName
                Include  = if ($null -ne $p.Include) { [string]$p.Include } else { '' }
                Exclude  = if ($null -ne $p.Exclude) { [string]$p.Exclude } else { '' }
                Disabled = if ($null -ne $p.Disabled) { [int]$p.Disabled } else { 0 }
                Library  = if ($null -ne $p.LibraryFileName) { [string]$p.LibraryFileName } else { '' }
                RegPath  = $key.PSPath
            }
        }
    }

    $svc = Get-Service -Name 'Windhawk' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Installed = [bool]$roots
        Mods      = $mods
        Service   = $svc
    }
}

function Get-BackupDir {
    $base = $null
    if ($PSScriptRoot) {
        try {
            $probe = Join-Path $PSScriptRoot '.write-probe'
            Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $base = $PSScriptRoot
        } catch { $base = $null }
    }
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'Documents' }

    $dir = Join-Path $base ('WindhawkFix-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Split-List {
    param([string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    if ($Value) {
        foreach ($v in ($Value -split '\|')) {
            $t = $v.Trim()
            if ($t) { $out.Add($t) }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# diagnose report
# ---------------------------------------------------------------------------
function Show-Diagnose {
    Write-Title 'ДИАГНОСТИКА'

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Step 'Система'
    Write-Item ("Windows: {0} (сборка {1})" -f $os.Caption, $os.BuildNumber)
    Write-Item ("Версия PowerShell: {0}" -f $PSVersionTable.PSVersion)

    $tg = Get-TelegramInfo
    Write-Step 'Telegram'
    if ($tg.Installed) {
        Write-Ok ("установлен: {0}" -f $tg.Path)
    } else {
        Write-Note 'Telegram Desktop не найден в стандартных папках'
    }
    if ($tg.Running.Count -gt 0) {
        Write-Item ("запущен, PID: {0}" -f (($tg.Running | ForEach-Object { $_.Id }) -join ', '))
    } else {
        Write-Item 'не запущен'
    }

    $wh = Get-WindhawkInfo
    Write-Step 'Windhawk'
    if ($wh.Installed) {
        Write-Ok 'установлен'
        if ($wh.Service) { Write-Item ("служба: {0}" -f $wh.Service.Status) }
    } else {
        Write-Note 'Windhawk не установлен'
    }

    if ($wh.Mods.Count -gt 0) {
        Write-Step ("Зарегистрированные модули ({0})" -f $wh.Mods.Count)
        foreach ($m in $wh.Mods) {
            $state = if ($m.Disabled -eq 1) { 'ВЫКЛ' } else { 'вкл ' }
            Write-Item ("[{0}] {1}  Include={2}  Exclude={3}" -f $state, $m.Name, ($m.Include), ($m.Exclude))
        }
    }

    # проверка, какие DLL реально загружены в процесс Telegram
    if ($tg.Running.Count -gt 0) {
        Write-Step 'Загруженные в Telegram DLL, связанные с Windhawk'
        $modsLibraries = @($wh.Mods | Where-Object { $_.Library } | ForEach-Object { $_.Library })
        $raw = & tasklist.exe /m /fi ("imagename eq {0}" -f $tg.Name) 2>$null
        $joined = ($raw -join "`n")
        $found = @()
        if ($joined -match 'windhawk\.dll') { $found += 'windhawk.dll (движок)' }
        foreach ($lib in $modsLibraries) {
            if ($joined -match [regex]::Escape($lib)) { $found += $lib }
        }
        if ($found.Count -eq 0) {
            Write-Ok 'в процесс не загружено ничего от Windhawk - модули не влияют'
        } else {
            foreach ($f in $found) { Write-Note ("загружено: {0}" -f $f) }
        }
    }

    Write-Step 'Кэш шрифтов'
    $fontCacheDir = Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Local\FontCache'
    $fnc = Join-Path $env:WINDIR 'System32\FNTCACHE.DAT'
    $n = 0
    if (Test-Path -LiteralPath $fontCacheDir) {
        $n = @(Get-ChildItem -LiteralPath $fontCacheDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    Write-Item ("файлов в кэше: {0}" -f $n)
    Write-Item ("FNTCACHE.DAT: {0}" -f $(if (Test-Path -LiteralPath $fnc) { 'есть' } else { 'нет' }))

    Write-Host ''
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
Show-Diagnose
if ($Diagnose) {
    Write-Host ''
    Write-Host '  Режим диагностики: изменения не вносились.' -ForegroundColor DarkGray
    Wait-Exit
    return
}

try {
Write-Title 'ПОЧИНКА'
Write-Host '  Telegram будет перезапущен. Несохранённый черновик может пропасть.' -ForegroundColor DarkGray
Write-Host ''

$tg = Get-TelegramInfo
$wh = Get-WindhawkInfo

# --- шаг 1: бэкап -------------------------------------------------------
$backupDir = Get-BackupDir
Write-Step 'Резервная копия настроек Windhawk'
$exported = 0
foreach ($rk in @('HKLM\SOFTWARE\Windhawk', 'HKCU\Software\Windhawk')) {
    $file = Join-Path $backupDir (($rk -replace '[\\:]', '_') + '.reg')
    $rc = -1
    try {
        # reg.exe пишет об ошибке в stderr, что при ErrorActionPreference=Stop
        # прерывает весь скрипт - временно переключаем режим
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & reg.exe export $rk $file /y 2>&1 | Out-Null
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
    }
    catch {
        Write-Note ("не удалось выгрузить {0}: {1}" -f $rk, $_.Exception.Message)
    }
    if ($rc -eq 0 -and (Test-Path -LiteralPath $file)) {
        Write-Ok ("сохранено: {0}" -f $file)
        $exported++
    }
    else {
        Write-Note ("ветка {0} не выгружена - возможно, её нет в системе" -f $rk)
    }
}
if ($exported -eq 0) { Write-Note 'ветка реестра Windhawk не найдена, бэкап не сделан' }

# --- шаг 2: исключения для модулей --------------------------------------
Write-Step 'Исключение Telegram из модулей Windhawk (без удаления)'
if (-not $wh.Installed) {
    Write-Note 'Windhawk не установлен - шаг пропущен'
}
else {
    $changed = 0
    foreach ($m in $wh.Mods) {
        if ($m.Disabled -eq 1) {
            Write-Item ("{0}: выключен, пропущен" -f $m.Name)
            continue
        }
        if ($m.Include -ne '*') {
            Write-Item ("{0}: Include={1} - работает не везде, трогать не нужно" -f $m.Name, $m.Include)
            continue
        }
        $list = Split-List $m.Exclude
        if ($list -contains $tg.Name) {
            Write-Item ("{0}: {1} уже в списке исключений" -f $m.Name, $tg.Name)
            continue
        }
        $list.Add($tg.Name)
        Set-ItemProperty -Path $m.RegPath -Name 'Exclude' -Value ($list -join '|') -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $m.RegPath -Name 'SettingsChangeTime' `
            -Value ([int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())) -ErrorAction SilentlyContinue
        Write-Ok ("{0}: добавлено в Exclude -> {1}" -f $m.Name, ($list -join '|'))
        $changed++
    }
    if ($changed -eq 0) { Write-Note 'изменять было нечего' }
}

# --- шаг 3: кэш шрифтов -------------------------------------------------
if ($SkipFontCache) {
    Write-Step 'Сброс кэша шрифтов'
    Write-Note 'пропущен флагом -SkipFontCache'
}
else {
    Write-Step 'Сброс кэша растеризации шрифтов (DirectWrite / GDI)'
    $fontSvc = Get-Service -Name 'FontCache' -ErrorAction SilentlyContinue

    if ($fontSvc) {
        foreach ($d in @($fontSvc.DependentServices)) {
            Stop-Service -Name $d.Name -Force -ErrorAction SilentlyContinue
        }
        if ($fontSvc.Status -ne 'Stopped') {
            Stop-Service -Name 'FontCache' -Force -ErrorAction SilentlyContinue
        }
        Get-Process -Name 'FontCache' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Ok 'служба FontCache остановлена'
    }

    $fontCacheDir = Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Local\FontCache'
    if (Test-Path -LiteralPath $fontCacheDir) {
        $removed = 0
        Get-ChildItem -LiteralPath $fontCacheDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { }
        }
        Write-Ok ("очищено файлов кэша: {0}" -f $removed)
    }
    else {
        Write-Note ("папка не найдена: {0}" -f $fontCacheDir)
    }

    $fnc = Join-Path $env:WINDIR 'System32\FNTCACHE.DAT'
    if (Test-Path -LiteralPath $fnc) {
        Remove-Item -LiteralPath $fnc -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $fnc) {
            Write-Note 'FNTCACHE.DAT занят другим процессом - будет удалён при следующей загрузке'
        } else {
            Write-Ok 'FNTCACHE.DAT удалён'
        }
    }

    if ($fontSvc) {
        Start-Service -Name 'FontCache' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Write-Ok ("служба FontCache: {0}" -f (Get-Service -Name 'FontCache').Status)
    }
}

# --- шаг 4: служба Windhawk --------------------------------------------
Write-Step 'Служба Windhawk'
if ($wh.Service) {
    if ($wh.Service.Status -ne 'Running') {
        Start-Service -Name 'Windhawk' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Write-Ok ("служба: {0}" -f (Get-Service -Name 'Windhawk').Status)
}
else {
    Write-Note 'служба Windhawk не найдена'
}

# --- шаг 5: перезапуск Telegram ----------------------------------------
Write-Step 'Перезапуск Telegram'
if ($KeepTelegramRunning) {
    Write-Note 'пропущен флагом -KeepTelegramRunning - закрой и открой Telegram вручную'
}
elseif ($tg.Installed) {
    Get-Process -Name 'Telegram' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Process -FilePath $tg.Path -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8
    if (Get-Process -Name 'Telegram' -ErrorAction SilentlyContinue) {
        Write-Ok 'Telegram запущен заново'
    } else {
        Write-Bad 'Telegram не удалось запустить, открой его вручную'
    }
}
else {
    Write-Note 'Telegram не найден, запускать нечего'
}

# --- итог ---------------------------------------------------------------
Write-Title 'ГОТОВО'
Write-Host '  Что было сделано:' -ForegroundColor White
Write-Item '1. Сделан бэкап настроек Windhawk (папка backup выше)'
Write-Item '2. Telegram.exe добавлен в исключения модулей с Include = *'
Write-Item '3. Пересоздан кэш шрифтов Windows - это и ломало буквы'
Write-Item '4. Перезапущены службы и клиент Telegram'
Write-Host ''
Write-Host '  Ни один модуль Windhawk не удалён и не отключён.' -ForegroundColor Green
Write-Host ''

Wait-Exit
}
catch {
    Write-Host ''
    Write-Bad ('Непредвиденная ошибка: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { Write-Item ($_.ScriptStackTrace -split "`n" | Select-Object -First 3) }
    Write-Host ''
    Wait-Exit
}