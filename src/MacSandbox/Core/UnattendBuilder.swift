// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import Foundation

/// Windows unattended answer (unattend.xml) and first-logon provisioning script generation.
///
/// Windows limits each FirstLogonCommands/CommandLine value to 1,024 characters. Keep the answer
/// file command short and put the actual provisioning logic in a PowerShell file copied offline.
final class UnattendBuilder {
    static let provisioningDirectory = #"C:\ProgramData\MacSandbox"#
    static let provisioningScriptPath = #"C:\ProgramData\MacSandbox\Provision.ps1"#
    static let maximumCommandLineLength = 1_024

    enum UnattendError: LocalizedError {
        case invalidXML(String)
        case commandLineTooLong(length: Int)

        var errorDescription: String? {
            switch self {
            case .invalidXML(let reason):
                return "Generated unattend.xml is invalid: \(reason)"
            case .commandLineTooLong(let length):
                return "Generated unattend.xml contains a \(length)-character CommandLine value; Windows allows at most \(UnattendBuilder.maximumCommandLineLength)."
            }
        }
    }

    /// Panther unattend for the first boot after DISM offline application.
    /// Uses only the oobeSystem pass and invokes one short, external provisioning script.
    func generatePantherXML(config: InstallConfig) throws -> String {
        let locale = config.locale
        let xml = #"""
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend"
                  xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-International-Core" processorArchitecture="arm64"
                           publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                    <InputLocale>\#(locale)</InputLocale>
                    <UILanguage>\#(locale)</UILanguage>
                    <UserLocale>\#(locale)</UserLocale>
                    <SystemLocale>\#(locale)</SystemLocale>
                </component>
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"
                           publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                    <OOBE>
                        <HideEULAPage>true</HideEULAPage>
                        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                        <ProtectYourPC>3</ProtectYourPC>
                        <SkipMachineOOBE>true</SkipMachineOOBE>
                        <SkipUserOOBE>true</SkipUserOOBE>
                    </OOBE>
                    <UserAccounts>
                        <LocalAccounts>
                            <LocalAccount wcm:action="add">
                                <Name>sandboxsetup</Name>
                                <DisplayName>sandboxsetup</DisplayName>
                                <Group>Administrators</Group>
                                <Password>
                                    <Value></Value>
                                    <PlainText>true</PlainText>
                                </Password>
                            </LocalAccount>
                        </LocalAccounts>
                    </UserAccounts>
                    <AutoLogon>
                        <Enabled>true</Enabled>
                        <Username>sandboxsetup</Username>
                        <LogonCount>1</LogonCount>
                        <Password>
                            <Value></Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </AutoLogon>
                    <FirstLogonCommands>
                        <SynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \#(Self.provisioningScriptPath)</CommandLine>
                            <Description>configure the sandbox account and remote desktop, remove provisioning files, and shut down</Description>
                        </SynchronousCommand>
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>
        """#
        try validate(xml: xml)
        return xml
    }

    /// PowerShell executed once under the bootstrap administrator account after OOBE.
    /// The generated password is alphanumeric, so embedding it in a single-quoted literal is safe.
    func generateProvisioningPowerShell(rdpPassword: String) -> String {
        #"""
        $ErrorActionPreference = 'Stop'
        $account = 'WDAGUtilityAccount'
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

        & net.exe user $account /active:yes
        if ($LASTEXITCODE -ne 0) { throw 'Could not enable WDAGUtilityAccount.' }
        & net.exe user $account '\#(rdpPassword)'
        if ($LASTEXITCODE -ne 0) { throw 'Could not set the WDAGUtilityAccount password.' }

        $accountObject = Get-LocalUser -Name $account
        Set-LocalUser -InputObject $accountObject -PasswordNeverExpires $true
        $adminGroup = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value.Split('\\')[-1]
        $adminMembers = Get-LocalGroupMember -Group $adminGroup
        if ($adminMembers.SID.Value -notcontains $accountObject.SID.Value) {
            Add-LocalGroupMember -Group $adminGroup -Member $account
        }

        New-ItemProperty -Path $winlogon -Name AutoAdminLogon -PropertyType String -Value '0' -Force | Out-Null
        Remove-ItemProperty -LiteralPath $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
        New-ItemProperty -Path $winlogon -Name DisableAutomaticRestartSignOn -PropertyType DWord -Value 1 -Force | Out-Null

        $terminalServer = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        New-ItemProperty -Path $terminalServer -Name fDenyTSConnections -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path "$terminalServer\WinStations\RDP-Tcp" -Name UserAuthentication -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -PropertyType DWord -Value 0 -Force | Out-Null

        Get-NetFirewallRule -Name MacSandboxRDP -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -Name MacSandboxRDP -DisplayName MacSandboxRDP -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -Profile Any | Out-Null

        $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        $logonAgent = 'cmd /c for %d in (D E F G H I) do if exist %d:\macsandbox-logon.vbs start wscript //B %d:\macsandbox-logon.vbs'
        New-ItemProperty -Path $runKey -Name MacSandboxLogon -PropertyType String -Value $logonAgent -Force | Out-Null

        $appModelUnlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        New-Item -Path $appModelUnlock -Force | Out-Null
        New-ItemProperty -Path $appModelUnlock -Name AllowDevelopmentWithoutDevLicense -PropertyType DWord -Value 1 -Force | Out-Null

        & net.exe user sandboxsetup /active:no
        if ($LASTEXITCODE -ne 0) { throw 'Could not disable the bootstrap account.' }

        Remove-Item -LiteralPath "$env:WINDIR\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PSCommandPath -Force
        shutdown.exe /s /t 15 /f
        """#
    }

    private func validate(xml: String) throws {
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: xml, options: [])
        } catch {
            throw UnattendError.invalidXML(error.localizedDescription)
        }

        let nodes: [XMLNode]
        do {
            nodes = try document.nodes(forXPath: "//*[local-name()='CommandLine']")
        } catch {
            throw UnattendError.invalidXML(error.localizedDescription)
        }
        for node in nodes {
            let length = node.stringValue?.count ?? 0
            if length > Self.maximumCommandLineLength {
                throw UnattendError.commandLineTooLong(length: length)
            }
        }
    }
}
