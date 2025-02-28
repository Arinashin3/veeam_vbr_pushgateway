# v0.4  ----------------------------------------------------------------------
# ----------------------  CUSTOM CONFIG  -------------------------------------

$GROUP = '[GROUPNAME]'
$BASE_URL = 'http://[IPADDRESS]:9091'
$SERVER = $env:COMPUTERNAME # SET CUSTOM NAME IF DESIRED
$SelectDate = 1

# ----------------------------------------------------------------------------
# ----------------------  GENERIC USEFUL STUFF  ------------------------------
# ----------------------------------------------------------------------------

# ANY ERROR WILL CAUSE SCRIPT TO TERMINATE EXECUTION
$ErrorActionPreference = "Continue"
$Metrics = $nul
# WHEN USING HTTPS THIS FORCES TLS 1.2 INSTEAD OF POWERSHELL DEFAULT 1.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# RETURNS EPOCH TIME, SECONDS SINCE 1.1.1970, UTC
Function GetUnixTimeUTC([AllowNull()][Nullable[DateTime]] $ttt) {
    if (!$ttt) { return 0 }
    [int]$unixtime = (get-date -Date $ttt.ToUniversalTime() -UFormat %s).`
    Substring(0,10)
    return "${unixtime}"
}

$CurrDate = Get-Date
$CollectAt = GetUnixTimeUTC($CurrDate)


function ParsingMetric($metricName, $metricLabels, $sample) {

  return "$metricName $modifyLabels $sample`n"
}

# ==========================================================
# Report Computer Backup Job Info
# - For Grafana Loki
# ==========================================================
$CompBackupJobs = Get-VBRComputerBackupJob

foreach ($Job in $CompBackupJobs) {

  $StreamLabel = @{
      "type"=$Job.Type.ToString(); 
      "mode"=$Job.Mode.ToString();
      "hostname"= $SERVER;
      "job_name"=$Job.Name;
      "job_id"=$Job.Id;
  } | ConvertTo-Json -Depth 5 -Compress

  if ( $Job.JobEnabled ) { $JobEnabled = 1 } else { $JobEnabled = 0 }

  $Metrics += ParsingMetric("veeam_vbr_backupjob_enabled", $StreamLabel, $JobEnabled)

}

# ==========================================================
# Report Backup Repository Info
# - For Grafana Loki
# ==========================================================

$Repositorys = Get-VBRBackupRepository
foreach ($Repo in $Repositorys) {

  $RepoId     = $Repo.Id
  $RepoName   = $Repo.Name
  $RepoPath   = $Repo.FriendlyPath
  $TotalSpace = $Repo.GetContainer().CachedTotalSpace.InMegabytes
  $FreeSpace  = $Repo.GetContainer().CachedFreeSpace.InMegabytes

  $StreamLabel = @{
      "type"=$Repo.TypeDisplay; 
      "repo" = $Repo.Name;
      "repo_id" = $Repo.Id;
      "hostname"= $SERVER;
  } | ConvertTo-Json -Depth 1 -Compress

  $Metrics += ParsingMetric("veeam_vbr_repository_space_totalspace_mb", $StreamLabel, $TotalSpace)
  $Metrics += ParsingMetric("veeam_vbr_repository_space_freespace_mb", $StreamLabel, $FreeSpace)

}

# ==========================================================
# Report Restore Point Info
# - For Grafana Loki
# ==========================================================
$RestorePoints = Get-VBRRestorePoint
foreach ($RP in $RestorePoints) {

  $CreateAt = GetUnixTimeUTC($RP.CreationTime)

  $StreamLabel = @{
      "usn" = $RP.CreationUsn.ToString(); 
      "backupjob"=$RP.GetBackup().Name; 
      "objname"=$RP.Name;
      "oid"=$RP.ObjectId;
      "tyep"=$RP.Type.ToString();
      "repo" = $RP.GetRepository().Name;
      "hostname"= $SERVER;
  } | ConvertTo-Json -Compress
  if ( $RP.HealthStatus.ToString() -eq "Ok" ) { $RPHealth = 1 } else { $RPHealth = 0 }

  $Metrics += ParsingMetric("veeam_vbr_restorepoint_health", $StreamLabel, $RPHealth)
  $Metrics += ParsingMetric("veeam_vbr_restorepoint_create_timestamp", $StreamLabel, $CreateAt)
  $Metrics += ParsingMetric("veeam_vbr_restorepoint_approx_size", $StreamLabel, $RP.ApproxSize)

}


