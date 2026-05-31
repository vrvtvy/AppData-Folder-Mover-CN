# Move-AppData-Folder.ps1
# GUI-программа для переноса папки из AppData на другой диск и создания NTFS junction-ссылки.
# Запуск: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\Move-AppData-Folder.ps1"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

function Normalize-Path([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim())).TrimEnd('\')
}

function Test-PathInside([string]$Child, [string]$Parent) {
    $c = (Normalize-Path $Child).ToLowerInvariant()
    $p = (Normalize-Path $Parent).ToLowerInvariant()
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p.TrimEnd('\') + '\')
}

function Get-UserAppDataRoot {
    return Normalize-Path (Join-Path $env:USERPROFILE "AppData")
}

function Get-AppDataRoots {
    $roots = @()
    $appDataRoot = Get-UserAppDataRoot
    if (Test-Path -LiteralPath $appDataRoot -PathType Container) { $roots += $appDataRoot }
    if ($env:APPDATA) { $roots += (Normalize-Path $env:APPDATA) }          # Roaming
    if ($env:LOCALAPPDATA) { $roots += (Normalize-Path $env:LOCALAPPDATA) } # Local
    $localLow = Join-Path $env:USERPROFILE "AppData\LocalLow"
    if (Test-Path -LiteralPath $localLow) { $roots += (Normalize-Path $localLow) }
    return $roots | Select-Object -Unique
}

function Get-RelativePathAfterAppData([string]$SourceRaw) {
    $source = Normalize-Path $SourceRaw
    $appDataRoot = Get-UserAppDataRoot

    if (!(Test-PathInside $source $appDataRoot)) {
        return $null
    }

    if ($source.ToLowerInvariant() -eq $appDataRoot.ToLowerInvariant()) {
        return ""
    }

    return $source.Substring($appDataRoot.Length).TrimStart('\')
}

function Join-BaseAndRelative([string]$BaseRaw, [string]$RelativeRaw) {
    $base = Normalize-Path $BaseRaw
    $relative = $RelativeRaw.TrimStart('\').TrimEnd('\')

    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $base
    }

    $result = $base
    foreach ($part in ($relative -split '\\')) {
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $result = Join-Path $result $part
        }
    }
    return Normalize-Path $result
}

function Build-DefaultTargetPath([string]$BaseRaw, [string]$SourceRaw) {
    $relative = Get-RelativePathAfterAppData $SourceRaw
    if ($null -eq $relative -or [string]::IsNullOrWhiteSpace($relative)) {
        return Normalize-Path $BaseRaw
    }
    return Join-BaseAndRelative $BaseRaw $relative
}

function Is-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}


function Format-Bytes([Int64]$Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $units = @("KB", "MB", "GB", "TB")
    $value = [double]$Bytes
    foreach ($unit in $units) {
        $value = $value / 1024
        if ($value -lt 1024) {
            return ("{0:N2} {1}" -f $value, $unit)
        }
    }
    return ("{0:N2} PB" -f ($value / 1024))
}

function Get-ReparsePointTarget([string]$PathRaw) {
    try {
        $item = Get-Item -LiteralPath $PathRaw -Force -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains "Target" -and $item.Target) {
            return ($item.Target -join "; ")
        }
        if ($item.PSObject.Properties.Name -contains "LinkTarget" -and $item.LinkTarget) {
            return $item.LinkTarget
        }
    } catch {}
    return ""
}

function Get-ReparsePointDisplayLine($Item) {
    $path = ""
    $target = ""
    try { $path = $Item.FullName } catch { $path = [string]$Item }
    try { $target = Get-ReparsePointTarget $path } catch {}

    if ([string]::IsNullOrWhiteSpace($target)) {
        return $path
    }
    return "$path -> $target"
}

function Get-NestedReparsePointDirectories([string]$RootRaw, [int]$MaxResults = 50) {
    $root = Normalize-Path $RootRaw
    $result = @()

    if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    try {
        $result = Get-ChildItem -LiteralPath $root -Force -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First $MaxResults
    } catch {
        return @()
    }

    return @($result)
}

function Get-DirectorySizeBytes([string]$PathRaw) {
    $path = Normalize-Path $PathRaw
    [Int64]$total = 0
    $files = 0
    $skippedLinks = 0
    $errors = 0

    if ([string]::IsNullOrWhiteSpace($path) -or !(Test-Path -LiteralPath $path -PathType Container)) {
        return [PSCustomObject]@{ Bytes = 0; Files = 0; SkippedLinks = 0; Errors = 1 }
    }

    try {
        $rootItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [PSCustomObject]@{ Bytes = 0; Files = 0; SkippedLinks = 1; Errors = 0 }
        }
    } catch {
        return [PSCustomObject]@{ Bytes = 0; Files = 0; SkippedLinks = 0; Errors = 1 }
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($path)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        try {
            Get-ChildItem -LiteralPath $current -Force -File -ErrorAction Stop | ForEach-Object {
                try {
                    $total += [Int64]$_.Length
                    $files += 1
                } catch {
                    $errors += 1
                }
            }
        } catch {
            $errors += 1
        }

        try {
            Get-ChildItem -LiteralPath $current -Force -Directory -ErrorAction Stop | ForEach-Object {
                try {
                    if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $skippedLinks += 1
                    } else {
                        $stack.Push($_.FullName)
                    }
                } catch {
                    $errors += 1
                }
            }
        } catch {
            $errors += 1
        }
    }

    return [PSCustomObject]@{ Bytes = $total; Files = $files; SkippedLinks = $skippedLinks; Errors = $errors }
}

