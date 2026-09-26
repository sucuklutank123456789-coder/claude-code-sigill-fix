# claude-code-fix.ps1
#
# Makes Claude Code run on x86-64 CPUs without AVX2 (e.g. Core 2 Duo, or
# Sandy/Ivy Bridge, which have AVX but no AVX2) on Windows, where the native
# binaries crash with exception code 0xc000001d (STATUS_ILLEGAL_INSTRUCTION).
#
# How it works: every Claude Code native binary is run under Intel SDE with
# Haswell emulation (-hsw).
#   - npm install: the npm shims (claude.cmd, claude.ps1, claude) call SDE.
#   - Everything else: claude.exe is replaced by a small compiled wrapper
#     (built with the C# compiler that ships with .NET Framework) that starts
#     the original binary under SDE.
#
# Safe to re-run: it only touches what an update has broken.
#
# If Intel SDE is missing, it offers to download SDE 9.48.0 into
# %LOCALAPPDATA%\claude-sigill-fix\sde. Newer SDE releases crash on CPUs
# without SSE4.2 (e.g. Core 2 Duo), 9.48.0 works on all of them.
# Extracting needs 7-Zip and SDE needs the Visual C++ runtime (x64 and x86);
# the script offers to install both with winget.
#
# Usage (from PowerShell; or use claude-code-fix.cmd, which runs the same):
#   powershell -ExecutionPolicy Bypass -File .\claude-code-fix.ps1            interactive menu
#   powershell -ExecutionPolicy Bypass -File .\claude-code-fix.ps1 4 1        fix targets 4 and 1 without the menu
#   powershell -ExecutionPolicy Bypass -File .\claude-code-fix.ps1 -Restore   undo the fixes (menu or numbers too)
#   powershell -ExecutionPolicy Bypass -File .\claude-code-fix.ps1 -Version   print the script version
#
# Options:
#   -Sde <path>     use this sde.exe, or install SDE from this downloaded
#                   .tar.xz / .zip package
#   -InstallSde     install SDE and its requirements without asking if missing
#   -NoAdmin        never run winget (it can show an administrator prompt);
#                   missing 7-Zip / Visual C++ runtime are then reported instead
#   Exit code is 1 if any step failed, 0 otherwise.
#
# Targets:
#   1. Terminal CLI (npm global install and the native installer)
#   2. Claude Desktop (embedded Claude Code CLI)
#   3. VS Code extension (also Insiders, VSCodium, Cursor, Windsurf)
#   4. Zed Claude Agent (ACP)
#   5. All of the above
#
# Not an official Anthropic tool. Use at your own risk.

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Restore,
    [switch]$InstallSde,
    [switch]$NoAdmin,
    [switch]$Version,
    [switch]$Help,
    [string]$Sde = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Targets = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"  # the progress bar makes downloads very slow in Windows PowerShell

$ScriptVersion = "1.0.0"  # keep in sync with CHANGELOG.md
$ScriptName = "claude-code-fix.ps1"

# --- Output helpers ------------------------------------------------------------
$script:Changed = $false
$script:Failed = $false

function Write-Header([string]$Text) { Write-Host ""; Write-Host "== $Text ==" -ForegroundColor Blue }
function Write-Ok([string]$Text)       { Write-Host "  [OK]       " -ForegroundColor Green -NoNewline; Write-Host $Text }
function Write-Patched([string]$Text)  { Write-Host "  [PATCHED]  " -ForegroundColor Yellow -NoNewline; Write-Host $Text; $script:Changed = $true }
function Write-Restored([string]$Text) { Write-Host "  [RESTORED] " -ForegroundColor Yellow -NoNewline; Write-Host $Text; $script:Changed = $true }
function Write-Skip([string]$Text)     { Write-Host "  [SKIP]     $Text" }
function Write-Warn([string]$Text)     { Write-Host "  [WARN]     " -ForegroundColor Yellow -NoNewline; Write-Host $Text }
function Write-Fail([string]$Text)     { Write-Host "  [ERROR]    " -ForegroundColor Red -NoNewline; Write-Host $Text; $script:Failed = $true }

function Show-Usage {
    Write-Host "$ScriptName $ScriptVersion"
    Write-Host ""
    $inUsage = $false
    foreach ($line in Get-Content -LiteralPath $PSCommandPath) {
        if ($line -like "# Usage*") { $inUsage = $true }
        if ($inUsage) { Write-Host ($line -replace '^# ?', '') }
        if ($inUsage -and $line -like "#   5.*") { break }
    }
}

