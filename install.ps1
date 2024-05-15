# Licensed under the MIT license
# <LICENSE-MIT or https://opensource.org/licenses/MIT>, at your
# option. This file may not be copied, modified, or distributed
# except according to those terms.

<#
.SYNOPSIS

The installer for cargo-insta 1.38.0

.DESCRIPTION

This script detects what platform you're on and fetches an appropriate archive from
https://github.com/mitsuhiko/insta/releases/download/1.38.0
then unpacks the binaries and installs them to $env:CARGO_HOME\bin ($HOME\.cargo\bin)

It will then add that dir to PATH by editing your Environment.Path registry key

.PARAMETER ArtifactDownloadUrl
The URL of the directory where artifacts can be fetched from

.PARAMETER NoModifyPath
Don't add the install directory to PATH

.PARAMETER Help
Print help

#>

param (
    [Parameter(HelpMessage = "The URL of the directory where artifacts can be fetched from")]
    [string]$ArtifactDownloadUrl = 'https://github.com/mitsuhiko/insta/releases/download/1.38.0',
    [Parameter(HelpMessage = "Don't add the install directory to PATH")]
    [switch]$NoModifyPath,
    [Parameter(HelpMessage = "Print Help")]
    [switch]$Help
)

$app_name = 'cargo-insta'
$app_version = '1.38.0'

$receipt = @"
{"binaries":["CARGO_DIST_BINS"],"install_prefix":"AXO_INSTALL_PREFIX","provider":{"source":"cargo-dist","version":"0.12.0"},"source":{"app_name":"cargo-insta","name":"insta","owner":"mitsuhiko","release_type":"github"},"version":"1.38.0"}
"@
$receipt_home = "${env:LOCALAPPDATA}\cargo-insta"

function Install-Binary($install_args) {
  if ($Help) {
    Get-Help $PSCommandPath -Detailed
    Exit
  }

  Initialize-Environment

  # Platform info injected by cargo-dist
  $platforms = @{
    "x86_64-pc-windows-msvc" = @{
      "artifact_name" = "cargo-insta-x86_64-pc-windows-msvc.zip"
      "bins" = "cargo-insta.exe"
      "zip_ext" = ".zip"
    }
  }

  $fetched = Download "$ArtifactDownloadUrl" $platforms
  # FIXME: add a flag that lets the user not do this step
  Invoke-Installer -bin_paths $fetched -platforms $platforms "$install_args"
}

function Get-TargetTriple() {
  try {
    # NOTE: this might return X64 on ARM64 Windows, which is OK since emulation is available.
    # It works correctly starting in PowerShell Core 7.3 and Windows PowerShell in Win 11 22H2.
    # Ideally this would just be
    #   [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    # but that gets a type from the wrong assembly on Windows PowerShell (i.e. not Core)
    $a = [System.Reflection.Assembly]::LoadWithPartialName("System.Runtime.InteropServices.RuntimeInformation")
    $t = $a.GetType("System.Runtime.InteropServices.RuntimeInformation")
    $p = $t.GetProperty("OSArchitecture")
    # Possible OSArchitecture Values: https://learn.microsoft.com/dotnet/api/system.runtime.interopservices.architecture
    # Rust supported platforms: https://doc.rust-lang.org/stable/rustc/platform-support.html
    switch ($p.GetValue($null).ToString())
    {
      "X86" { return "i686-pc-windows-msvc" }
      "X64" { return "x86_64-pc-windows-msvc" }
      "Arm" { return "thumbv7a-pc-windows-msvc" }
      "Arm64" { return "aarch64-pc-windows-msvc" }
    }
  } catch {
    # The above was added in .NET 4.7.1, so Windows PowerShell in versions of Windows
    # prior to Windows 10 v1709 may not have this API.
    Write-Verbose "Get-TargetTriple: Exception when trying to determine OS architecture."
    Write-Verbose $_
  }

  # This is available in .NET 4.0. We already checked for PS 5, which requires .NET 4.5.
  Write-Verbose("Get-TargetTriple: falling back to Is64BitOperatingSystem.")
  if ([System.Environment]::Is64BitOperatingSystem) {
    return "x86_64-pc-windows-msvc"
  } else {
    return "i686-pc-windows-msvc"
  }
}

