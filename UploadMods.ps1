<#
.SYNOPSIS
A robust script to upload large mod files to mod.io via multipart, and update mod metadata.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ConfigPath = Join-Path $PSScriptRoot "config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Host "Error: config.json not found in $ConfigPath" -ForegroundColor Red
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$Headers = @{
    "Authorization" = "Bearer $($Config.apiToken)"
}

$GameId = $Config.gameId
$ModId = $Config.modId
$BaseUrl = "https://api.mod.io/v1/games/$GameId/mods/$ModId"

function Upload-MultipartFile {
    param (
        [string]$FilePath,
        [string]$Label,
        [string]$Changelog = ""
    )

    if ([string]::IsNullOrWhiteSpace($Changelog)) {
        $Changelog = "Automated multipart upload ($Label)"
    } else {
        $Changelog = "$Changelog ($Label)"
    }

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path $FilePath)) {
        Write-Host "No valid .zip file found for $Label. Skipping." -ForegroundColor Yellow
        return $null
    }

    Write-Host "`n--- Starting Multipart Upload for $Label ---" -ForegroundColor Cyan
    Write-Host "File: $FilePath"

    # 1. Initialize Upload Session
    Write-Host "Initializing upload session..."
    $InitBody = @{
        filename = [System.IO.Path]::GetFileName($FilePath)
    }
    $InitResponse = try {
        Invoke-RestMethod -Uri "$BaseUrl/files/multipart" -Method Post -Headers $Headers -Body $InitBody -ContentType "application/x-www-form-urlencoded"
    } catch {
        Write-Host "Failed to initialize upload session. Error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $UploadId = $InitResponse.upload_id
    Write-Host "Session Created. ID: $UploadId" -ForegroundColor Green

    # 2. Upload Chunks (50MB maximum for Mod.io)
    # Using byte-level granular progress over HttpWebRequest instead of blocky Invoke-RestMethod for large files
    # Chunk size set to 50MB to strictly comply with Mod.io's multipart chunk limits
    $ChunkSize = 52428800 # 50MB
    $FileStream = [System.IO.File]::OpenRead($FilePath)
    $TotalBytes = $FileStream.Length
    $StartId = 0
    $PartNumber = 1

    try {
        while ($StartId -lt $TotalBytes) {
            $BytesToRead = [math]::Min($ChunkSize, $TotalBytes - $StartId)
            $EndId = $StartId + $BytesToRead - 1
            $RangeHeader = "bytes $StartId-$EndId/$TotalBytes"
            $ChunkUrl = "$BaseUrl/files/multipart?upload_id=$UploadId"

            $MaxRetries = 5
            $RetryCount = 0
            $ChunkSuccess = $false

            while (-not $ChunkSuccess -and $RetryCount -lt $MaxRetries) {
                # Ensure the file stream is at the correct position for this chunk (crucial for retries)
                $FileStream.Seek($StartId, [System.IO.SeekOrigin]::Begin) | Out-Null
                
                # Use raw HttpWebRequest so we can stream bytes dynamically and show granular progress
                $Request = [System.Net.HttpWebRequest]::Create($ChunkUrl)
                $Request.ServicePoint.Expect100Continue = $false
                $Request.Method = "PUT"
                $Request.Accept = "application/json"
                $Request.Headers.Add("Authorization", $Headers["Authorization"])
                $Request.Headers.Add("Content-Range", $RangeHeader)
                $Request.ContentType = "application/octet-stream"
                $Request.ContentLength = $BytesToRead
                $Request.Timeout = 10800000 
                $Request.ReadWriteTimeout = 10800000

                try {
                    $RequestStream = $Request.GetRequestStream()
                    $ReadBuffer = New-Object byte[] 65536 # 64KB mini-buffer for physical streaming
                    $ChunkBytesSent = 0

                    while ($ChunkBytesSent -lt $BytesToRead) {
                        $MiniReadSize = [math]::Min($ReadBuffer.Length, $BytesToRead - $ChunkBytesSent)
                        $Read = $FileStream.Read($ReadBuffer, 0, $MiniReadSize)
                        if ($Read -eq 0) { break }
                        
                        $RequestStream.Write($ReadBuffer, 0, $Read)
                        $ChunkBytesSent += $Read
                        
                        # --- Byte-by-byte granular progress calculation ---
                        $TotalSent = $StartId + $ChunkBytesSent
                        $PercentComplete = [math]::Min(100, [math]::Round(($TotalSent / $TotalBytes) * 100))
                        $BarLength = 40
                        $Filled = [math]::Floor(($PercentComplete / 100) * $BarLength)
                        $Empty = $BarLength - $Filled
                        $ProgressBar = "[" + ("=" * $Filled) + (" " * $Empty) + "]"
                        
                        $SentMB = [math]::Round($TotalSent / 1MB, 2)
                        $TotalMB = [math]::Round($TotalBytes / 1MB, 2)
                        
                        $RetryText = if ($RetryCount -gt 0) { " [Retry $RetryCount]" } else { "" }
                        Write-Host -NoNewline "`rUploading $($Label)$($RetryText): $ProgressBar $PercentComplete% ($SentMB / $TotalMB MB)  "
                    }
                    $RequestStream.Close()
                    
                    # Get the response to ensure Mod.io processed it successfully
                    $Response = $Request.GetResponse()
                    $Response.Close()
                    
                    $ChunkSuccess = $true
                } catch {
                    $RetryCount++
                    Write-Host "`nError uploading chunk (Attempt $RetryCount/$MaxRetries): $($_.Exception.Message)" -ForegroundColor Yellow
                    
                    if ($_.Exception.Response) {
                        try {
                            $ErrStream = $_.Exception.Response.GetResponseStream()
                            $ErrReader = New-Object System.IO.StreamReader($ErrStream)
                            $ErrBody = $ErrReader.ReadToEnd()
                            $ErrReader.Close()
                            Write-Host "Mod.io API Error Details:`n$ErrBody" -ForegroundColor Yellow
                        } catch {}
                    }
                    
                    if ($RetryCount -ge $MaxRetries) {
                        Write-Host "Max retries reached for this chunk. Aborting upload." -ForegroundColor Red
                        throw $_
                    } else {
                        $SleepSeconds = [math]::Pow(2, $RetryCount) # Exponential backoff: 2s, 4s, 8s, 16s...
                        Write-Host "Retrying in $SleepSeconds seconds..." -ForegroundColor DarkCyan
                        Start-Sleep -Seconds $SleepSeconds
                        
                        # Clear the current progress line to redraw fresh
                        Write-Host "`r                                                                                                    `r" -NoNewline
                    }
                }
            }
            
            $StartId += $BytesToRead
            $PartNumber++
        }
        Write-Host "`nAll chunks uploaded successfully." -ForegroundColor Green
    } finally {
        $FileStream.Close()
    }

    # 3. Complete Session
    Write-Host "Finalizing multipart session..."
    try {
        Invoke-RestMethod -Uri "$BaseUrl/files/multipart/complete?upload_id=$UploadId" -Method Post -Headers $Headers | Out-Null
    } catch {
        Write-Host "Failed to complete session: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    # 4. Attach to Mod as a new File
    Write-Host "Attaching file to Mod..."
    
    # Mod.io strictly expects multipart/form-data for the /files endpoint
    $Boundary = "----WebKitFormBoundary$([System.Guid]::NewGuid().ToString('N'))"
    $MultipartBody = ""
    
    $AttachFields = @{
        "upload_id" = $UploadId
        "changelog" = $Changelog
        "version"   = ""
    }
    
    foreach ($Key in $AttachFields.Keys) {
        $MultipartBody += "--$Boundary`r`n"
        $MultipartBody += "Content-Disposition: form-data; name=`"$Key`"`r`n`r`n"
        $MultipartBody += "$($AttachFields[$Key])`r`n"
    }
    $MultipartBody += "--$Boundary--`r`n"
    
    $AttachResponse = try {
        Invoke-RestMethod -Uri "$BaseUrl/files" -Method Post -Headers $Headers -Body $MultipartBody -ContentType "multipart/form-data; boundary=$Boundary"
    } catch {
        Write-Host "Failed to attach file to mod: $($_.Exception.Message)" -ForegroundColor Red
        if ($null -ne $_.Exception.Response) {
            $errResponseStream = $_.Exception.Response.GetResponseStream()
            $errReader = New-Object System.IO.StreamReader($errResponseStream)
            Write-Host "Server detail: $($errReader.ReadToEnd())" -ForegroundColor DarkRed
        }
        return $null
    }

    Write-Host "Upload Complete! New File ID: $($AttachResponse.id)" -ForegroundColor Green
    return $AttachResponse.id
}

function Get-PluginDataFromZip {
    param ([string]$ZipPath)
    if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path $ZipPath)) { return $null }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        # Just grab the first .json file we find in the zip, regardless of name
        $jsonEntry = $zip.Entries | Where-Object { $_.FullName -match '\.json$' } | Select-Object -First 1
        
        if ($null -ne $jsonEntry) {
            Write-Host "Found metadata file inside zip: $($jsonEntry.FullName)" -ForegroundColor Cyan
            try {
                $stream = $jsonEntry.Open()
                # Use stream reader with autodetection to handle potential UTF-16/UTF-8 BOMs cleanly
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                $jsonString = $reader.ReadToEnd()
                $reader.Close()
                
                $parsed = $jsonString | ConvertFrom-Json
                $zip.Dispose()
                
                if ($null -eq $parsed) {
                    Write-Host "DEBUG: ConvertFrom-Json returned null for $($jsonEntry.FullName)" -ForegroundColor Yellow
                }
                return $parsed
            } catch {
                Write-Host "Found JSON file but failed to read/parse it: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "DEBUG: No files ending in .json were found in the zip archives. Checked $($zip.Entries.Count) items." -ForegroundColor Yellow
            foreach ($e in $zip.Entries) { Write-Host "  - $($e.FullName)" -ForegroundColor DarkGray }
        }
        $zip.Dispose()
    } catch {
        Write-Host "Failed to explore zip: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $null
}

function Update-ModMetadata {
    param (
        [string]$ServerFileId,
        [string]$WindowsFileId,
        [string]$AndroidFileId,
        [string]$PluginRoot = "",
        [string[]]$ModDataPaths = @()
    )

    Write-Host "`n--- Updating Mod Metadata ---" -ForegroundColor Cyan
    Write-Host "Fetching current metadata..."

    $ModInfo = try {
        Invoke-RestMethod -Uri $BaseUrl -Method Get -Headers $Headers
    } catch {
        Write-Host "Failed to fetch mod info: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    $RawMetadata = $ModInfo.metadata_blob
    $MetadataObj = $null

    # Resilient Parsing Block
    try {
        if ([string]::IsNullOrWhiteSpace($RawMetadata)) {
            throw "Metadata is empty"
        }
        $MetadataObj = $RawMetadata | ConvertFrom-Json
        # Check if it actually parsed into an object
        if ($null -eq $MetadataObj) { throw "Parsed logic null" }
    } catch {
        Write-Host "Warning: Current metadata_blob is invalid, missing, or corrupt. Initializing a fresh metadata template." -ForegroundColor Yellow
        $MetadataObj = [PSCustomObject]@{
            serverFileId = ""
            windowsFileId = ""
            androidFileId = ""
        }
    }

    # Assign new IDs (Add properties if they somehow don't exist on the old object)
    if (-not $MetadataObj.psobject.properties.match('serverFileId').Count) { $MetadataObj | Add-Member -MemberType NoteProperty -Name "serverFileId" -Value "" }
    if (-not $MetadataObj.psobject.properties.match('windowsFileId').Count) { $MetadataObj | Add-Member -MemberType NoteProperty -Name "windowsFileId" -Value "" }
    if (-not $MetadataObj.psobject.properties.match('androidFileId').Count) { $MetadataObj | Add-Member -MemberType NoteProperty -Name "androidFileId" -Value "" }
    if (-not $MetadataObj.psobject.properties.match('pluginRoot').Count) { $MetadataObj | Add-Member -MemberType NoteProperty -Name "pluginRoot" -Value "" }
    if (-not $MetadataObj.psobject.properties.match('modDataPaths').Count) { $MetadataObj | Add-Member -MemberType NoteProperty -Name "modDataPaths" -Value @() }

    $MetadataObj.serverFileId = [string]$ServerFileId
    $MetadataObj.windowsFileId = [string]$WindowsFileId
    $MetadataObj.androidFileId = [string]$AndroidFileId
    if ([string]::IsNullOrWhiteSpace($PluginRoot) -eq $false) { $MetadataObj.pluginRoot = $PluginRoot }
    if ($null -ne $ModDataPaths -and $ModDataPaths.Count -gt 0) { $MetadataObj.modDataPaths = $ModDataPaths }

    $NewMetadataBlob = $MetadataObj | ConvertTo-Json -Compress

    Write-Host "New Metadata Blob: $NewMetadataBlob"

    # Put updated metadata back to server
    $PutBody = @{
        metadata_blob = $NewMetadataBlob
    }
    
    try {
        Invoke-RestMethod -Uri $BaseUrl -Method Put -Headers $Headers -Body $PutBody -ContentType "application/x-www-form-urlencoded" | Out-Null
        Write-Host "Metadata successfully updated!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to push new metadata: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Low-level TUI primitives (modeled on feathered-unicorns/tools/manage.ps1)
# ---------------------------------------------------------------------------

function Hide-Cursor { try { [Console]::CursorVisible = $false } catch {} }
function Show-Cursor { try { [Console]::CursorVisible = $true  } catch {} }

function Write-At($x, $y, $text, $fg = $null, $bg = $null) {
    try { [Console]::SetCursorPosition($x, $y) } catch { return }
    if ($null -ne $fg -and $null -ne $bg) { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
    elseif ($null -ne $fg)                { Write-Host $text -ForegroundColor $fg -NoNewline }
    else                                  { Write-Host $text -NoNewline }
}

function Clear-Region($x, $y, $width, $height) {
    $blank = ' ' * [Math]::Max(0, $width)
    for ($row = $y; $row -lt ($y + $height); $row++) { Write-At $x $row $blank }
}

# Read a line of text with inline editing. Returns string or $null on Esc.
function Read-Line-TUI($px, $py, $prompt, $initial = '') {
    Show-Cursor
    $buf = [System.Collections.Generic.List[char]]@()
    foreach ($c in $initial.ToCharArray()) { $buf.Add($c) }
    $cur = $buf.Count
    $w   = [Console]::WindowWidth - $px - 2

    while ($true) {
        try { [Console]::SetCursorPosition($px, $py) } catch {}
        $field   = (-join $buf)
        $display = $prompt + $field + (' ' * [Math]::Max(0, $w - $field.Length))
        Write-Host $display -NoNewline
        try { [Console]::SetCursorPosition($px + $prompt.Length + $cur, $py) } catch {}

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Enter'      { Hide-Cursor; return (-join $buf) }
            'Escape'     { Hide-Cursor; return $null }
            'Backspace'  { if ($cur -gt 0) { $cur--; $buf.RemoveAt($cur) } }
            'Delete'     { if ($cur -lt $buf.Count) { $buf.RemoveAt($cur) } }
            'LeftArrow'  { if ($cur -gt 0) { $cur-- } }
            'RightArrow' { if ($cur -lt $buf.Count) { $cur++ } }
            'Home'       { $cur = 0 }
            'End'        { $cur = $buf.Count }
            default {
                if ($k.KeyChar -ne "`0" -and $k.KeyChar -ne "`r") {
                    $buf.Insert($cur, $k.KeyChar); $cur++
                }
            }
        }
    }
}

# Arrow-key menu. Returns 0-based index or -1 on Esc.
# $headerLines: optional string[] painted above the menu (HUD).
# $itemColors: optional ConsoleColor[] aligned with $items.
function Show-Menu($title, [string[]]$items, $statusLine = '', $initialSel = 0, [string[]]$headerLines = $null, [ConsoleColor[]]$itemColors = $null) {
    Hide-Cursor
    $sel = if ($initialSel -ge 0 -and $initialSel -lt $items.Count) { $initialSel } else { 0 }
    # Skip leading separators
    while ($sel -lt $items.Count -and ($items[$sel] -like '---*' -or [string]::IsNullOrWhiteSpace($items[$sel]))) { $sel++ }
    if ($sel -ge $items.Count) { $sel = 0 }
    $top = 0

    while ($true) {
        Clear-Host
        $h = [Console]::WindowHeight
        $w = [Console]::WindowWidth - 4
        $row = 1
        if ($null -ne $headerLines) {
            foreach ($hl in $headerLines) {
                if ($row -ge $h - 4) { break }
                Write-At 2 $row $hl Yellow
                $row++
            }
            $row++
        }
        Write-At 2 $row $title Cyan
        Write-At 2 ($row + 1) ('-' * [Math]::Min($title.Length + 2, $w)) DarkCyan
        $listStart = $row + 2
        $visCount  = [Math]::Max(1, $h - $listStart - 2)

        if ($sel -lt $top) { $top = $sel }
        elseif ($sel -ge $top + $visCount) { $top = $sel - $visCount + 1 }

        for ($i = $top; $i -lt $items.Count -and ($i - $top) -lt $visCount; $i++) {
            $r     = $listStart + ($i - $top)
            $item  = $items[$i]
            $label = "   $item  "
            if ($label.Length -gt $w) { $label = $label.Substring(0, $w) }
            if ($i -eq $sel) {
                Write-At 2 $r $label Black White
            } elseif ($item -like '---*' -or [string]::IsNullOrWhiteSpace($item)) {
                Write-At 2 $r $label DarkGray
            } elseif ($item -like '+*') {
                Write-At 2 $r $label Green
            } elseif ($item -like '<*') {
                Write-At 2 $r $label DarkGray
            } else {
                $col = if ($null -ne $itemColors -and $i -lt $itemColors.Count -and $null -ne $itemColors[$i]) { $itemColors[$i] } else { [ConsoleColor]::White }
                Write-At 2 $r $label $col
            }
        }
        $fy  = [Math]::Min($listStart + $visCount, $h - 2)
        $nav = if ($items.Count -gt $visCount) { "  ($($sel + 1)/$($items.Count))  Up/Down: scroll    Enter: select    Esc: back" } else { 'Arrow keys: navigate    Enter: select    Esc: back' }
        if ($fy -ge 0 -and $fy -lt $h) { Write-At 2 $fy $nav DarkGray }
        if ($statusLine -ne '' -and ($fy + 1) -lt $h) { Write-At 2 ($fy + 1) $statusLine Yellow }

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow' {
                $orig = $sel
                do {
                    if ($sel -gt 0) { $sel-- } else { $sel = $items.Count - 1 }
                    if ($sel -eq $orig) { break }
                } while ($items[$sel] -like '---*' -or [string]::IsNullOrWhiteSpace($items[$sel]))
            }
            'DownArrow' {
                $orig = $sel
                do {
                    if ($sel -lt $items.Count - 1) { $sel++ } else { $sel = 0 }
                    if ($sel -eq $orig) { break }
                } while ($items[$sel] -like '---*' -or [string]::IsNullOrWhiteSpace($items[$sel]))
            }
            'Home'      { $sel = 0; while ($sel -lt $items.Count -and ($items[$sel] -like '---*' -or [string]::IsNullOrWhiteSpace($items[$sel]))) { $sel++ } }
            'End'       { $sel = $items.Count - 1; while ($sel -ge 0 -and ($items[$sel] -like '---*' -or [string]::IsNullOrWhiteSpace($items[$sel]))) { $sel-- } }
            'Enter'     {
                if (-not ($items[$sel] -like '---*' -or [string]::IsNullOrWhiteSpace($items[$sel]))) {
                    Show-Cursor; return $sel
                }
            }
            'Escape'    { Show-Cursor; return -1 }
        }
    }
}

# Fuzzy picker. Returns string (single), List[string] (multi), or $null on Esc.
# Type to filter, arrows to navigate, Space to toggle (multi), Enter to confirm.
function Show-Picker($title, [string[]]$items, $multiSelect = $false, [string[]]$subtexts = $null, $filterMode = 'fuzzy', [string[]]$preSelected = $null, $searchSubtexts = $true, [string[]]$headerLines = $null) {
    Hide-Cursor
    $selected = [System.Collections.Generic.List[string]]@()
    if ($multiSelect -and $null -ne $preSelected) {
        foreach ($p in $preSelected) { if ($p -ne '') { $selected.Add($p) } }
    }
    $query = ''
    $sel   = 0
    [string[]]$filtered = $items

    while ($true) {
        if ($query -eq '') {
            $filtered = $items
        } else {
            $q = $query.ToLower()
            $filtered = if ($items.Count -eq 0) { @() } else {
                @(0..($items.Count - 1) | ForEach-Object {
                    $candidate = $items[$_].ToLower()
                    if ($searchSubtexts -and $null -ne $subtexts -and $_ -lt $subtexts.Count -and $subtexts[$_] -ne '') {
                        $candidate = "$candidate $($subtexts[$_].ToLower())"
                    }
                    if ($filterMode -eq 'contains') {
                        if ($candidate.Contains($q)) { [PSCustomObject]@{ Idx = $_; Score = 1 } }
                    } else {
                        $s = $candidate; $qi = 0; $bestRun = 0; $curRun = 0; $lastPos = -2
                        for ($ci = 0; $ci -lt $s.Length; $ci++) {
                            if ($qi -lt $q.Length -and $s[$ci] -eq $q[$qi]) {
                                $curRun = if ($ci -eq $lastPos + 1) { $curRun + 1 } else { 1 }
                                if ($curRun -gt $bestRun) { $bestRun = $curRun }
                                $lastPos = $ci; $qi++
                            }
                        }
                        if ($qi -eq $q.Length) { [PSCustomObject]@{ Idx = $_; Score = $bestRun } }
                    }
                } | Where-Object { $null -ne $_ } | Sort-Object @{E='Score';D=$true},@{E={$items[$_.Idx].Length};D=$false} | ForEach-Object { $items[$_.Idx] })
            }
        }
        if ($null -eq $filtered) { $filtered = @() }
        if ($filtered.Count -eq 0) { $sel = 0 }
        elseif ($sel -ge $filtered.Count) { $sel = $filtered.Count - 1 }

        Clear-Host
        $w = [Console]::WindowWidth - 4
        $row = 1
        if ($null -ne $headerLines) {
            foreach ($hl in $headerLines) {
                Write-At 2 $row $hl Yellow
                $row++
            }
            $row++
        }
        Write-At 2 $row $title Cyan
        Write-At 2 ($row + 1) ('-' * [Math]::Min($title.Length + 2, $w)) DarkCyan
        $searchRow = $row + 2
        $searchLine = "  Search: $query"
        Write-At 2 $searchRow ($searchLine + (' ' * [Math]::Max(0, $w - $searchLine.Length))) White
        $selRow = $searchRow + 1
        if ($multiSelect -and $selected.Count -gt 0) {
            $sl = "  Selected ($($selected.Count)): " + ($selected -join ', ')
            if ($sl.Length -gt $w) { $sl = $sl.Substring(0, $w - 3) + '...' }
            Write-At 2 $selRow ($sl + (' ' * [Math]::Max(0, $w - $sl.Length))) Green
        } else {
            Clear-Region 2 $selRow $w 1
        }
        $listY  = $selRow + 1
        $maxVis = [Math]::Max(1, [Console]::WindowHeight - $listY - 3)
        if ($filtered.Count -eq 0) {
            Write-At 2 $listY ('  (no matches)' + (' ' * $w)) DarkGray
            Clear-Region 2 ($listY + 1) $w ($maxVis - 1)
        } else {
            $scrollTop = [Math]::Max(0, $sel - [Math]::Floor($maxVis / 2))
            $scrollTop = [Math]::Min($scrollTop, [Math]::Max(0, $filtered.Count - $maxVis))
            for ($vi = 0; $vi -lt $maxVis; $vi++) {
                $fi = $scrollTop + $vi
                if ($fi -ge $filtered.Count) { Clear-Region 2 ($listY + $vi) $w 1; continue }
                $item   = $filtered[$fi]
                $marker = if ($multiSelect) { if ($selected.Contains($item)) { '[x]' } else { '[ ]' } } else { '   ' }
                $label  = "  $marker $item"
                $sub    = ''
                if ($null -ne $subtexts) {
                    $origIdx = [Array]::IndexOf($items, $item)
                    if ($origIdx -ge 0 -and $origIdx -lt $subtexts.Count -and $subtexts[$origIdx] -ne '') {
                        $sub = "  $($subtexts[$origIdx])"
                    }
                }
                $totalLen = $label.Length + $sub.Length
                if ($totalLen -gt $w) {
                    if ($label.Length -ge $w) { $label = $label.Substring(0, $w - 1); $sub = '' }
                    else { $sub = $sub.Substring(0, $w - $label.Length) }
                    $totalLen = $label.Length + $sub.Length
                }
                $pad = ' ' * [Math]::Max(0, $w - $totalLen)
                if ($fi -eq $sel) {
                    Write-At 2 ($listY + $vi) ($label + $sub + $pad) Black White
                } else {
                    Write-At 2 ($listY + $vi) $label White
                    if ($sub -ne '') {
                        Write-At (2 + $label.Length) ($listY + $vi) $sub DarkGray
                    }
                    Write-At (2 + $label.Length + $sub.Length) ($listY + $vi) $pad
                }
            }
        }
        $fy = [Console]::WindowHeight - 2
        if ($multiSelect) { Write-At 2 $fy 'Type to filter   Up/Down: navigate   Space: toggle   Enter: confirm   Esc: cancel' DarkGray }
        else              { Write-At 2 $fy 'Type to filter   Up/Down: navigate   Enter: select   Esc: cancel' DarkGray }

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Escape' { Show-Cursor; return $null }
            'Enter'  {
                Show-Cursor
                if ($multiSelect) { return ,$selected }
                if ($filtered.Count -gt 0) { return $filtered[$sel] }
                return $null
            }
            'UpArrow'   { if ($sel -gt 0) { $sel-- } }
            'DownArrow' { if ($sel -lt $filtered.Count - 1) { $sel++ } }
            'Spacebar'  {
                if ($multiSelect -and $filtered.Count -gt 0) {
                    $item = $filtered[$sel]
                    if ($selected.Contains($item)) { $selected.Remove($item) | Out-Null }
                    else { $selected.Add($item) }
                }
            }
            'Backspace' {
                if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) }
                $sel = 0
            }
            default {
                $ch = $k.KeyChar
                if ($ch -ne "`0" -and $ch -ne "`r" -and $ch -ne ' ' -and $k.Key -ne 'Enter') {
                    $query += $ch; $sel = 0
                }
            }
        }
    }
}