if ($Help) { Show-Usage; exit 0 }
if ($Version) { Write-Host "$ScriptName $ScriptVersion"; exit 0 }

$Mode = "fix"
if ($Restore) { $Mode = "restore" }

# Prompts only when a person is at the keyboard; agents and scheduled tasks get
# the default answer.
$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
    -not ([Environment]::GetCommandLineArgs() -match '^-NonI')

function Confirm-Yes([string]$Question) {
    if (-not $Interactive) { return $false }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^[Yy]$')
}

# Windows PowerShell 5.1 still defaults to TLS 1.0 on some systems.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose "could not enable TLS 1.2: $_" }

# --- Paths ---------------------------------------------------------------------
$Base     = Join-Path $env:LOCALAPPDATA "claude-sigill-fix"
$SdeHome  = Join-Path $Base "sde"
$RealBin  = Join-Path $Base "real-bin"   # original binaries moved out of app folders
$WrapDir  = Join-Path $Base "wrappers"   # wrapper sources and builds

# --- CPU check -----------------------------------------------------------------
# Returns $true / $false, or $null when Windows can't tell.
function Test-CpuFeature([int]$Feature) {
    try {
        if (-not ("SigillFix.Kernel32" -as [type])) {
            Add-Type -Namespace SigillFix -Name Kernel32 -MemberDefinition `
                '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
        }
        return [SigillFix.Kernel32]::IsProcessorFeaturePresent($Feature)
    } catch {
        return $null
    }
}
$PF_SSE4_2 = 38
$PF_AVX2 = 40

# The native binaries need AVX2 (hence SDE's Haswell mode). A CPU that has it
# runs them natively, and wrapping them would only make them much slower.
if ($Mode -eq "fix" -and (Test-CpuFeature $PF_AVX2) -eq $true) {
    Write-Host "Your CPU supports AVX2, so Claude Code should run natively." -ForegroundColor Yellow
    Write-Host "This fix is only for CPUs without AVX2 and would make everything much slower."
    if (-not (Confirm-Yes "Continue anyway?")) { Write-Host "Nothing changed."; exit 0 }
}

# --- Target selection ----------------------------------------------------------
$script:Selected = @()

# Parses target numbers into $script:Selected. Returns $false on invalid input.
function Set-Selection([string[]]$Numbers) {
    $picks = @()
    foreach ($n in $Numbers) {
        switch ($n) {
            { $_ -in "1", "2", "3", "4" } { $picks += [int]$n; break }
            "5"     { $picks += 1, 2, 3, 4; break }
            default { return $false }
        }
    }
    if ($picks.Count -eq 0) { return $false }
    $script:Selected = $picks
    return $true
}

if ($Targets.Count -gt 0) {
    if (-not (Set-Selection $Targets)) {
        Write-Host "Invalid choice: $($Targets -join ' ') (use numbers 1-5)" -ForegroundColor Red
        exit 1
    }
} elseif (-not $Interactive) {
    Write-Host "No targets given. Pass target numbers, e.g.: $ScriptName 5" -ForegroundColor Red
    exit 1
} else {
    if ($Mode -eq "fix") { Write-Host "Which one do you want to fix?" } else { Write-Host "Which one do you want to restore?" }
    Write-Host "  1: Claude Code CLI (terminal)"
    Write-Host "  2: Claude Desktop (embedded Claude Code CLI)"
    Write-Host "  3: VS Code extension (also Cursor, Windsurf, VSCodium)"
    Write-Host "  4: Zed Claude Agent (ACP)"
    Write-Host "  5: All"
    while ($true) {
        $line = Read-Host "Enter numbers separated by spaces (e.g. 4 1)"
        if (Set-Selection (@($line -split '\s+') | Where-Object { $_ -ne "" })) { break }
        Write-Host "Invalid choice. Use numbers 1-5 separated by spaces." -ForegroundColor Red
    }
}

# --- Requirement: Intel SDE ----------------------------------------------------
$SdePage = "https://www.intel.com/content/www/us/en/download/684897/intel-software-development-emulator.html"
$SdeWantedVersion = "9.48.0"

function Find-Sde {
    if ($Sde -ne "" -and $Sde -like "*.exe") {
        if (Test-Path -LiteralPath $Sde -PathType Leaf) { return (Resolve-Path -LiteralPath $Sde).Path }
        return ""
    }
    $candidates = @()
    foreach ($root in @($SdeHome, "C:\intel-sde-old")) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        if (Test-Path -LiteralPath (Join-Path $root "sde.exe")) { $candidates += Join-Path $root "sde.exe" }
        $candidates += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName "sde.exe" } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    $onPath = Get-Command sde.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return ""
}

function Find-7Zip {
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $cmd = Get-Command 7z.exe, 7z -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return ""
}

# Runs `winget install` for each package id, after asking. Returns $true when all succeeded.
function Install-WithWinget([string]$What, [string[]]$Ids) {
    $commands = $Ids | ForEach-Object { "winget install -e --id $_" }
    if ($NoAdmin) {
        Write-Fail "$What is missing. Install it yourself (may ask for administrator rights):"
        $commands | ForEach-Object { Write-Host "             $_" }
        return $false
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Fail "$What is missing and winget is not available. Install it manually, then re-run."
        return $false
    }
    Write-Host "$What is missing. It will be installed with:"
    $commands | ForEach-Object { Write-Host "  $_" }
    Write-Host "Windows may show an administrator (UAC) prompt."
    if (-not $InstallSde -and -not (Confirm-Yes "Install it now?")) { return $false }
    foreach ($id in $Ids) {
        & winget install -e --id $id --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Write-Fail "winget install $id failed (exit code $LASTEXITCODE)"; return $false }
    }
    return $true
}

# SDE 9.48.0's launcher is 32-bit and its engine 64-bit, so both runtimes are needed.
function Test-VcRuntime {
    $ok = $true
    foreach ($dir in @("System32", "SysWOW64")) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR "$dir\vcruntime140.dll"))) { $ok = $false }
    }
    return $ok
}

# Looks for the SDE 9.48.0 Windows package on Intel's download page and the
# pages of its other versions. Returns the URL or "".
function Find-SdeUrl {
    $pattern = 'https://downloadmirror\.intel\.com/\d+/sde-external-' + [regex]::Escape($SdeWantedVersion) + '-[\d-]+-win\.(?:tar\.xz|zip)'
    $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    try {
        $html = (Invoke-WebRequest -Uri $SdePage -UseBasicParsing -UserAgent $userAgent -TimeoutSec 60).Content
    } catch {
        return ""
    }
    $m = [regex]::Match($html, $pattern)
    if ($m.Success) { return $m.Value }
    # Older versions have their own page: /download/684897/<id>/intel-software-development-emulator.html
    $pages = [regex]::Matches($html, '/content/www/us/en/download/684897/\d+/[A-Za-z0-9._-]+\.html') |
        ForEach-Object { $_.Value } | Select-Object -Unique -First 60
    foreach ($p in $pages) {
        try {
            $sub = (Invoke-WebRequest -Uri ("https://www.intel.com" + $p) -UseBasicParsing -UserAgent $userAgent -TimeoutSec 60).Content
        } catch {
            continue
        }
        $m = [regex]::Match($sub, $pattern)
        if ($m.Success) { return $m.Value }
    }
    return ""
}

# Extracts an SDE package (.tar.xz, .tar or .zip) into $SdeHome.
function Expand-SdePackage([string]$Archive) {
    $7z = Find-7Zip
    if ($7z -eq "") {
        if (-not (Install-WithWinget "7-Zip (needed to extract SDE)" @("7zip.7zip"))) { return $false }
        $7z = Find-7Zip
        if ($7z -eq "") { Write-Fail "7-Zip was installed but 7z.exe was not found"; return $false }
    }
    $tmp = Join-Path $Base "download\extract"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    & $7z x $Archive "-o$tmp" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "7-Zip could not extract $Archive"; return $false }
    # A .tar.xz first becomes a .tar
    $tar = Get-ChildItem -LiteralPath $tmp -Filter *.tar -File | Select-Object -First 1
    if ($tar) {
        & $7z x $tar.FullName "-o$tmp" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Fail "7-Zip could not extract $($tar.FullName)"; return $false }
        Remove-Item -LiteralPath $tar.FullName -Force
    }
    $exe = Get-ChildItem -LiteralPath $tmp -Filter sde.exe -File -Recurse | Select-Object -First 1
    if (-not $exe) { Write-Fail "sde.exe not found in $Archive"; return $false }
    New-Item -ItemType Directory -Force -Path $SdeHome | Out-Null
    $dest = Join-Path $SdeHome $exe.Directory.Name
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $exe.Directory.FullName -Destination $dest
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

function Install-Sde {
    $archive = ""
    if ($Sde -ne "") {
        $archive = $Sde
    } else {
        Write-Host "Looking up Intel SDE $SdeWantedVersion..."
        $url = Find-SdeUrl
        if ($url -ne "") {
            $dl = Join-Path $Base "download"
            New-Item -ItemType Directory -Force -Path $dl | Out-Null
            $archive = Join-Path $dl ($url -replace '^.*/', '')
            Write-Host "Downloading $url"
            try {
                Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -TimeoutSec 600
            } catch {
                Write-Fail "download failed: $($_.Exception.Message)"
                $archive = ""
            }
        }
        if ($archive -eq "") {
            Write-Host "Could not download SDE $SdeWantedVersion automatically." -ForegroundColor Yellow
            Write-Host "Download it manually:"
            Write-Host "  1. Open $SdePage"
            Write-Host "  2. Select version $SdeWantedVersion, accept the license and download the Windows package (.tar.xz)."
            if ($Interactive) {
                $archive = (Read-Host "Path of the downloaded file (empty to cancel)").Trim('"', ' ')
            } else {
                Write-Host "  3. Re-run this script with: -Sde <path of the downloaded file>"
            }
            if ($archive -eq "") { return $false }
        }
    }
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { Write-Fail "file not found: $archive"; return $false }
    if ($archive -like "*.exe") { return $true }
    $ok = Expand-SdePackage $archive
    if ($ok -and $Sde -eq "") { Remove-Item -LiteralPath (Join-Path $Base "download") -Recurse -Force -ErrorAction SilentlyContinue }
    return $ok
}

# Runs a real program under SDE: `sde.exe -version` alone doesn't show whether
# SDE works on this CPU.
function Test-Sde([string]$Path) {
    & $Path -hsw '--' cmd.exe /c exit 0 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

$SdePath = ""
if ($Mode -eq "fix") {
    $SdePath = Find-Sde
    if ($SdePath -eq "" -or ($Sde -ne "" -and $Sde -notlike "*.exe")) {
        if ($SdePath -eq "") {
            Write-Host "Intel SDE not found." -ForegroundColor Red -NoNewline
            Write-Host " The fix does not work without SDE."
        }
        Write-Host "SDE is Intel software under Intel's own license; installing it means you accept that license."
        if ($InstallSde -or $Sde -ne "" -or (Confirm-Yes "Do you want to install SDE $SdeWantedVersion now?")) {
            if (Install-Sde) { $SdePath = Find-Sde }
        }
        if ($SdePath -eq "") {
            Write-Host "SDE is not installed. Download SDE $SdeWantedVersion from $SdePage"
            Write-Host "and re-run this script with -Sde <downloaded file>."
            exit 1
        }
        Write-Host "Intel SDE: $SdePath" -ForegroundColor Green
    }

    if (-not (Test-VcRuntime)) {
        if (Install-WithWinget "The Visual C++ runtime (x64 and x86, needed by SDE)" @("Microsoft.VCRedist.2015+.x64", "Microsoft.VCRedist.2015+.x86")) {
            if (-not (Test-VcRuntime)) { Write-Warn "the Visual C++ runtime still looks incomplete" }
        } else {
            exit 1
        }
    }

    if (-not (Test-Sde $SdePath)) {
        Write-Host "Intel SDE could not run a test program ($SdePath -hsw -- cmd.exe /c exit 0)." -ForegroundColor Red
        if ($SdePath -notmatch [regex]::Escape("-$SdeWantedVersion-") -and (Test-CpuFeature $PF_SSE4_2) -ne $true) {
            Write-Host "Newer SDE releases crash on CPUs without SSE4.2. Install SDE $SdeWantedVersion instead:"
            Write-Host "delete $SdePath's folder and re-run this script, or pass -Sde <SDE $SdeWantedVersion package>."
        } else {
            Write-Host "Check that the Visual C++ runtime (x64 and x86) is installed."
        }
        exit 1
    }
}

# --- Wrapper -------------------------------------------------------------------
# Marker that identifies our wrappers (the exe's "File description").
$WrapperTitle = "claude-sigill-fix SDE wrapper"

$WrapperSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("__TITLE__")]
[assembly: AssemblyDescription(@"__INFO__")]
[assembly: AssemblyProduct("claude-sigill-fix")]

// Runs the original Claude Code binary under Intel SDE with Haswell emulation.
class Wrapper
{
    static readonly string Sde = @"__SDE__";
    static readonly string Real = @"__REAL__";
    // true: copy stdin/stdout/stderr by hand. Needed when an editor (VS Code,
    // Zed) talks to the binary over pipes; a terminal or Claude Desktop works
    // with the inherited handles.
    static readonly bool PumpStdio = __PUMP__;

    // Quotes one argument so that the child's command line parser gets it back unchanged.
    static string Quote(string s)
    {
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in s)
        {
            if (c == '\\') { slashes++; continue; }
            sb.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', slashes * 2);
        return sb.Append('"').ToString();
    }

    static void Pump(Stream src, Stream dst, bool closeDst)
    {
        try
        {
            byte[] buf = new byte[8192];
            int n;
            while ((n = src.Read(buf, 0, buf.Length)) > 0) { dst.Write(buf, 0, n); dst.Flush(); }
        }
        catch { }
        if (closeDst) { try { dst.Close(); } catch { } }
    }

    static int Main(string[] args)
    {
        var cmd = new StringBuilder("-hsw -- ");
        cmd.Append(Quote(Real));
        foreach (string a in args) { cmd.Append(' '); cmd.Append(Quote(a)); }

        var psi = new ProcessStartInfo(Sde, cmd.ToString());
        psi.UseShellExecute = false;
        if (PumpStdio)
        {
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
        }
        else
        {
            // Ctrl+C reaches every process in the console. Leave it to Claude
            // Code and keep waiting for it instead of exiting underneath it.
            try { Console.CancelKeyPress += delegate(object s, ConsoleCancelEventArgs e) { e.Cancel = true; }; } catch { }
        }

        Process p;
        try { p = Process.Start(psi); }
        catch (Exception e)
        {
            Console.Error.WriteLine("claude-sigill-fix: cannot start Intel SDE (" + Sde + "): " + e.Message);
            return 1;
        }

        if (PumpStdio)
        {
            var tIn = new Thread(() => Pump(Console.OpenStandardInput(), p.StandardInput.BaseStream, true));
            var tOut = new Thread(() => Pump(p.StandardOutput.BaseStream, Console.OpenStandardOutput(), false));
            var tErr = new Thread(() => Pump(p.StandardError.BaseStream, Console.OpenStandardError(), false));
            tIn.IsBackground = true; tOut.IsBackground = true; tErr.IsBackground = true;
            tIn.Start(); tOut.Start(); tErr.Start();
            p.WaitForExit();
            tOut.Join(2000); tErr.Join(2000);
        }
        else
        {
            p.WaitForExit();
        }
        return p.ExitCode;
    }
}
'@

function Find-Csc {
    foreach ($fw in @("Framework64", "Framework")) {
        $p = Join-Path $env:WINDIR "Microsoft.NET\$fw\v4.0.30319\csc.exe"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ""
}

function Get-PathId([string]$Path) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))
    return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}

# What a wrapper for this target must contain; stored in the exe's "Comments".
function Get-WrapperInfo([string]$Real, [bool]$Pump) {
    return "sde=$SdePath; real=$Real; pump=$Pump"
}

function Test-Wrapper([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-Item -LiteralPath $Path).VersionInfo.FileDescription -eq $WrapperTitle)
}

# Compiles a wrapper that runs $Real under SDE. Returns the exe path or "".
function New-Wrapper([string]$Target, [string]$Real, [bool]$Pump) {
    $csc = Find-Csc
    if ($csc -eq "") { Write-Fail "the C# compiler of .NET Framework 4 (csc.exe) was not found"; return "" }
    New-Item -ItemType Directory -Force -Path $WrapDir | Out-Null
    $id = Get-PathId $Target
    $src = Join-Path $WrapDir "$id.cs"
    $exe = Join-Path $WrapDir "$id.exe"
    $code = $WrapperSource.Replace("__TITLE__", $WrapperTitle).
        Replace("__INFO__", (Get-WrapperInfo $Real $Pump)).
        Replace("__SDE__", $SdePath).
        Replace("__REAL__", $Real).
        Replace("__PUMP__", $Pump.ToString().ToLowerInvariant())
    # With a BOM, csc reads non-ASCII paths (e.g. in the user name) correctly.
    [IO.File]::WriteAllText($src, $code, (New-Object Text.UTF8Encoding $true))
    $out = & $csc /nologo /target:exe "/out:$exe" $src 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        Write-Fail "could not compile the wrapper: $($out -join ' ')"
        return ""
    }
    return $exe
}

# Wraps one native binary (or undoes that in restore mode).
#   $Target: the claude.exe the app starts
#   $Real:   where the original binary is kept
#   $Pump:   use the stdio-pumping wrapper (VS Code, Zed)
function Invoke-Wrap([string]$Target, [string]$Real, [bool]$Pump) {
    $external = $Real.StartsWith($RealBin, [StringComparison]::OrdinalIgnoreCase)

    if ($Mode -eq "restore") {
        if (-not (Test-Wrapper $Target)) { Write-Ok "not wrapped: $Target"; return }
        if (-not (Test-Path -LiteralPath $Real)) {
            Write-Fail "the original binary is missing ($Real); reinstall the app to restore $Target"
            return
        }
        try {
            Copy-Item -LiteralPath $Real -Destination $Target -Force -ErrorAction Stop
            Remove-Item -LiteralPath $Real -Force -ErrorAction SilentlyContinue
            if ($external) { Remove-Item -LiteralPath "$Real.target" -Force -ErrorAction SilentlyContinue }
            Write-Restored "unwrapped: $Target"
        } catch {
            Write-Fail "could not restore $Target (close the app that uses it and re-run): $($_.Exception.Message)"
        }
        return
    }

    if (Test-Wrapper $Target) {
        if (-not (Test-Path -LiteralPath $Real)) {
            Write-Fail "wrapped, but the original binary is gone ($Real); reinstall the app, then re-run"
            return
        }
        if ((Get-Item -LiteralPath $Target).VersionInfo.Comments -eq (Get-WrapperInfo $Real $Pump)) {
            Write-Ok "already wrapped: $Target"
            return
        }
        # SDE moved or the wrapper type changed: build it again below.
    } elseif (Test-Path -LiteralPath $Target -PathType Leaf) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Real) | Out-Null
            Copy-Item -LiteralPath $Target -Destination $Real -Force -ErrorAction Stop
            if ($external) { [IO.File]::WriteAllText("$Real.target", $Target) }
        } catch {
            Write-Fail "could not copy $Target to $Real : $($_.Exception.Message)"
            return
        }
    } else {
        Write-Fail "not found: $Target"
        return
    }

    $wrapper = New-Wrapper $Target $Real $Pump
    if ($wrapper -eq "") { return }
    try {
        Copy-Item -LiteralPath $wrapper -Destination $Target -Force -ErrorAction Stop
        Write-Patched "wrapped: $Target"
    } catch {
        Write-Fail "could not replace $Target (close the app that uses it and re-run): $($_.Exception.Message)"
    }
}

# Where the original of a target is kept outside the app's own folder. VS Code
# and Zed delete unknown files from their folders, so they must not be kept there.
function Get-ExternalReal([string]$Target, [string]$Label) {
    return Join-Path $RealBin ("$Label-" + (Get-PathId $Target) + ".exe")
}

# Deletes kept originals whose app folder is gone (e.g. after an update).
function Remove-StaleOriginals {
    Get-ChildItem -LiteralPath $RealBin -Filter *.exe.target -File -ErrorAction SilentlyContinue | ForEach-Object {
        $target = (Get-Content -LiteralPath $_.FullName -Raw).Trim()
        if (-not (Test-Path -LiteralPath $target)) {
            $real = $_.FullName -replace '\.target$', ''
            Remove-Item -LiteralPath $real, $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed the kept original of a deleted app version: $target"
        }
    }
}

# --- 1) Terminal CLI -----------------------------------------------------------
# The npm shims are text files, so they get an SDE prefix instead of a wrapper.

# How each shim refers to SDE. %LOCALAPPDATA% is kept as a variable so that
# non-ASCII user names don't break cmd.exe or Windows PowerShell.
function Get-SdeRef([string]$Kind) {
    $local = $env:LOCALAPPDATA.TrimEnd('\') + '\'
    $rel = ""
    if ($SdePath.StartsWith($local, [StringComparison]::OrdinalIgnoreCase)) { $rel = $SdePath.Substring($local.Length) }
    switch ($Kind) {
        "cmd" { if ($rel) { return "`"%LOCALAPPDATA%\$rel`"" } else { return "`"$SdePath`"" } }
        "ps1" { if ($rel) { return "`"`$env:LOCALAPPDATA\$rel`"" } else { return "`"$SdePath`"" } }
        "sh"  { if ($rel) { return "`"`$LOCALAPPDATA/$($rel -replace '\\', '/')`"" } else { return "`"$($SdePath -replace '\\', '/')`"" } }
    }
}

