param(
    [string]$Instances
)

function Register-Project {

    $servers = $Instances | ConvertFrom-Json

          foreach ($s in $servers) {
              Write-Host "PoolName: $($s.PoolName) - SiteName: $($s.SiteName)  - DeployFolder: $($s.DeployFolder) - BackupFolder: $($s.BackupFolder)"
          }
    
}

try {
		Register-Project
    }
 catch {
    Write-Output "Error: $_"
	
    exit 1
 }