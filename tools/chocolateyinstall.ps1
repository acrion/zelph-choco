$packageName = 'zelph'
$toolsDir    = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$url         = 'https://github.com/acrion/zelph/releases/download/v0.9.5/zelph-windows.zip'
$checksum    = '074cf6ac96484a3c64011790fef90d1b6e99d795a4ad8a98c0e917ec9847ad2a'

Install-ChocolateyZipPackage `
  -PackageName $packageName `
  -Url $url `
  -UnzipLocation $toolsDir `
  -Checksum $checksum `
  -ChecksumType 'sha256' `
  -Url64bit $url `
  -Checksum64 $checksum `
  -ChecksumType64 'sha256'

$testsExe = Join-Path $toolsDir 'zelph_tests.exe'
& $testsExe
if ($LASTEXITCODE -ne 0) {
    throw "zelph_tests failed with exit code $LASTEXITCODE"
}

$zelphExe = Join-Path $toolsDir 'zelph.exe'
$output = & $zelphExe --version 2>&1
if ($output -notmatch 'Janet') {
    throw "zelph installation verification failed: 'Janet' not found in version output"
}
