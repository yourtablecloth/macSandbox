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

/// Windows unattended answer (unattend.xml) generation.
///
/// The current installation method is WinPE's DISM offline deployment, so there is no windowsPE partitioning/image-install pass.
/// After DISM is applied, it is copied to the disk's `\Windows\Panther\unattend.xml` to automate the first boot (specialize/oobe).
final class UnattendBuilder {

    /// Panther unattend for the first boot after DISM offline application.
    /// Uses the oobeSystem pass only (putting RunSynchronous in specialize makes some 25H2 builds reject the answer file).
    /// Auto-logs on with the bootstrap administrator account (sandboxsetup) → via FirstLogonCommands, enables the built-in
    /// WDAGUtilityAccount (blank password, administrator) and turns on RDP, then **at the end, disables the bootstrap account**
    /// (net user /active:no) and shuts down.
    /// Sandbox usage is a sole RDP (WDAGUtilityAccount) session. If console auto-logon is still alive, it races the RDP session
    /// (logon conflict) on a single-session client SKU. Empirical findings:
    ///  - WDAGUtilityAccount is a special account, so it cannot be a console auto-logon target (even a clean cold boot uses sandboxsetup).
    ///  - `AutoAdminLogon=0` alone cannot prevent OOBE's fresh-boot first auto-logon.
    ///  → The bootstrap account itself must be disabled so no console session is created (the console only shows an 'account unavailable' notice).
    func generatePantherXML(config: InstallConfig) -> String {
        let locale = config.locale
        let winlogon = "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
        let accountReadyMarker = "C:\\ProgramData\\MacSandbox-WDAGUtilityAccount.ready"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend"
                  xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-International-Core" processorArchitecture="arm64"
                           publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                    <InputLocale>\(locale)</InputLocale>
                    <UILanguage>\(locale)</UILanguage>
                    <UserLocale>\(locale)</UserLocale>
                    <SystemLocale>\(locale)</SystemLocale>
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
                            <CommandLine>cmd /c net user WDAGUtilityAccount /active:yes</CommandLine>
                            <Description>enable WDAGUtilityAccount</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>2</Order>
                            <CommandLine>cmd /c net user WDAGUtilityAccount "\(SandboxCreds.password)"</CommandLine>
                            <Description>set fixed internal password (credential-based RDP auto-logon; blank-password auto-logon is unreliable)</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>3</Order>
                            <CommandLine>%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; Set-LocalUser -Name 'WDAGUtilityAccount' -PasswordNeverExpires $true; Set-Content -LiteralPath '\(accountReadyMarker)' -Value 'ready' -Encoding Ascii"</CommandLine>
                            <Description>disable password expiration for the application-managed RDP account; failure leaves the readiness marker absent so baseline provisioning cannot complete</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>4</Order>
                            <CommandLine>cmd /c net localgroup Administrators WDAGUtilityAccount /add</CommandLine>
                            <Description>admin</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>5</Order>
                            <CommandLine>reg add "\(winlogon)" /v AutoAdminLogon /t REG_SZ /d 0 /f</CommandLine>
                            <Description>disable console autologon — RDP(WDAGUtilityAccount) is the sole interactive session; console autologon would race it on single-session client SKU</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>6</Order>
                            <CommandLine>reg delete "\(winlogon)" /v AutoLogonCount /f</CommandLine>
                            <Description>remove unattend LogonCount leftover (would re-trigger console autologon)</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>7</Order>
                            <CommandLine>reg delete "\(winlogon)" /v DefaultPassword /f</CommandLine>
                            <Description>clear stored autologon credential</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>8</Order>
                            <CommandLine>reg add "\(winlogon)" /v DisableAutomaticRestartSignOn /t REG_DWORD /d 1 /f</CommandLine>
                            <Description>disable ARSO so a guest reboot does not auto-restore a console session that would race RDP</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>9</Order>
                            <CommandLine>reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine>
                            <Description>enable RDP server</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>10</Order>
                            <CommandLine>reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f</CommandLine>
                            <Description>disable NLA (blank password RDP)</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>11</Order>
                            <CommandLine>reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Lsa" /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f</CommandLine>
                            <Description>allow blank password over RDP</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>12</Order>
                            <CommandLine>netsh advfirewall firewall add rule name=MacSandboxRDP dir=in action=allow protocol=TCP localport=3389 profile=any</CommandLine>
                            <Description>allow inbound TCP 3389 on all profiles (locale-independent; group= fails on localized Windows)</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>13</Order>
                            <CommandLine>reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" /v MacSandboxLogon /t REG_SZ /d "cmd /c for %d in (D E F G H I) do if exist %d:\\macsandbox-logon.vbs start wscript //B %d:\\macsandbox-logon.vbs" /f</CommandLine>
                            <Description>logon agent: runs sandbox LogonCommand from config disk via a hidden VBScript launcher (no visible console window, like Windows Sandbox). 'start' detaches wscript so this cmd exits immediately; wscript runs the .cmd with window style 0 (SW_HIDE).</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>14</Order>
                            <CommandLine>reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f</CommandLine>
                            <Description>enable Developer Mode so non-elevated logon agent can create symlinks (mapped folder Desktop mount); falls back to .lnk shortcut otherwise</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>15</Order>
                            <CommandLine>cmd /c net user sandboxsetup /active:no</CommandLine>
                            <Description>disable bootstrap account so it cannot console-autologon (AutoAdminLogon=0 alone does not stop the OOBE first-boot autologon; disabling the account does). RDP(WDAGUtilityAccount) becomes the sole session.</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>16</Order>
                            <CommandLine>cmd /c if exist "\(accountReadyMarker)" (del /f /q "\(accountReadyMarker)" &amp;&amp; shutdown /s /t 15 /f) else (echo ERROR: Baseline provisioning failed because WDAGUtilityAccount PasswordNeverExpires was not applied. &amp;&amp; %SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 86400")</CommandLine>
                            <Description>shutdown to finalize baseline only after the account password-expiration setting was applied</Description>
                        </SynchronousCommand>
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>
        """
    }
}
