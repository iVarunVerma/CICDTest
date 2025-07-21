param(
    [string]$RunnerWorkSpaceLocation,
    [string]$ProcessName,
	[string]$ProjectFileName,
	[string]$BuildLocation,
	[string]$DeployDriveLatter,
	[string]$TempLocation,
	[string]$BackupLocation,
	[string]$LogLocation,
	[string]$MachineName
)

$solutionRoot = "$RunnerWorkSpaceLocation\BuzzRxClaim\BuzzRxClaim.API"
$projectFile = "$solutionRoot\$ProjectFileName"
$buildOutput = "$RunnerWorkSpaceLocation\BuzzRxClaim\$BuildLocation" # -->> Publish
$deployLive = "$($DeployDriveLatter)\BuzzRxETL\$ProcessName"
$logDir = "$LogLocation\BuzzRxETL\$ProcessName"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "$logDir\deploy-$timestamp.log"
$currentDate = Get-Date -Format "dd-MMM-yyyy"

Start-Transcript -Path $logFile -Append

function Register-IISPool-Site {

	$ps_session = New-PSSession -ComputerName $MachineName

	Invoke-Command -Session $ps_session -ScriptBlock {
		param ($AppPoolName, $SiteName, $Port, $IPAddress, $HostName, $DeployPath)

        if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {

            New-WebAppPool -Name $AppPoolName

            # Set to 'No Managed Code'
            Set-ItemProperty IIS:\AppPools\$AppPoolName managedRuntimeVersion ''

            # Set pipeline mode to Integrated
            Set-ItemProperty IIS:\AppPools\$AppPoolName managedPipelineMode 'Integrated'

            # Start the App Pool
            Start-WebAppPool -Name $AppPoolName

            Write-Host "Application pool '$AppPoolName' created and started."
        } 
        else {
            Write-Host "Application pool '$AppPoolName' already exists."
        }

        # Create deployment folder if not exists
        if (-Not (Test-Path $DeployPath)) {
            New-Item -Path $DeployPath -ItemType Directory
            Write-Host "Deploy path directory is created: '$DeployPath'"
        }

        $sitPparams = @{
            Name = $SiteName
            Port = $Port
            IPAddress = $IPAddress
            HostHeader = $HostName
            PhysicalPath = $DeployPath
            ApplicationPool = $AppPoolName
        }

        # Create website with HTTP binding
        New-Website @sitPparams

        # Add HTTPS binding (Assumes SSL cert is installed and bound to the host)
        # Get the certificate thumbprint
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*.buzzintegrations.com*" } | Select-Object -First 1

        if ($cert) {

            $appid = [guid]::NewGuid().ToString("B")

            # SSL Binding
            New-WebBinding -Name $SiteName -Protocol https -Port 443 -IPAddress $IPAddress -HostHeader $HostName

            # Assign SSL cert to the binding
            $binding = "0.0.0.0!443!$HostName"
            netsh http add sslcert ipport=0.0.0.0:443 certhash=$($cert.Thumbprint) appid=$appid
        } else {
            Write-Warning "SSL certificate for $HostName not found."
        }

	} -ArgumentList $AppPoolName, $SiteName, $Port, $IPAddress, $HostName, $DeployPath

 	Write-Output "Remove-PSSession"
	Remove-PSSession $ps_session
 }

function Start-Build-Project {
    Write-Output "Building project on runner machine..."

    dotnet restore $projectFile

    dotnet build $projectFile -c Release

    if ($LASTEXITCODE -ne 0) {
      throw "Build failed."
    }

    if (!(Test-Path $buildOutput)) {
        New-Item -ItemType Directory -Path $buildOutput | Out-Null
    }

    dotnet publish $projectFile -c Release --output $buildOutput --no-restore

    $ReleaseFolder = "Release"

    $releasePath = "$RunnerWorkSpaceLocation\BuzzRxClaim\$ReleaseFolder"

    if (!(Test-Path $releasePath)) {
        New-Item -ItemType Directory -Path $releasePath | Out-Null
    }

    Write-Output "Creating zip file on runner machine..."
    Compress-Archive -Path $buildOutput -DestinationPath "$releasePath\Release-$currentDate.zip"
    
    Write-Output "Build and publish are successful."
}

function Deploy-ClaimAPI {
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
        $releasePath = "$RunnerWorkSpaceLocation\BuzzRxClaim\$ReleaseFolder"
		Copy-Item -Path "$releasePath\Release-$currentDate.zip" -Destination "$tempFolder\Release-$ProcessName-$currentDate.zip" -ToSession $ps_session
		
		#$templatePath = "$RunnerWorkSpaceLocation\Template\BuzzRxSmartBINClaimExport.xml"
		#Copy-Item -Path $templatePath -Destination $tempFolder -ToSession $ps_session
		
		# Unzip at temp location
		Write-Output "Unziping zip file..."
		Invoke-Command -Session $ps_session -ScriptBlock {
			param($currentDate, $tempFolder, $BackupLocation, $deployLive, $ProcessName)

			$unzipPath = "$tempFolder\unzip\$ProcessName"

			if (!(Test-Path $unzipPath)) 
			{
				New-Item -ItemType Directory -Path $unzipPath | Out-Null
			}

			Expand-Archive -Path "$tempFolder\Release-$ProcessName-$currentDate.zip" -DestinationPath $unzipPath -Force

			# Backup existing deployment
			Write-Output "Backing up current deployment..."
			$backupPath = "$BackupLocation\$currentDate\$ProcessName"
			Write-Output $backupPath

			if (!(Test-Path $backupPath)) 
			{
				New-Item -ItemType Directory -Path $backupPath | Out-Null
				Write-Output "Created backup folder..."
			}

			$excludePaths = @("logs")

			Write-Output "Backup start...[$backupPath]"
			Copy-Item $deployLive\* $backupPath -Exclude $excludePaths -Recurse -Force
			Write-Output "Backup end...[$backupPath]"

			# Deploy new code

			# Copy from unzip location
			$copyExcludes = @('appsettings.json', 'appsettings.Development.json')
			Copy-Item "$unzipPath\Publish\*" $deployLive -Exclude $copyExcludes -Recurse -Force
			Write-Output "Files are copied from unzip location to live...[$deployLive]"

		} -ArgumentList $currentDate, $tempFolder, $BackupLocation, $deployLive, $ProcessName
	
	Write-Output "Remove-PSSession"
	Remove-PSSession $ps_session

    Write-Output "Deployment completed."
}

# --- Main execution ---

 try {
		Write-Output "---------------------Project build start---------------------"
		Start-Build-Project
		Write-Output "---------------------Project build end---------------------"

		Write-Output "---------------------Deployment start---------------------"
		#Deploy-ClaimAPI
		Write-Output "---------------------Deployment end---------------------"

		Write-Output "---------------------Register task start---------------------"
		#Register-IISPool-Site
		Write-Output "---------------------Register task end---------------------"

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