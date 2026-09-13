<# Add stable source-record numbers without changing raw files or field values.
   Run from the repository root. Output is a derived import folder, not clean data. #>
[CmdletBinding()]
param(
    [string]$RawFolder = '.\data\raw',
    [string]$OutputFolder = '.\data\sql_import'
)
$ErrorActionPreference = 'Stop'
$sourceDirectory = (Resolve-Path -LiteralPath $RawFolder).Path
$destinationDirectory = [IO.Path]::GetFullPath($OutputFolder)
if ($sourceDirectory.TrimEnd('\') -eq $destinationDirectory.TrimEnd('\')) {
    throw 'OutputFolder must differ from RawFolder; raw files are immutable.'
}
[IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($table in @('customers','products','orders','order_lines','returns')) {
    # Import-Csv can trim unquoted leading spaces. Preserve them explicitly.
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new((Join-Path $sourceDirectory "$table.csv"), [Text.Encoding]::UTF8)
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true
    $parser.TrimWhiteSpace = $false
    try {
        $headers = $parser.ReadFields()
        if ($headers -contains 'source_row') { throw 'Raw inputs must not already contain source_row.' }
        # Match the Python audit: header is row 1, first data record is row 2.
        $sourceRecord = 1
        $numbered = @(while (-not $parser.EndOfData) {
            $values = $parser.ReadFields()
            if ($values.Count -ne $headers.Count) { throw "Unexpected field count in $table.csv" }
            $sourceRecord++
            $fields = [ordered]@{source_row = [string]$sourceRecord}
            for ($column = 0; $column -lt $headers.Count; $column++) {
                $fields[$headers[$column]] = $values[$column]
            }
            [pscustomobject]$fields
        })
        if ($numbered.Count -eq 0) { throw "$table.csv contains no data records." }
    } finally {
        $parser.Close()
        }
    $csvLines = @($numbered | ConvertTo-Csv -NoTypeInformation)
    # UTF-8 without BOM and LF terminators match 02_import.sql exactly.
    [IO.File]::WriteAllText((Join-Path $destinationDirectory "$table.csv"),
        ($csvLines -join [char]10) + [char]10, $utf8)
    [pscustomobject]@{Table=$table; SourceRecords=$numbered.Count; OutputFolder=$destinationDirectory}
}