function Get-SubfolderSizeRows([string]$RootRaw, [scriptblock]$GuiLog = $null) {
    $root = Normalize-Path $RootRaw

    if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root -PathType Container)) {
        throw "Папка для сортировки не найдена: $root"
    }

    if ($GuiLog) { & $GuiLog "Считаю размеры подпапок: $root" }
    Write-DetailLog "Считаю размеры подпапок: $root"

    $rows = New-Object System.Collections.Generic.List[object]
    $dirs = @(Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction Stop)
    $index = 0
    $totalDirs = $dirs.Count

    foreach ($dir in $dirs) {
        $index += 1
        if ($GuiLog) { & $GuiLog "[$index/$totalDirs] $($dir.Name)" }
        Write-DetailLog "Размер [$index/$totalDirs]: $($dir.FullName)"

        $isLink = (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $target = ""
        if ($isLink) { $target = Get-ReparsePointTarget $dir.FullName }

        $sizeInfo = Get-DirectorySizeBytes $dir.FullName
        $typeText = "папка"
        if ($isLink) { $typeText = "ссылка/junction" }
        elseif ($sizeInfo.SkippedLinks -gt 0) { $typeText = "папка, внутри есть ссылки: $($sizeInfo.SkippedLinks)" }

        $rows.Add([PSCustomObject]@{
            Name         = $dir.Name
            Path         = $dir.FullName
            Bytes        = [Int64]$sizeInfo.Bytes
            SizeText     = Format-Bytes ([Int64]$sizeInfo.Bytes)
            Files        = [int]$sizeInfo.Files
            SkippedLinks = [int]$sizeInfo.SkippedLinks
            Errors       = [int]$sizeInfo.Errors
            IsLink       = [bool]$isLink
            Target       = $target
            TypeText     = $typeText
        }) | Out-Null
    }

    return @($rows | Sort-Object Bytes -Descending)
}

function New-DetailedLogFile {
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $env:TEMP "AppData-Folder-Mover"
    }

    $logDir = Join-Path $root "detailed_logs"
    if (!(Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    return Join-Path $logDir "move_$timestamp.log"
}

function Write-DetailLog([string]$Message, [string]$LogFile = $script:CurrentDetailedLog) {
    $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $Message
    Write-Host $line
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Ensure-RestartManagerLoaded {
    if (([System.Management.Automation.PSTypeName]'RestartManagerUtil').Type) {
        return
    }

    $restartManagerCode = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;

public static class RestartManagerUtil
{
    private const int RmRebootReasonNone = 0;
    private const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    private enum RM_APP_TYPE
    {
        RmUnknownApp = 0,
        RmMainWindow = 1,
        RmOtherWindow = 2,
        RmService = 3,
        RmExplorer = 4,
        RmConsole = 5,
        RmCritical = 1000
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;

        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(
        uint pSessionHandle,
        uint nFiles,
        string[] rgsFilenames,
        uint nApplications,
        [In] RM_UNIQUE_PROCESS[] rgApplications,
        uint nServices,
        string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(
        uint dwSessionHandle,
        out uint pnProcInfoNeeded,
        ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
        ref uint lpdwRebootReasons);

    public static Process[] GetLockingProcesses(string[] paths)
    {
        string[] cleanPaths = paths
            .Where(p => !String.IsNullOrWhiteSpace(p))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanPaths.Length == 0)
        {
            return new Process[0];
        }

        uint handle;
        string key = Guid.NewGuid().ToString();
        int result = RmStartSession(out handle, 0, key);

        if (result != 0)
        {
            throw new Win32Exception(result);
        }

        try
        {
            result = RmRegisterResources(handle, (uint)cleanPaths.Length, cleanPaths, 0, null, 0, null);

            if (result != 0)
            {
                throw new Win32Exception(result);
            }

            uint pnProcInfoNeeded = 0;
            uint pnProcInfo = 0;
            uint lpdwRebootReasons = RmRebootReasonNone;

            result = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);

            if (result == ERROR_MORE_DATA)
            {
                RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
                pnProcInfo = pnProcInfoNeeded;

                result = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons);

                if (result != 0)
                {
                    throw new Win32Exception(result);
                }

                List<Process> processes = new List<Process>();

                for (int i = 0; i < pnProcInfo; i++)
                {
                    try
                    {
                        processes.Add(Process.GetProcessById(processInfo[i].Process.dwProcessId));
                    }
                    catch (ArgumentException)
                    {
                        // Process already exited.
                    }
                }

                return processes
                    .GroupBy(p => p.Id)
                    .Select(g => g.First())
                    .ToArray();
            }

            if (result == 0)
            {
                return new Process[0];
            }

            throw new Win32Exception(result);
        }
        finally
        {
            RmEndSession(handle);
        }
    }
}
'@

    Add-Type -Language CSharp -TypeDefinition $restartManagerCode -ErrorAction Stop
}

function Get-LockCheckPaths([string]$RootRaw, [int]$MaxFiles = 5000) {
    $root = Normalize-Path $RootRaw
    $items = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    $items.Add($root) | Out-Null

    try {
        Get-ChildItem -LiteralPath $root -Force -File -ErrorAction SilentlyContinue |
            Select-Object -First 100 |
            ForEach-Object { $items.Add($_.FullName) | Out-Null }
    } catch {}

    try {
        Get-ChildItem -LiteralPath $root -Force -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First $MaxFiles |
            ForEach-Object { $items.Add($_.FullName) | Out-Null }
    } catch {}

    return $items.ToArray() | Select-Object -Unique
}

function Split-ArrayIntoChunks([object[]]$Items, [int]$ChunkSize) {
    $chunks = @()
    if ($null -eq $Items -or $Items.Count -eq 0) { return $chunks }

    for ($i = 0; $i -lt $Items.Count; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize - 1, $Items.Count - 1)
        $chunks += ,($Items[$i..$end])
    }

    return $chunks
}

