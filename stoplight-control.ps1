<#
.SYNOPSIS
    Stoplight Control GUI - PowerShell WPF interface for ESP32 Stoplight

.DESCRIPTION
    Complete GUI application to control ESP32 Stoplight via COM port or Web API
    Features: COM/Web switching, connection testing, system tray, input fields

.AUTHOR
    Created: 2026-01-08

.NOTES
    Requires: PowerShell 5.0+, .NET Framework 4.5+
#>

param(
    [string]$ComPort = "COM5",
    [string]$WebApiUrl = "http://192.168.1.100",
    [switch]$UseTeamsPresence,
    [int]$PresencePollSeconds = 30
)

# CONFIG FILE
$script:ConfigPath = Join-Path $PSScriptRoot "stoplight-config.json"

function Load-Settings {
    if (Test-Path $script:ConfigPath) {
        try {
            $config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            return @{
                ComPort = $config.ComPort
                WebApiUrl = $config.WebApiUrl
                UseTeamsPresence = $config.UseTeamsPresence
                PresencePollSeconds = $config.PresencePollSeconds
            }
        }
        catch {
            Write-Host "Warning: Could not load config file" -ForegroundColor Yellow
        }
    }
    return @{
        ComPort = $ComPort
        WebApiUrl = $WebApiUrl
        UseTeamsPresence = $UseTeamsPresence
        PresencePollSeconds = $PresencePollSeconds
    }
}

