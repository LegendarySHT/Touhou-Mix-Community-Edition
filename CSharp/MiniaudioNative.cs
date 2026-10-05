using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using Godot;

namespace TouhouMix.Midi
{
    /// <summary>
    /// miniaudio C 桥接层的 P/Invoke 声明
    /// 对应 addons/miniaudio/native/miniaudio_bridge.h
    ///
    /// 库加载策略:
    ///   1. 通过 NativeLibrary.SetDllImportResolver 拦截 "miniaudio_bridge" 的加载
    ///   2. 按平台和构建类型 (debug/release) 解析到 addons/miniaudio/libs/{platform}/ 下的具体文件
    ///   3. 失败时返回 IntPtr.Zero
    ///
    /// 线程安全:
    ///   - ma_bridge_init / uninit / start / stop: 仅从主线程调用
    ///   - ma_bridge_data_proc 回调: 由 miniaudio 音频线程调用
    ///   - ma_bridge_set_volume: 原子操作, 任意线程可调用
    /// </summary>
    internal static class MiniaudioNative
    {
        // ---- 错误码 ----
        internal enum Result : int
        {
            Ok = 0,
            ErrInit = 1,
            ErrDevice = 2,
            ErrInvalidArg = 3,
            ErrNotInitialized = 4,
            ErrAlreadyInitialized = 5,
            ErrUnsupported = 6,
        }

        // ---- 后端选择 ----
        internal enum Backend : int
        {
            Default = 0,
            Wasapi = 1,
            Dsound = 2,
            Winmm = 3,
            Coreaudio = 4,
            Aaudio = 5,
            Opensl = 6,
            Pulseaudio = 7,
            Alsa = 8,
        }

        // ---- 初始化配置 (与 C 结构体布局严格对应) ----
        [StructLayout(LayoutKind.Sequential)]
        internal struct Config
        {
            public uint SampleRate;
            public uint PeriodSizeInFrames;
            public uint PeriodCount;
            public uint Channels;
            public int  Format;
            public Backend Backend;
            public int  WasapiExclusive;
            public int  AaudioExclusive;
            public int  NoPreSilencedInputBuffer;
            public int  NoClip;
            public int  NoDeviceStateChangedCallback;
            public int  NoAutoConvertSRC;
        }

        // ---- 数据回调委托 ----
        // 注意: 必须用 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] 标注
        // 且委托实例必须被 GC 引用 (本桥中存储在 _dataCallback 字段, 防止被回收)
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate void DataProc(IntPtr pUserData, IntPtr pOutput, uint frameCount);

        // ---- 设备枚举回调委托 (主线程调用) ----
        // 返回 1 继续枚举, 0 停止
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int DeviceEnumProc(IntPtr pUserData, IntPtr name, int isDefault);

        // ---- 默认配置 ----
        internal static Config ConfigInitDefault()
        {
            return new Config
            {
                SampleRate = 48000,
                PeriodSizeInFrames = 256,
                PeriodCount = 2,
                Channels = 2,
                Format = 0,
                Backend = Backend.Default,
                WasapiExclusive = 0,
                AaudioExclusive = 0,
                NoPreSilencedInputBuffer = 0,
                NoClip = 1,
                NoDeviceStateChangedCallback = 1,
                NoAutoConvertSRC = 0,
            };
        }

        // ====================================================================
        // 库加载逻辑
        // ====================================================================
        private static readonly object _loadLock = new object();
        private static IntPtr _libraryHandle = IntPtr.Zero;
        private static bool _resolverInstalled = false;
        private static bool _loadAttempted = false;
        private static bool _loadSucceeded = false;

        static MiniaudioNative()
        {
            InstallResolver();
        }

        private static void InstallResolver()
        {
            if (_resolverInstalled) return;
            try
            {
                NativeLibrary.SetDllImportResolver(typeof(MiniaudioNative).Assembly, ResolveLibrary);
            }
            catch (InvalidOperationException)
            {
                // 已有 resolver 被安装.
                // 这是正常情况 - 我们的 ResolveLibrary 不会被调用, 但 NativeLibrary.Load
                // 直接通过路径加载的方式仍可工作, 不影响功能.
            }
            _resolverInstalled = true;
        }

