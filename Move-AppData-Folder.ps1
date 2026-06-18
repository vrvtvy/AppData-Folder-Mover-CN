# Move-AppData-Folder.ps1
# GUI程序：将 AppData 中的文件夹迁移到其他磁盘并创建 NTFS junction 链接。
# 启动方式: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\Move-AppData-Folder.ps1"

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
        throw "排序文件夹未找到: $root"
    }

    if ($GuiLog) { & $GuiLog "正在计算子文件夹大小: $root" }
    Write-DetailLog "正在计算子文件夹大小: $root"

    $rows = New-Object System.Collections.Generic.List[object]
    $dirs = @(Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction Stop)
    $index = 0
    $totalDirs = $dirs.Count

    foreach ($dir in $dirs) {
        $index += 1
        if ($GuiLog) { & $GuiLog "[$index/$totalDirs] $($dir.Name)" }
        Write-DetailLog "大小 [$index/$totalDirs]: $($dir.FullName)"

        $isLink = (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $target = ""
        if ($isLink) { $target = Get-ReparsePointTarget $dir.FullName }

        $sizeInfo = Get-DirectorySizeBytes $dir.FullName
        $typeText = "文件夹"
        if ($isLink) { $typeText = "链接/junction" }
        elseif ($sizeInfo.SkippedLinks -gt 0) { $typeText = "文件夹, 内含链接: $($sizeInfo.SkippedLinks)" }

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

    if ($GuiLog) { & $GuiLog "正在检查哪些应用程序占用了文件夹中的文件..." }
    Write-DetailLog "正在检查锁定进程: $folder"

    Ensure-RestartManagerLoaded

    $paths = @(Get-LockCheckPaths $folder 5000)
    if ($GuiLog) { & $GuiLog "已检查占用路径数: $($paths.Count)" }
    Write-DetailLog "已检查占用路径数: $($paths.Count)"

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
            if ($GuiLog) { & $GuiLog "警告: 部分文件无法通过 Restart Manager 检查: $($_.Exception.Message)" }
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
        $lines += "...还有 $(@($Processes).Count - $MaxLines) 个"
    }

    return ($lines -join "`r`n")
}

function Log-LockingProcesses($Processes, [scriptblock]$GuiLog) {
    if ($null -eq $Processes -or @($Processes).Count -eq 0) {
        & $GuiLog "未发现占用文件的应用程序。"
        Write-DetailLog "未发现占用文件的应用程序。"
        return
    }

    & $GuiLog "发现可能阻碍迁移的应用程序:"
    Write-DetailLog "发现可能阻碍迁移的应用程序:"

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
                & $GuiLog "正在发送关闭命令: $line"
                Write-DetailLog "正在发送关闭命令: $line"
                [void]$p.CloseMainWindow()
            } else {
                & $GuiLog "该进程没有主窗口，无法温和关闭: $line"
                Write-DetailLog "该进程没有主窗口，无法温和关闭: $line"
            }
        } catch {
            & $GuiLog "无法发送关闭命令: $($_.Exception.Message)"
            Write-DetailLog "无法发送关闭命令: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 3
}

