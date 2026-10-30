[CmdletBinding()]
param([string]$QuartusBin = '')

# Builds a fresh local snapshot. It never discovers a cable or programs hardware.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectName = 'pistorm_retained_brjp_bg_schmitt_diag_epm240_i5'
$sourceRoot = Split-Path -Parent $PSScriptRoot
# Build snapshots are created below the source tree; no hardware is programmed.
$rtlSource = Join-Path $sourceRoot 'rtl/pistorm.v'
if (-not (Test-Path -LiteralPath $rtlSource -PathType Leaf)) { throw 'Candidate RTL is missing.' }
$sourceHash = (Get-FileHash -LiteralPath $rtlSource -Algorithm SHA256).Hash.ToLowerInvariant()
$rtlText = Get-Content -LiteralPath $rtlSource -Raw
$holdParameter = [regex]::Matches($rtlText, '(?m)^\s*(?:localparam|parameter)\s+(?:integer\s+)?EXTRA_HOLD_CYCLES\s*=\s*([01])\s*;')
if ($holdParameter.Count -ne 1 -or $holdParameter[0].Groups[1].Value -ne '0') { throw 'BRJP-open diagnostic requires one literal EXTRA_HOLD_CYCLES=0 declaration; no compilation was started.' }

function Find-QuartusTool([string]$toolName) {
    if ($QuartusBin) {
        $toolPath = Join-Path $QuartusBin ($toolName + '.exe')
        if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) { throw "Missing Quartus executable: $toolPath" }
        return (Resolve-Path -LiteralPath $toolPath).Path
    }
    $resolvedCommand = Get-Command $toolName -ErrorAction SilentlyContinue
    if (-not $resolvedCommand) { throw "Install Quartus Lite/Standard with MAX II support and supply -QuartusBin; $toolName is unavailable." }
    return $resolvedCommand.Source
}
$quartusSh = Find-QuartusTool 'quartus_sh'
$quartusSta = Find-QuartusTool 'quartus_sta'
$quartusCpf = Find-QuartusTool 'quartus_cpf'