$ShimTargetRe = '"[^"\r\n]*[\\/]@anthropic-ai[\\/]claude-code[\\/]bin[\\/]claude\.exe"'
$ShimPrefixRe = '"[^"\r\n]*sde\.exe" -hsw (?:--|''--'') '

function Update-Shim([string]$File, [string]$Kind) {
    $text = [IO.File]::ReadAllText($File)
    $clean = [regex]::Replace($text, $ShimPrefixRe, "")
    if ($Mode -eq "restore") {
        $new = $clean
    } else {
        if (-not [regex]::IsMatch($clean, $ShimTargetRe)) {
            Write-Skip "$File does not start the native claude.exe (older npm package?)"
            return
        }
        $dashes = "--"
        if ($Kind -eq "ps1") { $dashes = "'--'" }  # a bare -- is not passed on by every PowerShell version
        $prefix = (Get-SdeRef $Kind) + " -hsw $dashes "
        $new = [regex]::Replace($clean, $ShimTargetRe, $prefix.Replace('$', '$$') + '$0')
    }
    if ($new -eq $text) {
        if ($Mode -eq "restore") { Write-Ok "not patched: $File" } else { Write-Ok "already patched: $File" }
        return
    }
    try {
        [IO.File]::WriteAllText($File, $new, (New-Object Text.UTF8Encoding $false))
        if ($Mode -eq "restore") { Write-Restored "unpatched: $File" } else { Write-Patched "patched: $File" }
    } catch {
        Write-Fail "could not write $File : $($_.Exception.Message)"
    }
}

