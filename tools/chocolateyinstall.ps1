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

# What a package may check at install time is that the program runs on this
# machine, and nothing beyond that. Until 1.0.1 these lines ran the fast test
# tier instead: twenty-one seconds on a developer machine, forty-six on the
# Windows runner of the project, and more than forty-three minutes on the
# Chocolatey verifier, which killed the install when the 2700 second execution
# timeout expired and rejected the package. No budget calibrated on a machine
# you own survives one you have never seen; three statements do.
#
# They are the example from the quick start guide, and the answer to them
# proves the whole chain in one step: the executable started, zelph.dll loaded
# beside it, the parser read a rule, and the engine derived a fact that stands
# in none of the three lines. It takes six milliseconds here, so a machine a
# hundred times slower still finishes well inside a second.
#
# The failure worth catching is a processor below x86-64-v3. The binaries are
# built for AVX2, and an older one stops with an illegal instruction instead of
# a message -- which is what 1.0.0 did on the machines of the people who
# installed it.
$zelph = Join-Path $toolsDir 'zelph.exe'

$statements = @(
    'Berlin "is capital of" Germany'
    'Germany "is located in" Europe'
    '(X "is capital of" Y, Y "is located in" Z) => (X "is located in" Z)'
)
$derived = '(Berlin "is located in" Europe)'

$answer = $statements | & $zelph
$status = $LASTEXITCODE

if ($status -ne 0 -or (($answer -join "`n") -notlike "*$derived*")) {
    Write-Host ($answer -join "`n")
    throw @"
zelph was installed, but it did not answer on this machine.
zelph.exe left with exit code $status and did not derive $derived

The most likely cause is a processor older than x86-64-v3: the binaries use
AVX2, BMI2 and FMA, which means Intel from Haswell (2013) or AMD from
Excavator (2015) onwards. An older processor stops the program with an illegal
instruction. The other cause that fits is a missing Visual C++ runtime, which
this package declares as a dependency on vcredist140.

Please report this at https://github.com/acrion/zelph/issues and include the
output above.
"@
}

Write-Host "zelph derived $derived - the installation is working."