function Kill-LockingProcesses($Processes, [scriptblock]$GuiLog) {
    foreach ($p in @($Processes)) {
        try {
            if ($p.HasExited) { continue }

            $line = Get-ProcessDisplayLine $p
            & $GuiLog "正在强制关闭: $line"
            Write-DetailLog "正在强制关闭: $line"
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            & $GuiLog "无法强制关闭进程: $($_.Exception.Message)"
            Write-DetailLog "无法强制关闭进程: $($_.Exception.Message)"
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
        "这些应用程序占用了所选文件夹中的文件，可能阻碍迁移：`r`n`r`n$listText`r`n`r`n是否尝试自动关闭它们？`r`n`r`n首先会发送普通的窗口关闭命令。这些应用中未保存的数据可能会丢失。",
        "文件夹正在使用中",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) {
        & $GuiLog "迁移已被用户取消。"
        return $false
    }

    if ($answer -eq [System.Windows.Forms.DialogResult]::No) {
        & $GuiLog "用户拒绝了自动关闭。迁移已取消。"
        return $false
    }

    Close-LockingProcessesGracefully $lockers $GuiLog

    $lockersAfterClose = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Log-LockingProcesses $lockersAfterClose $GuiLog

    if ($lockersAfterClose.Count -eq 0) {
        & $GuiLog "温和关闭后未发现占用。"
        return $true
    }

    $listText2 = Format-LockingProcessesText $lockersAfterClose 14

    $killAnswer = [System.Windows.Forms.MessageBox]::Show(
        "部分进程仍然占用文件：`r`n`r`n$listText2`r`n`r`n是否强制关闭？`r`n`r`n这可能导致未保存的数据丢失。",
        "进程仍然占用中",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($killAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
        & $GuiLog "用户拒绝了强制关闭。迁移已取消。"
        return $false
    }

    Kill-LockingProcesses $lockersAfterClose $GuiLog

    $lockersAfterKill = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Log-LockingProcesses $lockersAfterKill $GuiLog

    if ($lockersAfterKill.Count -eq 0) {
        & $GuiLog "强制关闭后未发现占用。"
        return $true
    }

    [System.Windows.Forms.MessageBox]::Show(
        "文件夹仍在使用中。迁移已取消。`r`n`r`n请手动关闭应用程序或重启 Windows。",
        "文件夹仍被占用",
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

    if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("未指定源文件夹。") }
    if ([string]::IsNullOrWhiteSpace($target)) { $errors.Add("未指定目标文件夹。") }

    if ($errors.Count -eq 0) {
        if (!(Test-Path -LiteralPath $source -PathType Container)) {
            $errors.Add("源文件夹不存在: $source")
        }

        $appDataRoot = Get-UserAppDataRoot
        if (!(Test-PathInside $source $appDataRoot)) {
            $errors.Add("源文件夹必须在 AppData 内: Local、Roaming 或 LocalLow。")
        }

        $forbiddenRoots = @(
            $appDataRoot,
            (Normalize-Path $env:LOCALAPPDATA),
            (Normalize-Path $env:APPDATA),
            (Normalize-Path (Join-Path $env:USERPROFILE "AppData\LocalLow"))
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

        foreach ($root in $forbiddenRoots) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $root).ToLowerInvariant()) {
                $errors.Add("不能整体迁移根目录 AppData/Local/Roaming/LocalLow: $source")
            }
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            try {
                if (Is-ReparsePoint $source) {
                    $errors.Add("源文件夹已经是链接/reparse point，无法重复迁移。")
                }
            } catch {
                $errors.Add("无法检查源文件夹: $($_.Exception.Message)")
            }

            try {
                $nestedLinks = @(Get-NestedReparsePointDirectories $source 25)
                if ($nestedLinks.Count -gt 0) {
                    $errors.Add("所选文件夹内已有已迁移/链接的文件夹。无法安全迁移父文件夹，否则嵌套链接可能在复制时丢失。")
                    foreach ($link in $nestedLinks) {
                        $errors.Add("  嵌套链接: $(Get-ReparsePointDisplayLine $link)")
                    }
                    if ($nestedLinks.Count -ge 25) {
                        $errors.Add("  显示了前 25 个链接；可能还有更多。")
                    }
                }
            } catch {
                $warnings.Add("无法检查嵌套链接/reparse point: $($_.Exception.Message)")
            }
        }

        if (Test-Path -LiteralPath $target) {
            $errors.Add("目标文件夹已存在。请指定一个不存在的路径: $target")
        }

        $targetParent = Split-Path -Parent $target
        if ([string]::IsNullOrWhiteSpace($targetParent)) {
            $errors.Add("目标文件夹必须有父目录。")
        }

        if (Test-PathInside $target $source) {
            $errors.Add("目标文件夹不能位于源文件夹内。")
        }

        if (Test-PathInside $source $target) {
            $errors.Add("源文件夹不能位于目标文件夹内。")
        }

        if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
            $errors.Add("源路径和目标路径相同。")
        }

        $sourceRoot = [System.IO.Path]::GetPathRoot($source)
        $targetRoot = [System.IO.Path]::GetPathRoot($target)
        if ($sourceRoot -eq $targetRoot) {
            $warnings.Add("源文件夹和目标文件夹在同一磁盘上。安全迁移需要临时占用空间用于复制。")
        }

        if ($target -match '^[A-Za-z]:\\') {
            $drive = $target.Substring(0,1)
            try {
                $vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
                if ($vol.FileSystem -ne "NTFS") {
                    $warnings.Add("目标磁盘不是 NTFS ($($vol.FileSystem))。Junction 链接仅支持 NTFS。")
                }
            } catch {
                $warnings.Add("无法检查目标磁盘的文件系统。Junction 需要 NTFS。")
            }
        } else {
            $warnings.Add("目标路径不像普通的本地路径（如 D:\Folder）。网络路径不支持 junction。")
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
    Write-DetailLog "详细输出如下。如果文件夹较大，请关注此控制台窗口。" $DetailLogFile
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

    $originalEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        & robocopy.exe @args
    } finally {
        [Console]::OutputEncoding = $originalEncoding
    }
    $code = $LASTEXITCODE

    Write-DetailLog "Robocopy 退出码: $code" $DetailLogFile

    if ($code -ge 8) {
        throw "Robocopy 报告错误。代码: $code。详情请查看: $DetailLogFile"
    }

    if (!(Test-Path -LiteralPath $To -PathType Container)) {
        throw "复制后未找到目标文件夹: $To"
    }
}

