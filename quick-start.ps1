# RethNotebook Quick Start Script (No Docker Required)
# Author: AI Assistant
# Purpose: Start local development server without Docker

Write-Host "Starting RethNotebook local development server..." -ForegroundColor Green

# Check if Node.js is installed
try {
    $nodeVersion = node --version
    Write-Host "Node.js version: $nodeVersion" -ForegroundColor Green
} catch {
    Write-Host "Node.js is not installed. Please install Node.js from https://nodejs.org/" -ForegroundColor Red
    Write-Host "Recommended version: Node.js 18 or higher" -ForegroundColor Yellow
    exit 1
}

# Check if npm is available
try {
    $npmVersion = npm --version
    Write-Host "npm version: $npmVersion" -ForegroundColor Green
} catch {
    Write-Host "npm is not available" -ForegroundColor Red
    exit 1
}

# Install dependencies if node_modules doesn't exist
if (-not (Test-Path "node_modules")) {
    Write-Host "Installing dependencies..." -ForegroundColor Yellow
    npm install
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to install dependencies" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Dependencies already installed" -ForegroundColor Green
}

# Start development server
Write-Host "Starting development server..." -ForegroundColor Blue
Write-Host "Access URL: http://localhost:5173" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Gray
Write-Host "" -ForegroundColor White

# Ask if open browser
$openBrowser = Read-Host "Do you want to open browser? (Y/n)"
if ($openBrowser -ne "n" -and $openBrowser -ne "N") {
    Start-Sleep -Seconds 3
    Start-Process "http://localhost:5173"
}

# Start the server
npm run dev