function Get-LockingProcessesForFolder([string]$FolderRaw, [scriptblock]$GuiLog = $null) {
    $folder = Normalize-Path $FolderRaw

    if ($GuiLog) { & $GuiLog "Проверяю, какие приложения держат файлы в папке..." }
    Write-DetailLog "Проверка блокирующих процессов: $folder"

    Ensure-RestartManagerLoaded

    $paths = @(Get-LockCheckPaths $folder 5000)
    if ($GuiLog) { & $GuiLog "Проверено путей для занятости: $($paths.Count)" }
    Write-DetailLog "Проверено путей для занятости: $($paths.Count)"

    if ($paths.Count -eq 0) {
        return @()
    }

    $processMap = @{}
    $chunks = Split-ArrayIntoChunks $paths 256

    foreach ($chunk in $chunks) {
        try {
            $found = [RestartManagerUtil]::GetLockingProcesses([string[]]$chunk)
            foreach ($p in $found) {
                if ($p -and -not $processMap.ContainsKey($p.Id)) {
                    $processMap[$p.Id] = $p
                }
            }
        } catch {
            if ($GuiLog) { & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: не удалось проверить часть файлов через Restart Manager: $($_.Exception.Message)" }
            Write-DetailLog "Restart Manager error: $($_.Exception.Message)"
        }
    }

    return @($processMap.Values | Sort-Object ProcessName, Id)
}

function Get-ProcessDisplayLine($Process) {
    $name = ""
    $id = ""
    $title = ""
    $path = ""

    try { $name = $Process.ProcessName } catch { $name = "unknown" }
    try { $id = $Process.Id } catch { $id = "?" }
    try { $title = $Process.MainWindowTitle } catch { $title = "" }
    try { $path = $Process.MainModule.FileName } catch { $path = "" }

    $line = "$name | PID $id"
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        $line += " | $title"
    }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $line += " | $path"
    }

    return $line
}

function Format-LockingProcessesText($Processes, [int]$MaxLines = 12) {
    $lines = @()
    foreach ($p in @($Processes | Select-Object -First $MaxLines)) {
        $lines += (Get-ProcessDisplayLine $p)
    }

    if (@($Processes).Count -gt $MaxLines) {
        $lines += "...ещё $(@($Processes).Count - $MaxLines)"
    }

    return ($lines -join "`r`n")
}

function Log-LockingProcesses($Processes, [scriptblock]$GuiLog) {
    if ($null -eq $Processes -or @($Processes).Count -eq 0) {
        & $GuiLog "Блокирующих приложений не найдено."
        Write-DetailLog "Блокирующих приложений не найдено."
        return
    }

    & $GuiLog "Найдены приложения, которые могут мешать переносу:"
    Write-DetailLog "Найдены приложения, которые могут мешать переносу:"

    foreach ($p in @($Processes)) {
        $line = Get-ProcessDisplayLine $p
        & $GuiLog "  $line"
        Write-DetailLog "  $line"
    }
}