function Remove-FolderAfterSuccessfulMove([string]$Path, [scriptblock]$GuiLog) {
    if (!(Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    & $GuiLog "正在删除临时源文件夹副本。对于大文件夹可能需要一些时间..."
    Write-DetailLog "正在删除临时源文件夹副本: $Path"

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-DetailLog "临时副本已删除。"
    } catch {
        & $GuiLog "警告: 链接已创建，但无法删除临时副本: $Path"
        & $GuiLog "您可以在检查后手动删除它。"
        Write-DetailLog "无法删除临时副本: $($_.Exception.Message)"
    }
}

function Move-AppDataFolderAndLink([string]$SourceRaw, [string]$TargetRaw, [scriptblock]$Log) {
    $plan = Validate-MovePlan $SourceRaw $TargetRaw
    foreach ($e in $plan.Errors) { & $Log "错误: $e" }
    foreach ($w in $plan.Warnings) { & $Log "警告: $w" }
    if ($plan.Errors.Count -gt 0) { throw "计划包含错误。迁移已取消。" }

    $source = $plan.Source
    $target = $plan.Target
    $targetParent = Split-Path -Parent $target
    $sourceParent = Split-Path -Parent $source
    $sourceName = Split-Path -Leaf $source
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tempPath = Join-Path $sourceParent ($sourceName + ".__moving_to_link_" + $timestamp)

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "源文件夹: $source"
    & $Log "目标文件夹: $target"
    & $Log "详细日志:  $script:CurrentDetailedLog"
    & $Log "大文件夹迁移时请关注控制台窗口。"
    & $Log "临时名称:  $tempPath"

    Write-DetailLog "=== AppData Folder Mover ==="
    Write-DetailLog "源文件夹: $source"
    Write-DetailLog "目标文件夹: $target"
    Write-DetailLog "临时名称: $tempPath"

    try {
        if (!(Test-Path -LiteralPath $targetParent -PathType Container)) {
            & $Log "正在创建父目录: $targetParent"
            Write-DetailLog "正在创建父目录: $targetParent"
            New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop | Out-Null
        }

        & $Log "正在将源文件夹重命名为临时名称..."
        Write-DetailLog "正在将源文件夹重命名为临时名称..."

        try {
            Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $tempPath) -ErrorAction Stop
        } catch {
            & $Log "无法重命名源文件夹。可能被应用程序占用。"
            Write-DetailLog "重命名失败: $($_.Exception.Message)"
            try {
                $lockers = @(Get-LockingProcessesForFolder $source $Log)
                Log-LockingProcesses $lockers $Log
            } catch {
                & $Log "无法确定占用进程: $($_.Exception.Message)"
            }
            throw "源文件夹被占用或没有重命名权限: $($_.Exception.Message)"
        }

        try {
            & $Log "正在通过 robocopy 复制数据。详细信息输出到控制台..."
            Copy-FolderWithRobocopy $tempPath $target $script:CurrentDetailedLog
        } catch {
            & $Log "复制失败。正在恢复源文件夹..."
            Write-DetailLog "复制失败。正在尝试恢复源文件夹。"
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw
        }

        & $Log "正在创建 junction 链接..."
        Write-DetailLog "正在创建 junction 链接: $source -> $target"
        $mk = New-Junction $source $target
        if ($mk.Output) {
            & $Log $mk.Output
            Write-DetailLog $mk.Output
        }

        if ($mk.ExitCode -ne 0 -or !(Test-Path -LiteralPath $source)) {
            & $Log "链接创建失败。正在尝试回滚迁移..."
            Write-DetailLog "链接创建失败。正在尝试回滚迁移。"
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath -PathType Container) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw "mklink 返回代码 $($mk.ExitCode)。"
        }

        Remove-FolderAfterSuccessfulMove $tempPath $Log

        & $Log "完成。旧路径现在指向目标文件夹。"
        & $Log "验证: $source -> $target"
        Write-DetailLog "完成。旧路径现在指向目标文件夹。"
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
$lblInfo.Text = "将 AppData 中的文件夹迁移到新位置，并在旧路径创建 NTFS junction 链接。目标路径构建方式：所选基础文件夹 + AppData 之后的路径。"
$lblInfo.Location = New-Object System.Drawing.Point(12, 12)
$lblInfo.Size = New-Object System.Drawing.Size(840, 42)
$form.Controls.Add($lblInfo)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = "AppData 中的源文件夹:"
$lblSource.Location = New-Object System.Drawing.Point(12, 64)
$lblSource.Size = New-Object System.Drawing.Size(820, 20)
$form.Controls.Add($lblSource)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(12, 86)
$txtSource.Size = New-Object System.Drawing.Size(735, 24)
$txtSource.Anchor = "Top,Left,Right"
$form.Controls.Add($txtSource)

$btnSource = New-Object System.Windows.Forms.Button
$btnSource.Text = "选择"
$btnSource.Location = New-Object System.Drawing.Point(755, 84)
$btnSource.Size = New-Object System.Drawing.Size(95, 28)
$btnSource.Anchor = "Top,Right"
$form.Controls.Add($btnSource)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "目标文件夹。默认: 其他磁盘上的基础文件夹 + 源文件夹在 AppData 之后的路径:"
$lblTarget.Location = New-Object System.Drawing.Point(12, 122)
$lblTarget.Size = New-Object System.Drawing.Size(820, 20)
$form.Controls.Add($lblTarget)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(12, 144)
$txtTarget.Size = New-Object System.Drawing.Size(735, 24)
$txtTarget.Anchor = "Top,Left,Right"
$form.Controls.Add($txtTarget)

$btnTarget = New-Object System.Windows.Forms.Button
$btnTarget.Text = "基础"
$btnTarget.Location = New-Object System.Drawing.Point(755, 142)
$btnTarget.Size = New-Object System.Drawing.Size(95, 28)
$btnTarget.Anchor = "Top,Right"
$form.Controls.Add($btnTarget)

$lblExample = New-Object System.Windows.Forms.Label
$lblExample.Text = "示例: C:\Users\User\AppData\Local\Game\Saved + D:\AppDataMoved => D:\AppDataMoved\Local\Game\Saved"
$lblExample.Location = New-Object System.Drawing.Point(12, 174)
$lblExample.Size = New-Object System.Drawing.Size(840, 20)
$form.Controls.Add($lblExample)

$chkClosed = New-Object System.Windows.Forms.CheckBox
$chkClosed.Text = "我已关闭使用该文件夹的程序/游戏"
$chkClosed.Location = New-Object System.Drawing.Point(12, 200)
$chkClosed.Size = New-Object System.Drawing.Size(820, 24)
$form.Controls.Add($chkClosed)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "检查"
$btnCheck.Location = New-Object System.Drawing.Point(12, 232)
$btnCheck.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnCheck)