# Show message and wait for any key
function Show-Status($msg, $color = 'Green') {
    Clear-Host
    $row = 2
    foreach ($line in (($msg -replace "`r", '') -split "`n")) {
        Write-At 2 $row $line $color
        $row++
    }
    Write-At 2 ($row + 1) 'Press any key...' DarkGray
    [Console]::ReadKey($true) | Out-Null
}

# Show a transient error line, returns immediately
function Show-Error($msg, $row = 6) {
    Write-At 2 $row (' ' * ([Console]::WindowWidth - 4))
    Write-At 2 $row $msg Red
}

# Yes/No prompt. Returns $true / $false (Esc = $false).
function Show-Confirm($title, $prompt, $defaultYes = $false) {
    $sel = Show-Menu $title @('No', 'Yes') $prompt (if ($defaultYes) { 1 } else { 0 })
    return ($sel -eq 1)
}

# Read a single field on a fresh screen. Returns string or $null on Esc.
function Read-Field($title, $prompt, $initial = '', [string[]]$headerLines = $null) {
    Hide-Cursor
    Clear-Host
    $row = 1
    if ($null -ne $headerLines) {
        foreach ($hl in $headerLines) { Write-At 2 $row $hl Yellow; $row++ }
        $row++
    }
    Write-At 2 $row $title Cyan
    Write-At 2 ($row + 1) 'Esc to cancel, Enter to confirm.' DarkGray
    return Read-Line-TUI 2 ($row + 3) $prompt $initial
}

