# RethNotebook Docker Deploy Script (Windows PowerShell)
# Author: AI Assistant
# Purpose: Quick deployment of VitePress documentation site

Write-Host "Starting RethNotebook deployment..." -ForegroundColor Green

# Check if Docker is installed
try {
    docker --version | Out-Null
    Write-Host "Docker is installed" -ForegroundColor Green
} catch {
    Write-Host "Docker is not installed. Please install Docker Desktop first" -ForegroundColor Red
    exit 1
}

# Check if docker-compose is available
try {
    docker-compose --version | Out-Null
    Write-Host "docker-compose is available" -ForegroundColor Green
} catch {
    Write-Host "docker-compose is not available. Please ensure Docker Desktop is running" -ForegroundColor Red
    exit 1
}

# Stop and remove existing containers
Write-Host "Stopping existing containers..." -ForegroundColor Yellow
try {
    docker-compose down --remove-orphans 2>$null
} catch {
    # Ignore errors, might be first run
}

# Ask if cleanup old images
$cleanup = Read-Host "Do you want to cleanup old Docker images? (y/N)"
if ($cleanup -eq "y" -or $cleanup -eq "Y") {
    Write-Host "Cleaning up old images..." -ForegroundColor Yellow
    docker system prune -f
    docker image prune -f
}

# Build and start containers
Write-Host "Building Docker image..." -ForegroundColor Blue
docker-compose build --no-cache

if ($LASTEXITCODE -ne 0) {
    Write-Host "Image build failed" -ForegroundColor Red
    exit 1
}

Write-Host "Starting containers..." -ForegroundColor Blue
docker-compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Host "Container startup failed" -ForegroundColor Red
    docker-compose logs
    exit 1
}

# Wait for service to start
Write-Host "Waiting for service to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Check container status
$containerStatus = docker-compose ps
if ($containerStatus -match "Up") {
    Write-Host "Deployment successful!" -ForegroundColor Green
    Write-Host "Access URL: http://localhost:40501" -ForegroundColor Cyan
    Write-Host "View logs: docker-compose logs -f" -ForegroundColor Gray
    Write-Host "Stop service: docker-compose down" -ForegroundColor Gray
    
    # Try to open browser
    $openBrowser = Read-Host "Do you want to open browser to visit the site? (Y/n)"
    if ($openBrowser -ne "n" -and $openBrowser -ne "N") {
        Start-Process "http://localhost:40501"
    }
} else {
    Write-Host "Deployment failed, please check logs:" -ForegroundColor Red
    docker-compose logs
    exit 1
}

Write-Host "RethNotebook deployment completed!" -ForegroundColor Green