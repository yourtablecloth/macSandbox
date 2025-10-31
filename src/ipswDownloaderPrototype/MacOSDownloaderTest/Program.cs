using System;
using System.Runtime.InteropServices;

namespace MacOSDownloaderTest
{
    public static class NativeMethods
    {
        private const string LibName = "libMacOSDownloaderLib.dylib";

        [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr macosdownloader_get_version();

        [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
        public static extern int macosdownloader_get_system_info(
            out IntPtr model,
            out IntPtr arch,
            out IntPtr board
        );

        [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
        public static extern int macosdownloader_get_latest_image(
            out IntPtr version,
            out IntPtr build,
            out IntPtr url,
            out long size
        );

        [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
        public static extern int macosdownloader_download(
            [MarshalAs(UnmanagedType.LPStr)] string url,
            [MarshalAs(UnmanagedType.LPStr)] string outputPath
        );

        [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
        public static extern void macosdownloader_free_string(IntPtr str);
    }

    class Program
    {
        static void Main(string[] args)
        {
            Console.WriteLine("🍎 macOS Downloader .NET P/Invoke Test");
            Console.WriteLine("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
            Console.WriteLine();

            // 1. 라이브러리 버전
            IntPtr versionPtr = NativeMethods.macosdownloader_get_version();
            if (versionPtr != IntPtr.Zero)
            {
                string version = Marshal.PtrToStringAnsi(versionPtr);
                Console.WriteLine($"📦 라이브러리 버전: {version}");
                NativeMethods.macosdownloader_free_string(versionPtr);
                Console.WriteLine();
            }

            // 2. 시스템 정보
            Console.WriteLine("🖥️  시스템 정보:");
            int result = NativeMethods.macosdownloader_get_system_info(
                out IntPtr modelPtr,
                out IntPtr archPtr,
                out IntPtr boardPtr
            );

            if (result == 0)
            {
                string model = Marshal.PtrToStringAnsi(modelPtr) ?? "Unknown";
                string arch = Marshal.PtrToStringAnsi(archPtr) ?? "Unknown";
                string board = Marshal.PtrToStringAnsi(boardPtr) ?? "Unknown";

                Console.WriteLine($"   모델: {model}");
                Console.WriteLine($"   아키텍처: {arch}");
                Console.WriteLine($"   보드 ID: {board}");

                NativeMethods.macosdownloader_free_string(modelPtr);
                NativeMethods.macosdownloader_free_string(archPtr);
                NativeMethods.macosdownloader_free_string(boardPtr);
                Console.WriteLine();
            }
            else
            {
                Console.WriteLine($"   ❌ 시스템 정보 가져오기 실패 (코드: {result})");
                Console.WriteLine();
            }

            // 3. 최신 복구 이미지
            Console.WriteLine("🔍 최신 macOS 복구 이미지 가져오기...");
            result = NativeMethods.macosdownloader_get_latest_image(
                out IntPtr versionImgPtr,
                out IntPtr buildPtr,
                out IntPtr urlPtr,
                out long size
            );

            if (result == 0)
            {
                string imgVersion = Marshal.PtrToStringAnsi(versionImgPtr) ?? "Unknown";
                string build = Marshal.PtrToStringAnsi(buildPtr) ?? "Unknown";
                string url = Marshal.PtrToStringAnsi(urlPtr) ?? "Unknown";

                Console.WriteLine("   ✅ 성공!");
                Console.WriteLine($"   버전: {imgVersion}");
                Console.WriteLine($"   빌드: {build}");
                Console.WriteLine($"   URL: {url}");
                Console.WriteLine($"   크기: {size} bytes");

                NativeMethods.macosdownloader_free_string(versionImgPtr);
                NativeMethods.macosdownloader_free_string(buildPtr);
                NativeMethods.macosdownloader_free_string(urlPtr);
            }
            else if (result == -1)
            {
                Console.WriteLine("   ⚠️  지원되지 않는 macOS 버전");
            }
            else
            {
                Console.WriteLine($"   ❌ 이미지 가져오기 실패 (코드: {result})");
            }

            Console.WriteLine();
            Console.WriteLine("🎉 테스트 완료!");
        }
    }
}