# Stub left in place so the original main loop body can keep its skeleton until refactored
function Show-TuiMenu {
    param ([string]$Title, [string]$Subtitle, [string[]]$Options, [ConsoleColor[]]$OptionColors = $null)
    $hdr = if (-not [string]::IsNullOrWhiteSpace($Subtitle)) { (($Subtitle -replace "`r", '') -split "`n") } else { $null }
    $sel = Show-Menu $Title $Options '' 0 $hdr $OptionColors
    if ($sel -lt 0) { return '0' }
    return [string]($sel + 1)
}

function Show-TuiMultiSelect {
    param ([string]$Title, [string]$Subtitle, [string[]]$Options, [string[]]$Preselected = @())
    $hdr = if (-not [string]::IsNullOrWhiteSpace($Subtitle)) { (($Subtitle -replace "`r", '') -split "`n") } else { $null }
    $res = Show-Picker $Title $Options $true $null 'fuzzy' $Preselected $true $hdr
    if ($null -eq $res) { return @() }
    return @($res)
}

# Legacy implementations removed - replaced by Show-Menu/Show-Picker above.
function _Removed_Legacy_PlaceholderToBeDeleted {
    while ($true) {
        $winWidth = 80; $winHeight = 24; $maxLen = $winWidth - 1

        # Prepare Header completely pre-wrapped
        $headerText = @()
        $headerText += "=========================================".PadRight($maxLen, ' ').Substring(0, [math]::Min(41, $maxLen))
        $headerText += "  $Title".PadRight($maxLen, ' ').Substring(0, [math]::Min("  $Title".Length, $maxLen))
        $headerText += "=========================================".PadRight($maxLen, ' ').Substring(0, [math]::Min(41, $maxLen))
        $headerText += "".PadRight($maxLen, ' ')

        if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
            $subLines = ($Subtitle -replace "`r", "") -split "`n"
            foreach ($sl in $subLines) {
                if ($sl.Length -gt $maxLen) { $headerText += $sl.Substring(0, $maxLen) }
                else { $headerText += $sl.PadRight($maxLen, ' ') }
            }
            $headerText += "".PadRight($maxLen, ' ')
        }
        
        $headerLinesCount = $headerText.Count
        $maxMenuLines = $winHeight - $headerLinesCount - 3 # leave safety lines at bottom
        if ($maxMenuLines -lt 5) { $maxMenuLines = 5 }

        # Pre-parse options structurally so we know EXACTLY how many lines each item takes
        $ParsedOptions = @()
        foreach ($opt in $Options) {
            $optLines = @()
            $rawLines = ($opt -replace "`r", "") -split "`n"
            foreach ($rl in $rawLines) {
                if ($rl.Length -eq 0) {
                    $optLines += ""
                } else {
                    $readIdx = 0
                    while ($readIdx -lt $rl.Length) {
                        # -4 width to accommodate the active option prefix '  > '
                        $chunkLen = [math]::Min($maxLen - 4, $rl.Length - $readIdx)
                        $optLines += $rl.Substring($readIdx, $chunkLen)
                        $readIdx += $chunkLen
                    }
                }
            }
            $ParsedOptions += ,$optLines
        }

        # Dynamic array slicing to center the cursor vertically based on physical lines, not items
        $startIdx = $selectedIndex
        $endIdx = $selectedIndex
        $currentLines = $ParsedOptions[$selectedIndex].Count

        while ($startIdx -gt 0 -or $endIdx -lt ($Options.Count - 1)) {
            $canExpand = $false
            
            # Try to expand upward
            if ($startIdx -gt 0) {
                $linesNeeded = $ParsedOptions[$startIdx - 1].Count
                if ($currentLines + $linesNeeded -le $maxMenuLines) {
                    $startIdx--
                    $currentLines += $linesNeeded
                    $canExpand = $true
                }
            }
            
            # Try to expand downward
            if ($endIdx -lt ($Options.Count - 1)) {
                $linesNeeded = $ParsedOptions[$endIdx + 1].Count
                if ($currentLines + $linesNeeded -le $maxMenuLines) {
                    $endIdx++
                    $currentLines += $linesNeeded
                    $canExpand = $true
                }
            }
            
            if (-not $canExpand) { break }
        }

        # Lock rendering to row 0. We completely bypass scrolling out-of-bounds by explicitly filling the terminal buffer matrix manually.
        try { [Console]::SetCursorPosition(0, 0) } catch {}
        
        # 1. Paint Header
        Write-Host $headerText[0] -ForegroundColor Magenta
        Write-Host $headerText[1] -ForegroundColor White -BackgroundColor DarkMagenta
        Write-Host $headerText[2] -ForegroundColor Magenta
        $isHudBlock = $false
        for ($i = 3; $i -lt $headerText.Count; $i++) {
            $line = $headerText[$i]
            if ($line -match "^\s*Use Up/Down Arrows" -or $line -match "^\s*Press Enter" -or $line.Trim().Length -eq 0) {
                $isHudBlock = $false
                Write-Host $line -ForegroundColor DarkCyan
            } elseif ($line -match "^(Target Mod\s*:\s*)(.*)") {
                $isHudBlock = $true
                $matchLabel = $matches[1]
                $matchValueOriginal = $matches[2]
                $matchValue = $matchValueOriginal.TrimEnd()
                $pads = $matchValueOriginal.Substring($matchValue.Length)
                Write-Host $matchLabel -NoNewline -ForegroundColor Yellow
                Write-Host $matchValue -NoNewline -ForegroundColor Black -BackgroundColor Yellow
                Write-Host $pads
            } elseif ($line -match "(Updated|Live Files|Win|And|Svr|Changelog)\s*:|ID:") {
                $isHudBlock = $true
                Write-Host $line -ForegroundColor Yellow
            } elseif ($isHudBlock) {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line -ForegroundColor DarkCyan
            }
        }

        # 2. Paint Options
        $linesDrawnThisFrame = 0
        for ($i = $startIdx; $i -le $endIdx; $i++) {
            $lines = $ParsedOptions[$i]
            $isSel = ($i -eq $selectedIndex)
            
            for ($L = 0; $L -lt $lines.Count; $L++) {
                $pfx = if ($L -eq 0) { if ($isSel) { "  > " } else { "    " } } else { "    " }
                $str = "$pfx$($lines[$L])".PadRight($maxLen, ' ')
                
                if ($isSel) {
                    Write-Host $str -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    $itemColor = if ($null -ne $OptionColors -and $i -lt $OptionColors.Count -and $null -ne $OptionColors[$i]) { $OptionColors[$i] } else { [ConsoleColor]::Gray }
                    Write-Host $str -ForegroundColor $itemColor -BackgroundColor Black
                }
                $linesDrawnThisFrame++
            }
        }

        # 3. Paint rest of Window buffer pure black to destroy ghosting
        $blankStr = "".PadRight($maxLen, ' ')
        $totalDrawn = $headerLinesCount + $linesDrawnThisFrame
        $linesToClear = $winHeight - $totalDrawn - 1 # Stop exactly before Window bottom to prevent cascade scrolling
        if ($linesToClear -gt 0) {
            for ($c = 0; $c -lt $linesToClear; $c++) {
                Write-Host $blankStr
            }
        }

        # Wait for input
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'UpArrow') {
            do {
                $selectedIndex = ($selectedIndex - 1 + $Options.Count) % $Options.Count
            } while ($Options[$selectedIndex].StartsWith("---") -or [string]::IsNullOrWhiteSpace($Options[$selectedIndex]))
        } elseif ($key.Key -eq 'DownArrow') {
            do {
                $selectedIndex = ($selectedIndex + 1) % $Options.Count
            } while ($Options[$selectedIndex].StartsWith("---") -or [string]::IsNullOrWhiteSpace($Options[$selectedIndex]))
        } elseif ($key.Key -eq 'Enter') {
            if (-not ($Options[$selectedIndex].StartsWith("---") -or [string]::IsNullOrWhiteSpace($Options[$selectedIndex]))) {
                break
            }
        } elseif ($key.Key -eq 'Escape') {
            $selectedIndex = -1
            break
        }
    }

    try { [Console]::CursorVisible = $true } catch {}
    Clear-Host
    
    return [string]($selectedIndex + 1)
}