# ==========================================================
# Report Backup Session Info (Last 1day)
# - For Grafana Loki
# ==========================================================
$ComputerBackupJobSessions = Get-VBRComputerBackupJobSession | Where-Object {$_.CreationTime -ge ($CurrDate.AddDays(-$SelectDate)) -AND $_.CreationTime -le $CurrDate}
foreach ($Session in $ComputerBackupJobSessions) {

    # 동작중인 경우, 스킵
    if ( $Session.Result -eq "None" ) { continue }

    # 각각의 Session 상세정보 조회
    $Task = Get-VBRTaskSession -Session $Session
    if ( $Task -eq $null ) { continue }
    $JobSess = $Task.JobSess

    
    $StreamLabel = @{
      "job_name"=$JobSess.JobName; 
      "job_id"=$JobSess.JobId; 
      "objname"=$Task.Info.ObjectName;
      "oid"=$Task.Info.ObjectId;
      "type"=$JobSess.JobType.ToString();
      "hostname"= $SERVER;
      "session_id"=$JobSess.Id;
    } | ConvertTo-Json -Depth 1 -Compress

    
    $JobSessStart = GetUnixTimeUTC($Session.CreationTime)
    $JobSessEnd = GetUnixTimeUTC($Session.EndTime)
    $TaskAvgSpeed = $Task.Progress.AvgSpeed
    $BackupSize = $JobSess.BackupStats.BackupSize
    $DataSize = $JobSess.BackupStats.DataSize
    $CompressRatio = $JobSess.BackupStats.CompressRatio
    $DedupRatio = $JobSess.BackupStats.DedupRatio
    if ( $JobSess.Result -eq "Success" ){ 
      $JobSessResultNum = 1
    } elseif ( $JobSess.Result -eq "Failed" ){ 
      $JobSessResultNum = 0
    } elseif ( $JobSess.Result -eq "Warning" ){ 
      $JobSessResultNum = 2
    } else { 
      $JobSessResultNum = -1 
    }

    $Metrics += ParsingMetric("veeam_vbr_session_result", $StreamLabel, $JobSessResultNum)
    $Metrics += ParsingMetric("veeam_vbr_session_start_timestamp", $StreamLabel, $JobSessStart)
    $Metrics += ParsingMetric("veeam_vbr_session_end_timestamp", $StreamLabel, $JobSessEnd)
    $Metrics += ParsingMetric("veeam_vbr_session_avg_speed", $StreamLabel, $TaskAvgSpeed)
    $Metrics += ParsingMetric("veeam_vbr_session_backup_size", $StreamLabel, $BackupSize)
    $Metrics += ParsingMetric("veeam_vbr_session_data_size", $StreamLabel, $DataSize)
    $Metrics += ParsingMetric("veeam_vbr_session_compress_ratio", $StreamLabel, $CompressRatio)
    $Metrics += ParsingMetric("veeam_vbr_session_dedup_ratio", $StreamLabel, $DedupRatio)

}

$Metrics = $Metrics.Replace("`":`"","=`"")
$Metrics = $Metrics.Replace("`{`"","{")
$Metrics = $Metrics.Replace(",`"",",")
$Metrics=@"
$Metrics
"@.Replace("  `n","`n")

  Invoke-RestMethod `
    -Method POST `
    -Uri "$BASE_URL/metrics/job/veeam_report" `
    -Verbose `
    -Body "$Metrics"