function Download($download_url, $platforms) {
  $arch = Get-TargetTriple

  if (-not $platforms.ContainsKey($arch)) {
    # X64 is well-supported, including in emulation on ARM64
    Write-Verbose "$arch is not available, falling back to X64"
    $arch = "x86_64-pc-windows-msvc"
  }

  if (-not $platforms.ContainsKey($arch)) {
    # should not be possible, as currently we always produce X64 binaries.
    $platforms_json = ConvertTo-Json $platforms
    throw "ERROR: could not find binaries for this platform. Last platform tried: $arch platform info: $platforms_json"
  }

  # Lookup what we expect this platform to look like
  $info = $platforms[$arch]
  $zip_ext = $info["zip_ext"]
  $bin_names = $info["bins"]
  $artifact_name = $info["artifact_name"]

  # Make a new temp dir to unpack things to
  $tmp = New-Temp-Dir
  $dir_path = "$tmp\$app_name$zip_ext"

  # Download and unpack!
  $url = "$download_url/$artifact_name"
  Write-Information "Downloading $app_name $app_version ($arch)"
  Write-Verbose "  from $url"
  Write-Verbose "  to $dir_path"
  $wc = New-Object Net.Webclient
  $wc.downloadFile($url, $dir_path)

  Write-Verbose "Unpacking to $tmp"

  # Select the tool to unpack the files with.
  #
  # As of windows 10(?), powershell comes with tar preinstalled, but in practice
  # it only seems to support .tar.gz, and not xz/zstd. Still, we should try to
  # forward all tars to it in case the user has a machine that can handle it!
  switch -Wildcard ($zip_ext) {
    ".zip" {
      Expand-Archive -Path $dir_path -DestinationPath "$tmp";
      Break
    }
    ".tar.*" {
      tar xf $dir_path --strip-components 1 -C "$tmp";
      Break
    }
    Default {
      throw "ERROR: unknown archive format $zip_ext"
    }
  }

  # Let the next step know what to copy
  $bin_paths = @()
  foreach ($bin_name in $bin_names) {
    Write-Verbose "  Unpacked $bin_name"
    $bin_paths += "$tmp\$bin_name"
  }

  if ($null -ne $info["updater"]) {
    $updater_id = $info["updater"]["artifact_name"]
    $updater_url = "$download_url/$updater_id"
    $out_name = "$tmp\cargo-insta-update.exe"

    $wc.downloadFile($updater_url, $out_name)
    $bin_paths += $out_name
  }

  return $bin_paths
}