function Repair-Cli {
    Write-Header "Terminal CLI"
    $found = $false

    # npm global install: %APPDATA%\npm unless the prefix was changed
    $prefixes = @(Join-Path $env:APPDATA "npm")
    $npm = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npm) {
        $p = (& $npm.Source prefix -g 2>$null | Select-Object -First 1)
        if ($p) { $prefixes = @($p.Trim()) + $prefixes }
    }
    $seen = @{}
    foreach ($prefix in $prefixes) {
        if ($seen.ContainsKey($prefix.ToLowerInvariant())) { continue }
        $seen[$prefix.ToLowerInvariant()] = $true
        if (-not (Test-Path -LiteralPath (Join-Path $prefix "node_modules\@anthropic-ai\claude-code"))) { continue }
        foreach ($shim in @(@("claude.cmd", "cmd"), @("claude.ps1", "ps1"), @("claude", "sh"))) {
            $file = Join-Path $prefix $shim[0]
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $found = $true
                Update-Shim $file $shim[1]
            }
        }
    }

    # Native installer, and any other claude.exe on PATH
    $exes = @(Join-Path $env:USERPROFILE ".local\bin\claude.exe")
    $exes += @(Get-Command claude.exe -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    $seen = @{}
    foreach ($exe in $exes) {
        if ($seen.ContainsKey($exe.ToLowerInvariant())) { continue }
        $seen[$exe.ToLowerInvariant()] = $true
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $found = $true
        Invoke-Wrap $exe (Get-ExternalReal $exe "cli") $false
    }

    if (-not $found) { Write-Skip "Claude Code CLI not installed" }
}

