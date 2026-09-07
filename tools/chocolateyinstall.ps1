$packageName = 'zelph'
$toolsDir    = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$url         = 'https://github.com/acrion/zelph/releases/download/v1.0.1/zelph-windows.zip'
$checksum    = '0d77f9d2357b9016faa99c329a40bdbfd1d394077d4f843f5e3843f844742b75'

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
& $testsExe --test-suite-exclude=slow
if ($LASTEXITCODE -ne 0) {
    throw "zelph_tests failed with exit code $LASTEXITCODE"
}
