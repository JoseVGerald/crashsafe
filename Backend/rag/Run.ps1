param([int]$Port = 8787)
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
python rag.py ingest
if ($LASTEXITCODE -ne 0) { throw "Index build failed" }
python rag.py serve --port $Port