function _Removed_Legacy_TuiMultiSelect_PlaceholderToBeDeleted {
    param (
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Options,
        [string[]]$Preselected = @()
    )
    $selectedIndex = 0
    $selectedStates = @($false) * $Options.Count
    for ($i = 0; $i -lt $Options.Count; $i++) {
        if ($Preselected -contains $Options[$i]) {
            $selectedStates[$i] = $true
        }
    }
    
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host

    while ($true) {
        $winWidth = if ([Console]::WindowWidth -gt 10) { [Console]::WindowWidth } else { 80 }
        $winHeight = if ([Console]::WindowHeight -gt 10) { [Console]::WindowHeight } else { 24 }
        $maxLen = $winWidth - 1

        $headerText = @()
        $headerText += "=========================================".PadRight($maxLen, ' ').Substring(0, [math]::Min(41, $maxLen))
        $headerText += "  $Title".PadRight($maxLen, ' ').Substring(0, [math]::Min("  $Title".Length, $maxLen))
        $headerText += "=========================================".PadRight($maxLen, ' ').Substring(0, [math]::Min(41, $maxLen))
        $headerText += "".PadRight($maxLen, ' ')

        if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
            $subLines = ($Subtitle -replace "`r", "") -split "`n"
            foreach ($sl in $subLines) {
                if ($sl.Length -gt $maxLen) { $headerText += $sl.Substring(0, $maxLen) }
                else { $headerText += $sl.PadRight($maxLen, ' ') }
            }
            $headerText += "".PadRight($maxLen, ' ')
        }
        
        $headerLinesCount = $headerText.Count
        $maxMenuLines = $winHeight - $headerLinesCount - 3
        if ($maxMenuLines -lt 5) { $maxMenuLines = 5 }

        $ParsedOptions = @()
        foreach ($i in 0..($Options.Count - 1)) {
            $opt = $Options[$i]
            $check = if ($selectedStates[$i]) { "[X]" } else { "[ ]" }
            $optText = "$check $opt"

            $optLines = @()
            $rawLines = ($optText -replace "`r", "") -split "`n"
            foreach ($rl in $rawLines) {
                if ($rl.Length -eq 0) {
                    $optLines += ""
                } else {
                    $readIdx = 0
                    while ($readIdx -lt $rl.Length) {
                        $chunkLen = [math]::Min($maxLen - 4, $rl.Length - $readIdx)
                        $optLines += $rl.Substring($readIdx, $chunkLen)
                        $readIdx += $chunkLen
                    }
                }
            }
            $ParsedOptions += ,$optLines
        }

        $startIdx = $selectedIndex
        $endIdx = $selectedIndex
        $currentLines = $ParsedOptions[$selectedIndex].Count

        while ($startIdx -gt 0 -or $endIdx -lt ($Options.Count - 1)) {
            $canExpand = $false
            if ($startIdx -gt 0) {
                $linesNeeded = $ParsedOptions[$startIdx - 1].Count
                if ($currentLines + $linesNeeded -le $maxMenuLines) {
                    $startIdx--
                    $currentLines += $linesNeeded
                    $canExpand = $true
                }
            }
            if ($endIdx -lt ($Options.Count - 1)) {
                $linesNeeded = $ParsedOptions[$endIdx + 1].Count
                if ($currentLines + $linesNeeded -le $maxMenuLines) {
                    $endIdx++
                    $currentLines += $linesNeeded
                    $canExpand = $true
                }
            }
            if (-not $canExpand) { break }
        }

        try { [Console]::SetCursorPosition(0, 0) } catch {}
        
        Write-Host $headerText[0] -ForegroundColor Magenta
        Write-Host $headerText[1] -ForegroundColor White -BackgroundColor DarkMagenta
        Write-Host $headerText[2] -ForegroundColor Magenta
        $isHudBlock = $false
        for ($i = 3; $i -lt $headerText.Count; $i++) {
            $line = $headerText[$i]
            if ($line -match "^\s*Use Up/Down Arrows" -or $line -match "^\s*Press SPACE" -or $line -match "^\s*Press ENTER" -or $line.Trim().Length -eq 0) {
                $isHudBlock = $false
                Write-Host $line -ForegroundColor DarkCyan
            } elseif ($line -match "^(Target Mod\s*:\s*)(.*)") {
                $isHudBlock = $true
                $matchLabel = $matches[1]
                $matchValueOriginal = $matches[2]
                $matchValue = $matchValueOriginal.TrimEnd()
                $pads = $matchValueOriginal.Substring($matchValue.Length)
                Write-Host $matchLabel -NoNewline -ForegroundColor Yellow
                Write-Host $matchValue -NoNewline -ForegroundColor Black -BackgroundColor Yellow
                Write-Host $pads
            } elseif ($line -match "(Updated|Live Files|Win|And|Svr|Changelog)\s*:|ID:") {
                $isHudBlock = $true
                Write-Host $line -ForegroundColor Yellow
            } elseif ($isHudBlock) {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line -ForegroundColor DarkCyan
            }
        }

        $linesDrawnThisFrame = 0
        for ($i = $startIdx; $i -le $endIdx; $i++) {
            $lines = $ParsedOptions[$i]
            $isSel = ($i -eq $selectedIndex)
            
            for ($L = 0; $L -lt $lines.Count; $L++) {
                $pfx = if ($L -eq 0) { if ($isSel) { "  > " } else { "    " } } else { "    " }
                $str = "$pfx$($lines[$L])".PadRight($maxLen, ' ')
                
                if ($isSel) {
                    Write-Host $str -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    $itemColor = if ($selectedStates[$i]) { [ConsoleColor]::Green } else { [ConsoleColor]::Gray }
                    Write-Host $str -ForegroundColor $itemColor -BackgroundColor Black
                }
                $linesDrawnThisFrame++
            }
        }

        $blankStr = "".PadRight($maxLen, ' ')
        $totalDrawn = $headerLinesCount + $linesDrawnThisFrame
        $linesToClear = $winHeight - $totalDrawn - 1
        if ($linesToClear -gt 0) {
            for ($c = 0; $c -lt $linesToClear; $c++) {
                Write-Host $blankStr
            }
        }

        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'UpArrow') {
            $selectedIndex = ($selectedIndex - 1 + $Options.Count) % $Options.Count
        } elseif ($key.Key -eq 'DownArrow') {
            $selectedIndex = ($selectedIndex + 1) % $Options.Count
        } elseif ($key.Key -eq 'Spacebar') {
            $selectedStates[$selectedIndex] = -not $selectedStates[$selectedIndex]
        } elseif ($key.Key -eq 'Enter') {
            break
        } elseif ($key.Key -eq 'Escape') {
            $selectedStates = @($false) * $Options.Count
            break
        }
    }

    try { [Console]::CursorVisible = $true } catch {}
    Clear-Host
    
    $selectedResults = @()
    for ($i = 0; $i -lt $Options.Count; $i++) {
        if ($selectedStates[$i]) {
            $selectedResults += $Options[$i]
        }
    }
    
    return $selectedResults
}