function Close-LockingProcessesGracefully($Processes, [scriptblock]$GuiLog) {
    foreach ($p in @($Processes)) {
        try {
            if ($p.HasExited) { continue }

            $line = Get-ProcessDisplayLine $p

            if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                & $GuiLog "Отправляю команду закрытия: $line"
                Write-DetailLog "Отправляю команду закрытия: $line"
                [void]$p.CloseMainWindow()
            } else {
                & $GuiLog "У процесса нет главного окна для мягкого закрытия: $line"
                Write-DetailLog "У процесса нет главного окна для мягкого закрытия: $line"
            }
        } catch {
            & $GuiLog "Не удалось отправить закрытие: $($_.Exception.Message)"
            Write-DetailLog "Не удалось отправить закрытие: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 3
}

function Kill-LockingProcesses($Processes, [scriptblock]$GuiLog) {
    foreach ($p in @($Processes)) {
        try {
            if ($p.HasExited) { continue }

            $line = Get-ProcessDisplayLine $p
            & $GuiLog "Принудительно закрываю: $line"
            Write-DetailLog "Принудительно закрываю: $line"
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            & $GuiLog "Не удалось принудительно закрыть процесс: $($_.Exception.Message)"
            Write-DetailLog "Не удалось принудительно закрыть процесс: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
}

function Resolve-LockingProcessesBeforeMove([string]$FolderRaw, [scriptblock]$GuiLog, [System.Windows.Forms.Form]$OwnerForm) {
    $lockers = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Log-LockingProcesses $lockers $GuiLog

    if ($lockers.Count -eq 0) {
        return $true
    }

    $listText = Format-LockingProcessesText $lockers 14

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Эти приложения держат файлы в выбранной папке и могут помешать переносу:`r`n`r`n$listText`r`n`r`nПопробовать закрыть их автоматически?`r`n`r`nСначала будет отправлена обычная команда закрытия окна. Несохранённые данные в этих приложениях могут быть потеряны.",
        "Папка используется",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) {
        & $GuiLog "Перенос отменён пользователем."
        return $false
    }

    if ($answer -eq [System.Windows.Forms.DialogResult]::No) {
        & $GuiLog "Пользователь отказался от автозакрытия. Перенос отменён."
        return $false
    }

    Close-LockingProcessesGracefully $lockers $GuiLog

    $lockersAfterClose = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Log-LockingProcesses $lockersAfterClose $GuiLog

    if ($lockersAfterClose.Count -eq 0) {
        & $GuiLog "После мягкого закрытия блокировок не найдено."
        return $true
    }

    $listText2 = Format-LockingProcessesText $lockersAfterClose 14

    $killAnswer = [System.Windows.Forms.MessageBox]::Show(
        "Некоторые процессы всё ещё держат файлы:`r`n`r`n$listText2`r`n`r`nЗакрыть их принудительно?`r`n`r`nЭто может привести к потере несохранённых данных.",
        "Процессы всё ещё мешают",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($killAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
        & $GuiLog "Пользователь отказался от принудительного закрытия. Перенос отменён."
        return $false
    }

    Kill-LockingProcesses $lockersAfterClose $GuiLog

    $lockersAfterKill = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Log-LockingProcesses $lockersAfterKill $GuiLog

    if ($lockersAfterKill.Count -eq 0) {
        & $GuiLog "После принудительного закрытия блокировок не найдено."
        return $true
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Папка всё ещё используется. Перенос отменён.`r`n`r`nЗакройте приложения вручную или перезагрузите Windows.",
        "Папка всё ещё занята",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    return $false
}

function Validate-MovePlan([string]$SourceRaw, [string]$TargetRaw) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $source = Normalize-Path $SourceRaw
    $target = Normalize-Path $TargetRaw

    if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("Не указана исходная папка.") }
    if ([string]::IsNullOrWhiteSpace($target)) { $errors.Add("Не указана новая папка.") }

    if ($errors.Count -eq 0) {
        if (!(Test-Path -LiteralPath $source -PathType Container)) {
            $errors.Add("Исходная папка не существует: $source")
        }

        $appDataRoot = Get-UserAppDataRoot
        if (!(Test-PathInside $source $appDataRoot)) {
            $errors.Add("Исходная папка должна быть внутри AppData: Local, Roaming или LocalLow.")
        }

        $forbiddenRoots = @(
            $appDataRoot,
            (Normalize-Path $env:LOCALAPPDATA),
            (Normalize-Path $env:APPDATA),
            (Normalize-Path (Join-Path $env:USERPROFILE "AppData\LocalLow"))
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

        foreach ($root in $forbiddenRoots) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $root).ToLowerInvariant()) {
                $errors.Add("Нельзя переносить корневую папку AppData/Local/Roaming/LocalLow целиком: $source")
            }
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            try {
                if (Is-ReparsePoint $source) {
                    $errors.Add("Исходная папка уже является ссылкой/reparse point. Повторно переносить её нельзя.")
                }
            } catch {
                $errors.Add("Не удалось проверить исходную папку: $($_.Exception.Message)")
            }

            try {
                $nestedLinks = @(Get-NestedReparsePointDirectories $source 25)
                if ($nestedLinks.Count -gt 0) {
                    $errors.Add("Внутри выбранной папки уже есть перенесённые/ссылочные папки. Нельзя безопасно переносить родительскую папку, иначе вложенная ссылка может потеряться при копировании.")
                    foreach ($link in $nestedLinks) {
                        $errors.Add("  вложенная ссылка: $(Get-ReparsePointDisplayLine $link)")
                    }
                    if ($nestedLinks.Count -ge 25) {
                        $errors.Add("  показаны первые 25 ссылок; возможно, внутри есть ещё.")
                    }
                }
            } catch {
                $warnings.Add("Не удалось проверить вложенные ссылки/reparse point: $($_.Exception.Message)")
            }
        }

        if (Test-Path -LiteralPath $target) {
            $errors.Add("Новая папка уже существует. Укажите путь, которого ещё нет: $target")
        }

        $targetParent = Split-Path -Parent $target
        if ([string]::IsNullOrWhiteSpace($targetParent)) {
            $errors.Add("У новой папки должен быть родительский каталог.")
        }

        if (Test-PathInside $target $source) {
            $errors.Add("Новая папка не может находиться внутри исходной папки.")
        }

        if (Test-PathInside $source $target) {
            $errors.Add("Исходная папка не может находиться внутри новой папки.")
        }

        if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
            $errors.Add("Исходный и новый путь совпадают.")
        }

        $sourceRoot = [System.IO.Path]::GetPathRoot($source)
        $targetRoot = [System.IO.Path]::GetPathRoot($target)
        if ($sourceRoot -eq $targetRoot) {
            $warnings.Add("Исходная и новая папка находятся на одном диске. Для безопасного переноса потребуется временно занять место под копию.")
        }

        if ($target -match '^[A-Za-z]:\\') {
            $drive = $target.Substring(0,1)
            try {
                $vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
                if ($vol.FileSystem -ne "NTFS") {
                    $warnings.Add("Целевой диск не NTFS ($($vol.FileSystem)). Junction-ссылки работают только на NTFS.")
                }
            } catch {
                $warnings.Add("Не удалось проверить файловую систему целевого диска. Для junction нужен NTFS.")
            }
        } else {
            $warnings.Add("Целевой путь не похож на обычный локальный путь вида D:\Folder. Сетевые пути для junction не подходят.")
        }
    }

    return [PSCustomObject]@{
        Source   = $source
        Target   = $target
        Errors   = $errors
        Warnings = $warnings
    }
}

