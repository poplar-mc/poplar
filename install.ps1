# Installs the latest Poplar release in %LOCALAPPDATA%\Programs\poplar (or $env:POPLAR_PREFIX) and adds it to your PATH.
#   irm https://raw.githubusercontent.com/poplar-mc/poplar/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'

$prefix = if ($env:POPLAR_PREFIX) { $env:POPLAR_PREFIX } else { Join-Path $env:LOCALAPPDATA 'Programs\poplar' }
$releaseUrl = if ($env:POPLAR_RELEASE_URL) { $env:POPLAR_RELEASE_URL } else { 'https://github.com/poplar-mc/poplar/releases/latest/download' }
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$archive = "poplar-windows-$arch.zip"

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Write-Host "Downloading $archive"
    Invoke-WebRequest "$releaseUrl/$archive" -OutFile (Join-Path $temp $archive)
    Expand-Archive (Join-Path $temp $archive) -DestinationPath $temp

    New-Item -ItemType Directory -Force -Path (Join-Path $prefix 'bin'), (Join-Path $prefix 'lib\poplar') | Out-Null
    Remove-Item -Recurse -Force (Join-Path $prefix 'lib\poplar\std') -ErrorAction SilentlyContinue
    # Windows locks a running poplar.exe (for example `poplar lsp`), but it can be renamed. The old copy is removed when it is free.
    $exe = Join-Path $prefix 'bin\poplar.exe'
    $old = "$exe.old"
    Remove-Item -Force $old -ErrorAction SilentlyContinue
    if (Test-Path $exe) { Move-Item -Force $exe $old }
    Copy-Item (Join-Path $temp 'bin\poplar.exe') $exe
    Remove-Item -Force $old -ErrorAction SilentlyContinue
    Copy-Item -Recurse (Join-Path $temp 'lib\poplar\std') (Join-Path $prefix 'lib\poplar\std')
} finally {
    Remove-Item -Recurse -Force $temp
}

$bin = Join-Path $prefix 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $bin)) {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$bin", 'User')
    Write-Host "Added $bin to your PATH. Open a new terminal to use poplar."
}
& (Join-Path $bin 'poplar.exe') --version