function Get-ZipBySuffix($Suffix) {
    $FoundFile = Get-ChildItem -Path $PSScriptRoot -Filter "*_${Suffix}.zip" | Select-Object -First 1
    if ($FoundFile) { return $FoundFile.FullName }
    return $null
}

function Resolve-PluginDataWithConfig {
    param (
        [PSCustomObject]$ExtractedData
    )

    if ($null -ne $ExtractedData -and -not [string]::IsNullOrWhiteSpace($ExtractedData.pluginRoot)) {
        return @{
            pluginRoot = $ExtractedData.pluginRoot
            modDataPaths = @($ExtractedData.modDataPaths)
        }
    }
    
    Write-Host "No valid extraction data found." -ForegroundColor Yellow
    return @{
        pluginRoot = ""
        modDataPaths = @()
    }
}

function New-ModIoMod {
    param (
        [string]$Name,
        [string]$Summary,
        [string[]]$Tags,
        [string]$LogoPath
    )

    Write-Host "`n--- Creating New Mod on Mod.io ---" -ForegroundColor Cyan

    $Boundary = "----WebKitFormBoundary$([System.Guid]::NewGuid().ToString('N'))"
    $MultipartBody = ""

    # Attach required logo first
    $LogoBytes = [System.IO.File]::ReadAllBytes($LogoPath)
    $LogoContent = [System.Text.Encoding]::GetEncoding("iso-8859-1").GetString($LogoBytes)

    $MultipartBody += "--$Boundary`r`n"
    $MultipartBody += "Content-Disposition: form-data; name=`"logo`"; filename=`"$([System.IO.Path]::GetFileName($LogoPath))`"`r`n"
    $MultipartBody += "Content-Type: image/png`r`n`r`n"
    $MultipartBody += "$LogoContent`r`n"

    $Fields = @{
        "name" = $Name
        "summary" = $Summary
        "visible" = "1"
        "metadata_blob" = "{ `"serverFileId`": `"`", `"windowsFileId`": `"`", `"androidFileId`": `"`" }"
    }

    foreach ($Key in $Fields.Keys) {
        $MultipartBody += "--$Boundary`r`n"
        $MultipartBody += "Content-Disposition: form-data; name=`"$Key`"`r`n`r`n"
        $MultipartBody += "$($Fields[$Key])`r`n"
    }

    foreach ($Tag in $Tags) {
        $MultipartBody += "--$Boundary`r`n"
        $MultipartBody += "Content-Disposition: form-data; name=`"tags[]`"`r`n`r`n"
        $MultipartBody += "$Tag`r`n"
    }

    $MultipartBody += "--$Boundary--`r`n"

    try {
        # Using iso-8859-1 encoding ensures raw byte values are maintained through the string conversion
        $Bytes = [System.Text.Encoding]::GetEncoding("iso-8859-1").GetBytes($MultipartBody)
        $CreateResponse = Invoke-RestMethod -Uri "https://api.mod.io/v1/games/$GameId/mods" -Method Post -Headers $Headers -Body $Bytes -ContentType "multipart/form-data; boundary=$Boundary"
        
        Write-Host "Mod successfully created! ID: $($CreateResponse.id)" -ForegroundColor Green
        return [string]$CreateResponse.id
    } catch {
        Write-Host "Failed to create mod: $($_.Exception.Message)" -ForegroundColor Red
        if ($null -ne $_.Exception.Response) {
            try {
                $errStream = $_.Exception.Response.GetResponseStream()
                $errReader = New-Object System.IO.StreamReader($errStream)
                Write-Host "Verbose error: $($errReader.ReadToEnd())" -ForegroundColor DarkRed
                $errReader.Close()
            } catch {}
        }
        return $null
    }
}