function New-Junction([string]$LinkPath, [string]$TargetPath) {
    $cmd = "mklink /J `"$LinkPath`" `"$TargetPath`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c $cmd"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        Output   = ($stdout + "`r`n" + $stderr).Trim()
    }
}

function Copy-FolderWithRobocopy([string]$From, [string]$To, [string]$DetailLogFile) {
    Write-DetailLog "Подробный вывод копирования ниже. Если папка большая, следите за этим окном консоли." $DetailLogFile
    Write-DetailLog "Robocopy: $From -> $To" $DetailLogFile

    $args = @(
        $From,
        $To,
        "/E",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/R:2",
        "/W:2",
        "/XJ",
        "/FFT",
        "/ETA",
        "/TEE",
        "/LOG+:$DetailLogFile"
    )

    & robocopy.exe @args
    $code = $LASTEXITCODE

    Write-DetailLog "Robocopy exit code: $code" $DetailLogFile

    if ($code -ge 8) {
        throw "Robocopy сообщил об ошибке. Код: $code. Подробности в файле: $DetailLogFile"
    }

    if (!(Test-Path -LiteralPath $To -PathType Container)) {
        throw "После копирования новая папка не найдена: $To"
    }
}

function Remove-FolderAfterSuccessfulMove([string]$Path, [scriptblock]$GuiLog) {
    if (!(Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    & $GuiLog "Удаляю временную исходную копию. Для большой папки это может занять время..."
    Write-DetailLog "Удаляю временную исходную копию: $Path"

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-DetailLog "Временная копия удалена."
    } catch {
        & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: ссылку создал, но временную копию удалить не удалось: $Path"
        & $GuiLog "Её можно удалить вручную после проверки."
        Write-DetailLog "Не удалось удалить временную копию: $($_.Exception.Message)"
    }
}

function Move-AppDataFolderAndLink([string]$SourceRaw, [string]$TargetRaw, [scriptblock]$Log) {
    $plan = Validate-MovePlan $SourceRaw $TargetRaw
    foreach ($e in $plan.Errors) { & $Log "ОШИБКА: $e" }
    foreach ($w in $plan.Warnings) { & $Log "ПРЕДУПРЕЖДЕНИЕ: $w" }
    if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Перенос отменён." }

    $source = $plan.Source
    $target = $plan.Target
    $targetParent = Split-Path -Parent $target
    $sourceParent = Split-Path -Parent $source
    $sourceName = Split-Path -Leaf $source
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tempPath = Join-Path $sourceParent ($sourceName + ".__moving_to_link_" + $timestamp)

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "Исходная папка: $source"
    & $Log "Новая папка:    $target"
    & $Log "Подробный лог:  $script:CurrentDetailedLog"
    & $Log "Во время большого переноса смотрите окно консоли."
    & $Log "Временное имя:  $tempPath"

    Write-DetailLog "=== AppData Folder Mover ==="
    Write-DetailLog "Исходная папка: $source"
    Write-DetailLog "Новая папка:    $target"
    Write-DetailLog "Временное имя:  $tempPath"

    try {
        if (!(Test-Path -LiteralPath $targetParent -PathType Container)) {
            & $Log "Создаю родительскую папку: $targetParent"
            Write-DetailLog "Создаю родительскую папку: $targetParent"
            New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop | Out-Null
        }

        & $Log "Переименовываю исходную папку во временную..."
        Write-DetailLog "Переименовываю исходную папку во временную..."

        try {
            Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $tempPath) -ErrorAction Stop
        } catch {
            & $Log "Не удалось переименовать исходную папку. Вероятно, она занята приложением."
            Write-DetailLog "Rename failed: $($_.Exception.Message)"
            try {
                $lockers = @(Get-LockingProcessesForFolder $source $Log)
                Log-LockingProcesses $lockers $Log
            } catch {
                & $Log "Не удалось определить мешающее приложение: $($_.Exception.Message)"
            }
            throw "Исходная папка занята или нет прав на переименование: $($_.Exception.Message)"
        }

        try {
            & $Log "Копирую данные через robocopy. Подробности выводятся в консоль..."
            Copy-FolderWithRobocopy $tempPath $target $script:CurrentDetailedLog
        } catch {
            & $Log "Копирование не удалось. Возвращаю исходную папку на место..."
            Write-DetailLog "Копирование не удалось. Пытаюсь вернуть исходную папку на место."
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw
        }

        & $Log "Создаю junction-ссылку..."
        Write-DetailLog "Создаю junction-ссылку: $source -> $target"
        $mk = New-Junction $source $target
        if ($mk.Output) {
            & $Log $mk.Output
            Write-DetailLog $mk.Output
        }

        if ($mk.ExitCode -ne 0 -or !(Test-Path -LiteralPath $source)) {
            & $Log "Создание ссылки не удалось. Пробую откатить перенос..."
            Write-DetailLog "Создание ссылки не удалось. Пробую откатить перенос."
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath -PathType Container) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw "mklink вернул код $($mk.ExitCode)."
        }

        Remove-FolderAfterSuccessfulMove $tempPath $Log

        & $Log "Готово. Старый путь теперь ведёт в новую папку."
        & $Log "Проверка: $source -> $target"
        Write-DetailLog "Готово. Старый путь теперь ведёт в новую папку."
    } catch {
        throw $_
    }
}