$btnLocks = New-Object System.Windows.Forms.Button
$btnLocks.Text = "占用"
$btnLocks.Location = New-Object System.Drawing.Point(132, 232)
$btnLocks.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnLocks)

$btnSizes = New-Object System.Windows.Forms.Button
$btnSizes.Text = "大小"
$btnSizes.Location = New-Object System.Drawing.Point(252, 232)
$btnSizes.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnSizes)

$btnMove = New-Object System.Windows.Forms.Button
$btnMove.Text = "迁移"
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
$btnOpenLogs.Text = "日志"
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
    $selected = & $pickFolder "请选择 AppData 中的文件夹" $env:LOCALAPPDATA
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

    $selected = & $pickFolder "请选择其他磁盘上的基础文件夹。将自动添加 AppData 之后的路径。" $initial
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
                & $log "AppData 之后的路径: $relative"
            }
        }

        $plan = Validate-MovePlan $txtSource.Text $txtTarget.Text
        & $log "检查计划:"
        & $log "源文件夹: $($plan.Source)"
        & $log "目标文件夹: $($plan.Target)"
        foreach ($w in $plan.Warnings) { & $log "警告: $w" }
        foreach ($e in $plan.Errors) { & $log "错误: $e" }
        if ($plan.Errors.Count -eq 0) {
            & $log "未发现错误。可以开始迁移。"
        }
    } catch {
        & $log "错误: $($_.Exception.Message)"
    }
})

