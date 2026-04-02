param(
    [string]$IcarusBin = "D:\programfiles\iverilog\bin",
    [switch]$SkipCompile
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$iverilog = Join-Path $IcarusBin "iverilog.exe"
$vvp = Join-Path $IcarusBin "vvp.exe"

if (-not (Test-Path $iverilog)) {
    throw "iverilog.exe not found at $iverilog"
}

if (-not (Test-Path $vvp)) {
    throw "vvp.exe not found at $vvp"
}

$commonSources = @(
    "tb_dual_txbram_rxsd.v",
    "picorv32.v",
    "bram_memory.v",
    "spi_slave_8lane.v",
    "spi_rx_buffer.v",
    "dual_soc_mailbox.v",
    "Aes-Code\ASMD_Encryption.v",
    "Aes-Code\ControlUnit_Enryption.v",
    "Aes-Code\Datapath_Encryption.v",
    "Aes-Code\Round_Key_Update.v",
    "Aes-Code\Sub_Bytes.v",
    "Aes-Code\shift_rows.v",
    "Aes-Code\mix_cols.v",
    "Aes-Code\Register.v",
    "Aes-Code\Counter.v",
    "Aes-Code\function_g.v",
    "Aes-Code\S_BOX.v",
    "Aes-Code\Aes-Decryption\ASMD_Decryption.v",
    "Aes-Code\Aes-Decryption\ControlUnit_Decryption.v",
    "Aes-Code\Aes-Decryption\Datapath_Decryption.v",
    "Aes-Code\Aes-Decryption\Inv_Sub_Bytes.v",
    "Aes-Code\Aes-Decryption\Inv_shift_rows.v",
    "Aes-Code\Aes-Decryption\Inv_mix_cols.v",
    "Aes-Code\Aes-Decryption\inv_S_box.v"
)

$cases = @(
    @{
        Name = "normal"
        Output = "tb_dual_txbram_rxsd.vvp"
        Defines = @()
        Log = "verify_outputs\psk_normal.log"
    },
    @{
        Name = "tamper"
        Output = "tb_dual_txbram_rxsd_tamper.vvp"
        Defines = @("-P", "tb_dual_txbram_rxsd.TAMPER_RX_BLOCK_INDEX=196")
        Log = "verify_outputs\psk_tamper.log"
    },
    @{
        Name = "bad_psk"
        Output = "tb_dual_txbram_rxsd_badpsk.vvp"
        Defines = @("-P", "tb_dual_txbram_rxsd.BAD_RX_PSK=1")
        Log = "verify_outputs\psk_bad_psk.log"
    }
)

function Invoke-CheckedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

Write-Host "Regenerating BRAM images..."
Invoke-CheckedCommand -FilePath "python" -Arguments @("generate_program_dual_txbram_rxsd_hex.py")

if (-not $SkipCompile) {
    foreach ($case in $cases) {
        Write-Host "Compiling $($case.Name) case..."
        $args = @("-g2012") + $case.Defines + @("-o", $case.Output) + $commonSources
        Invoke-CheckedCommand -FilePath $iverilog -Arguments $args
    }
}

New-Item -ItemType Directory -Force -Path "verify_outputs" | Out-Null

$summaryPatterns = @(
    "TX nonce_rx=",
    "RX nonce_rx=",
    "TX Kenc:",
    "RX Kenc:",
    "TX Kmac:",
    "RX Kmac:",
    "TX K1",
    "RX K1",
    "TAG block",
    "LOC tag",
    "Mailbox aux0",
    "Key agreement mismatches",
    "^PASS:",
    "^FAIL:"
)

foreach ($case in $cases) {
    Write-Host ""
    Write-Host "Running $($case.Name) case..."
    $logPath = Join-Path $repoRoot $case.Log
    & $vvp $case.Output 2>&1 | Tee-Object -FilePath $logPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Simulation failed for case $($case.Name)"
    }

    Write-Host "Summary for $($case.Name):"
    Select-String -Path $logPath -Pattern $summaryPatterns | ForEach-Object {
        $_.Line
    }
    Write-Host "Full log: $logPath"
}