# ---------- GUI ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = "AppData Folder Mover"
$form.Size = New-Object System.Drawing.Size(900, 690)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(860, 620)

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

$script:TargetBaseForAutoPath = ""

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "Переносит выбранную папку из AppData в новое место и создаёт NTFS junction-ссылку на старом пути. Целевой путь строится как: выбранная базовая папка + путь после AppData."
$lblInfo.Location = New-Object System.Drawing.Point(12, 12)
$lblInfo.Size = New-Object System.Drawing.Size(840, 42)
$form.Controls.Add($lblInfo)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = "Исходная папка в AppData:"
$lblSource.Location = New-Object System.Drawing.Point(12, 64)
$lblSource.Size = New-Object System.Drawing.Size(820, 20)
$form.Controls.Add($lblSource)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(12, 86)
$txtSource.Size = New-Object System.Drawing.Size(735, 24)
$txtSource.Anchor = "Top,Left,Right"
$form.Controls.Add($txtSource)

$btnSource = New-Object System.Windows.Forms.Button
$btnSource.Text = "Выбрать"
$btnSource.Location = New-Object System.Drawing.Point(755, 84)
$btnSource.Size = New-Object System.Drawing.Size(95, 28)
$btnSource.Anchor = "Top,Right"
$form.Controls.Add($btnSource)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "Новая папка. По умолчанию: базовая папка на другом диске + путь исходной папки после AppData:"
$lblTarget.Location = New-Object System.Drawing.Point(12, 122)
$lblTarget.Size = New-Object System.Drawing.Size(820, 20)
$form.Controls.Add($lblTarget)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(12, 144)
$txtTarget.Size = New-Object System.Drawing.Size(735, 24)
$txtTarget.Anchor = "Top,Left,Right"
$form.Controls.Add($txtTarget)

$btnTarget = New-Object System.Windows.Forms.Button
$btnTarget.Text = "База"
$btnTarget.Location = New-Object System.Drawing.Point(755, 142)
$btnTarget.Size = New-Object System.Drawing.Size(95, 28)
$btnTarget.Anchor = "Top,Right"
$form.Controls.Add($btnTarget)

$lblExample = New-Object System.Windows.Forms.Label
$lblExample.Text = "Пример: C:\Users\User\AppData\Local\Game\Saved + D:\AppDataMoved => D:\AppDataMoved\Local\Game\Saved"
$lblExample.Location = New-Object System.Drawing.Point(12, 174)
$lblExample.Size = New-Object System.Drawing.Size(840, 20)
$form.Controls.Add($lblExample)

$chkClosed = New-Object System.Windows.Forms.CheckBox
$chkClosed.Text = "Я закрыл программу/игру, которая использует эту папку"
$chkClosed.Location = New-Object System.Drawing.Point(12, 200)
$chkClosed.Size = New-Object System.Drawing.Size(820, 24)
$form.Controls.Add($chkClosed)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Проверить"
$btnCheck.Location = New-Object System.Drawing.Point(12, 232)
$btnCheck.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnCheck)

$btnLocks = New-Object System.Windows.Forms.Button
$btnLocks.Text = "Занятость"
$btnLocks.Location = New-Object System.Drawing.Point(132, 232)
$btnLocks.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnLocks)

$btnSizes = New-Object System.Windows.Forms.Button
$btnSizes.Text = "Размеры"
$btnSizes.Location = New-Object System.Drawing.Point(252, 232)
$btnSizes.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnSizes)

$btnMove = New-Object System.Windows.Forms.Button
$btnMove.Text = "Перенести"
$btnMove.Location = New-Object System.Drawing.Point(372, 232)
$btnMove.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnMove)

$btnOpenLocal = New-Object System.Windows.Forms.Button
$btnOpenLocal.Text = "Local"
$btnOpenLocal.Location = New-Object System.Drawing.Point(502, 232)
$btnOpenLocal.Size = New-Object System.Drawing.Size(75, 32)
$form.Controls.Add($btnOpenLocal)

$btnOpenRoaming = New-Object System.Windows.Forms.Button
$btnOpenRoaming.Text = "Roaming"
$btnOpenRoaming.Location = New-Object System.Drawing.Point(587, 232)
$btnOpenRoaming.Size = New-Object System.Drawing.Size(85, 32)
$form.Controls.Add($btnOpenRoaming)

$btnOpenLocalLow = New-Object System.Windows.Forms.Button
$btnOpenLocalLow.Text = "LocalLow"
$btnOpenLocalLow.Location = New-Object System.Drawing.Point(682, 232)
$btnOpenLocalLow.Size = New-Object System.Drawing.Size(85, 32)
$form.Controls.Add($btnOpenLocalLow)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = "Логи"
$btnOpenLogs.Location = New-Object System.Drawing.Point(777, 232)
$btnOpenLogs.Size = New-Object System.Drawing.Size(75, 32)
$form.Controls.Add($btnOpenLogs)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 278)
$txtLog.Size = New-Object System.Drawing.Size(858, 360)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($txtLog)