# --- 2) Claude Desktop ---------------------------------------------------------
function Repair-Desktop {
    Write-Header "Claude Desktop embedded CLI"
    # The Store / MSIX build keeps its data inside the package folder.
    $roots = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Packages") -Directory -Filter "*Claude*" -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "LocalCache\Roaming\Claude\claude-code" })
    $roots += Join-Path $env:APPDATA "Claude\claude-code"
    $found = $false
    foreach ($root in $roots) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $exe = Join-Path $dir.FullName "claude.exe"
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            $found = $true
            # Claude Desktop leaves extra files alone, so the original stays next to the wrapper.
            Invoke-Wrap $exe (Join-Path $dir.FullName "claude.realbinary.exe") $false
        }
    }
    if (-not $found) { Write-Skip "Desktop embedded CLI not found" }
}

# --- 3) VS Code extension ------------------------------------------------------
# Only the two subprocess startup timeouts are touched, e.g.
#   initializeTimeoutMs:J=60000   loadTimeoutMs??60000
$TimeoutRe = '((?:initialize|load)TimeoutMs(?::[A-Za-z_$][A-Za-z0-9_$]*=|\?\?|:|=))'

function Update-ExtensionJs([string]$Js) {
    $from = "60000"; $to = "900000"
    if ($Mode -eq "restore") { $from = "900000"; $to = "60000" }
    $text = [IO.File]::ReadAllText($Js)
    if ([regex]::IsMatch($text, $TimeoutRe + $from + '(?![0-9])')) {
        $new = [regex]::Replace($text, $TimeoutRe + $from + '(?![0-9])', '${1}' + $to)
        try {
            [IO.File]::WriteAllText($Js, $new, (New-Object Text.UTF8Encoding $false))
            if ($Mode -eq "restore") { Write-Restored "extension.js timeout -> 60000" } else { Write-Patched "extension.js startup timeout 60000 -> 900000" }
        } catch {
            Write-Fail "could not patch $Js : $($_.Exception.Message)"
        }
    } elseif ([regex]::IsMatch($text, $TimeoutRe + $to + '(?![0-9])')) {
        Write-Ok "extension.js timeout already set to $to"
    } else {
        Write-Fail "timeout setting not found in $Js (the extension changed?), not patched"
    }
}