$snapshotId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$snapshotRoot = Join-Path $sourceRoot ('builds/' + $snapshotId)
$snapshotProject = Join-Path $snapshotRoot 'project'
$snapshotRtl = Join-Path $snapshotRoot 'rtl'
$null = New-Item -ItemType Directory -Path $snapshotProject
$null = New-Item -ItemType Directory -Path $snapshotRtl
Get-ChildItem -LiteralPath $PSScriptRoot -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $snapshotProject }
Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'rtl') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $snapshotRtl }
if ((Get-FileHash -LiteralPath (Join-Path $snapshotRtl 'pistorm.v') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) { throw 'RTL changed while its fresh snapshot was being created.' }
$sourceRecords = @(Get-ChildItem -LiteralPath $snapshotProject -File; Get-ChildItem -LiteralPath $snapshotRtl -File) | ForEach-Object {
    [ordered]@{ file = $_.FullName.Substring($snapshotRoot.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$sourceRecords | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $snapshotRoot 'source-hashes.json') -Encoding UTF8

function Invoke-Quartus([string]$Executable, [string[]]$ToolArguments, [string]$LogName) {
    & $Executable @ToolArguments 2>&1 | Tee-Object -FilePath $LogName
    if ($LASTEXITCODE -ne 0) { throw "Quartus failed with exit code $LASTEXITCODE; see $LogName" }
}

Push-Location $snapshotProject
try {
    Invoke-Quartus $quartusSh @('--version') 'quartus-version.log'
    Invoke-Quartus $quartusSh @('--flow','compile',$projectName) 'compile.log'
    $reportRoot = Join-Path $snapshotProject 'output_files'
    foreach ($suffix in @('fit.rpt','sta.rpt','asm.rpt','pin','pof')) {
        if (-not (Test-Path -LiteralPath (Join-Path $reportRoot ($projectName + '.' + $suffix)) -PathType Leaf)) { throw "Required fresh build artifact missing: $suffix" }
    }
    $fitText = Get-Content -LiteralPath (Join-Path $reportRoot ($projectName + '.fit.rpt')) -Raw
    if ($fitText -notmatch '(?i)EPM240T100I5' -or $fitText -notmatch '(?i)Fitter Status\s*[:;]\s*Successful') { throw 'Fitter report does not confirm the expected device and successful fit.' }

    # Fail closed if the actual Quartus .pin format cannot be parsed as expected.
    $pinText = Get-Content -LiteralPath (Join-Path $reportRoot ($projectName + '.pin')) -Raw
    $pinExpectations = Get-Content -LiteralPath 'canonical-pins.json' -Raw | ConvertFrom-Json
    if ($pinExpectations.target -ne 'EPM240T100I5' -or @($pinExpectations.pins).Count -ne 56) { throw 'Canonical pin evidence must specify EPM240T100I5 and exactly 56 signal pins.' }
    $actualSignalPins = [regex]::Matches($pinText, '(?im)^\s*(?<name>[^:\r\n]+?)\s*:\s*(?:PIN_)?(?<pin>\d+)\s*:\s*(?<direction>input|output|bidir)\s*:')
    # Quartus .pin includes four dedicated JTAG pins in addition to user pins.
    # Require exactly 56 user pins in the fitter report and permit only those
    # four known JTAG rows outside the canonical list; arbitrary extra ports fail.
    $fitPinCounts = [regex]::Matches($fitText, '(?im)^;\s*Total pins\s*;\s*(?<count>\d+)\s*/')
    if ($fitPinCounts.Count -ne 1 -or [int]$fitPinCounts[0].Groups['count'].Value -ne 56) { throw 'Fitter must report exactly 56 user signal pins.' }
    $dedicatedJtag = @{ TMS=@(22,'input'); TDI=@(23,'input'); TCK=@(24,'input'); TDO=@(25,'output') }
    $canonicalNames = @($pinExpectations.pins | ForEach-Object { $_.name })
    $extraPins = @($actualSignalPins | Where-Object { $_.Groups['name'].Value.Trim() -notin $canonicalNames })
    if ($actualSignalPins.Count -ne 60 -or $extraPins.Count -ne 4) { throw 'Pin report must contain exactly 56 canonical user pins plus four dedicated JTAG rows.' }
    foreach ($extraPin in $extraPins) {
        $extraName = $extraPin.Groups['name'].Value.Trim()
        if (-not $dedicatedJtag.ContainsKey($extraName)) { throw "Unexpected extra fitted signal pin: $extraName" }
        $expectedJtag = $dedicatedJtag[$extraName]
        if ([int]$extraPin.Groups['pin'].Value -ne $expectedJtag[0] -or $extraPin.Groups['direction'].Value -ine $expectedJtag[1]) { throw "Dedicated JTAG pin mapping/direction mismatch: $extraName" }
        $dedicatedJtag.Remove($extraName)
    }
    if ($dedicatedJtag.Count -ne 0) { throw 'Missing or duplicate dedicated JTAG pin row.' }
    $pinResults = @()
    foreach ($pinEntry in $pinExpectations.pins) {
        $pinPattern = '(?im)^\s*' + [regex]::Escape($pinEntry.name) + '\s*:\s*(?:PIN_)?(?<pin>\d+)\s*:\s*(?<direction>[^:\r\n]+)\s*:'
        $pinMatches = [regex]::Matches($pinText,$pinPattern)
        if ($pinMatches.Count -ne 1) { throw "Cannot uniquely find fitted pin $($pinEntry.name); review the .pin format/report." }
        $match = $pinMatches[0]
        if ([int]$match.Groups['pin'].Value -ne [int]$pinEntry.pin) { throw "Fitted pin mismatch: $($pinEntry.name)" }
        $direction = $match.Groups['direction'].Value.Trim()
        if ($pinEntry.name -in @('M68K_E','M68K_BG_n') -and $direction -notmatch '^(?i:input)$') { throw "Retained Diagnostic E/BG must be physical inputs only: $($pinEntry.name) is $direction" }
        $pinResults += [ordered]@{ name=$pinEntry.name; pin=$pinEntry.pin; direction=$direction }
    }
    $pinResults | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath 'verified-pins.json' -Encoding UTF8
    # Verify the actual implemented electrical mode; assigning an option is not proof.
    $ioRows = [regex]::Matches($pinText, '(?im)^\s*(?<name>[^:\r\n]+?)\s*:\s*(?:PIN_)?(?<pin>\d+)\s*:\s*(?<direction>input|output|bidir)\s*:\s*(?<standard>[^:\r\n]*?)\s*:')
    $canonicalIoRows = @($ioRows | Where-Object { $_.Groups['name'].Value.Trim() -in $canonicalNames })
    if ($canonicalIoRows.Count -ne 56) { throw 'Cannot uniquely verify electrical standards for all 56 user pins.' }
    $schmittPins = @()
    foreach ($ioRow in $canonicalIoRows) {
        $ioName = $ioRow.Groups['name'].Value.Trim()
        $ioStandard = $ioRow.Groups['standard'].Value.Trim()
        if ($ioName -eq 'M68K_BG_n') {
            if ([int]$ioRow.Groups['pin'].Value -ne 71 -or $ioRow.Groups['direction'].Value -ine 'input' -or $ioStandard -ine '3.3V Schmitt Trigger Input') { throw 'BG must fit as pin71 INPUT using 3.3V Schmitt Trigger Input; no SVF is exported.' }
            $schmittPins += $ioName
        } elseif ($ioStandard -ine '3.3-V LVTTL') {
            throw "Unexpected electrical-standard change outside BG: $ioName is $ioStandard"
        }
    }
    if ($schmittPins.Count -ne 1) { throw 'Exactly BG, and no other user pin, must use Schmitt input mode.' }
    [ordered]@{ status='PASS_BG_ONLY_SCHMITT_PIN_IMPLEMENTATION'; target='EPM240T100I5'; pin=71; direction='input'; ioStandard='3.3V Schmitt Trigger Input'; onlySchmittPort='M68K_BG_n'; userPins=56; rtlSha256=$sourceHash; guardsChanged=$false } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath 'verified-bg-schmitt.json' -Encoding UTF8


    # A separate STA script checks paths numerically; compilation success is insufficient.
    Invoke-Quartus $quartusSta @('-t','verify_timing.tcl',$projectName) 'timing-verification.log'
    if (-not (Test-Path -LiteralPath 'reports/internal-timing-passed.json' -PathType Leaf)) { throw 'Internal timing verification did not produce its success record.' }
    $critical = Get-ChildItem -LiteralPath $snapshotProject -Filter '*.log' -File | Select-String -Pattern '(?i)Critical Warning(?:\s*\(\d+\))?\s*:|Error\s*(?:\(\d+\))?\s*:'
    if ($critical) { throw 'Quartus reported an error or critical warning. No SVF is exported; inspect the logs.' }

    foreach ($sourceRecord in $sourceRecords) {
        $snapshotFile = Join-Path $snapshotRoot $sourceRecord.file
        if ((Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceRecord.sha256) { throw "Snapshot source changed during build: $($sourceRecord.file)" }
    }
    $pofPath = Join-Path $reportRoot ($projectName + '.pof')
    $pofHash = (Get-FileHash -LiteralPath $pofPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $svfPath = Join-Path $snapshotProject ($projectName + '.svf')
    # Official offline conversion only. This command cannot talk to a cable.
    Invoke-Quartus $quartusCpf @('-c','-q','100KHz','-g','3.3','-n','p',$pofPath,$svfPath) 'svf-conversion.log'
    $conversionCritical = Select-String -LiteralPath 'svf-conversion.log' -Pattern '(?i)Critical Warning(?:\s*\(\d+\))?\s*:|Error\s*(?:\(\d+\))?\s*:'
    if ($conversionCritical) { throw 'SVF conversion reported an error or critical warning; do not use its output.' }
    if ((Get-FileHash -LiteralPath $pofPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pofHash) { throw 'POF changed during conversion.' }
    if (-not (Test-Path -LiteralPath $svfPath -PathType Leaf)) { throw 'Quartus did not export an SVF.' }
    $svfText = Get-Content -LiteralPath $svfPath -Raw
    if ($svfText -notmatch '(?im)^!Device\s+#1:\s+EPM240\b' -or $svfText -notmatch '(?im)^SIR\s+' -or $svfText -notmatch '(?im)^SDR\s+') { throw 'SVF does not identify an EPM240 single-device programming sequence.' }
    [ordered]@{
        status='CANDIDATE_INTERNAL_TIMING_ONLY'; diagnostic=$true; ufmPersistent=$true; holdVariant='BRJP_OPEN_BG_SCHMITT_DIAG'; extraHoldCycles=0; historicalLongHoldAttested=$false; label='BRJP_OPEN_BG_SCHMITT_PIN_EVENT_UFM_DIAGNOSTIC'; architecture='CORRECTED_BRJP_OPEN_BASE; isolated PiStorm BR ignored; Original-control/V5-derived; native E/BG inputs; direct S7 read capture; native CPU required'; target='EPM240T100I5'; orderedPart='EPM240T100I5N'
        bgInputSchmitt=$true; bgInputSchmittOnlyPort='M68K_BG_n'; functionalRtlChanged=$false; guardsChanged=$false; glitchRejectionGuaranteed=$false
        sourceSha256=$sourceHash; native68000Required=$true; intendedRetainedCpuFix=$true; retainedCpuFixProven=$false
        nativeEInputDelayAssumption=@{maxNs=60.0;minNs=0.0;reference='M68K_CLK falling edge';cpuMaxNs=55.0;assumedUnmeasuredBoardNs=5.0}; physicalTimingBudgetMeasured=$false
        hardwareProgrammed=$false; externalInterfaceQualified=$false; pcbPinMapAssumption='historical Original QSF; published Rev B PDF differs'
        pofSha256=$pofHash; svfSha256=(Get-FileHash -LiteralPath $svfPath -Algorithm SHA256).Hash.ToLowerInvariant()
        buildSnapshot=$snapshotId; jtagFrequency='100KHz'; jtagVoltage='3.3V'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath 'candidate-manifest.json' -Encoding UTF8
    Write-Output "Candidate generated in $snapshotProject . No hardware was programmed. External interface timing remains unqualified."
} finally { Pop-Location }