$log = {
    param([string]$msg)
    $txtLog.AppendText(("[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg + "`r`n"))
}

$pickFolder = {
    param([string]$Description, [string]$InitialPath)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dlg.SelectedPath = $InitialPath
    }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return $null
}

function Refresh-TargetFromBaseIfPossible {
    if ([string]::IsNullOrWhiteSpace($script:TargetBaseForAutoPath)) { return }
    if ([string]::IsNullOrWhiteSpace($txtSource.Text)) { return }

    try {
        $relative = Get-RelativePathAfterAppData $txtSource.Text
        if ($null -ne $relative -and -not [string]::IsNullOrWhiteSpace($relative)) {
            $txtTarget.Text = Build-DefaultTargetPath $script:TargetBaseForAutoPath $txtSource.Text
        }
    } catch {}
}

$btnSource.Add_Click({
    $selected = & $pickFolder "Выберите папку внутри AppData" $env:LOCALAPPDATA
    if ($selected) {
        $txtSource.Text = $selected
        Refresh-TargetFromBaseIfPossible
    }
})

$btnTarget.Add_Click({
    $initial = ""
    if ($script:TargetBaseForAutoPath -and (Test-Path -LiteralPath $script:TargetBaseForAutoPath -PathType Container)) {
        $initial = $script:TargetBaseForAutoPath
    } elseif ($txtTarget.Text) {
        try {
            $targetNorm = Normalize-Path $txtTarget.Text
            while ($targetNorm -and !(Test-Path -LiteralPath $targetNorm -PathType Container)) {
                $targetNorm = Split-Path -Parent $targetNorm
            }
            if ($targetNorm -and (Test-Path -LiteralPath $targetNorm -PathType Container)) {
                $initial = $targetNorm
            }
        } catch {}
    }

    $selected = & $pickFolder "Выберите базовую папку на другом диске. К ней будет добавлен путь после AppData." $initial
    if ($selected) {
        $script:TargetBaseForAutoPath = Normalize-Path $selected
        if ($txtSource.Text) {
            $txtTarget.Text = Build-DefaultTargetPath $script:TargetBaseForAutoPath $txtSource.Text
        } else {
            $txtTarget.Text = $script:TargetBaseForAutoPath
        }
    }
})

$btnCheck.Add_Click({
    $txtLog.Clear()
    try {
        if ($txtSource.Text) {
            $relative = Get-RelativePathAfterAppData $txtSource.Text
            if ($relative) {
                & $log "Путь после AppData: $relative"
            }
        }

        $plan = Validate-MovePlan $txtSource.Text $txtTarget.Text
        & $log "Проверка плана:"
        & $log "Исходная папка: $($plan.Source)"
        & $log "Новая папка:    $($plan.Target)"
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }
        if ($plan.Errors.Count -eq 0) {
            & $log "Ошибок не найдено. Можно переносить."
        }
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
    }
})

$btnLocks.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSource.Text) -or !(Test-Path -LiteralPath (Normalize-Path $txtSource.Text) -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала выберите существующую исходную папку.",
            "Нет исходной папки",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $btnLocks.Enabled = $false
    try {
        $lockers = @(Get-LockingProcessesForFolder $txtSource.Text $log)
        Log-LockingProcesses $lockers $log

        if ($lockers.Count -gt 0) {
            $listText = Format-LockingProcessesText $lockers 16
            [System.Windows.Forms.MessageBox]::Show(
                "Найдены приложения, которые держат файлы:`r`n`r`n$listText",
                "Папка используется",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Блокирующих приложений не найдено.",
                "Папка свободна",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    } catch {
        & $log "ОШИБКА проверки занятости: $($_.Exception.Message)"
    } finally {
        $btnLocks.Enabled = $true
    }
})


function Show-SizeSelectionWindow([object[]]$Rows, [string]$RootPath) {
    $sizeForm = New-Object System.Windows.Forms.Form
    $sizeForm.Text = "Размеры подпапок: $RootPath"
    $sizeForm.Size = New-Object System.Drawing.Size(980, 620)
    $sizeForm.StartPosition = "CenterParent"
    $sizeForm.MinimumSize = New-Object System.Drawing.Size(850, 480)
    $sizeForm.Font = $font

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Сортировка по размеру по убыванию. Двойной щелчок или кнопка выбора подставит папку как исходную. Ссылки/junction не раскрываются и не считаются как реальный размер цели."
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(940, 36)
    $sizeForm.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(12, 54)
    $list.Size = New-Object System.Drawing.Size(940, 455)
    $list.Anchor = "Top,Bottom,Left,Right"
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.HideSelection = $false
    [void]$list.Columns.Add("Размер", 100)
    [void]$list.Columns.Add("Имя", 190)
    [void]$list.Columns.Add("Тип", 210)
    [void]$list.Columns.Add("Файлы", 80)
    [void]$list.Columns.Add("Путь", 330)

    foreach ($row in $Rows) {
        $item = New-Object System.Windows.Forms.ListViewItem($row.SizeText)
        [void]$item.SubItems.Add($row.Name)
        [void]$item.SubItems.Add($row.TypeText)
        [void]$item.SubItems.Add([string]$row.Files)
        [void]$item.SubItems.Add($row.Path)
        $item.Tag = $row
        [void]$list.Items.Add($item)
    }
    $sizeForm.Controls.Add($list)

    $btnUse = New-Object System.Windows.Forms.Button
    $btnUse.Text = "Выбрать как исходную"
    $btnUse.Location = New-Object System.Drawing.Point(12, 522)
    $btnUse.Size = New-Object System.Drawing.Size(170, 32)
    $btnUse.Anchor = "Bottom,Left"
    $sizeForm.Controls.Add($btnUse)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "Открыть"
    $btnOpen.Location = New-Object System.Drawing.Point(194, 522)
    $btnOpen.Size = New-Object System.Drawing.Size(100, 32)
    $btnOpen.Anchor = "Bottom,Left"
    $sizeForm.Controls.Add($btnOpen)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Закрыть"
    $btnClose.Location = New-Object System.Drawing.Point(852, 522)
    $btnClose.Size = New-Object System.Drawing.Size(100, 32)
    $btnClose.Anchor = "Bottom,Right"
    $sizeForm.Controls.Add($btnClose)

    $useSelected = {
        if ($list.SelectedItems.Count -eq 0) { return }
        $row = $list.SelectedItems[0].Tag
        $txtSource.Text = $row.Path
        Refresh-TargetFromBaseIfPossible
        $sizeForm.Close()
    }

    $btnUse.Add_Click($useSelected)
    $list.Add_DoubleClick($useSelected)
    $btnOpen.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $row = $list.SelectedItems[0].Tag
        Start-Process explorer.exe $row.Path
    })
    $btnClose.Add_Click({ $sizeForm.Close() })

    [void]$sizeForm.ShowDialog($form)
}