function Save-Settings {
    param(
        [string]$ComPort,
        [string]$WebApiUrl,
        [bool]$UseTeamsPresence,
        [int]$PresencePollSeconds
    )
    try {
        $config = @{
            ComPort = $ComPort
            WebApiUrl = $WebApiUrl
            UseTeamsPresence = $UseTeamsPresence
            PresencePollSeconds = $PresencePollSeconds
            LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $config | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8
    }
    catch {
        Write-Host "Warning: Could not save config file" -ForegroundColor Yellow
    }
}

# ========== SYSTEM REQUIREMENTS CHECK ==========
Write-Host "Checking system requirements..." -ForegroundColor Cyan

$psVersion = $PSVersionTable.PSVersion.Major
if ($psVersion -lt 5) {
    Write-Host "ERROR: PowerShell 5.0+ required (current: $psVersion)" -ForegroundColor Red
    exit 1
}
Write-Host "OK: PowerShell $psVersion.0" -ForegroundColor Green

$dotnetVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Version
if (-not $dotnetVersion) {
    Write-Host "WARNING: .NET Framework 4.5+ check inconclusive" -ForegroundColor Yellow
} else {
    Write-Host "OK: .NET Framework $dotnetVersion" -ForegroundColor Green
}

try {
    [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
    Write-Host "OK: WPF available" -ForegroundColor Green
} catch {
    Write-Host "ERROR: WPF not available" -ForegroundColor Red
    exit 1
}

Write-Host "`nInitializing GUI..." -ForegroundColor Cyan

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# CONFIGURATION
$BAUD_RATE = 115200
$READ_TIMEOUT_MS = 1000
$MAX_RETRIES = 1
$RETRY_DELAY_MS = 200

$ModeNames = @{
    0 = "OFF"
    1 = "GREEN"
    2 = "ORANGE"
    3 = "RED"
    4 = "DISCO"
    5 = "FADE"
    6 = "STROBE"
    7 = "LOOP"
}

# SERIAL COMMUNICATION CLASS
class SerialConnection {
    [System.IO.Ports.SerialPort]$port
    [string]$portName
    [int]$baudRate
    [int]$readTimeoutMs
    [int]$maxRetries
    [int]$retryDelayMs
    
    SerialConnection([string]$comPort, [int]$baud, [int]$timeout, [int]$retries, [int]$retryDelay) {
        $this.portName = $comPort
        $this.baudRate = $baud
        $this.readTimeoutMs = $timeout
        $this.maxRetries = $retries
        $this.retryDelayMs = $retryDelay
        $this.port = $null
    }
    
    [bool] Open() {
        try {
            $this.port = New-Object System.IO.Ports.SerialPort($this.portName, $this.baudRate, `
                [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
            
            $this.port.Handshake = [System.IO.Ports.Handshake]::None
            $this.port.DtrEnable = $false
            $this.port.RtsEnable = $false
            $this.port.ReadTimeout = $this.readTimeoutMs
            $this.port.WriteTimeout = $this.readTimeoutMs
            $this.port.NewLine = "`n"
            
            $this.port.Open()
            Start-Sleep -Milliseconds 500
            $this.port.DiscardInBuffer()
            $this.port.DiscardOutBuffer()
            
            return $true
        }
        catch {
            return $false
        }
    }
    
    [void] Close() {
        if ($this.port -and $this.port.IsOpen) {
            try {
                $this.port.Close()
                $this.port.Dispose()
            }
            catch { }
        }
    }
    
    [PSCustomObject] SendCommand([string]$cmd) {
        return $this.SendCommandInternal($cmd, 0)
    }
    
    hidden [PSCustomObject] SendCommandInternal([string]$cmd, [int]$retryCount) {
        $result = @{
            Success = $false
            Command = $cmd
            Response = @()
            Error = $null
            Attempts = $retryCount + 1
        }
        
        if ($retryCount -gt $this.maxRetries) {
            $result.Error = "Max retries exceeded"
            return [PSCustomObject]$result
        }
        
        try {
            $this.port.WriteLine($cmd)
            $this.port.BaseStream.Flush()
            
            $responses = @()
            $ackReceived = $false
            $timeout = [DateTime]::Now.AddMilliseconds($this.readTimeoutMs)
            
            while ([DateTime]::Now -lt $timeout) {
                try {
                    if ($this.port.BytesToRead -gt 0) {
                        $line = $this.port.ReadLine()
                        
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $responses += $line.Trim()
                            
                            if ($line -match '\[ACK\]') {
                                $ackReceived = $true
                            }
                            
                            if ($line -match '\[(OK|ERR|DATA|PONG)\]') {
                                break
                            }
                        }
                    }
                    else {
                        Start-Sleep -Milliseconds 10
                    }
                }
                catch [System.TimeoutException] {
                    # Continue
                }
            }
            
            if ($responses.Count -eq 0) {
                Start-Sleep -Milliseconds $this.retryDelayMs
                return $this.SendCommandInternal($cmd, $retryCount + 1)
            }
            
            if (-not $ackReceived) {
                Start-Sleep -Milliseconds $this.retryDelayMs
                return $this.SendCommandInternal($cmd, $retryCount + 1)
            }
            
            $result.Success = $true
            $result.Response = $responses
            
            return [PSCustomObject]$result
        }
        catch {
            if ($retryCount -lt $this.maxRetries) {
                Start-Sleep -Milliseconds $this.retryDelayMs
                return $this.SendCommandInternal($cmd, $retryCount + 1)
            }
            
            $result.Error = $_.Exception.Message
            return [PSCustomObject]$result
        }
    }
}

# COMMUNICATION HELPERS
function Send-ComCommand {
    param([int]$Mode, [string]$Port)
    
    try {
        $conn = [SerialConnection]::new($Port, $BAUD_RATE, $READ_TIMEOUT_MS, $MAX_RETRIES, $RETRY_DELAY_MS)
        
        if (-not $conn.Open()) {
            return @{ Success = $false; Error = "Cannot open port $Port" }
        }
        
        try {
            $response = $conn.SendCommand("mode:$Mode")
            return @{ Success = $response.Success; Error = $response.Error; Response = $response.Response }
        }
        finally {
            $conn.Close()
        }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Send-WebCommand {
    param([int]$Mode, [string]$Url)
    
    try {
        $response = Invoke-WebRequest -Uri "$Url/api/mode?value=$Mode" -UseBasicParsing -TimeoutSec 5
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-BootMode {
    param([string]$CommunicationMode, [string]$ComPort, [string]$WebUrl)
    
    try {
        if ($CommunicationMode -eq "COM") {
            $conn = [SerialConnection]::new($ComPort, $BAUD_RATE, $READ_TIMEOUT_MS, $MAX_RETRIES, $RETRY_DELAY_MS)
            if ($conn.Open()) {
                $response = $conn.SendCommand("getBootMode")
                $conn.Close()
                if ($response.Success -and $response.Response -match "(\d+)") {
                    return [int]$Matches[1]
                }
            }
        }
        else {
            $response = Invoke-WebRequest -Uri "$WebUrl/getBootMode" -UseBasicParsing -TimeoutSec 5 | ConvertFrom-Json
            return [int]$response.mode
        }
    }
    catch { }
    
    return 1
}

function Set-BootMode {
    param([int]$Mode, [string]$CommunicationMode, [string]$ComPort, [string]$WebUrl)
    
    try {
        if ($CommunicationMode -eq "COM") {
            $conn = [SerialConnection]::new($ComPort, $BAUD_RATE, $READ_TIMEOUT_MS, $MAX_RETRIES, $RETRY_DELAY_MS)
            if ($conn.Open()) {
                $response = $conn.SendCommand("setBootMode:$Mode")
                $conn.Close()
                return $response.Success
            }
        }
        else {
            $response = Invoke-WebRequest -Uri "$WebUrl/setBootMode?mode=$Mode" -UseBasicParsing -TimeoutSec 5 | ConvertFrom-Json
            return $response.success
        }
    }
    catch { }
    
    return $false
}

function Find-StoplightPort {
    $ports = @([System.IO.Ports.SerialPort]::GetPortNames())
    
    foreach ($port in $ports) {
        try {
            $conn = [SerialConnection]::new($port, $BAUD_RATE, $READ_TIMEOUT_MS, $MAX_RETRIES, $RETRY_DELAY_MS)
            if ($conn.Open()) {
                $result = $conn.SendCommand("ping")
                $conn.Close()
                if ($result.Success) {
                    return $port
                }
            }
        }
        catch { }
    }
    
    return "COM5"
}

# TEAMSPRESENCE HELPERS
function Test-GraphModulesAvailable {
    $requiredModules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.CloudCommunications'
    )
    
    $missing = @()
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missing += $module
        }
    }
    
    return @{
        Available = ($missing.Count -eq 0)
        Missing = $missing
    }
}

function Get-PresenceScriptPath {
    # Try multiple possible locations
    $possiblePaths = @(
        (Join-Path $PSScriptRoot "Get-TeamsPresenceDelegated.ps1"),
        (Join-Path (Split-Path $PSCommandPath) "Get-TeamsPresenceDelegated.ps1"),
        (Join-Path (Get-Location) "Get-TeamsPresenceDelegated.ps1"),
        "C:\Git\Operations\EntraID\teams Status\Get-TeamsPresenceDelegated.ps1"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # If not found, return the first option and let caller handle the error
    return $possiblePaths[0]
}

function Map-PresenceColorToMode {
    param([string]$Color)
    switch ($Color) {
        'Green' { return 1 }
        'Red' { return 3 }
        'Orange' { return 2 }
        'Yellow' { return 2 }
        default { return 2 }
    }
}

function Set-StoplightMode {
    param(
        [int]$Mode,
        [string]$Source = "Manual"
    )
    $result = $null
    if ($script:CommunicationMode -eq "COM") {
        $result = Send-ComCommand -Mode $Mode -Port $script:ComPort
    }
    else {
        $result = Send-WebCommand -Mode $Mode -Url $script:WebApiUrl
    }
    if (-not $result.Success) {
        if ($StatusLabel) {
            $StatusLabel.Text = "Error: $($result.Error)"
            $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Red
        }
    }
    else {
        if ($StatusLabel) {
            $StatusLabel.Text = "${Source}: $($ModeNames[$Mode])"
            $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Green
        }
    }
    return $result
}

function Handle-PresenceUpdate {
    param($Presence)
    if (-not $Presence) { return }
    $mode = Map-PresenceColorToMode -Color $Presence.Color
    $script:PresenceLastMode = $mode
    Set-StoplightMode -Mode $mode -Source "Teams"
    if ($PresenceStatus) {
        $PresenceStatus.Text = "Teams: $($Presence.Availability) / $($ModeNames[$mode])"
        $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
    }
    if ($PresenceLastUpdate) {
        $PresenceLastUpdate.Text = "Laatste update: $($Presence.Timestamp)"
    }
}

function Stop-PresenceMonitor {
    if ($script:PresencePollTimer) {
        $script:PresencePollTimer.Stop()
    }
    if ($script:PresenceJob) {
        try {
            Stop-Job -Job $script:PresenceJob -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $script:PresenceJob -Force -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
    $script:PresenceJob = $null
    $script:PresenceLastMode = $null
    if ($PresenceStatus) {
        $PresenceStatus.Text = "Teams sync uit"
        $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::Gray
    }
}

function Poll-PresenceJobOutput {
    if (-not $script:PresenceJob) { return }
    try {
        # Check job state - it should be running
        if ($script:PresenceJob.State -in @('Completed','Failed','Stopped')) {
            Write-Host "Presence job ended with state: $($script:PresenceJob.State)" -ForegroundColor Yellow
            # Try to get any error output
            $errors = $script:PresenceJob.ChildJobs[0].Error 2>$null
            if ($errors) {
                Write-Host "Job errors: $errors" -ForegroundColor Red
            }
            Stop-PresenceMonitor
            if ($PresenceStatus) {
                $PresenceStatus.Text = "Teams sync stond af (job beëindigd)"
                $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::Red
            }
            return
        }
        
        # Receive all new output from the job (without -Keep so it's consumed)
        $outputs = Receive-Job -Job $script:PresenceJob -ErrorAction SilentlyContinue
        foreach ($item in $outputs) {
            if ($item -is [pscustomobject] -and $item.PSObject.Properties.Name -contains 'Availability') {
                Handle-PresenceUpdate -Presence $item
            }
        }
    }
    catch { 
        Write-Host "Error polling presence job: $_" -ForegroundColor Red
    }
}

function Start-PresenceMonitor {
    param([int]$PollSeconds)
    
    # Check if required modules are installed
    $moduleCheck = Test-GraphModulesAvailable
    if (-not $moduleCheck.Available) {
        $missingList = $moduleCheck.Missing -join ', '
        $message = "Microsoft Graph modules niet geïnstalleerd: $missingList`n`nInstalleer met:`nInstall-Module $($moduleCheck.Missing -join ',') -Scope CurrentUser -Force"
        
        if ($PresenceStatus) {
            $PresenceStatus.Text = "Graph modules ontbreken"
            $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::Red
        }
        
        Write-Host "ERROR: Required modules not installed" -ForegroundColor Red
        Write-Host $message -ForegroundColor Yellow
        
        $result = [System.Windows.MessageBox]::Show(
            $message,
            "Microsoft Graph Modules Vereist",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        
        return
    }
    
    $path = Get-PresenceScriptPath
    if (-not (Test-Path $path)) {
        if ($PresenceStatus) {
            $PresenceStatus.Text = "Teams script niet gevonden: $path"
            $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::Red
        }
        Write-Host "ERROR: Teams script not found at: $path" -ForegroundColor Red
        Write-Host "Searched in: PSScriptRoot=$PSScriptRoot, PSCommandPath=$PSCommandPath, CWD=$(Get-Location)" -ForegroundColor Yellow
        return
    }
    
    Stop-PresenceMonitor
    try {
        # Start the presence script - will authenticate on first run only
        Write-Host "Starting Teams presence monitor from: $path" -ForegroundColor Green
        $script:PresenceJob = Start-Job -FilePath $path -ArgumentList @($PollSeconds, 0) -ErrorAction Stop
        if (-not $script:PresencePollTimer) {
            $script:PresencePollTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:PresencePollTimer.Interval = [TimeSpan]::FromSeconds(5)
            $script:PresencePollTimer.Add_Tick({ Poll-PresenceJobOutput })
        }
        $script:PresencePollTimer.Start()
        if ($PresenceStatus) {
            $PresenceStatus.Text = "Teams sync actief (poll $PollSeconds s)"
            $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::Yellow
        }
    }
    catch {
        if ($PresenceStatus) {
            $PresenceStatus.Text = "Fout bij starten sync: $($_.Exception.Message)"
            $PresenceStatus.Foreground = [System.Windows.Media.Brushes]::Red
        }
        Write-Host "ERROR starting presence monitor: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# CREATE STOPLIGHT ICON
function Get-StoplightIcon {
    # Create a simple stoplight icon programmatically
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    
    # Background (dark gray rectangle)
    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(50, 50, 50))
    $graphics.FillRectangle($bgBrush, 4, 0, 8, 16)
    
    # Red light (top)
    $redBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 50, 50))
    $graphics.FillEllipse($redBrush, 5, 1, 6, 4)
    
    # Yellow light (middle)
    $yellowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 200, 0))
    $graphics.FillEllipse($yellowBrush, 5, 6, 6, 4)
    
    # Green light (bottom)
    $greenBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(50, 220, 50))
    $graphics.FillEllipse($greenBrush, 5, 11, 6, 4)
    
    $graphics.Dispose()
    $bgBrush.Dispose()
    $redBrush.Dispose()
    $yellowBrush.Dispose()
    $greenBrush.Dispose()
    
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

# LOAD WPF ASSEMBLIES
try {
    [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
    Write-Host "WPF Assemblies loaded" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to load WPF assemblies: $_" -ForegroundColor Red
    exit 1
}

# Load saved settings
$savedSettings = Load-Settings
$ComPort = $savedSettings.ComPort
$WebApiUrl = $savedSettings.WebApiUrl
$UseTeamsPresence = [bool]$savedSettings.UseTeamsPresence
if ($savedSettings.PresencePollSeconds) {
    $PresencePollSeconds = [int]$savedSettings.PresencePollSeconds
}
Write-Host "Loaded settings: COM=$ComPort, Web=$WebApiUrl" -ForegroundColor Green

# Keep icon reference in script scope to prevent garbage collection
$script:StoplightIcon = $null

# XAML GUI DEFINITION
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Stoplight Control" 
        Width="650" Height="900" 
        Background="#1a1a2e"
        Foreground="White"
        WindowStyle="SingleBorderWindow"
        ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="CenterScreen">
    
    <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="20">
            <TextBlock Text="Stoplight Control" FontSize="32" FontWeight="Bold" Margin="0,0,0,5"/>
            <TextBlock Text="Control Panel" FontSize="14" Foreground="#aaaaaa" Margin="0,0,0,20"/>
            
            <Border Background="#252535" CornerRadius="12" Padding="15" Margin="0,0,0,20" BorderThickness="1" BorderBrush="#404050">
                <StackPanel>
                    <TextBlock Text="Communicatie" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
                    
                    <TextBlock Text="COM Port:" FontSize="12" Foreground="#aaa" Margin="0,5,0,5"/>
                    <TextBox Name="TxtComPort" Text="COM5" FontSize="14" Padding="8" Background="#1a1a2e" Foreground="White" BorderBrush="#404050" BorderThickness="1" Margin="0,0,0,10"/>
                    
                    <TextBlock Text="Web API URL:" FontSize="12" Foreground="#aaa" Margin="0,5,0,5"/>
                    <TextBox Name="TxtWebApiUrl" Text="http://192.168.1.100" FontSize="14" Padding="8" Background="#1a1a2e" Foreground="White" BorderBrush="#404050" BorderThickness="1" Margin="0,0,0,15"/>
                    
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button Name="BtnComMode" Grid.Column="0" Content="COM Port" Background="#4CAF50" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnWebMode" Grid.Column="1" Content="Web API" Background="#2d2d44" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                    </Grid>
                    <TextBlock Name="StatusLabel" Text="Status: Ready" FontSize="12" Foreground="#ffaa00" Margin="0,10,0,0"/>
                </StackPanel>
            </Border>
            
            <Border Background="#252535" CornerRadius="12" Padding="15" Margin="0,0,0,20" BorderThickness="1" BorderBrush="#404050">
                <StackPanel>
                    <TextBlock Text="Directe Besturing" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
                    <UniformGrid Columns="2">
                        <Button Name="BtnGreen" Content="GREEN" Background="#4CAF50" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnOrange" Content="ORANGE" Background="#ff9800" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnRed" Content="RED" Background="#f44336" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnDisco" Content="DISCO" Background="#9c27b0" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnFade" Content="FADE" Background="#ffd700" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="#222"/>
                        <Button Name="BtnStrobe" Content="STROBE" Background="#cccccc" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="#222"/>
                        <Button Name="BtnLoop" Content="LOOP" Background="#00ff00" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="#222"/>
                        <Button Name="BtnOff" Content="OFF" Background="#555555" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                    </UniformGrid>
                </StackPanel>
            </Border>
            
            <Border Background="#252535" CornerRadius="12" Padding="15" Margin="0,0,0,20" BorderThickness="1" BorderBrush="#404050">
                <StackPanel>
                    <TextBlock Text="Boot Mode" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
                    <TextBlock Text="Default mode on startup:" FontSize="12" Foreground="#aaa" Margin="0,0,0,8"/>
                    <Border Background="#1a1a2e" Padding="10" CornerRadius="6" Margin="0,0,0,10">
                        <TextBlock Name="BootModeDisplay" Text="Loading..." FontSize="12" Foreground="#4CAF50" FontWeight="Bold"/>
                    </Border>
                    <UniformGrid Columns="2">
                        <Button Name="BtnBootOff" Content="OFF" Background="#555555" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnBootGreen" Content="GREEN" Background="#4CAF50" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnBootOrange" Content="ORANGE" Background="#ff9800" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                        <Button Name="BtnBootRed" Content="RED" Background="#f44336" Margin="5" Padding="15,12" FontSize="14" FontWeight="Bold" Foreground="White"/>
                    </UniformGrid>
                    <TextBlock Name="BootModeStatus" Text="" FontSize="11" Foreground="#90EE90" Margin="0,10,0,0"/>
                </StackPanel>
            </Border>
            
            <Border Background="#252535" CornerRadius="12" Padding="15" Margin="0,0,0,20" BorderThickness="1" BorderBrush="#404050">
                <StackPanel>
                    <TextBlock Text="Teams Presence" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
                    <TextBlock Text="Gebruik je Teams status om het stoplicht automatisch te zetten" FontSize="12" Foreground="#aaa" Margin="0,0,0,10"/>
                    <CheckBox Name="ChkPresenceSync" Content="Synchroniseer met Teams" FontSize="14" Padding="6" Background="#1a1a2e" Foreground="White" BorderBrush="#404050" BorderThickness="1" Margin="0,0,0,10"/>
                    <TextBlock Text="Poll interval (seconden):" FontSize="12" Foreground="#aaa" Margin="0,10,0,5"/>
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                        <TextBox Name="TxtPollSeconds" Width="60" FontSize="12" Padding="6" Background="#1a1a2e" Foreground="White" BorderBrush="#404050" BorderThickness="1" Text="30" HorizontalAlignment="Left"/>
                        <TextBlock Text="Standaard: 30 sec" FontSize="11" Foreground="#888" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Name="PresenceStatus" Text="Teams sync uit" FontSize="12" Foreground="#888888" Margin="0,5,0,0"/>
                    <TextBlock Name="PresenceLastUpdate" Text="Laatste update: -" FontSize="11" Foreground="#666666" Margin="0,2,0,0"/>
                </StackPanel>
            </Border>
            
            <Border Background="#252535" CornerRadius="12" Padding="15" Margin="0,0,0,20" BorderThickness="1" BorderBrush="#404050">
                <StackPanel>
                    <TextBlock Text="Settings" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
                    <Button Name="BtnReboot" Content="RESTART DEVICE" Background="#9c27b0" Padding="15,15" FontSize="14" FontWeight="Bold" Foreground="White" Margin="5"/>
                    <TextBlock Name="RebootStatus" Text="" FontSize="11" Foreground="#90EE90" Margin="0,10,0,0"/>
                </StackPanel>
            </Border>
            
            <TextBlock Text="Minimize to system tray" FontSize="11" Foreground="#666666" Margin="0,20,0,0" TextAlignment="Center"/>
        </StackPanel>
    </ScrollViewer>
</Window>
"@

# Parse XAML
try {
    Write-Host "Parsing XAML..." -ForegroundColor Cyan
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    Write-Host "XAML parsed successfully" -ForegroundColor Green
    
    # Set window icon - keep reference in script scope
    try {
        $script:StoplightIcon = Get-StoplightIcon
        $bitmapSource = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $script:StoplightIcon.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
        )
        $bitmapSource.Freeze()  # Make it thread-safe
        $window.Icon = $bitmapSource
        Write-Host "Window icon set" -ForegroundColor Green
    }
    catch {
        Write-Host "Warning: Could not set window icon: $_" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "ERROR: Failed to parse XAML: $_" -ForegroundColor Red
    exit 1
}

# Get control references
try {
    Write-Host "Loading UI controls..." -ForegroundColor Cyan
    $TxtComPort = $window.FindName("TxtComPort")
    $TxtWebApiUrl = $window.FindName("TxtWebApiUrl")
    
    # Set saved values
    $TxtComPort.Text = $ComPort
    $TxtWebApiUrl.Text = $WebApiUrl
    
    $BtnComMode = $window.FindName("BtnComMode")
    $BtnWebMode = $window.FindName("BtnWebMode")
    $StatusLabel = $window.FindName("StatusLabel")
    $BtnGreen = $window.FindName("BtnGreen")
    $BtnOrange = $window.FindName("BtnOrange")
    $BtnRed = $window.FindName("BtnRed")
    $BtnDisco = $window.FindName("BtnDisco")
    $BtnFade = $window.FindName("BtnFade")
    $BtnStrobe = $window.FindName("BtnStrobe")
    $BtnLoop = $window.FindName("BtnLoop")
    $BtnOff = $window.FindName("BtnOff")
    $BtnBootOff = $window.FindName("BtnBootOff")
    $BtnBootGreen = $window.FindName("BtnBootGreen")
    $BtnBootOrange = $window.FindName("BtnBootOrange")
    $BtnBootRed = $window.FindName("BtnBootRed")
    $BootModeDisplay = $window.FindName("BootModeDisplay")
    $BootModeStatus = $window.FindName("BootModeStatus")
    $ChkPresenceSync = $window.FindName("ChkPresenceSync")
    $PresenceStatus = $window.FindName("PresenceStatus")
    $PresenceLastUpdate = $window.FindName("PresenceLastUpdate")
    $TxtPollSeconds = $window.FindName("TxtPollSeconds")
    $BtnReboot = $window.FindName("BtnReboot")
    $RebootStatus = $window.FindName("RebootStatus")
    Write-Host "UI controls loaded" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to load UI controls: $_" -ForegroundColor Red
    exit 1
}

# SCRIPT VARIABLES
$script:CommunicationMode = "COM"
$script:ComPort = $ComPort
$script:WebApiUrl = $WebApiUrl
$script:UseTeamsPresence = [bool]$UseTeamsPresence
$script:PresencePollSeconds = $PresencePollSeconds
$script:PresenceJob = $null
$script:PresencePollTimer = $null
$script:PresenceLastMode = $null
$script:notifyIcon = $null

# FUNCTIONS
function Update-ConnectionStatus {
    if ($script:CommunicationMode -eq "COM") {
        $StatusLabel.Text = "Mode: COM Port ($($script:ComPort))"
    }
    else {
        $StatusLabel.Text = "Mode: Web API ($($script:WebApiUrl))"
    }
}

function Test-Connection {
    param([string]$Mode)
    
    $StatusLabel.Text = "Testing connection..."
    $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Yellow
    
    if ($Mode -eq "COM") {
        $port = $TxtComPort.Text
        $script:ComPort = $port
        
        try {
            $conn = [SerialConnection]::new($port, $BAUD_RATE, $READ_TIMEOUT_MS, $MAX_RETRIES, $RETRY_DELAY_MS)
            if ($conn.Open()) {
                $result = $conn.SendCommand("ping")
                $conn.Close()
                
                if ($result.Success) {
                    $StatusLabel.Text = "Connected: $port"
                    $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Green
                    return $true
                }
            }
            $StatusLabel.Text = "Error: Cannot connect to $port"
            $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Red
            return $false
        }
        catch {
            $StatusLabel.Text = "Error: $($_.Exception.Message)"
            $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Red
            return $false
        }
    }
    else {
        $url = $TxtWebApiUrl.Text
        $script:WebApiUrl = $url
        
        try {
            $response = Invoke-WebRequest -Uri "$url/api/mode?value=1" -UseBasicParsing -TimeoutSec 3
            $StatusLabel.Text = "Connected: $url"
            $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Green
            return $true
        }
        catch {
            $StatusLabel.Text = "Error: Cannot connect to $url"
            $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Red
            return $false
        }
    }
}

function OnCommunicationModeChanged {
    param($sender)
    
    if ($sender -eq $BtnComMode) {
        if (Test-Connection -Mode "COM") {
            $script:CommunicationMode = "COM"
            $BtnComMode.Background = [System.Windows.Media.Brushes]::Green
            $BtnWebMode.Background = "#2d2d44"
            Update-ConnectionStatus
            Refresh-BootModeDisplay
        }
    }
    else {
        if (Test-Connection -Mode "Web") {
            $script:CommunicationMode = "Web"
            $BtnWebMode.Background = [System.Windows.Media.Brushes]::Green
            $BtnComMode.Background = "#2d2d44"
            Update-ConnectionStatus
            Refresh-BootModeDisplay
        }
    }
}

function OnModeClick {
    param($sender)
    
    $modeMap = @{
        $BtnGreen = 1
        $BtnOrange = 2
        $BtnRed = 3
        $BtnDisco = 4
        $BtnFade = 5
        $BtnStrobe = 6
        $BtnLoop = 7
        $BtnOff = 0
    }
    
    $mode = $modeMap[$sender]
    Set-StoplightMode -Mode $mode -Source "Manual"
}

function OnBootModeClick {
    param($sender)
    
    $modeMap = @{
        $BtnBootOff = 0
        $BtnBootGreen = 1
        $BtnBootOrange = 2
        $BtnBootRed = 3
    }
    
    $mode = $modeMap[$sender]
    
    $success = Set-BootMode -Mode $mode -CommunicationMode $script:CommunicationMode -ComPort $script:ComPort -WebUrl $script:WebApiUrl
    
    if ($success) {
        $BootModeStatus.Text = "Saved: $($ModeNames[$mode])"
        $BootModeStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
        Start-Sleep -Milliseconds 2000
        Refresh-BootModeDisplay
    }
    else {
        $BootModeStatus.Text = "Error saving"
        $BootModeStatus.Foreground = [System.Windows.Media.Brushes]::Red
    }
}

function Refresh-BootModeDisplay {
    $mode = Get-BootMode -CommunicationMode $script:CommunicationMode -ComPort $script:ComPort -WebUrl $script:WebApiUrl
    $BootModeDisplay.Text = $ModeNames[$mode]
}

function OnPresenceSyncChanged {
    if ($ChkPresenceSync.IsChecked) {
        # Validate poll seconds input
        $pollInput = $TxtPollSeconds.Text
        if (-not [int]::TryParse($pollInput, [ref]$script:PresencePollSeconds)) {
            $script:PresencePollSeconds = 30
            $TxtPollSeconds.Text = "30"
        }
        else {
            $script:PresencePollSeconds = [int]$pollInput
        }
        
        $script:UseTeamsPresence = $true
        Save-Settings -ComPort $script:ComPort -WebApiUrl $script:WebApiUrl -UseTeamsPresence $script:UseTeamsPresence -PresencePollSeconds $script:PresencePollSeconds
        Start-PresenceMonitor -PollSeconds $script:PresencePollSeconds
    }
    else {
        $script:UseTeamsPresence = $false
        Stop-PresenceMonitor
        Save-Settings -ComPort $script:ComPort -WebApiUrl $script:WebApiUrl -UseTeamsPresence $script:UseTeamsPresence -PresencePollSeconds $script:PresencePollSeconds
    }
}


# SYSTEM TRAY SETUP
function Initialize-SystemTray {
    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    
    try {
        $script:notifyIcon.Icon = Get-StoplightIcon
    }
    catch {
        $script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
    
    $script:notifyIcon.Text = "Stoplight Control"
    $script:notifyIcon.Visible = $false
    
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $menuItemRestore = New-Object System.Windows.Forms.ToolStripMenuItem("Open")
    $menuItemExit = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    
    $menuItemRestore.Add_Click({
        $window.Show()
        $window.WindowState = [System.Windows.WindowState]::Normal
        $window.Activate()
        $script:notifyIcon.Visible = $false
    })
    
    $menuItemExit.Add_Click({
        if ($script:notifyIcon) {
            $script:notifyIcon.Visible = $false
            $script:notifyIcon.Dispose()
        }
        $window.Close()
        [System.Windows.Application]::Current.Shutdown()
        Stop-Process -Id $PID -Force
    })
    
    $contextMenu.Items.Add($menuItemRestore) | Out-Null
    $contextMenu.Items.Add($menuItemExit) | Out-Null
    $script:notifyIcon.ContextMenuStrip = $contextMenu
    
    $script:notifyIcon.Add_DoubleClick({
        $window.Show()
        $window.WindowState = [System.Windows.WindowState]::Normal
        $window.Activate()
        $script:notifyIcon.Visible = $false
    })
}

Initialize-SystemTray

# Window state change handler for system tray
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $window.Hide()
        $script:notifyIcon.Visible = $true
        $script:notifyIcon.ShowBalloonTip(2000, "Stoplight Control", "Minimized to system tray", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# Window closing handler
$window.Add_Closing({
    param($sender, $e)
    
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
    
    Stop-PresenceMonitor
    
    # Force application shutdown
    [System.Windows.Application]::Current.Shutdown()
    
    # Kill PowerShell process
    Stop-Process -Id $PID -Force
})

# REGISTER EVENTS
$TxtComPort.Add_TextChanged({
    $script:ComPort = $TxtComPort.Text
    Save-Settings -ComPort $script:ComPort -WebApiUrl $script:WebApiUrl -UseTeamsPresence $script:UseTeamsPresence -PresencePollSeconds $script:PresencePollSeconds
})

$TxtWebApiUrl.Add_TextChanged({
    $script:WebApiUrl = $TxtWebApiUrl.Text
    Save-Settings -ComPort $script:ComPort -WebApiUrl $script:WebApiUrl -UseTeamsPresence $script:UseTeamsPresence -PresencePollSeconds $script:PresencePollSeconds
})

$BtnComMode.Add_Click({ OnCommunicationModeChanged $BtnComMode })
$BtnWebMode.Add_Click({ OnCommunicationModeChanged $BtnWebMode })

$BtnGreen.Add_Click({ OnModeClick $BtnGreen })
$BtnOrange.Add_Click({ OnModeClick $BtnOrange })
$BtnRed.Add_Click({ OnModeClick $BtnRed })
$BtnDisco.Add_Click({ OnModeClick $BtnDisco })
$BtnFade.Add_Click({ OnModeClick $BtnFade })
$BtnStrobe.Add_Click({ OnModeClick $BtnStrobe })
$BtnLoop.Add_Click({ OnModeClick $BtnLoop })
$BtnOff.Add_Click({ OnModeClick $BtnOff })

$BtnBootOff.Add_Click({ OnBootModeClick $BtnBootOff })
$BtnBootGreen.Add_Click({ OnBootModeClick $BtnBootGreen })
$BtnBootOrange.Add_Click({ OnBootModeClick $BtnBootOrange })
$BtnBootRed.Add_Click({ OnBootModeClick $BtnBootRed })

$ChkPresenceSync.Add_Checked({ OnPresenceSyncChanged })
$ChkPresenceSync.Add_Unchecked({ OnPresenceSyncChanged })

$TxtPollSeconds.Add_TextChanged({
    $newPollSeconds = 0
    if ([int]::TryParse($TxtPollSeconds.Text, [ref]$newPollSeconds)) {
        $script:PresencePollSeconds = $newPollSeconds
        Save-Settings -ComPort $script:ComPort -WebApiUrl $script:WebApiUrl -UseTeamsPresence $script:UseTeamsPresence -PresencePollSeconds $script:PresencePollSeconds
    }
})

$BtnReboot.Add_Click({
    $result = [System.Windows.MessageBox]::Show("Restart device?", "Confirm", [System.Windows.MessageBoxButton]::OKCancel)
    if ($result -eq [System.Windows.MessageBoxResult]::OK) {
        try {
            if ($script:CommunicationMode -eq "COM") {
                $conn = [SerialConnection]::new($script:ComPort, $BAUD_RATE, $READ_TIMEOUT_MS, $MAX_RETRIES, $RETRY_DELAY_MS)
                if ($conn.Open()) {
                    $conn.SendCommand("reboot") | Out-Null
                    $conn.Close()
                }
            }
            else {
                Invoke-WebRequest -Uri "$($script:WebApiUrl)/reboot" -UseBasicParsing -TimeoutSec 5 | Out-Null
            }
            $RebootStatus.Text = "Rebooting..."
            $RebootStatus.Foreground = [System.Windows.Media.Brushes]::Green
        }
        catch {
            $RebootStatus.Text = "Failed"
            $RebootStatus.Foreground = [System.Windows.Media.Brushes]::Red
        }
    }
})

# INITIALIZATION
$TxtComPort.Text = $ComPort
$TxtWebApiUrl.Text = $WebApiUrl
$TxtPollSeconds.Text = $PresencePollSeconds
$ChkPresenceSync.IsChecked = $UseTeamsPresence
Update-ConnectionStatus
Refresh-BootModeDisplay
if ($UseTeamsPresence) {
    Start-PresenceMonitor -PollSeconds $script:PresencePollSeconds
}

# Auto-detect COM port
if ($ComPort -eq "COM5") {
    $detected = Find-StoplightPort
    if ($detected -ne "COM5") {
        $script:ComPort = $detected
        $TxtComPort.Text = $detected
        Update-ConnectionStatus
    }
}

# SHOW WINDOW
Write-Host "Launching window..." -ForegroundColor Green
$window.Show()
$window.Activate()
$window.Focus()
$window.Topmost = $true
$window.Topmost = $false

# Start WPF message pump
[System.Windows.Threading.Dispatcher]::Run()