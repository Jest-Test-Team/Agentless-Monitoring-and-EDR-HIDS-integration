# Windows Tier 2 Deployment Guide

Windows bare-metal hosts need **Sysmon** (system call monitoring) + **Wazuh Agent** for EDR/HIDS coverage. This guide covers installation and configuration.

## Prerequisites

| Component | Version | Source |
|-----------|---------|--------|
| Windows Server | 2019/2022 or Win 10/11 Pro | — |
| Wazuh Agent | 4.x | `https://packages.wazuh.com/4.x/windows/wazuh-agent-4.x.msi` |
| Sysmon | 14.x | `https://download.sysinternals.com/files/Sysmon.zip` |
| Sysmon Modular Config | latest | `https://github.com/SwiftOnSecurity/sysmon-config` |

## 1. Sysmon Installation

### 1.1 Download & Install

```powershell
# Download Sysmon
Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile "$env:TEMP\Sysmon.zip"
Expand-Archive -Path "$env:TEMP\Sysmon.zip" -DestinationPath "$env:TEMP\Sysmon"

# Download SwiftOnSecurity config
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile "$env:TEMP\Sysmon\sysmonconfig.xml"

# Install Sysmon with config
$sysmonDir = "$env:ProgramFiles\Sysmon"
New-Item -ItemType Directory -Force -Path $sysmonDir
Copy-Item "$env:TEMP\Sysmon\*" -Destination $sysmonDir -Force
& "$sysmonDir\Sysmon64.exe" -accepteula -i "$env:TEMP\Sysmon\sysmonconfig.xml"

# Verify
Get-Service -Name Sysmon64
Get-WinEvent -LogName "Microsoft-Windows-Sysmon/Operational" -MaxEvents 5
```

### 1.2 Sysmon Event Logs

Sysmon writes to: `Applications and Services Logs/Microsoft-Windows-Sysmon/Operational`

Key Event IDs:

| Event ID | Description | Importance |
|----------|-------------|------------|
| 1 | Process creation | Critical |
| 3 | Network connection | Critical |
| 7 | Image loaded | High |
| 8 | CreateRemoteThread | Critical |
| 10 | ProcessAccess | Critical |
| 11 | FileCreate | High |
| 15 | FileCreateStreamHash | Medium |
| 22 | DNSEvent | Critical |

## 2. Wazuh Agent Installation

### 2.1 Install Agent

```powershell
$manager = "10.0.0.30"
$agentName = "$env:COMPUTERNAME"
Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.0-1.msi" -OutFile "$env:TEMP\wazuh-agent.msi"

msiexec /i "$env:TEMP\wazuh-agent.msi" /quiet `
    WAZUH_MANAGER="$manager" `
    WAZUH_AGENT_NAME="$agentName" `
    WAZUH_REGISTRATION_SERVER="$manager"

Start-Service -Name WazuhSvc
```

### 2.2 Configure ossec.conf for Windows

Edit `C:\Program Files (x86)\ossec-agent\ossec.conf`:

```xml
<ossec_config>
  <client>
    <server>
      <address>10.0.0.30</address>
      <port>1514</port>
      <protocol>TCP</protocol>
    </server>
  </client>

  <syscheck>
    <frequency>3600</frequency>
    <directories check_all="yes">%WINDIR%\System32,%WINDIR%\SysWOW64</directories>
    <directories check_all="yes" realtime="yes">%WINDIR%\Temp</directories>
  </syscheck>

  <rootcheck>
    <frequency>1800</frequency>
  </rootcheck>

  <!-- Sysmon channel -->
  <localfile>
    <log_format>eventchannel</log_format>
    <location>Microsoft-Windows-Sysmon/Operational</location>
  </localfile>

  <!-- Security channel -->
  <localfile>
    <log_format>eventchannel</log_format>
    <location>Security</location>
  </localfile>

  <!-- PowerShell operational -->
  <localfile>
    <log_format>eventchannel</log_format>
    <location>Microsoft-Windows-PowerShell/Operational</location>
  </localfile>
</ossec_config>
```

### 2.3 Verify Agent Connection

```powershell
& "C:\Program Files (x86)\ossec-agent\agent_control.exe" -l
```

## 3. Wazuh Server Rules for Windows Events

On the Wazuh Manager (`/var/ossec/etc/rules/local_rules.xml`):

```xml
<group name="windows_sysmon">
  <rule id="100001" level="7">
    <if_group>windows_sysmon</if_group>
    <field name="win.eventdata.eventID">1</field>
    <description>Windows Sysmon: Process created - $(win.eventdata.image)</description>
  </rule>

  <rule id="100002" level="5">
    <if_group>windows_sysmon</if_group>
    <field name="win.eventdata.eventID">3</field>
    <description>Windows Sysmon: Network connection - $(win.eventdata.destinationIp):$(win.eventdata.destinationPort)</description>
  </rule>

  <rule id="100003" level="12">
    <if_group>windows_sysmon</if_group>
    <field name="win.eventdata.eventID">8</field>
    <description>Windows Sysmon: CreateRemoteThread detected - potential injection</description>
  </rule>

  <rule id="100004" level="12">
    <if_group>windows_sysmon</if_group>
    <field name="win.eventdata.eventID">10</field>
    <description>Windows Sysmon: ProcessAccess detected - potential credential dumping</description>
  </rule>
</group>
```

## 4. Windows Osquery (Optional)

```powershell
# Download osquery MSI
Invoke-WebRequest -Uri "https://pkg.osquery.io/windows/osquery-5.12.0.msi" -OutFile "$env:TEMP\osquery.msi"
msiexec /i "$env:TEMP\osquery.msi" /quiet

# Place osquery.conf in C:\ProgramData\osquery\
```

## 5. Log Shipping to Logstash

If not using Wazuh Manager, ship Windows Event logs directly via Winlogbeat:

```powershell
# Install Winlogbeat
# Configure winlogbeat.yml → output.logstash hosts: ["10.0.0.20:5044"]
```

## 6. Verify the Full Pipeline

```powershell
# Trigger a test event
Start-Process notepad.exe

# Check Sysmon
Get-WinEvent -LogName "Microsoft-Windows-Sysmon/Operational" -MaxEvents 1 | Format-List

# Check Wazuh agent log
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" -Tail 20

# Check OpenSearch (from management host)
# curl -s 'http://10.0.0.10:9200/security-events-*/_search?q=win.eventdata.eventID:1'
```
