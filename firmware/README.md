# MacSandbox UEFI firmware

MacSandbox uses a project-specific build of the AArch64 EDK II firmware shipped with QEMU 10.2.1. The build keeps QEMU itself unchanged and replaces only `edk2-aarch64-code.fd`.

The customization applies four changes:

- `assets/BootLogo.bmp` in place of the TianoCore logo
- A black framebuffer before the logo appears
- A zero-second EDK II boot-menu timeout
- No graphical-console handler for `BdsDxe` load and start messages

The patch leaves EDK II serial output intact. QEMU captures it whenever the runtime supplies a `serialLogPath`. The Windows boot spinner belongs to the guest boot manager and remains enabled.

## Pinned source

- QEMU tag: `v10.2.1`
- EDK II commit: `4dfdca63a93497203f197ec98ba20e2327e4afe4`
- Source patch: `firmware/macsandbox-edk2.patch`
- Logo source: `assets/AppIcon.png`
- Generated firmware logo: `assets/BootLogo.bmp`

## Build

On macOS, the build script uses Docker, Podman, or Apple container for the Linux cross-compiler. On Linux, it runs the toolchain directly.

```sh
swift scripts/make_assets.swift
scripts/build_firmware.sh
python3 scripts/bundle_qemu.py --require-custom-firmware
```

The firmware build writes its output and SHA-256 manifest under `.build/firmware/`. The QEMU bundler verifies the version, size, and digest before copying the image into `vendor/qemu/share/qemu/`.

With a zero-second timeout, the firmware does not pause for the normal boot-menu hotkey window. Troubleshooting can enable QEMU's serial log. A diagnostic build can also omit the patch or run with the stock QEMU firmware.

## Windows boot UI

After EDK II starts Windows Boot Manager, Windows draws its own rotating status indicator. Microsoft supports hiding it with [Unbranded Boot](https://learn.microsoft.com/en-us/windows/configuration/unbranded-boot/) and `bootuxdisabled`, while retaining a custom BGRT firmware logo. This optional component is limited to Enterprise, Enterprise LTSC, Education, IoT Enterprise, and IoT Enterprise LTSC editions. MacSandbox does not enable it automatically because the project accepts other Windows 11 editions and the setting also removes Windows boot status information.