$btnSizes.Add_Click({
    $root = ""
    try {
        if (-not [string]::IsNullOrWhiteSpace($txtSource.Text) -and (Test-Path -LiteralPath (Normalize-Path $txtSource.Text) -PathType Container)) {
            $root = Normalize-Path $txtSource.Text
        } else {
            $root = Normalize-Path $env:LOCALAPPDATA
        }
    } catch {
        $root = Normalize-Path $env:LOCALAPPDATA
    }

    $btnSizes.Enabled = $false
    try {
        $txtLog.Clear()
        & $log "Сортирую подпапки по размеру. Для больших папок это может занять время."
        $rows = @(Get-SubfolderSizeRows $root $log)

        if ($rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "В выбранной папке нет подпапок для сортировки.",
                "Нет подпапок",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        & $log "Готово. Найдено подпапок: $($rows.Count). Открываю окно сортировки."
        Show-SizeSelectionWindow $rows $root
    } catch {
        & $log "ОШИБКА сортировки по размеру: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось отсортировать папки по размеру:`r`n$($_.Exception.Message)",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnSizes.Enabled = $true
    }
})

$btnMove.Add_Click({
    if (-not $chkClosed.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала закройте программу/игру, которая использует эту папку, и поставьте галочку.",
            "Папка может быть занята",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Будет выполнено:`r`n`r`n1. Перед переносом программа проверит, какие приложения держат файлы.`r`n2. Если такие приложения найдены, будет предложено закрыть их автоматически.`r`n3. Исходная папка будет временно переименована.`r`n4. Данные будут скопированы через robocopy с подробным выводом в консоль.`r`n5. На старом пути будет создана junction-ссылка.`r`n6. Временная исходная копия будет удалена после успешного создания ссылки.`r`n`r`nПродолжить?",
        "Подтверждение переноса",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnMove.Enabled = $false
    $btnCheck.Enabled = $false
    $btnLocks.Enabled = $false
    $btnSizes.Enabled = $false

    try {
        $plan = Validate-MovePlan $txtSource.Text $txtTarget.Text
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Перенос отменён." }

        $canContinue = Resolve-LockingProcessesBeforeMove $txtSource.Text $log $form
        if (-not $canContinue) {
            return
        }

        Move-AppDataFolderAndLink $txtSource.Text $txtTarget.Text $log

        [System.Windows.Forms.MessageBox]::Show(
            "Перенос завершён. Старый путь теперь является ссылкой на новую папку.",
            "Готово",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Перенос не завершён:`r`n$($_.Exception.Message)`r`n`r`nСмотрите лог в окне и подробный лог в папке detailed_logs.",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnMove.Enabled = $true
        $btnCheck.Enabled = $true
        $btnLocks.Enabled = $true
        $btnSizes.Enabled = $true
    }
})

$btnOpenLocal.Add_Click({ if ($env:LOCALAPPDATA) { Start-Process explorer.exe $env:LOCALAPPDATA } })
$btnOpenRoaming.Add_Click({ if ($env:APPDATA) { Start-Process explorer.exe $env:APPDATA } })
$btnOpenLocalLow.Add_Click({
    $p = Join-Path $env:USERPROFILE "AppData\LocalLow"
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p }
})
$btnOpenLogs.Add_Click({
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $env:TEMP "AppData-Folder-Mover"
    }
    $logDir = Join-Path $root "detailed_logs"
    if (!(Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Start-Process explorer.exe $logDir
})

[void][System.Windows.Forms.Application]::Run($form)
