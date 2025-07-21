param(
    [string]$SiteName,
    [string]$AppPoolName,
    [string]$DeployPath,
    [string]$HostName,
    [string]$IPAddress,
    [string]$Port
)

# Create deployment folder if not exists
if (-Not (Test-Path $DeployPath)) {
    New-Item -Path $DeployPath -ItemType Directory
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