function Invoke-Installer($bin_paths, $platforms) {

  # first try CARGO_HOME, then fallback to HOME
  # (for whatever reason $HOME is not a normal env var and doesn't need the $env: prefix)
  $root = if (($base_dir = $env:CARGO_HOME)) {
    $base_dir
  } elseif (($base_dir = $HOME)) {
    Join-Path $base_dir ".cargo"
  } else {
    throw "ERROR: could not find your HOME dir or CARGO_HOME to install binaries to"
  }

  $dest_dir = Join-Path $root "bin"

  # ...ignoring all of the above, if the user asked us to completely override
  # those choices and use a specified directory, then pick that now
  if (($env:CARGO_DIST_FORCE_INSTALL_DIR)) {
    $dest_dir = Join-Path $env:CARGO_DIST_FORCE_INSTALL_DIR "bin"
  }

  # The replace call here ensures proper escaping is inlined into the receipt
  $receipt = $receipt.Replace('AXO_INSTALL_PREFIX', $dest_dir.replace("\", "\\"))

  $dest_dir = New-Item -Force -ItemType Directory -Path $dest_dir
  Write-Information "Installing to $dest_dir"
  # Just copy the binaries from the temp location to the install dir
  foreach ($bin_path in $bin_paths) {
    $installed_file = Split-Path -Path "$bin_path" -Leaf
    Copy-Item "$bin_path" -Destination "$dest_dir"
    Remove-Item "$bin_path" -Recurse -Force
    Write-Information "  $installed_file"
  }

  # Replaces the placeholder binary entry with the actual list of binaries
  $arch = Get-TargetTriple

  if (-not $platforms.ContainsKey($arch)) {
    # X64 is well-supported, including in emulation on ARM64
    Write-Verbose "$arch is not available, falling back to X64"
    $arch = "x86_64-pc-windows-msvc"
  }

  if (-not $platforms.ContainsKey($arch)) {
    # should not be possible, as currently we always produce X64 binaries.
    $platforms_json = ConvertTo-Json $platforms
    throw "ERROR: could not find binaries for this platform. Last platform tried: $arch platform info: $platforms_json"
  }

  $info = $platforms[$arch]
  $formatted_bins = ($info["bins"] | ForEach-Object { '"' + $_ + '"' }) -join ","
  $receipt = $receipt.Replace('"CARGO_DIST_BINS"', $formatted_bins)

  # Write the install receipt
  $null = New-Item -Path $receipt_home -ItemType "directory" -ErrorAction SilentlyContinue
  # Trying to get Powershell 5.1 (not 6+, which is fake and lies) to write utf8 is a crime
  # because "Out-File -Encoding utf8" actually still means utf8BOM, so we need to pull out
  # .NET's APIs which actually do what you tell them (also apparently utf8NoBOM is the
  # default in newer .NETs but I'd rather not rely on that at this point).
  $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
  [IO.File]::WriteAllLines("$receipt_home/cargo-insta-receipt.json", "$receipt", $Utf8NoBomEncoding)

  Write-Information "Everything's installed!"
  if (-not $NoModifyPath) {
    if (Add-Path $dest_dir) {
        Write-Information ""
        Write-Information "$dest_dir was added to your PATH, you may need to restart your shell for that to take effect."
    }
  }
}

# Try to add the given path to PATH via the registry
#
# Returns true if the registry was modified, otherwise returns false
# (indicating it was already on PATH)
function Add-Path($OrigPathToAdd) {
  Write-Verbose "Adding $OrigPathToAdd to your PATH"
  $RegistryPath = "HKCU:\Environment"
  $PropertyName = "Path"
  $PathToAdd = $OrigPathToAdd

  $Item = if (Test-Path $RegistryPath) {
    # If the registry key exists, get it
    Get-Item -Path $RegistryPath
  } else {
    # If the registry key doesn't exist, create it
    Write-Verbose  "Creating $RegistryPath"
    New-Item -Path $RegistryPath -Force
  }

  $OldPath = ""
  try {
    # Try to get the old PATH value. If that fails, assume we're making it from scratch.
    # Otherwise assume there's already paths in here and use a ; separator
    $OldPath = $Item | Get-ItemPropertyValue -Name $PropertyName
    $PathToAdd = "$PathToAdd;"
  } catch {
    # We'll be creating the PATH from scratch
    Write-Verbose "No $PropertyName Property exists on $RegistryPath (we'll make one)"
  }

  # Check if the path is already there
  #
  # We don't want to incorrectly match "C:\blah\" to "C:\blah\blah\", so we include the semicolon
  # delimiters when searching, ensuring exact matches. To avoid corner cases we add semicolons to
  # both sides of the input, allowing us to pretend we're always in the middle of a list.
  Write-Verbose "Old $PropertyName Property is $OldPath"
  if (";$OldPath;" -like "*;$OrigPathToAdd;*") {
    # Already on path, nothing to do
    Write-Verbose "install dir already on PATH, all done!"
    return $false
  } else {
    # Actually update PATH
    Write-Verbose "Actually mutating $PropertyName Property"
    $NewPath = $PathToAdd + $OldPath
    # We use -Force here to make the value already existing not be an error
    $Item | New-ItemProperty -Name $PropertyName -Value $NewPath -PropertyType String -Force | Out-Null
    return $true
  }
}

function Initialize-Environment() {
  If (($PSVersionTable.PSVersion.Major) -lt 5) {
    throw @"
Error: PowerShell 5 or later is required to install $app_name.
Upgrade PowerShell:

    https://docs.microsoft.com/en-us/powershell/scripting/setup/installing-windows-powershell

"@
  }

  # show notification to change execution policy:
  $allowedExecutionPolicy = @('Unrestricted', 'RemoteSigned', 'ByPass')
  If ((Get-ExecutionPolicy).ToString() -notin $allowedExecutionPolicy) {
    throw @"
Error: PowerShell requires an execution policy in [$($allowedExecutionPolicy -join ", ")] to run $app_name. For example, to set the execution policy to 'RemoteSigned' please run:

    Set-ExecutionPolicy RemoteSigned -scope CurrentUser

"@
  }

  # GitHub requires TLS 1.2
  If ([System.Enum]::GetNames([System.Net.SecurityProtocolType]) -notcontains 'Tls12') {
    throw @"
Error: Installing $app_name requires at least .NET Framework 4.5
Please download and install it first:

    https://www.microsoft.com/net/download

"@
  }
}

function New-Temp-Dir() {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $parent = [System.IO.Path]::GetTempPath()
  [string] $name = [System.Guid]::NewGuid()
  New-Item -ItemType Directory -Path (Join-Path $parent $name)
}

# PSScriptAnalyzer doesn't like how we use our params as globals, this calms it
$Null = $ArtifactDownloadUrl, $NoModifyPath, $Help
# Make Write-Information statements be visible
$InformationPreference = "Continue"

# The default interactive handler
try {
  Install-Binary "$Args"
} catch {
  Write-Information $_
  exit 1
}
