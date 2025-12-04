$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$varsFilePath = Join-Path $PSScriptRoot "\Shared\vars.json"
$vars = Get-Content -Path $varsFilePath -Raw | ConvertFrom-Json

# JSON Variables
$organization   = $vars.organization
$project        = $vars.project
$pat            = $vars.pat
$apiVersion     = $vars.apiVersion
$wikiIdentifier = $vars.wikiIdentifier

# Output
$outputDir  = Join-Path $PSScriptRoot "\Data"
$date       = Get-Date -Format "yyyy-MM-dd"
$outputFile = Join-Path -Path $outputDir -ChildPath "WikiPages.json"

# Authentication 
$encodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{
    Authorization  = "Basic $encodedPat"
    "Content-Type" = "application/json"
}

# Fetch all wiki pages (with continuation token) 
function Get-WikiPages {
    $continuationToken = $null
    $allPages = @()
    $pagePaths = @()
    $attempts = 0

    do {
        $attempts++
        Write-Host "Fetching batch attempt #$attempts"

        $url = "https://dev.azure.com/$organization/$project/_apis/wiki/wikis/$wikiIdentifier/pagesbatch?api-version=$apiVersion"
        $body = @{
            "top" = 100
        }
        if ($continuationToken) {
            $body["continuationToken"] = $continuationToken
        }

        try {
            $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 3)
            $continuationToken = $($response.Headers["X-MS-ContinuationToken"])
        }
        catch {
            Write-Host "Error fetching batch: $_"
            break
        }

        if ($null -eq $response.Content -or $response.Content -eq "") {
            Write-Host "No content in response. Ending fetch."
            break
        }

        $responseData = $response.Content | ConvertFrom-Json
        foreach ($page in $responseData.value) {
            if (-not ($pagePaths -contains $page.path)) {
                $pagePaths += $page.path
                $allPages += $page
            }
        }

    } while ($continuationToken)

    return $allPages
}

# Fetch wiki page content
function Get-WikiPageContent {
    param ([string]$pagePath)

    $encodedPath = [uri]::EscapeDataString($pagePath)
    $url = "https://dev.azure.com/$organization/$project/_apis/wiki/wikis/$wikiIdentifier/pages?path=$encodedPath&includeContent=true&api-version=7.2-preview.1"

    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    }
    catch {
        Write-Host "Failed to get content for path: $pagePath - $($_.Exception.Message)"
        return $null
    }
}

function Main {
    Write-Host "Fetching all wiki pages..."
    $pages = Get-WikiPages
    Write-Host "Found $($pages.Count) pages total.`n"

    $wikiData = @()
    $pageCount = 0

    foreach ($page in $pages) {
        $pageCount++
        $pagePath = $page.path
        $pageId = $page.id
        $pageTitle = ($pagePath.Split('/')[-1] -replace ' ', '-')

        Write-Host "Fetching stats for page ID: $pageId ($pageCount / $($pages.Count))"

        # Build URL
        $webUrl = "https://dev.azure.com/$organization/$project/_wiki/wikis/$wikiIdentifier/$pageId/$pageTitle"

        # Fetch content
        $pageContent = Get-WikiPageContent -pagePath $pagePath

        if ($pageContent) {
            $wikiData += [PSCustomObject]@{
                path    = $pagePath
                url     = $webUrl
                content = $pageContent.content
            }
        }
    }

    Write-Host "Collected $($wikiData.Count) pages with content."

    if (!(Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
    }

    $wikiData | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 -FilePath $outputFile
    Write-Host "Wiki pages saved to $outputFile"
}

Main
