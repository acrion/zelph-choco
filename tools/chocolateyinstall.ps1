$packageName = 'zelph'
$toolsDir    = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$url         = 'https://github.com/acrion/zelph/releases/download/v0.9.7/zelph-windows.zip'
$checksum    = '4f4154ba996d70ccc3c6e179fe66e04d1d15025f1247c26b9123d4467f769050'

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