function Get-ExtensionVersion([IO.DirectoryInfo]$Dir) {
    $v = [regex]::Match($Dir.Name, '-(\d+(?:\.\d+){1,3})')
    if ($v.Success) { return [version]$v.Groups[1].Value }
    return [version]"0.0"
}

function Repair-VSCode {
    Write-Header "VS Code extension"
    $found = $false
    foreach ($editor in @(".vscode", ".vscode-insiders", ".vscode-oss", ".cursor", ".windsurf")) {
        $root = Join-Path $env:USERPROFILE "$editor\extensions"
        $dir = Get-ChildItem -LiteralPath $root -Directory -Filter "anthropic.claude-code-*" -ErrorAction SilentlyContinue |
            Sort-Object { Get-ExtensionVersion $_ } | Select-Object -Last 1
        if (-not $dir) { continue }
        $found = $true

        $exe = Join-Path $dir.FullName "resources\native-binary\claude.exe"
        Invoke-Wrap $exe (Get-ExternalReal $exe "vscode") $true

        $js = Join-Path $dir.FullName "extension.js"
        if (-not (Test-Path -LiteralPath $js)) { $js = Join-Path $dir.FullName "dist\extension.js" }
        if (Test-Path -LiteralPath $js) { Update-ExtensionJs $js } else { Write-Skip "extension.js not found in $($dir.FullName)" }
    }
    if (-not $found) { Write-Skip "VS Code extension not installed" }
}

