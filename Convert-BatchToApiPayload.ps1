<#
.SYNOPSIS
    Transforms legacy XML enrollment batch files into OpenAPI 3.0 compliant JSON payloads.
.DESCRIPTION
    Reads sample-batch.xml, extracts batch metadata and member nodes, executes schema field validation,
    maps legacy node structures to modern target REST JSON formats, exports payload.json, and routes
    invalid records to a reject log.
#>

[CmdletBinding()]
param (
    [string]$InputXmlPath   = "$PSScriptRoot\sample-batch.xml",
    [string]$OutputJsonPath  = "$PSScriptRoot\payload.json",
    [string]$RejectJsonPath  = "$PSScriptRoot\rejected-records.json",
    [string]$LogFilePath     = "$PSScriptRoot\transformation.log"
)

function Write-PipelineLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Write-Host $logLine -ForegroundColor $(if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARN") { "Yellow" } else { "Green" })
    Add-Content -Path $LogFilePath -Value $logLine
}

Write-PipelineLog "=== Starting Batch to OpenAPI Transformation Pipeline ==="

# 1. Verify and Load Input XML
if (-not (Test-Path -Path $InputXmlPath)) {
    Write-PipelineLog "Source file not found: $InputXmlPath" -Level "ERROR"
    exit 1
}

Write-PipelineLog "Loading source XML file: $InputXmlPath"
[xml]$xmlData = Get-Content -Path $InputXmlPath

# 2. Extract Header Metadata
$batchId      = $xmlData.BatchEnrollmentEnvelope.Header.BatchIdentifier
$sourceSystem = $xmlData.BatchEnrollmentEnvelope.Header.SourceSystemCode
$recordCount  = [int]$xmlData.BatchEnrollmentEnvelope.Header.TotalRecordCount

Write-PipelineLog "Processing Batch ID: $batchId ($recordCount records in envelope)"

# 3. Process Member Records & Execute Validation
$validMemberList    = [System.Collections.Generic.List[PSObject]]::new()
$rejectedMemberList = [System.Collections.Generic.List[PSObject]]::new()
$processedIndex = 0

foreach ($memberNode in $xmlData.BatchEnrollmentEnvelope.MemberRecords.Member) {
    $processedIndex++

    # Contract Schema Field Extraction
    $memberId  = $memberNode.LegacyID
    $firstName = $memberNode.Demographics.FirstName
    $lastName  = $memberNode.Demographics.LastName
    $dob       = $memberNode.Demographics.DOB
    $planCode  = $memberNode.PlanSelection.PlanCode
    $status    = $memberNode.PlanSelection.Status

    # Define allowed CoverageStatus enumeration values
    $allowedStatuses = @('ACTIVE', 'PENDING', 'TERMINATED')

    # Identify Missing Mandatory Fields
    $missingFields = @()
    if ([string]::IsNullOrWhiteSpace($memberId))  { $missingFields += "memberId" }
    if ([string]::IsNullOrWhiteSpace($firstName)) { $missingFields += "firstName" }
    if ([string]::IsNullOrWhiteSpace($lastName))  { $missingFields += "lastName" }
    if ([string]::IsNullOrWhiteSpace($dob))       { $missingFields += "dateOfBirth" }
    if ([string]::IsNullOrWhiteSpace($planCode))  { $missingFields += "planCode" }

    # Check Enum Constraint
    $hasInvalidStatus = $allowedStatuses -notcontains $status

    # Route Invalid Records to Reject Queue
    if ($missingFields.Count -gt 0 -or $hasInvalidStatus) {
        $rejectionReasons = @()
        if ($missingFields.Count -gt 0) { 
            $rejectionReasons += "Missing mandatory schema field(s): $($missingFields -join ', ')" 
        }
        if ($hasInvalidStatus) { 
            $rejectionReasons += "Invalid CoverageStatus value '$status'. Allowed: $($allowedStatuses -join ', ')" 
        }

        # Consolidate failure reasons into a single string
        $reason = $rejectionReasons -join " | "

        Write-PipelineLog "Record #$processedIndex (ID: '$memberId') FAILED validation. $reason" -Level "WARN"

        $rejectedObject = [PSCustomObject]@{
            recordIndex   = $processedIndex
            legacyId      = $memberId
            failureReason = $reason
            rawXmlRecord  = $memberNode.OuterXml
        }
        $rejectedMemberList.Add($rejectedObject)
        continue
    }

    # Construct Schema-Compliant Member Object
    $memberObject = [PSCustomObject]@{
        memberId       = [string]$memberId
        firstName      = [string]$firstName
        lastName       = [string]$lastName
        dateOfBirth    = [string]$dob
        planCode       = [string]$planCode
        coverageStatus = if ([string]::IsNullOrWhiteSpace($status)) { "ACTIVE" } else { [string]$status }
    }

    $validMemberList.Add($memberObject)
}

# 4. Export REST API Payload
$apiPayload = [PSCustomObject]@{
    batchHeader = [PSCustomObject]@{
        batchId      = [string]$batchId
        sourceSystem = [string]$sourceSystem
        recordCount  = [int]$validMemberList.Count
    }
    members     = $validMemberList
}

$apiPayload | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputJsonPath -Encoding utf8
Write-PipelineLog "Exported $($validMemberList.Count) valid record(s) to REST payload: $OutputJsonPath"

# 5. Export Rejected Records Queue (if any exist)
if ($rejectedMemberList.Count -gt 0) {
    $rejectedPayload = [PSCustomObject]@{
        batchId         = $batchId
        rejectedCount   = $rejectedMemberList.Count
        rejectedRecords = $rejectedMemberList
    }
    $rejectedPayload | ConvertTo-Json -Depth 5 | Out-File -FilePath $RejectJsonPath -Encoding utf8
    Write-PipelineLog "Exported $($rejectedMemberList.Count) rejected record(s) to Dead-Letter file: $RejectJsonPath" -Level "WARN"
} else {
    Write-PipelineLog "Zero record validation failures."
}

Write-PipelineLog "=== Transformation Complete ==="