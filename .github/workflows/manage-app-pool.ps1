param(
    [string]$AppPoolName
)

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