# Builds the wrapper from Claude-Code/Windows/fix/claude-code-fix.ps1 with
# .NET Framework's csc.exe (as the fix script does) and checks, with a fake
# sde.exe, that arguments, stdin/stdout and the exit code pass through, and
# that the fix script can recognize the wrapper. Runs on Windows in CI.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$fix = Join-Path $PSScriptRoot "..\Claude-Code\Windows\fix\claude-code-fix.ps1"
$m = [regex]::Match((Get-Content -LiteralPath $fix -Raw), "(?s)\`$WrapperSource = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { throw "wrapper source not found in $fix" }
$title = [regex]::Match((Get-Content -LiteralPath $fix -Raw), '\$WrapperTitle = "([^"]+)"').Groups[1].Value

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$dir = Join-Path ([IO.Path]::GetTempPath()) ("wrapper-test " + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null

function Invoke-Csc([string]$Source, [string]$Exe) {
    $src = [IO.Path]::ChangeExtension($Exe, ".cs")
    [IO.File]::WriteAllText($src, $Source, (New-Object Text.UTF8Encoding $true))
    & $csc /nologo /target:exe "/out:$Exe" $src
    if ($LASTEXITCODE -ne 0) { throw "csc failed for $src" }
}

# Fake SDE: prints the arguments after "-hsw --", echoes one stdin line, exits 7.
$sde = Join-Path $dir "sde.exe"
Invoke-Csc @'
using System;
class FakeSde {
    static int Main(string[] a) {
        if (a.Length < 3 || a[0] != "-hsw" || a[1] != "--") { Console.WriteLine("bad SDE arguments"); return 90; }
        for (int i = 2; i < a.Length; i++) Console.WriteLine("[" + a[i] + "]");
        string line = Console.In.ReadLine();
        Console.WriteLine("stdin:" + (line == null ? "<eof>" : line.ToUpperInvariant()));
        return 7;
    }
}
'@ $sde

$real = Join-Path $dir "real claude.exe"
$testArgs = @("a b", "", 'q"x', 'C:\dir\', '{"p":"C:\\x\\"}', 'end\\', "--flag=1")
$expected = @("[$real]") + ($testArgs | ForEach-Object { "[$_]" }) + "stdin:HELLO"

$failed = $false
foreach ($pump in @($false, $true)) {
    $info = "sde=$sde; real=$real; pump=$pump"
    $code = $m.Groups[1].Value.Replace("__TITLE__", $title).
        Replace("__INFO__", $info).
        Replace("__SDE__", $sde).
        Replace("__REAL__", $real).
        Replace("__PUMP__", $pump.ToString().ToLowerInvariant())
    $wrapper = Join-Path $dir "wrapper-$pump.exe"
    Invoke-Csc $code $wrapper

    $vi = (Get-Item -LiteralPath $wrapper).VersionInfo
    if ($vi.FileDescription -ne $title) { Write-Host "pump=${pump}: FileDescription is '$($vi.FileDescription)'"; $failed = $true }
    if ($vi.Comments -ne $info) { Write-Host "pump=${pump}: Comments is '$($vi.Comments)'"; $failed = $true }

    $psi = New-Object Diagnostics.ProcessStartInfo $wrapper
    foreach ($a in $testArgs) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine("hello")
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd() -split "\r?\n" | Where-Object { $_ -ne "" }
    $p.WaitForExit()

    if (($out -join "`n") -ne ($expected -join "`n")) {
        Write-Host "pump=${pump}: unexpected output:"; $out | ForEach-Object { Write-Host "  $_" }
        $failed = $true
    }
    if ($p.ExitCode -ne 7) { Write-Host "pump=${pump}: exit code $($p.ExitCode), expected 7"; $failed = $true }
    if (-not $failed) { Write-Host "pump=${pump}: OK" }
}

Remove-Item -LiteralPath $dir -Recurse -Force
if ($failed) { exit 1 }