        /// <summary>
        /// 尝试加载 native 库. 成功后所有 DllImport 都会自动解析到该库.
        /// 调用方应在 Initialize 前调用此方法.
        /// </summary>
        internal static bool TryLoadNativeLibrary()
        {
            if (_loadSucceeded) return true;
            lock (_loadLock)
            {
                if (_loadSucceeded) return true;
                if (_loadAttempted) return false; // 已经尝试过且失败, 不再重试

                _loadAttempted = true;
                var libraryPath = ResolveLibraryPath();
                if (string.IsNullOrEmpty(libraryPath))
                {
                    var osName = OS.GetName();
                    var arch = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture;
                    GD.PushWarning($"[MiniaudioNative] No library path resolved for platform: {osName} ({arch}). " +
                        $"Ensure the native library is compiled and placed in addons/miniaudio/libs/<platform>/.");
                    return false;
                }

                try
                {
                    _libraryHandle = NativeLibrary.Load(libraryPath);
                    _loadSucceeded = _libraryHandle != IntPtr.Zero;
                    if (_loadSucceeded)
                    {
                        GD.Print($"[MiniaudioNative] Loaded native library: {libraryPath}");
                    }
                    else
                    {
                        GD.PushWarning($"[MiniaudioNative] NativeLibrary.Load returned zero handle for: {libraryPath}");
                    }
                    return _loadSucceeded;
                }
                catch (Exception ex)
                {
                    var osName = OS.GetName();
                    GD.PushWarning($"[MiniaudioNative] Failed to load '{libraryPath}' on {osName}: {ex.GetType().Name}: {ex.Message}");
                    if (osName == "Android")
                    {
                        GD.PushWarning("[MiniaudioNative] Android 提示: " +
                            "确保已通过 miniaudio Android 导出插件将 libminiaudio_bridge.so 打包进 APK. " +
                            "运行 addons/miniaudio/native/build_unix.sh android (需 NDK) 生成 AAR, " +
                            "然后在编辑器中启用 miniaudio 插件并重新导出 APK.");
                    }
                    return false;
                }
            }
        }

        /// <summary>是否已成功加载 native 库.</summary>
        internal static bool IsAvailable => _loadSucceeded;

