param(
    [string]$RunnerWorkSpaceLocation,
    [string]$ProcessName,
	[string]$ProjectFileName,
	[string]$BuildLocation,
	[string]$DeployDriveLatter,
	[string]$TempLocation,
	[string]$BackupLocation,
	[string]$LogLocation,
	[string]$MachineName,
	[string]$Author,
	[string]$UserID
)

$solutionRoot = "$RunnerWorkSpaceLocation\BuzzRxPriceFlatteningMonitor"
$projectFile = "$solutionRoot\$ProjectFileName"
$buildOutput = "$solutionRoot\$BuildLocation"
$deployLive = "$($DeployDriveLatter)\BuzzRxETL\$ProcessName"
$logDir = "$LogLocation\BuzzRxETL\$ProcessName"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "$logDir\deploy-$timestamp.log"
$currentDate = Get-Date -Format "dd-MMM-yyyy"

Start-Transcript -Path $logFile -Append

function Register-DeployPFTask {
	param (
		[string]$ProcessName,
		[string]$ProcessType
	)

	$ps_session = New-PSSession -ComputerName $MachineName

	Invoke-Command -Session $ps_session -ScriptBlock {
		param ($currentDate, $TempLocation, $deployLive, $Author, $UserID)

		$taskPath = "\BuzzRxSchedulars"
		$taskName = "$ProcessName-$ProcessType-CD"

		# App machine temp location
		$tempFolder = "$TempLocation\$currentDate"
		$templatePath = "$tempFolder\$ProcessName-$ProcessType.xml"

		$taskExists = Get-ScheduledTask -TaskPath "$taskPath\*" -TaskName $taskName -ErrorAction SilentlyContinue

		if (-not $taskExists) 
		{
			Write-Output "Task does not exists, creating new."

			# Load the XML file
			[xml]$xml = Get-Content -Path $templatePath

			# Update Date
			$now = Get-Date
			$MicroSeconds = [long](($now.Ticks % [timespan]::TicksPerSecond) / 10)
			$TimeStamp = "{0:yyyy-MM-ddTHH:mm:ss}.{1:D6}" -f $now, $MicroSeconds

			$xml.Task.RegistrationInfo.Date = $TimeStamp
 
			# Update Auther Name
			$xml.Task.RegistrationInfo.Author = $Author

			# Update Principal ID
			$authorPrincipal = $xml.Task.Principals.Principal | Where-Object { $_.id -eq "Author" }

			if ($authorPrincipal)
			{
				$authorPrincipal.UserId = $UserID
			}
			else
			{
				Write-Output "No principal found with id Author"
			}

			# Update Command
			$xml.Task.Actions.Exec.Command = "$deployLive\$ProcessName.exe"

			# Save the changes in the same xml file
			$xml.Save($templatePath)


			Register-ScheduledTask -XML (Get-Content $templatePath | Out-String) -TaskName $taskName -TaskPath $taskPath
		}
		else
		{
			Write-Output "Task exists."
		}
	} -ArgumentList $currentDate, $TempLocation, $deployLive, $Author, $UserID

 	Write-Output "Remove-PSSession"
	Remove-PSSession $ps_session
 }

function Build-Project {
    Write-Output "Building project on runner machine..."
    
	# Code is build on runner machine
	$result = dotnet build $projectFile -c Release
    
	if ($LASTEXITCODE -ne 0) {
      throw "Build failed."
    }
	
	Write-Output "Creating zip file on runner machine..."
	Compress-Archive -Path $buildOutput -DestinationPath "$buildOutput\Release-$currentDate.zip"
	
    Write-Output "Build successful."
}

function Start-Deploy-PFMonitorTask {
	param (
		[string]$ProcessName
	)

    Write-Output "Starting deployment..."
	
	$ps_session = New-PSSession -ComputerName $MachineName
	Write-Output "New-PSSession"

		Write-Output "Connected to machine...[$MachineName]"

		# App machine temp location
		$tempFolder = "$TempLocation\$currentDate"
		Write-Output "Temp location...[$tempFolder]"
		
		Invoke-Command -Session $ps_session -ScriptBlock {
			param($tempFolder)

			if (!(Test-Path $tempFolder)) 
			{
				Write-Output "Temp folder does now exists, creating new..."
				New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
			}
		} -ArgumentList $tempFolder

		# Move zip file in temp location
		Write-Output "Moving zip file..."
		Copy-Item -Path "$buildOutput\Release-$currentDate.zip" -Destination "$tempFolder\Release-$currentDate.zip" -ToSession $ps_session
		
		$templatePath = "$RunnerWorkSpaceLocation\Template\$ProcessName-$ProcessType.xml"
		Copy-Item -Path $templatePath -Destination $tempFolder -ToSession $ps_session
		
		# Unzip at temp location
		Write-Output "Unziping zip file..."
		Invoke-Command -Session $ps_session -ScriptBlock {
			param($currentDate, $tempFolder, $BackupLocation, $deployLive, $ProcessName)

			$unzipPath = "$tempFolder\unzip"

			if (!(Test-Path $unzipPath)) 
			{
				New-Item -ItemType Directory -Path $unzipPath | Out-Null
			}

			Expand-Archive -Path "$tempFolder\Release-$currentDate.zip" -DestinationPath $unzipPath -Force

			# Backup existing deployment
			Write-Output "Backing up current deployment..."
			$backupPath = "$BackupLocation\$currentDate\$ProcessName"
			Write-Output $backupPath

			if (!(Test-Path $backupPath)) 
			{
				New-Item -ItemType Directory -Path $backupPath | Out-Null
				Write-Output "Created backup folder..."
			}

			$excludePaths = @("ClaimExport", "logs")

			Write-Output "Backup start...[$backupPath]"
			Copy-Item $deployLive\* $backupPath -Exclude $excludePaths -Recurse -Force
			Write-Output "Backup end...[$backupPath]"

			# Deploy new code

			# Copy from unzip location
			$copyExcludes = @('appsettings.json')
			Copy-Item "$unzipPath\net8.0\*" $deployLive -Exclude $copyExcludes -Recurse -Force
			Write-Output "Files are copied from unzip location to live...[$deployLive]"

		} -ArgumentList $currentDate, $tempFolder, $BackupLocation, $deployLive, $ProcessName
	
	Write-Output "Remove-PSSession"
	Remove-PSSession $ps_session

    Write-Output "Deployment completed."
}

# --- Main execution ---

 try {
		Write-Output "---------------------Project build start---------------------"
		Build-Project
		Write-Output "---------------------Project build end---------------------"

		Write-Output "---------------------Deployment start---------------------"
		Start-Deploy-PFMonitorTask -ProcessName $ProcessName
		Write-Output "---------------------Deployment end---------------------"

		Write-Output "---------------------Register PF Start task start---------------------"
		Register-DeployPFTask -ProcessName $ProcessName -ProcessType "Start"
		Write-Output "---------------------Register PF Start task end---------------------"

		Write-Output "---------------------Register PF Delay task start---------------------"
		Register-DeployPFTask -ProcessName $ProcessName -ProcessType "Delay"
		Write-Output "---------------------Register PF Delay task end---------------------"

		<#
		Write-Output "Print all variables"
		Write-Output $RunnerWorkSpaceLocation
		Write-Output $MachineName
		Write-Output $BackupLocation
		Write-Output $LogLocation
		Write-Output $DeployDriveLatter
		Write-Output $TempLocation
		#>
		
		Stop-Transcript
    }
 catch {
    Write-Output "Error: $_"
	
	Stop-Transcript
	
    exit 1
 }