$packageName = 'zelph'
$toolsDir    = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$url         = 'https://github.com/acrion/zelph/releases/download/v0.9.8/zelph-windows.zip'
$checksum    = 'ef84b0f66248c57460edc4d595a3ed2642d79e35427de6782edba1a40ca25a91'

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