        private static IntPtr ResolveLibrary(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
        {
            // 仅处理我们自己的库名
            if (!libraryName.Equals("miniaudio_bridge", StringComparison.OrdinalIgnoreCase))
            {
                return IntPtr.Zero;
            }
            if (TryLoadNativeLibrary())
            {
                return _libraryHandle;
            }
            return IntPtr.Zero;
        }

        private static string ResolveLibraryPath()
        {
            var baseDir = ProjectSettings.GlobalizePath("res://addons/miniaudio/libs");
            var osName = OS.GetName();

            if (osName == "Windows")
            {
                // debug/release 用同一个 dll (miniaudio 无 L 区分)
                var path = Path.Combine(baseDir, "windows", "miniaudio_bridge.dll");
                return File.Exists(path) ? path : string.Empty;
            }

            if (osName == "Linux")
            {
                var path = Path.Combine(baseDir, "linux", "libminiaudio_bridge.so");
                return File.Exists(path) ? path : string.Empty;
            }

            if (osName == "macOS")
            {
                var path = Path.Combine(baseDir, "macos", "libminiaudio_bridge.dylib");
                return File.Exists(path) ? path : string.Empty;
            }

            if (osName == "Android")
            {
                // Android: 库由 APK 打包, 系统按名加载 (无需路径)
                return "libminiaudio_bridge.so";
            }

            if (osName == "iOS")
            {
                // iOS: 静态链接进可执行文件, 但 NativeLibrary.Load 仍需一个占位名
                // 实际通过 Xcode 工程链接 .a, 此处仅返回名称供 resolver 识别
                return "miniaudio_bridge";
            }

            return string.Empty;
        }

        // ====================================================================
        // P/Invoke 声明 (对应 miniaudio_bridge.h)
        // ====================================================================
        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_init(ref Config pConfig,
                                                      DataProc dataCallback,
                                                      IntPtr pUserData,
                                                      out IntPtr ppBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_start(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_stop(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_get_period_size(IntPtr pBridge,
                                                                 out uint pPeriodSize,
                                                                 out uint pPeriodCount);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_get_sample_rate(IntPtr pBridge, out uint pSampleRate);

        // 获取设备报告的内部延迟 (帧数). 旧版 DLL 可能没有此导出, 调用方需 try/catch
        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_get_latency(IntPtr pBridge, out uint pLatencyInFrames);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr ma_bridge_get_backend_name(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_set_volume(IntPtr pBridge, float volume);

        // ---- Vocal control (miniaudio decoder + ring buffer mixed in callback) ----
        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_load(IntPtr pBridge, byte[] pFilePath);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ma_bridge_vocal_unload(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_play(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_pause(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_stop(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_seek(IntPtr pBridge, ulong frameIndex);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_set_volume(IntPtr pBridge, float volume);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern double ma_bridge_vocal_get_position_ms(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern long ma_bridge_vocal_get_length_ms(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ma_bridge_vocal_is_playing(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ma_bridge_vocal_is_finished(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern uint ma_bridge_vocal_get_underrun_count(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern ulong ma_bridge_vocal_get_underrun_frames(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern uint ma_bridge_vocal_get_catchup_frames(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern Result ma_bridge_vocal_skip_frames(IntPtr pBridge, uint frames);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ma_bridge_uninit(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr ma_bridge_get_version();

        // 设备枚举与选择 (用于独占模式选择正确的设备端点)
        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ma_bridge_set_device_name(byte[] pName);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ma_bridge_enumerate_devices(IntPtr pBridge,
                                                                DeviceEnumProc callback,
                                                                IntPtr pUserData);

        // 诊断函数 (用于排查独占模式无声音问题)
        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ma_bridge_get_device_state(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ma_bridge_get_share_mode(IntPtr pBridge);

        [DllImport("miniaudio_bridge", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int ma_bridge_has_device_id(IntPtr pBridge);

        // ====================================================================
        // 辅助: 安全读取 IntPtr 返回的 C 字符串
        // ====================================================================
        internal static string PtrToStringAnsiSafe(IntPtr ptr)
        {
            if (ptr == IntPtr.Zero) return string.Empty;
            return Marshal.PtrToStringAnsi(ptr) ?? string.Empty;
        }

        /// <summary>
        /// 安全读取 IntPtr 返回的 UTF-8 C 字符串.
        /// miniaudio 的设备名称是 UTF-8 编码, 用 PtrToStringAnsi (ANSI/CP_ACP) 解码会乱码.
        /// </summary>
        internal static string PtrToStringUtf8Safe(IntPtr ptr)
        {
            if (ptr == IntPtr.Zero) return string.Empty;
            // 先用 Ansi 读取字节 (C 字符串以 null 结尾), 再用 UTF-8 解码
            string ansi = Marshal.PtrToStringAnsi(ptr) ?? string.Empty;
            // Marshal.PtrToStringAnsi 会用 CP_ACP 解码, 对于 UTF-8 字节会产生错误字符.
            // 我们需要原始字节. 用 unsafe 方式读取.
            // 但为了简单, 这里用 PtrToStringUTF8 (如果可用) 或手动读取.
            // .NET 6+ 有 Marshal.PtrToStringUTF8.
            try
            {
                return Marshal.PtrToStringUTF8(ptr) ?? string.Empty;
            }
            catch
            {
                // 旧运行时没有 PtrToStringUTF8, 回退到 Ansi
                return ansi;
            }
        }

        /// <summary>
        /// 将 C# string 转换为 UTF-8 byte 数组 (含 null 终止符), 用于传递给 C 函数.
        /// </summary>
        internal static byte[] StringToUtf8NullTerminated(string s)
        {
            if (string.IsNullOrEmpty(s)) return new byte[] { 0 };
            int byteCount = System.Text.Encoding.UTF8.GetByteCount(s);
            byte[] bytes = new byte[byteCount + 1];
            System.Text.Encoding.UTF8.GetBytes(s, 0, s.Length, bytes, 0);
            // bytes[byteCount] = 0 (自动, 数组初始化为 0)
            return bytes;
        }
    }
}