# --- Main Menu UI ---
while ($true) {
    Clear-Host
    Write-Host "Fetching live Mod.io metadata..." -ForegroundColor Cyan
    
    $ModInfo = try { Invoke-RestMethod -Uri $BaseUrl -Method Get -Headers $Headers } catch { $null }
    
    $HeadsUp = ""
    if ($null -ne $ModInfo) {
        $modUpdated = if ($null -ne $ModInfo.date_updated) { (Get-Date "1970-01-01T00:00:00Z").AddSeconds($ModInfo.date_updated).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
        $HeadsUp += "Target Mod : $($ModInfo.name)`n"
        $HeadsUp += "Updated    : $modUpdated`n"
        
        $TargetFileId = $null
        if (-not [string]::IsNullOrWhiteSpace($ModInfo.metadata_blob)) {
            try {
                $ParsedData = $ModInfo.metadata_blob | ConvertFrom-Json
                $svId = if (-not [string]::IsNullOrWhiteSpace($ParsedData.serverFileId)) { $ParsedData.serverFileId } else { "None" }
                $pcId = if (-not [string]::IsNullOrWhiteSpace($ParsedData.windowsFileId)) { $ParsedData.windowsFileId } else { "None" }
                $anId = if (-not [string]::IsNullOrWhiteSpace($ParsedData.androidFileId)) { $ParsedData.androidFileId } else { "None" }
                
                $ValidIds = @($pcId, $anId, $svId) | Where-Object { $_ -ne "None" -and -not [string]::IsNullOrWhiteSpace($_) }
                $FileCache = @{}
                if ($ValidIds.Count -gt 0) {
                    $idStr = $ValidIds -join ','
                    $LiveFilesRes = try { Invoke-RestMethod -Uri "$BaseUrl/files?id-in=$idStr" -Method Get -Headers $Headers } catch { $null }
                    if ($null -ne $LiveFilesRes -and $null -ne $LiveFilesRes.data) {
                        foreach ($f in $LiveFilesRes.data) { $FileCache[[string]$f.id] = $f.filename }
                    }
                }

                $pcName = if ($pcId -ne "None" -and $FileCache.ContainsKey($pcId)) { $FileCache[$pcId] } elseif ($pcId -ne "None") { "Unknown" } else { "None" }
                $anName = if ($anId -ne "None" -and $FileCache.ContainsKey($anId)) { $FileCache[$anId] } elseif ($anId -ne "None") { "Unknown" } else { "None" }
                $svName = if ($svId -ne "None" -and $FileCache.ContainsKey($svId)) { $FileCache[$svId] } elseif ($svId -ne "None") { "Unknown" } else { "None" }

                $HeadsUp += "Live Files :`n"
                $HeadsUp += "        Win : $pcName ($pcId)`n"
                $HeadsUp += "        And : $anName ($anId)`n"
                $HeadsUp += "        Svr : $svName ($svId)`n"
                
                if ($pcId -ne "None") { $TargetFileId = $pcId }
                elseif ($svId -ne "None") { $TargetFileId = $svId }
                elseif ($anId -ne "None") { $TargetFileId = $anId }
            } catch {}
        } else {
            $HeadsUp += "Live Files : No metadata_blob found.`n"
        }

        $cLogStr = "None"
        if ($null -ne $TargetFileId) {
            $TargetFileInfo = try { Invoke-RestMethod -Uri "$BaseUrl/files/$TargetFileId" -Method Get -Headers $Headers } catch { $null }
            if ($null -ne $TargetFileInfo -and -not [string]::IsNullOrWhiteSpace($TargetFileInfo.changelog)) {
                $cLogStr = $TargetFileInfo.changelog
            }
        }
        if ($cLogStr -eq "None" -and $null -ne $ModInfo.modfile -and -not [string]::IsNullOrWhiteSpace($ModInfo.modfile.changelog)) {
            $cLogStr = $ModInfo.modfile.changelog
        }

        $cLogStr = $cLogStr -replace " \((Server|Windows|Android|Metadata)\)$", ""
        $cLogLines = ($cLogStr -replace "`r", "") -split "`n"
        $HeadsUp += "Changelog  : $($cLogLines[0])`n"
        for ($i = 1; $i -lt $cLogLines.Count; $i++) {
            $HeadsUp += "             $($cLogLines[$i])`n"
        }
    } else {
        $HeadsUp += "Target Mod : <Failed to retrieve data>`n"
    }

    $MenuTitle = "Mod.io Multipart Uploader"
    $MenuSubtitle = "$HeadsUp`nUse Up/Down Arrows to navigate. Press Enter to select."
    $MenuOptions = @(
        "Upload Mod (Uploads Windows, Android, Server ZIPs)",
        "Rollback / Update Metadata Only (View past releases & restore)",
        "",
        "Switch Mod",
        "Create Mod",
        "Edit Mod",
        "Open in Mod.io",
        "",
        "Exit"
    )

    $Choice = Show-TuiMenu -Title $MenuTitle -Subtitle $MenuSubtitle -Options $MenuOptions

    if ($Choice -eq "9" -or $Choice -eq "0") {
        Write-Host "Exiting." -ForegroundColor Cyan
        exit 0
    }

if ($Choice -eq "1") {
    $TargetModName = if ($null -ne $ModInfo -and -not [string]::IsNullOrWhiteSpace($ModInfo.name)) { $ModInfo.name } else { "<Unknown Mod>" }

    $ServerZip = Get-ZipBySuffix "server"
    $WindowsZip = Get-ZipBySuffix "pc"
    $AndroidZip = Get-ZipBySuffix "android"

    # Present found files to the user before uploading
    $FoundCount = 0
    $FoundItems = @()
    if ($WindowsZip) { $FoundItems += "Windows: $(Split-Path $WindowsZip -Leaf)"; $FoundCount++ } else { $FoundItems += "Windows: [Not Found]" }
    if ($AndroidZip) { $FoundItems += "Android: $(Split-Path $AndroidZip -Leaf)"; $FoundCount++ } else { $FoundItems += "Android: [Not Found]" }
    if ($ServerZip) { $FoundItems += "Server: $(Split-Path $ServerZip -Leaf)"; $FoundCount++ } else { $FoundItems += "Server: [Not Found]" }

    if ($FoundCount -eq 0) {
        $UploadMenuSubtitle = "Target Mod: $TargetModName (ID: $ModId)`n`nCRITICAL: No mod ZIP files found in the current directory! `n`nSearched for:`n  *_pc.zip (or *_windows.zip)`n  *_android.zip`n  *_server.zip"
        $UploadOptions = @("Go Back")
    } else {
        $UploadMenuSubtitle = "Target Mod: $TargetModName (ID: $ModId)`n`nFound the following resources:`n  $($FoundItems -join "`n  ")"
        $UploadOptions = @("Proceed with Upload", "Cancel")
    }
    
    $UploadChoice = Show-TuiMenu -Title "Review Pending Uploads" -Subtitle $UploadMenuSubtitle -Options $UploadOptions

    if ($FoundCount -eq 0 -or $UploadChoice -ne "1") {
        Show-Status 'Upload cancelled.' Yellow
        continue
    }

    $GlobalChangelog = Read-Field 'Mod.io Release Configuration' 'Changelog (optional, blank for none): ' ''
    if ($null -eq $GlobalChangelog) { Show-Status 'Upload cancelled.' Yellow; continue }

    Clear-Host
    Write-Host "--- Starting Uploads ---" -ForegroundColor Cyan

    $WindowsId = Upload-MultipartFile -FilePath $WindowsZip -Label "Windows" -Changelog $GlobalChangelog
    $AndroidId = Upload-MultipartFile -FilePath $AndroidZip -Label "Android" -Changelog $GlobalChangelog
    $ServerId = Upload-MultipartFile -FilePath $ServerZip -Label "Server" -Changelog $GlobalChangelog

    # Use fallbacks if an upload skipped/failed to ensure we don't wipe out the record entirely
    # We query the remote Mod.io since local config fallbacks have been removed
    $CurrentModInfo = try { Invoke-RestMethod -Uri $BaseUrl -Method Get -Headers $Headers } catch { $null }
    $CurrentMetadata = if ($null -ne $CurrentModInfo -and -not [string]::IsNullOrWhiteSpace($CurrentModInfo.metadata_blob)) { $CurrentModInfo.metadata_blob | ConvertFrom-Json } else { $null }

    if ($null -eq $ServerId -and $null -ne $CurrentMetadata) { $ServerId = $CurrentMetadata.serverFileId }
    if ($null -eq $WindowsId -and $null -ne $CurrentMetadata) { $WindowsId = $CurrentMetadata.windowsFileId }
    if ($null -eq $AndroidId -and $null -ne $CurrentMetadata) { $AndroidId = $CurrentMetadata.androidFileId }

    # Try extracting plugin root and data from the Windows zip mainly, or whichever is available
    $PluginData = Get-PluginDataFromZip $WindowsZip
    if ($null -eq $PluginData) { $PluginData = Get-PluginDataFromZip $ServerZip }
    if ($null -eq $PluginData) { $PluginData = Get-PluginDataFromZip $AndroidZip }

    $ResolvedPluginData = Resolve-PluginDataWithConfig -ExtractedData $PluginData
    $PluginRootVal = $ResolvedPluginData.pluginRoot
    $ModDataPathsVal = $ResolvedPluginData.modDataPaths

    Update-ModMetadata -ServerFileId $ServerId -WindowsFileId $WindowsId -AndroidFileId $AndroidId -PluginRoot $PluginRootVal -ModDataPaths $ModDataPathsVal

} elseif ($Choice -eq "2") {
    Write-Host "`n--- Interactive Mod Rollback ---" -ForegroundColor Cyan
    Write-Host "Fetching past uploads from Mod.io..."
    
    $FilesRes = try {
        Invoke-RestMethod -Uri "$BaseUrl/files?_sort=-date_added&_limit=100" -Method Get -Headers $Headers
    } catch {
        Write-Host "Failed to fetch files from Mod.io: $($_.Exception.Message)" -ForegroundColor Red
        $FilesRes = $null
    }

    if ($null -ne $FilesRes -and $null -ne $FilesRes.data) {
        $AllFiles = $FilesRes.data | Sort-Object date_added -Descending

        if ($AllFiles.Count -eq 0) {
            Write-Host "No files found on Mod.io to rollback to." -ForegroundColor Yellow
        } else {
            $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

            # Helper to generate options based on context
            $GetFilteredMenu = {
                param ([string]$Platform, [int]$AnchorTime, [string[]]$ExcludeIds)
                $fOpts = @()
                $fObjs = @()
                $fCols = @()
                
                foreach ($f in $AllFiles) {
                    $fid = [string]$f.id
                    if ($null -ne $ExcludeIds -and $ExcludeIds -contains $fid) { continue }

                    $fname = if ($null -ne $f.filename) { $f.filename.ToLower() } else { "" }
                    
                    if ($fname -match "^release_metadata(\.\d+)?\.zip$") { continue }
                    
                    # Exclude clearly foreign platform files but keep generic ones
                    if ($Platform -eq "Windows" -and ($fname -match "_android(\.\d+)?\.zip$" -or $fname -match "_server(\.\d+)?\.zip$")) { continue }
                    if ($Platform -eq "Server" -and ($fname -match "_android(\.\d+)?\.zip$" -or $fname -match "(_pc|_windows)(\.\d+)?\.zip$")) { continue }
                    if ($Platform -eq "Android" -and ($fname -match "_server(\.\d+)?\.zip$" -or $fname -match "(_pc|_windows)(\.\d+)?\.zip$")) { continue }
                    
                    # 24-hour anchor limit from first picked file
                    if ($AnchorTime -gt 0 -and [math]::Abs($f.date_added - $AnchorTime) -gt 86400) { continue }
                    
                    $dateStr = (Get-Date "1970-01-01T00:00:00Z").AddSeconds($f.date_added).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
                    $dispName = if ($null -ne $f.filename) { $f.filename } else { "Unknown" }
                    $fSizeMB = [math]::Round($f.filesize / 1MB, 2)
                    $cLog = if (-not [string]::IsNullOrWhiteSpace($f.changelog)) { " | $($f.changelog)" } else { "" }
                    
                    $fOpts += "[$dateStr] $dispName (${fSizeMB}MB)$cLog"
                    $fObjs += $f
                    
                    if ($AnchorTime -gt 0) {
                        # Increase sensitivity: highlight only within 1 hour (3600 seconds) of anchor time
                        $diffSeconds = [math]::Abs($f.date_added - $AnchorTime)
                        if ($diffSeconds -le 3600) { $fCols += [ConsoleColor]::White }
                        else { $fCols += [ConsoleColor]::DarkGray }
                    } else {
                        $ageSeconds = $nowUnix - $f.date_added
                        if ($ageSeconds -lt 86400) { $fCols += [ConsoleColor]::White }
                        elseif ($ageSeconds -lt 604800) { $fCols += [ConsoleColor]::Gray }
                        else { $fCols += [ConsoleColor]::DarkGray }
                    }
                }
                
                return @{
                    Options = @("Cancel Rollback", "Skip / None (Leave Empty)") + $fOpts
                    Colors  = @([ConsoleColor]::Red, [ConsoleColor]::DarkYellow) + $fCols
                    Objects = $fObjs
                }
            }
            
            $Confirmed = $false
            $Cancelled = $false
            while (-not $Confirmed -and -not $Cancelled) {
                $AnchorTime = 0
                $ExcIds = @()

                # Prompt for Windows File
                $WinMenu = &$GetFilteredMenu -Platform "Windows" -AnchorTime $AnchorTime -ExcludeIds $ExcIds
                $WinChoice = Show-TuiMenu -Title "Rollback: Select Windows File" -Subtitle "Pick the Mod.io file to assign to the Windows (PC) platform." -Options $WinMenu.Options -OptionColors $WinMenu.Colors
                if ($WinChoice -eq "0" -or $WinChoice -eq "1") { 
                    $Cancelled = $true
                    break 
                }
                $SelWindows = if ($WinChoice -eq "2") { $null } else { $WinMenu.Objects[[int]$WinChoice - 3] }
                if ($null -ne $SelWindows) {
                    if ($AnchorTime -eq 0) { $AnchorTime = $SelWindows.date_added }
                    $ExcIds += [string]$SelWindows.id
                }

                # Prompt for Android File
                $AndMenu = &$GetFilteredMenu -Platform "Android" -AnchorTime $AnchorTime -ExcludeIds $ExcIds
                $AndChoice = Show-TuiMenu -Title "Rollback: Select Android File" -Subtitle "Pick the Mod.io file to assign to the Android platform." -Options $AndMenu.Options -OptionColors $AndMenu.Colors
                if ($AndChoice -eq "0" -or $AndChoice -eq "1") { 
                    $Cancelled = $true
                    break 
                }
                $SelAndroid = if ($AndChoice -eq "2") { $null } else { $AndMenu.Objects[[int]$AndChoice - 3] }
                if ($null -ne $SelAndroid) {
                    if ($AnchorTime -eq 0) { $AnchorTime = $SelAndroid.date_added }
                    $ExcIds += [string]$SelAndroid.id
                }

                # Prompt for Server File
                $SvrMenu = &$GetFilteredMenu -Platform "Server" -AnchorTime $AnchorTime -ExcludeIds $ExcIds
                $SvrChoice = Show-TuiMenu -Title "Rollback: Select Server File" -Subtitle "Pick the Mod.io file to assign to the Server platform." -Options $SvrMenu.Options -OptionColors $SvrMenu.Colors
                if ($SvrChoice -eq "0" -or $SvrChoice -eq "1") { 
                    $Cancelled = $true
                    break 
                }
                $SelServer = if ($SvrChoice -eq "2") { $null } else { $SvrMenu.Objects[[int]$SvrChoice - 3] }
                if ($null -ne $SelServer) {
                    if ($AnchorTime -eq 0) { $AnchorTime = $SelServer.date_added }
                    $ExcIds += [string]$SelServer.id
                }

                $SelWindowsId = if ($null -ne $SelWindows) { [string]$SelWindows.id } else { "" }
                $SelServerId  = if ($null -ne $SelServer)  { [string]$SelServer.id  } else { "" }
                $SelAndroidId = if ($null -ne $SelAndroid) { [string]$SelAndroid.id } else { "" }

                $ConfirmOptions = @(
                    "Cancel Rollback",
                    "Proceed with these selections",
                    "Revise selections (Start Over)"
                )
                
                $GetFileInfo = {
                    param ($f)
                    if ($null -eq $f) { return "None" }
                    $dateStr = (Get-Date "1970-01-01T00:00:00Z").AddSeconds($f.date_added).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
                    $fName = if ($null -ne $f.filename) { $f.filename } else { "Unknown" }
                    $cLog = if (-not [string]::IsNullOrWhiteSpace($f.changelog)) { " | $($f.changelog)" } else { "" }
                    return "$fName [$dateStr]$cLog"
                }
                
                $ConfirmSub = "Review your target files:`n"
                $ConfirmSub += "  Windows : $(&$GetFileInfo $SelWindows)`n"
                $ConfirmSub += "  Android : $(&$GetFileInfo $SelAndroid)`n"
                $ConfirmSub += "  Server  : $(&$GetFileInfo $SelServer)"
                
                $ConfirmChoice = Show-TuiMenu -Title "Rollback: Confirm Selections" -Subtitle $ConfirmSub -Options $ConfirmOptions
                
                if ($ConfirmChoice -eq "2") {
                    $Confirmed = $true
                } elseif ($ConfirmChoice -eq "3") {
                    continue
                } else {
                    $Cancelled = $true
                    break
                }
            }

            if ($Cancelled) {
                Show-Status 'Rollback cancelled.' Yellow
                continue
            }

            if ([string]::IsNullOrWhiteSpace($SelWindowsId) -and [string]::IsNullOrWhiteSpace($SelServerId) -and [string]::IsNullOrWhiteSpace($SelAndroidId)) {
                Show-Status 'No files selected to rollback. Aborting.' Yellow
                continue
            }

            Write-Host "`nSelected Release Targets:" -ForegroundColor Cyan
            Write-Host "  Windows : $(if($SelWindows){$SelWindows.filename + ' (' + $SelWindowsId + ')'}else{'None'})"
            Write-Host "  Android : $(if($SelAndroid){$SelAndroid.filename + ' (' + $SelAndroidId + ')'}else{'None'})"
            Write-Host "  Server  : $(if($SelServer){$SelServer.filename + ' (' + $SelServerId + ')'}else{'None'})"

            $PluginRootVal = ""
            $ModDataPathsVal = @()
            $MetadataLoaded = $false

            # Always try extracting the structural info directly from the old uploaded zips first when rolling back
            $FallbackZips = @()
            if ($null -ne $SelAndroid) { $FallbackZips += @{ Name = "Android"; FileObj = $SelAndroid } }
            if ($null -ne $SelServer) { $FallbackZips += @{ Name = "Server"; FileObj = $SelServer } }
            if ($null -ne $SelWindows) { $FallbackZips += @{ Name = "Windows"; FileObj = $SelWindows } }

            foreach ($fb in $FallbackZips) {
                if ($MetadataLoaded) { break }
                
                $fObj = $fb.FileObj
                if ($null -ne $fObj -and -not [string]::IsNullOrWhiteSpace($fObj.download.binary_url)) {
                    Write-Host "Downloading the $($fb.Name) zip to extract plugin.json for metadata recovery..." -ForegroundColor Cyan
                    try {
                        $dlUrl = $fObj.download.binary_url
                        $DlDestZip = Join-Path $PSScriptRoot "downloaded_$($fb.Name.ToLower())_meta.zip"
                            
                            $oldProgress = $ProgressPreference
                            $ProgressPreference = 'SilentlyContinue'
                            Invoke-RestMethod -Uri $dlUrl -OutFile $DlDestZip -UseBasicParsing
                            $ProgressPreference = $oldProgress
                            
                            Start-Sleep -Seconds 2
                            
                            if (Test-Path $DlDestZip) {
                                $PluginData = Get-PluginDataFromZip -ZipPath $DlDestZip
                                if ($null -ne $PluginData -and ($null -ne $PluginData.pluginRoot -or $null -ne $PluginData.modDataPaths)) {
                                    if (-not [string]::IsNullOrWhiteSpace($PluginData.pluginRoot)) { $PluginRootVal = [string]$PluginData.pluginRoot }
                                    if ($null -ne $PluginData.modDataPaths) { $ModDataPathsVal = @($PluginData.modDataPaths) }
                                    Write-Host "Successfully loaded metadata from extracted $($fb.Name) zip!" -ForegroundColor Green
                                    $MetadataLoaded = $true
                                }
                                Remove-Item $DlDestZip -ErrorAction SilentlyContinue
                            }
                        } catch {
                            Write-Host "Failed to extract from $($fb.Name) zip (Error: $($_.Exception.Message))" -ForegroundColor Red
                        }
                    }
                }

            # Validate metadata data before rolling back
            $MissingData = @()
            if ([string]::IsNullOrWhiteSpace($SelServerId)) { $MissingData += "Server File ID" }
            if ([string]::IsNullOrWhiteSpace($SelWindowsId)) { $MissingData += "Windows File ID" }
            if ([string]::IsNullOrWhiteSpace($SelAndroidId)) { $MissingData += "Android File ID" }
            
            $MissingPluginData = $false
            if ([string]::IsNullOrWhiteSpace($PluginRootVal)) { $MissingPluginData = $true }
            if ($null -eq $ModDataPathsVal -or $ModDataPathsVal.Count -eq 0) { $MissingPluginData = $true }
            
            if ($MissingPluginData) {
                Show-Status "CRITICAL ERROR: pluginRoot or modDataPaths could not be resolved.`nA valid existing Mod.io record or successful zip extraction is required.`nRollback cancelled." Red
                continue
            }

            if ($MissingData.Count -gt 0) {
                Write-Host ""
                Write-Host "WARNING: The following platforms will be left empty/missing on Mod.io:" -ForegroundColor Red
                foreach ($item in $MissingData) {
                    Write-Host "  - $item" -ForegroundColor Red
                }
                $missingMsg = "Missing platform IDs: $($MissingData -join ', ')"
                if (-not (Show-Confirm 'Rollback: Confirm Incomplete Data' "$missingMsg`nProceed anyway?" $false)) {
                    Show-Status 'Rollback cancelled by user.' Yellow
                    continue
                }
            }

            # Push updated metadata to Mod.io
            Update-ModMetadata -ServerFileId $SelServerId -WindowsFileId $SelWindowsId -AndroidFileId $SelAndroidId -PluginRoot $PluginRootVal -ModDataPaths $ModDataPathsVal
        }
    }
} elseif ($Choice -eq "4") {
    Write-Host "`nFetching your mods from Mod.io..." -ForegroundColor Cyan
    $MyModsRes = try {
        Invoke-RestMethod -Uri "https://api.mod.io/v1/me/mods?game_id=$GameId&_sort=-date_updated&_limit=100" -Method Get -Headers $Headers
    } catch {
        Write-Host "Failed to fetch your mods: $($_.Exception.Message)" -ForegroundColor Red
        $null
    }

    if ($null -ne $MyModsRes -and $null -ne $MyModsRes.data -and $MyModsRes.data.Count -gt 0) {
        $ModObjs = $MyModsRes.data
        $items = @($ModObjs | ForEach-Object { $_.name })
        $subs  = @($ModObjs | ForEach-Object {
            $upd = if ($null -ne $_.date_updated) { (Get-Date '1970-01-01T00:00:00Z').AddSeconds($_.date_updated).ToLocalTime().ToString('yyyy-MM-dd') } else { '?' }
            "[$($_.id)]  updated $upd"
        })
        $picked = Show-Picker 'Select Target Mod' $items $false $subs 'fuzzy' $null $true @('Pick a mod to manage. Saved to config.json.')
        if ($null -ne $picked) {
            $idx = [Array]::IndexOf($items, $picked)
            $SelectedMod = $ModObjs[$idx]
            $Config.modId = [string]$SelectedMod.id
            $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath
            $ModId = $Config.modId
            $BaseUrl = "https://api.mod.io/v1/games/$GameId/mods/$ModId"
            Show-Status "Switched target mod to: $($SelectedMod.name) ($($SelectedMod.id))" Green
            continue
        } else {
            Show-Status 'Mod selection cancelled.' Yellow
            continue
        }
    } else {
        Show-Status 'No mods found for this game, or failed to fetch.' Yellow
        continue
    }
} elseif ($Choice -eq "5") {
    $NewModName = Read-Field 'Create New Mod' 'Name: ' ''
    if ($null -eq $NewModName) { Show-Status 'Mod creation cancelled.' Yellow; continue }
    $NewModSummary = Read-Field 'Create New Mod' 'Summary: ' '' @("Name: $NewModName")
    if ($null -eq $NewModSummary) { Show-Status 'Mod creation cancelled.' Yellow; continue }

    if ([string]::IsNullOrWhiteSpace($NewModName) -or [string]::IsNullOrWhiteSpace($NewModSummary)) {
        Show-Status 'Name and Summary are required. Aborting mod creation.' Red
        continue
    }

    $AvailableTags = @("Loadout", "Windows", "Android", "Server", "Map", "CustomMode")
    $TagSelectionSubtitle = "Select tags for the new mod.`nUse Up/Down Arrows to navigate.`nPress SPACE to toggle selection.`nPress ENTER to submit."
    $SelectedTags = Show-TuiMultiSelect -Title "Select Mod Tags" -Subtitle $TagSelectionSubtitle -Options $AvailableTags

    $LogoFile = Get-ChildItem -Path $PSScriptRoot -Filter "*.png" | Select-Object -First 1
    if (-not $LogoFile) {
        Show-Status 'Error: No .png file found in the current directory to use as a logo. A logo is required by Mod.io.' Red
        continue
    }

    $NewModId = New-ModIoMod -Name $NewModName -Summary $NewModSummary -Tags $SelectedTags -LogoPath $LogoFile.FullName

    if ($null -ne $NewModId) {
        $Config.modId = $NewModId
        $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath
        $ModId = $Config.modId
        $BaseUrl = "https://api.mod.io/v1/games/$GameId/mods/$ModId"
        Show-Status "Target mod set to new mod (ID: $NewModId)." Green
        continue
    }
} elseif ($Choice -eq "6") {
    while ($true) {
        Write-Host "`nFetching current mod details..." -ForegroundColor Cyan
        $CurrentModInfo = try { Invoke-RestMethod -Uri $BaseUrl -Method Get -Headers $Headers } catch { $null }
        
        if ($null -eq $CurrentModInfo) {
            Show-Status 'Failed to fetch mod info. Ensure the Target Mod exists.' Red
            break
        }
        
        $CurrentTagsObj = $CurrentModInfo.tags | Sort-Object name
        $CurrentTagsStr = if ($null -ne $CurrentTagsObj -and $CurrentTagsObj.Count -gt 0) { ($CurrentTagsObj.name -join ', ') } else { "None" }

        $EditOpts = @(
            "Name    : $($CurrentModInfo.name)",
            "Summary : $($CurrentModInfo.summary)",
            "Tags    : $CurrentTagsStr",
            "Logo    : Update from first .png in folder",
            "Go Back"
        )
        
        $EditSub = "Editing Mod ID: $ModId`nUse Up/Down Arrows to navigate. Press Enter to select."
        $EditChoice = Show-TuiMenu -Title "Edit Mod Details" -Subtitle $EditSub -Options $EditOpts
        
        if ($EditChoice -eq "5" -or $EditChoice -eq "0") {
            break
        }

        if ($EditChoice -eq "1") {
            $NewName = Read-Field 'Edit Name' 'Name: ' $CurrentModInfo.name
            if ($null -ne $NewName -and -not [string]::IsNullOrWhiteSpace($NewName) -and $NewName -ne $CurrentModInfo.name) {
                try {
                    $BodyData = "name=$([uri]::EscapeDataString($NewName))"
                    Invoke-RestMethod -Uri $BaseUrl -Method Put -Headers $Headers -Body $BodyData -ContentType 'application/x-www-form-urlencoded' | Out-Null
                    Show-Status 'Name updated successfully!' Green
                } catch { Show-Status "Failed to update Name: $($_.Exception.Message)" Red }
            }
        } elseif ($EditChoice -eq "2") {
            $NewSummary = Read-Field 'Edit Summary' 'Summary: ' $CurrentModInfo.summary
            if ($null -ne $NewSummary -and -not [string]::IsNullOrWhiteSpace($NewSummary) -and $NewSummary -ne $CurrentModInfo.summary) {
                try {
                    $BodyData = "summary=$([uri]::EscapeDataString($NewSummary))"
                    Invoke-RestMethod -Uri $BaseUrl -Method Put -Headers $Headers -Body $BodyData -ContentType 'application/x-www-form-urlencoded' | Out-Null
                    Show-Status 'Summary updated successfully!' Green
                } catch { Show-Status "Failed to update Summary: $($_.Exception.Message)" Red }
            }
        } elseif ($EditChoice -eq "3") {
            # Fetch the game's actual tag schema instead of hard-coding values.
            # The mod PUT endpoint silently ignores tags[]; tags must go through
            # POST /tags (add) and DELETE /tags (remove) on the mod.
            $TagSchemaRes = try { Invoke-RestMethod -Uri "https://api.mod.io/v1/games/$GameId/tags" -Method Get -Headers $Headers } catch { $null }
            $AvailableTags = @()
            if ($null -ne $TagSchemaRes -and $null -ne $TagSchemaRes.data) {
                foreach ($cat in $TagSchemaRes.data) {
                    if ($null -ne $cat.tags) { $AvailableTags += @($cat.tags) }
                }
                $AvailableTags = @($AvailableTags | Select-Object -Unique)
            }
            $ExistingTagsArr = if ($null -ne $CurrentTagsObj) { @($CurrentTagsObj.name) } else { @() }
            # Make sure currently-applied tags that aren't in the schema still show up so the user can see/remove them.
            foreach ($t in $ExistingTagsArr) { if ($AvailableTags -notcontains $t) { $AvailableTags += $t } }
            if ($AvailableTags.Count -eq 0) {
                Show-Status 'Failed to fetch tag schema from mod.io and no existing tags to seed the list.' Red
                continue
            }

            $TagSelectionSubtitle = "Select tags for the mod.`nUse Up/Down Arrows to navigate.`nPress SPACE to toggle selection.`nPress ENTER to submit."
            $SelectedTags = Show-TuiMultiSelect -Title "Edit Mod Tags" -Subtitle $TagSelectionSubtitle -Options $AvailableTags -Preselected $ExistingTagsArr

            $SelectedTagsArr = @($SelectedTags)
            $ToAdd    = @($SelectedTagsArr | Where-Object { $ExistingTagsArr -notcontains $_ })
            $ToRemove = @($ExistingTagsArr  | Where-Object { $SelectedTagsArr  -notcontains $_ })

            if ($ToAdd.Count -eq 0 -and $ToRemove.Count -eq 0) {
                Show-Status 'No tag changes to apply.' DarkGray
                continue
            }

            Clear-Host
            Write-Host "Updating tags..." -ForegroundColor Cyan
            if ($ToAdd.Count    -gt 0) { Write-Host ("  + " + ($ToAdd    -join ', ')) -ForegroundColor Green }
            if ($ToRemove.Count -gt 0) { Write-Host ("  - " + ($ToRemove -join ', ')) -ForegroundColor Yellow }

            $TagsApiOk = $true
            $TagsApiErr = ''
            try {
                if ($ToRemove.Count -gt 0) {
                    # DELETE with body=tags[]=... ; pass via query string too as belt-and-braces against WAFs that strip DELETE bodies.
                    $delQuery = (@($ToRemove | ForEach-Object { "tags[]=$([uri]::EscapeDataString($_))" })) -join '&'
                    Invoke-RestMethod -Uri "$BaseUrl/tags?$delQuery" -Method Delete -Headers $Headers -Body $delQuery -ContentType 'application/x-www-form-urlencoded' | Out-Null
                }
                if ($ToAdd.Count -gt 0) {
                    $addBody = (@($ToAdd | ForEach-Object { "tags[]=$([uri]::EscapeDataString($_))" })) -join '&'
                    Invoke-RestMethod -Uri "$BaseUrl/tags" -Method Post -Headers $Headers -Body $addBody -ContentType 'application/x-www-form-urlencoded' | Out-Null
                }
            } catch {
                $TagsApiOk = $false
                $TagsApiErr = $_.Exception.Message
                if ($null -ne $_.Exception.Response) {
                    try {
                        $errStream = $_.Exception.Response.GetResponseStream()
                        $errReader = New-Object System.IO.StreamReader($errStream)
                        $TagsApiErr += "`n" + $errReader.ReadToEnd()
                        $errReader.Close()
                    } catch {}
                }
            }

            if (-not $TagsApiOk) {
                Show-Status "Failed to update tags:`n$TagsApiErr" Red
                continue
            }

            # Verify the change actually landed by re-fetching from the server.
            $VerifyMod = try { Invoke-RestMethod -Uri $BaseUrl -Method Get -Headers $Headers } catch { $null }
            $VerifyTags = if ($null -ne $VerifyMod -and $null -ne $VerifyMod.tags) { @($VerifyMod.tags.name) } else { @() }
            $StillAdd    = @($ToAdd    | Where-Object { $VerifyTags -notcontains $_ })
            $StillRemove = @($ToRemove | Where-Object { $VerifyTags -contains    $_ })
            if ($StillAdd.Count -eq 0 -and $StillRemove.Count -eq 0) {
                Show-Status "Tags updated successfully!`nNow on mod.io: $(if($VerifyTags.Count -gt 0){$VerifyTags -join ', '}else{'(none)'})" Green
            } else {
                $msg = "Tag update partially applied. Server now reports: $(if($VerifyTags.Count -gt 0){$VerifyTags -join ', '}else{'(none)'})"
                if ($StillAdd.Count    -gt 0) { $msg += "`nNot added: "    + ($StillAdd    -join ', ') }
                if ($StillRemove.Count -gt 0) { $msg += "`nNot removed: "  + ($StillRemove -join ', ') }
                $msg += "`nThe missing tags may not exist in this game's tag schema."
                Show-Status $msg Yellow
            }
        } elseif ($EditChoice -eq "4") {
            $LogoFile = Get-ChildItem -Path $PSScriptRoot -Filter "*.png" | Select-Object -First 1
            if (-not $LogoFile) {
                Write-Host "Error: No .png file found in the current directory." -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                Write-Host "`nUpdating Logo using: $($LogoFile.Name) ..." -ForegroundColor Cyan
                
                $Boundary = "----WebKitFormBoundary$([System.Guid]::NewGuid().ToString('N'))"
                $MultipartBody = ""

                $LogoBytes = [System.IO.File]::ReadAllBytes($LogoFile.FullName)
                $LogoContent = [System.Text.Encoding]::GetEncoding("iso-8859-1").GetString($LogoBytes)

                $MultipartBody += "--$Boundary`r`n"
                $MultipartBody += "Content-Disposition: form-data; name=`"logo`"; filename=`"$($LogoFile.Name)`"`r`n"
                $MultipartBody += "Content-Type: image/png`r`n`r`n"
                $MultipartBody += "$LogoContent`r`n"
                $MultipartBody += "--$Boundary--`r`n"

                try {
                    $Bytes = [System.Text.Encoding]::GetEncoding("iso-8859-1").GetBytes($MultipartBody)
                    Invoke-RestMethod -Uri "$BaseUrl/media" -Method Post -Headers $Headers -Body $Bytes -ContentType "multipart/form-data; boundary=$Boundary" | Out-Null
                    Write-Host "Logo updated successfully!" -ForegroundColor Green
                    Start-Sleep -Seconds 2
                } catch {
                    Write-Host "Failed to update logo: $($_.Exception.Message)" -ForegroundColor Red
                    if ($null -ne $_.Exception.Response) {
                        try {
                            $errStream = $_.Exception.Response.GetResponseStream()
                            $errReader = New-Object System.IO.StreamReader($errStream)
                            Write-Host "Server details: $($errReader.ReadToEnd())" -ForegroundColor DarkRed
                            $errReader.Close()
                        } catch {}
                    }
                    Start-Sleep -Seconds 3
                }
            }
        }
    }
} elseif ($Choice -eq "7") {
    if ($null -ne $ModInfo -and -not [string]::IsNullOrWhiteSpace($ModInfo.profile_url)) {
        Write-Host "Opening $($ModInfo.profile_url) in your default browser..." -ForegroundColor Cyan
        Start-Process $ModInfo.profile_url
    } else {
        Write-Host "Mod URL not found. Ensure the Target Mod is valid." -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
} else {
    Write-Host "Invalid selection. Going back to main menu." -ForegroundColor Red
}

Write-Host "`nOperation complete. Press any key to return to main menu..." -ForegroundColor DarkGray
[Console]::ReadKey($true) | Out-Null
}