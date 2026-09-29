Add-Type -AssemblyName Microsoft.VisualBasic

# Usa automáticamente la carpeta donde está este .ps1
$folder = $PSScriptRoot

Write-Host ""
Write-Host "Procesando carpeta:"
Write-Host $folder
Write-Host ""

# ---------------------------------------------------------
# 1. BORRAR LOS ARCHIVOS QUE TERMINAN EN " L_"
#    Se mandan a la Papelera
# ---------------------------------------------------------

Get-ChildItem -LiteralPath $folder -File -Filter "*.wav" | ForEach-Object {

    if ($_.BaseName -match ' L_$') {

        Write-Host "A PAPELERA: $($_.Name)"

        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $_.FullName,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
    }
}

# ---------------------------------------------------------
# 2. QUITAR " L+" DEL NOMBRE
# ---------------------------------------------------------

Get-ChildItem -LiteralPath $folder -File -Filter "*.wav" | ForEach-Object {

    if ($_.BaseName -match ' L\+$') {

        $nuevoBase = $_.BaseName -replace ' L\+$', ''
        $nuevoNombre = $nuevoBase + $_.Extension
        $nuevoPath = Join-Path $folder $nuevoNombre

        if (Test-Path -LiteralPath $nuevoPath) {

            Write-Host "YA EXISTE, NO SE TOCA: $nuevoNombre"

        } else {

            Write-Host "RENOMBRANDO: $($_.Name) -> $nuevoNombre"
            Rename-Item -LiteralPath $_.FullName -NewName $nuevoNombre
        }
    }
}

Write-Host ""
Write-Host "======================================"
Write-Host "LISTO"
Write-Host "======================================"
Write-Host ""
Write-Host "L_  -> enviado a Papelera"
Write-Host "L+  -> eliminado del nombre"
Write-Host "C_  -> se conserva"
Write-Host ""

Read-Host "Presiona ENTER para cerrar"