# --- 4) Zed Claude Agent (ACP) -------------------------------------------------
function Repair-Zed {
    Write-Header "Zed Claude Agent (ACP)"
    $exes = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Zed") -Recurse -File -Filter claude.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq "claude-agent-sdk-win32-x64" })
    foreach ($exe in $exes) {
        Invoke-Wrap $exe.FullName (Get-ExternalReal $exe.FullName "zed") $true
    }
    if ($exes.Count -eq 0) { Write-Skip "Zed agent binary not found" }
}

# --- Run selected targets ------------------------------------------------------
if ($script:Selected -contains 1) { Repair-Cli }
if ($script:Selected -contains 2) { Repair-Desktop }
if ($script:Selected -contains 3) { Repair-VSCode }
if ($script:Selected -contains 4) { Repair-Zed }
Remove-StaleOriginals

# --- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "========= SUMMARY ($ScriptName $ScriptVersion) =========" -ForegroundColor Blue
if ($script:Changed -and $Mode -eq "restore") {
    Write-Host "Original files were restored." -ForegroundColor Yellow
    Write-Host "Fully close and reopen the restored apps."
} elseif ($script:Changed) {
    Write-Host "Some patches were (re)applied." -ForegroundColor Yellow
    Write-Host "Fully close and reopen the patched apps (terminal, VS Code, Zed, Claude Desktop)."
} else {
    Write-Host "Nothing to do." -ForegroundColor Green
}
if ($script:Failed) {
    Write-Host "Some steps failed, see the [ERROR] lines above." -ForegroundColor Red
    exit 1
}
exit 0
