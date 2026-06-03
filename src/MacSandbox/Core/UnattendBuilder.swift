import Foundation

/// Windows 무인 응답(unattend.xml) 생성.
///
/// 현재 설치 방식은 WinPE의 DISM 오프라인 배포이므로, windowsPE 파티셔닝/이미지설치 패스는 없다.
/// DISM 적용 후 디스크의 `\Windows\Panther\unattend.xml`로 복사되어 첫 부팅(specialize/oobe)을 자동화한다.
final class UnattendBuilder {

    /// DISM 오프라인 적용 후 첫 부팅용 Panther unattend.
    /// oobeSystem 패스만 사용(specialize에 RunSynchronous를 넣으면 일부 25H2 빌드가 응답 파일을 거부).
    /// 부트스트랩 관리자 계정으로 자동 로그온 → FirstLogonCommands로 내장 WDAGUtilityAccount를
    /// 활성화하고 영구 자동 로그온을 설정 → 종료. (이후 샌드박스 부팅 시 WDAGUtilityAccount로 자동 로그온)
    func generatePantherXML(config: InstallConfig) -> String {
        let locale = config.locale
        let winlogon = "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
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
                            <CommandLine>cmd /c net user WDAGUtilityAccount ""</CommandLine>
                            <Description>blank password</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>3</Order>
                            <CommandLine>cmd /c net localgroup Administrators WDAGUtilityAccount /add</CommandLine>
                            <Description>admin</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>4</Order>
                            <CommandLine>reg add "\(winlogon)" /v AutoAdminLogon /t REG_SZ /d 1 /f</CommandLine>
                            <Description>autologon on</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>5</Order>
                            <CommandLine>reg add "\(winlogon)" /v DefaultUserName /t REG_SZ /d WDAGUtilityAccount /f</CommandLine>
                            <Description>autologon user</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>6</Order>
                            <CommandLine>reg add "\(winlogon)" /v DefaultPassword /t REG_SZ /d "" /f</CommandLine>
                            <Description>autologon password</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>7</Order>
                            <CommandLine>reg add "\(winlogon)" /v DefaultDomainName /t REG_SZ /d . /f</CommandLine>
                            <Description>autologon domain</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>8</Order>
                            <CommandLine>reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine>
                            <Description>enable RDP server</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>9</Order>
                            <CommandLine>reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f</CommandLine>
                            <Description>disable NLA (blank password RDP)</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>10</Order>
                            <CommandLine>reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Lsa" /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f</CommandLine>
                            <Description>allow blank password over RDP</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>11</Order>
                            <CommandLine>netsh advfirewall firewall add rule name=MacSandboxRDP dir=in action=allow protocol=TCP localport=3389 profile=any</CommandLine>
                            <Description>allow inbound TCP 3389 on all profiles (locale-independent; group= fails on localized Windows)</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>12</Order>
                            <CommandLine>reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" /v MacSandboxLogon /t REG_SZ /d "cmd /c for %d in (D E F G H I) do if exist %d:\\macsandbox-logon.cmd call %d:\\macsandbox-logon.cmd" /f</CommandLine>
                            <Description>logon agent: runs sandbox LogonCommand from config disk</Description>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>13</Order>
                            <CommandLine>cmd /c shutdown /s /t 15 /f</CommandLine>
                            <Description>shutdown to finalize baseline</Description>
                        </SynchronousCommand>
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>
        """
    }
}