$btnLocks.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSource.Text) -or !(Test-Path -LiteralPath (Normalize-Path $txtSource.Text) -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            "请先选择一个存在的源文件夹。",
            "未选择源文件夹",
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
                "发现占用文件的应用程序:`r`n`r`n$listText",
                "文件夹正在使用中",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "未发现占用文件的应用程序。",
                "文件夹空闲",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    } catch {
        & $log "占用检查错误: $($_.Exception.Message)"
    } finally {
        $btnLocks.Enabled = $true
    }
})


function Show-SizeSelectionWindow([object[]]$Rows, [string]$RootPath) {
    $sizeForm = New-Object System.Windows.Forms.Form
    $sizeForm.Text = "子文件夹大小: $RootPath"
    $sizeForm.Size = New-Object System.Drawing.Size(980, 620)
    $sizeForm.StartPosition = "CenterParent"
    $sizeForm.MinimumSize = New-Object System.Drawing.Size(850, 480)
    $sizeForm.Font = $font

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "按大小降序排列。双击或点击选择按钮可将文件夹设为源文件夹。链接/junction 不会展开，不计算目标的实际大小。"
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
    [void]$list.Columns.Add("大小", 100)
    [void]$list.Columns.Add("名称", 190)
    [void]$list.Columns.Add("类型", 210)
    [void]$list.Columns.Add("文件", 80)
    [void]$list.Columns.Add("路径", 330)

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
    $btnUse.Text = "选择为源文件夹"
    $btnUse.Location = New-Object System.Drawing.Point(12, 522)
    $btnUse.Size = New-Object System.Drawing.Size(170, 32)
    $btnUse.Anchor = "Bottom,Left"
    $sizeForm.Controls.Add($btnUse)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "打开"
    $btnOpen.Location = New-Object System.Drawing.Point(194, 522)
    $btnOpen.Size = New-Object System.Drawing.Size(100, 32)
    $btnOpen.Anchor = "Bottom,Left"
    $sizeForm.Controls.Add($btnOpen)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "关闭"
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
        & $log "正在按大小排序子文件夹。对于大文件夹可能需要一些时间。"
        $rows = @(Get-SubfolderSizeRows $root $log)

        if ($rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "所选文件夹中没有可排序的子文件夹。",
                "无子文件夹",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        & $log "完成。找到子文件夹: $($rows.Count)。正在打开排序窗口。"
        Show-SizeSelectionWindow $rows $root
    } catch {
        & $log "大小排序错误: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "无法按大小排序文件夹:`r`n$($_.Exception.Message)",
            "错误",
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
            "请先关闭使用该文件夹的程序/游戏，并勾选复选框。",
            "文件夹可能被占用",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "将执行以下操作：`r`n`r`n1. 迁移前程序将检查哪些应用程序占用了文件。`r`n2. 如果发现占用程序，将提示自动关闭。`r`n3. 源文件夹将被临时重命名。`r`n4. 数据将通过 robocopy 复制，详细信息输出到控制台。`r`n5. 在旧路径创建 junction 链接。`r`n6. 链接创建成功后删除临时源副本。`r`n`r`n是否继续？",
        "确认迁移",
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
        foreach ($e in $plan.Errors) { & $log "错误: $e" }
        foreach ($w in $plan.Warnings) { & $log "警告: $w" }
        if ($plan.Errors.Count -gt 0) { throw "计划包含错误。迁移已取消。" }

        $canContinue = Resolve-LockingProcessesBeforeMove $txtSource.Text $log $form
        if (-not $canContinue) {
            return
        }

        Move-AppDataFolderAndLink $txtSource.Text $txtTarget.Text $log

        [System.Windows.Forms.MessageBox]::Show(
            "迁移完成。旧路径现在是指向目标文件夹的链接。",
            "完成",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        & $log "错误: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "迁移未完成:`r`n$($_.Exception.Message)`r`n`r`n请查看窗口日志和 detailed_logs 文件夹中的详细日志。",
            "错误",
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
