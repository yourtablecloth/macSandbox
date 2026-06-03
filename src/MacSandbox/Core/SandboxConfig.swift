import Foundation

/// 일회용 샌드박스 실행 설정. Windows Sandbox의 `.wsb` 스키마에 대응한다.
///
/// 적용 시점은 **샌드박스 런타임(매 실행)** 이며, 네트워킹/공유폴더/클립보드/오디오 등 일부는
/// 게스트 드라이버·에이전트가 베이스라인에 미리 심어져 있어야 실제로 동작한다(아래 주석 참조).
struct SandboxConfig: Codable, Equatable {

    /// 가상 GPU 표시 장치. Windows Sandbox의 host-GPU 공유(WDDM 파라가상)는 QEMU에서 불가하므로,
    /// on = virtio-gpu(2D, viogpudo 드라이버 필요), off = ramfb(드라이버리스 기본 프레임버퍼).
    var vGpuEnabled: Bool = false

    /// NAT 네트워킹. on = virtio-net(NAT). 실제 연결은 NetKVM(virtio-net) 드라이버가 베이스라인에 필요.
    var networkingEnabled: Bool = true

    /// 호스트 폴더 매핑. virtiofs/9p 또는 SMB 우회 — 게스트 드라이버 필요(WinFsp/virtiofs). [TODO: 드라이버 주입]
    var mappedFolders: [MappedFolder] = []

    /// 로그온 직후 게스트에서 실행할 명령. 베이스라인의 로그온 에이전트(Run 키)가 설정 디스크의
    /// `macsandbox-logon.cmd`를 실행하는 방식으로 전달된다.
    var logonCommand: String = ""

    /// 호스트 마이크 입력 공유. QEMU 오디오(coreaudio) + 게스트 오디오 드라이버 필요.
    var audioInputEnabled: Bool = false

    /// 호스트 웹캠 입력 공유. USB 패스스루(`usb-host`) — 호스트 카메라 권한/디바이스 클레임 필요. [TODO]
    var videoInputEnabled: Bool = false

    /// 클립보드 복사/공유. SPICE + spice-vdagent 필요(현재 디스플레이는 VNC). [TODO: SPICE 전환]
    var clipboardEnabled: Bool = true

    /// 프린터 리다이렉트. QEMU 네이티브 수단 없음(RDP/네트워크 프린터 우회 필요). [TODO]
    var printerEnabled: Bool = false

    /// 메모리 크기 (MB)
    var memoryMB: Int = 4096

    /// CPU 코어 수
    var cpuCores: Int = 4

    /// 종료 시 변경사항 폐기(일회용). Windows Sandbox와 동일하게 기본 true.
    var disposable: Bool = true
}

/// 호스트 ↔ 게스트 폴더 매핑 (`.wsb`의 MappedFolder)
struct MappedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var hostPath: String
    var readOnly: Bool = false

    private enum CodingKeys: String, CodingKey { case hostPath, readOnly }
}
