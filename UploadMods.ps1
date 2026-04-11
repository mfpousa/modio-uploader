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

function Show-TuiMenu {
    param (
        [string]$Title,
        [string]$Subtitle,
        [string[]]$Options,
        [ConsoleColor[]]$OptionColors = $null
    )
    $selectedIndex = 0
    
    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host

    while ($true) {
        # Recalculate dimensions live to cleanly handle terminal window resizing 
        $winWidth = if ([Console]::WindowWidth -gt 10) { [Console]::WindowWidth } else { 80 }
        $winHeight = if ([Console]::WindowHeight -gt 10) { [Console]::WindowHeight } else { 24 }
        $maxLen = $winWidth - 1

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
        for ($i = 3; $i -lt $headerText.Count; $i++) {
            Write-Host $headerText[$i] -ForegroundColor DarkCyan
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

function Show-TuiMultiSelect {
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
        for ($i = 3; $i -lt $headerText.Count; $i++) {
            Write-Host $headerText[$i] -ForegroundColor DarkCyan
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
        Write-Host "Upload cancelled." -ForegroundColor Yellow
        Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
        [Console]::ReadKey($true) | Out-Null
        continue
    }

    Clear-Host
    Write-Host "=========================================" -ForegroundColor Magenta
    Write-Host "  Mod.io Release Configuration" -ForegroundColor White -BackgroundColor DarkMagenta
    Write-Host "=========================================`n" -ForegroundColor Magenta
    
    $GlobalChangelog = Read-Host "Enter an optional changelog for this release (leave blank for none)"
    
    Write-Host "`n--- Starting Uploads ---" -ForegroundColor Cyan

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
                Write-Host "Rollback cancelled." -ForegroundColor Yellow
                Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
                [Console]::ReadKey($true) | Out-Null
                continue
            }

            if ([string]::IsNullOrWhiteSpace($SelWindowsId) -and [string]::IsNullOrWhiteSpace($SelServerId) -and [string]::IsNullOrWhiteSpace($SelAndroidId)) {
                Write-Host "No files selected to rollback. Aborting." -ForegroundColor Yellow
                Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
                [Console]::ReadKey($true) | Out-Null
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
                Write-Host "`nCRITICAL ERROR: pluginRoot or modDataPaths could not be resolved." -ForegroundColor Red
                Write-Host "A valid existing Mod.io record or successful zip extraction is required." -ForegroundColor Yellow
                Write-Host "Rollback cancelled." -ForegroundColor Yellow
                Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
                [Console]::ReadKey($true) | Out-Null
                continue
            }

            if ($MissingData.Count -gt 0) {
                Write-Host ""
                Write-Host "WARNING: The following platforms will be left empty/missing on Mod.io:" -ForegroundColor Red
                foreach ($item in $MissingData) {
                    Write-Host "  - $item" -ForegroundColor Red
                }
                Write-Host "Proceeding will upload this incomplete data to the Mod.io server." -ForegroundColor Yellow
                $ContinueObj = Read-Host "Are you sure you want to continue? (Y/N)"
                if ($ContinueObj -notmatch "^[Yy]") {
                    Write-Host "Rollback cancelled by user." -ForegroundColor Yellow
                    Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
                    [Console]::ReadKey($true) | Out-Null
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

        $FilterStr = ""
        $SelectedIndex = 0
        $Cancelled = $false
        $ConfirmedIndex = -1

        try { [Console]::CursorVisible = $false } catch {}
        Clear-Host

        while ($true) {
            $winWidth = if ([Console]::WindowWidth -gt 10) { [Console]::WindowWidth } else { 80 }
            $winHeight = if ([Console]::WindowHeight -gt 10) { [Console]::WindowHeight } else { 24 }
            
            # Fuzzy filter logic
            $FilteredIndices = @()
            if ([string]::IsNullOrWhiteSpace($FilterStr)) {
                for ($i=0; $i -lt $ModObjs.Count; $i++) { $FilteredIndices += $i }
            } else {
                $SearchPattern = ($FilterStr.ToCharArray() | foreach { [regex]::Escape($_) }) -join '.*'
                for ($i=0; $i -lt $ModObjs.Count; $i++) {
                    if ($ModObjs[$i].name -match "(?i)$SearchPattern") {
                        $FilteredIndices += $i
                    }
                }
            }

            if ($SelectedIndex -ge $FilteredIndices.Count) { $SelectedIndex = [math]::Max(0, $FilteredIndices.Count - 1) }

            $headerText = @(
                "=========================================",
                "  Select Target Mod",
                "=========================================",
                "Select the mod you want to manage. ModId will be saved to config.json.",
                "Start typing to filter. Up/Down to select. Enter to confirm. Esc to cancel.",
                "-----------------------------------------",
                "Filter: $(if($FilterStr){$FilterStr}else{'<type to search>'})",
                "-----------------------------------------"
            )

            try { [Console]::SetCursorPosition(0, 0) } catch {}

            foreach ($i in 0..7) {
                if ($headerText[$i].Length -ge ($winWidth-1)) {
                    $headerText[$i] = $headerText[$i].Substring(0, $winWidth-1)
                } else {
                    $headerText[$i] = $headerText[$i].PadRight($winWidth-1, ' ')
                }
            }

            Write-Host $headerText[0] -ForegroundColor Magenta
            Write-Host $headerText[1] -ForegroundColor White -BackgroundColor DarkMagenta
            Write-Host $headerText[2] -ForegroundColor Magenta
            Write-Host $headerText[3] -ForegroundColor DarkCyan
            Write-Host $headerText[4] -ForegroundColor DarkCyan
            Write-Host $headerText[5] -ForegroundColor DarkGray
            Write-Host $headerText[6] -ForegroundColor Yellow
            Write-Host $headerText[7] -ForegroundColor DarkGray

            $linesDrawn = 0
            $maxMenuLines = $winHeight - $headerText.Count - 2
            
            if ($FilteredIndices.Count -eq 0) {
                Write-Host "  (No matches found)".PadRight($winWidth-1, ' ') -ForegroundColor Red
                $linesDrawn++
            } else {
                $startIdx = 0
                if ($SelectedIndex -ge $maxMenuLines) {
                    $startIdx = $SelectedIndex - $maxMenuLines + 1
                }
                $endIdx = [math]::Min($startIdx + $maxMenuLines - 1, $FilteredIndices.Count - 1)

                for ($i = $startIdx; $i -le $endIdx; $i++) {
                    $mIdx = $FilteredIndices[$i]
                    $m = $ModObjs[$mIdx]
                    
                    $dispStr = "[$($m.id)] $($m.name)"
                    $pfx = if ($i -eq $SelectedIndex) { "  > " } else { "    " }
                    $str = "$pfx$dispStr".PadRight($winWidth-1, ' ')

                    if ($i -eq $SelectedIndex) {
                        Write-Host $str -ForegroundColor Black -BackgroundColor Cyan
                    } else {
                        Write-Host $str -ForegroundColor Gray -BackgroundColor Black
                    }
                    $linesDrawn++
                }
            }

            $blankStr = "".PadRight($winWidth-1, ' ')
            $linesToClear = $winHeight - $headerText.Count - $linesDrawn - 1
            if ($linesToClear -gt 0) {
                for ($c = 0; $c -lt $linesToClear; $c++) { Write-Host $blankStr }
            }

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Escape') {
                $Cancelled = $true
                break
            } elseif ($key.Key -eq 'Enter') {
                if ($FilteredIndices.Count -gt 0) {
                    $ConfirmedIndex = $FilteredIndices[$SelectedIndex]
                } else {
                    $Cancelled = $true
                }
                break
            } elseif ($key.Key -eq 'UpArrow') {
                $SelectedIndex = ($SelectedIndex - 1 + [math]::Max(1, $FilteredIndices.Count)) % [math]::Max(1, $FilteredIndices.Count)
            } elseif ($key.Key -eq 'DownArrow') {
                $SelectedIndex = ($SelectedIndex + 1) % [math]::Max(1, $FilteredIndices.Count)
            } elseif ($key.Key -eq 'Backspace') {
                if ($FilterStr.Length -gt 0) {
                    $FilterStr = $FilterStr.Substring(0, $FilterStr.Length - 1)
                }
            } elseif (-not [char]::IsControl($key.KeyChar)) {
                $FilterStr += $key.KeyChar
            }
        }

        try { [Console]::CursorVisible = $true } catch {}
        Clear-Host

        if (-not $Cancelled -and $ConfirmedIndex -ge 0) {
            $SelectedMod = $ModObjs[$ConfirmedIndex]
            $Config.modId = [string]$SelectedMod.id
            $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath
            
            $ModId = $Config.modId
            $BaseUrl = "https://api.mod.io/v1/games/$GameId/mods/$ModId"
            
            Write-Host "Successfully changed target mod to: $($SelectedMod.name) ($($SelectedMod.id))" -ForegroundColor Green
        } else {
            Write-Host "Mod selection cancelled." -ForegroundColor Yellow
        }
    } else {
        Write-Host "No mods found for this game, or failed to fetch." -ForegroundColor Yellow
    }
} elseif ($Choice -eq "5") {
    Write-Host "`n--- Interactive Mod Creation ---" -ForegroundColor Cyan
    $NewModName = Read-Host "Enter the Name for the new mod"
    $NewModSummary = Read-Host "Enter a short Summary for the new mod"

    if ([string]::IsNullOrWhiteSpace($NewModName) -or [string]::IsNullOrWhiteSpace($NewModSummary)) {
        Write-Host "Name and Summary are required. Aborting mod creation." -ForegroundColor Red
        Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
        [Console]::ReadKey($true) | Out-Null
        continue
    }

    $AvailableTags = @("Loadout", "Windows", "Android", "Server")
    $TagSelectionSubtitle = "Select tags for the new mod.`nUse Up/Down Arrows to navigate.`nPress SPACE to toggle selection.`nPress ENTER to submit."
    $SelectedTags = Show-TuiMultiSelect -Title "Select Mod Tags" -Subtitle $TagSelectionSubtitle -Options $AvailableTags

    $LogoFile = Get-ChildItem -Path $PSScriptRoot -Filter "*.png" | Select-Object -First 1
    if (-not $LogoFile) {
        Write-Host "Error: No .png file found in the current directory to use as a logo. A logo is required by Mod.io." -ForegroundColor Red
        Write-Host "`nPress any key to return to main menu..." -ForegroundColor Cyan
        [Console]::ReadKey($true) | Out-Null
        continue
    }

    $NewModId = New-ModIoMod -Name $NewModName -Summary $NewModSummary -Tags $SelectedTags -LogoPath $LogoFile.FullName

    if ($null -ne $NewModId) {
        $Config.modId = $NewModId
        $Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath
        
        $ModId = $Config.modId
        $BaseUrl = "https://api.mod.io/v1/games/$GameId/mods/$ModId"
        
        Write-Host "Target mode mapped to brand new mod successfully." -ForegroundColor Green
    }
} elseif ($Choice -eq "6") {
    while ($true) {
        Write-Host "`nFetching current mod details..." -ForegroundColor Cyan
        $CurrentModInfo = try { Invoke-RestMethod -Uri $BaseUrl -Method Get -Headers $Headers } catch { $null }
        
        if ($null -eq $CurrentModInfo) {
            Write-Host "Failed to fetch mod info. Ensure the Target Mod exists." -ForegroundColor Red
            Write-Host "Press any key to return..." -ForegroundColor Cyan
            [Console]::ReadKey($true) | Out-Null
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
            Write-Host "`n--- Edit Name ---" -ForegroundColor Cyan
            $NewName = Read-Host "Enter new Name (leave blank to cancel)"
            if (-not [string]::IsNullOrWhiteSpace($NewName)) {
                try {
                    $BodyData = "name=$([uri]::EscapeDataString($NewName))"
                    Invoke-RestMethod -Uri $BaseUrl -Method Put -Headers $Headers -Body $BodyData -ContentType "application/x-www-form-urlencoded" | Out-Null
                    Write-Host "Name updated successfully!" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                } catch { Write-Host "Failed to update Name: $($_.Exception.Message)" -ForegroundColor Red; Start-Sleep -Seconds 2 }
            }
        } elseif ($EditChoice -eq "2") {
            Write-Host "`n--- Edit Summary ---" -ForegroundColor Cyan
            $NewSummary = Read-Host "Enter new Summary (leave blank to cancel)"
            if (-not [string]::IsNullOrWhiteSpace($NewSummary)) {
                try {
                    $BodyData = "summary=$([uri]::EscapeDataString($NewSummary))"
                    Invoke-RestMethod -Uri $BaseUrl -Method Put -Headers $Headers -Body $BodyData -ContentType "application/x-www-form-urlencoded" | Out-Null
                    Write-Host "Summary updated successfully!" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                } catch { Write-Host "Failed to update Summary: $($_.Exception.Message)" -ForegroundColor Red; Start-Sleep -Seconds 2 }
            }
        } elseif ($EditChoice -eq "3") {
            $AvailableTags = @("Loadout", "Windows", "Android", "Server")
            $TagSelectionSubtitle = "Select tags for the mod.`nUse Up/Down Arrows to navigate.`nPress SPACE to toggle selection.`nPress ENTER to submit."
            $ExistingTagsArr = if ($null -ne $CurrentTagsObj) { @($CurrentTagsObj.name) } else { @() }
            
            $SelectedTags = Show-TuiMultiSelect -Title "Edit Mod Tags" -Subtitle $TagSelectionSubtitle -Options $AvailableTags -Preselected $ExistingTagsArr
            
            Write-Host "`nUpdating tags..." -ForegroundColor Cyan
            try {
                $PutBody = @()
                foreach ($t in $SelectedTags) { $PutBody += "tags[]=$([uri]::EscapeDataString($t))" }
                
                if ($PutBody.Count -gt 0) {
                    # Overwrite all tags using the PUT endpoint directly on the mod
                    Invoke-RestMethod -Uri $BaseUrl -Method Put -Headers $Headers -Body ($PutBody -join '&') -ContentType "application/x-www-form-urlencoded" | Out-Null
                } else {
                    # Wiping all tags requires DELETE. We pass via query string to avoid WAF 403 Forbidden errors on DELETE bodies
                    if ($ExistingTagsArr.Count -gt 0) {
                        $DelQuery = @()
                        foreach ($t in $ExistingTagsArr) { $DelQuery += "tags[]=$([uri]::EscapeDataString($t))" }
                        $DelUri = "$BaseUrl/tags?" + ($DelQuery -join '&')
                        Invoke-RestMethod -Uri $DelUri -Method Delete -Headers $Headers | Out-Null
                    }
                }
                Write-Host "Tags updated successfully!" -ForegroundColor Green
                Start-Sleep -Seconds 1
            } catch {
                Write-Host "Failed to update tags: $($_.Exception.Message)" -ForegroundColor Red
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

Write-Host "`nOperation complete. Press any key to return to main menu..." -ForegroundColor Cyan
[Console]::ReadKey($true) | Out-Null
}