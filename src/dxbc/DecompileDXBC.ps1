
$WorkDirectory = Split-Path $MyInvocation.MyCommand.Path -Resolve -Parent

$HLSLCompiler = Join-Path $WorkDirectory "../../Tools/HLSLDecompiler/cmd_Decompiler.exe" -Resolve

$DXDCBinaryFileList = Get-Item ($WorkDirectory + "/*.txt")

Write-Output $DXDCBinaryFileList

for ($i = 0; $i -lt $DXDCBinaryFileList.Count; $i++) {
    & $HLSLCompiler -D $DXDCBinaryFileList[$i].FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Try decompile with 3Dmigoto's disassembler failed, file: " + $DXDCBinaryFileList[$i].FullName)
    }

    # & $HLSLCompiler -d $DXDCBinaryFileList[$i].FullName
    # if($LASTEXITCODE -ne 0) {
    #     Write-Error ("Try decompile with Flugan's disassembler failed, file: " + $DXDCBinaryFileList[$i].FullName)
    # }

    # & $HLSLCompiler --disassemble-ms $DXDCBinaryFileList[$i].FullName
    # if ($LASTEXITCODE -ne 0) {
    #     Write-Error ("Try decompile with MS disassembler failed, file: " + $DXDCBinaryFileList[$i].FullName)
    # }
}