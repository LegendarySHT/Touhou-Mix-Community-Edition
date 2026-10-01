using Godot;
using System;
using System.Runtime.InteropServices;
using System.Threading;

// CA1416：Marshal.ReleaseComObject / Microsoft.Win32.Registry 仅 Windows 可用。
// 所有调用路径均由 DetectFull 中的 OperatingSystem.IsWindows() 运行时守卫，
// 分析器无法穿透工作线程 lambda 识别该守卫，故对本文件显式抑制。
#pragma warning disable CA1416

/// <summary>
/// 音频输出路由检测器（autoload，参考 ChartDB 注册方式）
/// Windows: 通过 WASAPI COM (IMMDeviceEnumerator) 读取默认渲染端点的
///           DEVPKEY_Device_EnumeratorName 总线类型，判定蓝牙：
///           BTHENUM(经典 A2DP) / BTHHFENUM(HFP) 前缀，以及
///           {2101C4C0-...}(Windows 11 蓝牙 LE Audio 端点枚举器 GUID)。
/// 其余平台: IsBluetoothOutput 恒为 false（由 GDScript 侧 AudioBtDetector 分发，
///           Android 走 JavaClassWrapper 路径，不经过本类）。
/// COM 检测在短生命周期专用 MTA 线程上执行，避免依赖 Godot 主线程的 COM 单元状态。
/// </summary>
public partial class AudioRouteDetector : Node
{
	// ===== 对 GDScript 暴露的 API（PascalCase，经 autoload 全局名直接调用）=====

	/// <summary>当前默认输出端点是否为蓝牙（BTHENUM/BTHHFENUM/LE Audio 端点）</summary>
	public bool IsBluetoothOutput(bool refresh)
	{
		var (enumerator, _) = Detect(refresh);
		return IsBluetoothEnumerator(enumerator);
	}

	/// <summary>
	/// 判定端点枚举器名是否为蓝牙总线。
	/// - BTH 前缀: BTHENUM(经典 A2DP) / BTHHFENUM(HFP 免提)
	/// - {2101C4C0-2C15-4035-A0D0-EEC3C2277B11}: Windows 11 蓝牙 LE Audio 端点枚举器
	///   (该枚举器下设备均为 Render&CP_* / Capture&CP_* Codec Profile，实测 LE Audio
	///   耳机连接时默认输出端点的 EnumeratorName 即此 GUID，非 BTH 前缀)
	/// </summary>
	private static bool IsBluetoothEnumerator(string enumerator)
	{
		if (string.IsNullOrEmpty(enumerator))
		{
			return false;
		}
		if (enumerator.StartsWith("BTH", StringComparison.OrdinalIgnoreCase))
		{
			return true;
		}
		return enumerator.Equals("{2101C4C0-2C15-4035-A0D0-EEC3C2277B11}", StringComparison.OrdinalIgnoreCase);
	}

	/// <summary>当前默认输出端点友好名（如 "耳机 (WH-1000XM4 Stereo)"），失败返回空串</summary>
	public string GetOutputName(bool refresh)
	{
		var (_, name) = Detect(refresh);
		return name;
	}

	/// <summary>诊断信息串（如 "source=com; enumerator=BTHENUM; name=..."），供日志验证</summary>
	public string GetDetectionInfo(bool refresh)
	{
		var (source, enumerator, name) = DetectFull(refresh);
		return $"source={source}; enumerator={enumerator}; name={name}";
	}

	public override void _Ready()
	{
		// 启动时检测一次并输出日志，便于验证（检测线程 ~1-5ms）
		GD.Print($"[AudioRouteDetector] init: {GetDetectionInfo(false)}");
	}

	// ===== 检测实现 =====

	// 缓存（GDScript 侧 AudioBtDetector 已有 TTL 控制刷新频率，这里仅缓存最近一次结果）
	private static readonly object _lock = new object();
	private static string _cachedSource = "none";
	private static string _cachedEnumerator = "";
	private static string _cachedName = "";
	private static bool _hasCache = false;

	private static (string enumerator, string name) Detect(bool refresh)
	{
		var (_, enumerator, name) = DetectFull(refresh);
		return (enumerator, name);
	}

	private static (string source, string enumerator, string name) DetectFull(bool refresh)
	{
		lock (_lock)
		{
			if (_hasCache && !refresh)
			{
				return (_cachedSource, _cachedEnumerator, _cachedName);
			}

			if (!OperatingSystem.IsWindows())
			{
				_cachedSource = "unsupported_platform";
				_cachedEnumerator = "";
				_cachedName = "";
				_hasCache = true;
				return (_cachedSource, _cachedEnumerator, _cachedName);
			}

			try
			{
				DetectOnWorkerThread(out var enumerator, out var name);
				_cachedSource = "com";
				_cachedEnumerator = enumerator;
				_cachedName = name;
			}
			catch (Exception e)
			{
				// COM 失败 → 注册表兜底 → 仍失败则按"非蓝牙"处理（回退普通延迟预设）
				try
				{
					DetectViaRegistry(out var regEnumerator, out var regName);
					_cachedSource = "registry";
					_cachedEnumerator = regEnumerator;
					_cachedName = regName;
				}
				catch (Exception e2)
				{
					_cachedSource = "failed";
					_cachedEnumerator = "";
					_cachedName = "";
					GD.PrintErr($"[AudioRouteDetector] detection failed: COM={e.Message}; registry={e2.Message}");
				}
			}

			_hasCache = true;
			return (_cachedSource, _cachedEnumerator, _cachedName);
		}
	}

	/// <summary>在专用 MTA 线程上执行 COM 检测（COM 对象不能跨线程使用，全部在线程内完成）</summary>
	private static void DetectOnWorkerThread(out string enumerator, out string name)
	{
		enumerator = "";
		name = "";
		string localEnum = "";
		string localName = "";
		Exception error = null;

		var thread = new Thread(() =>
		{
			try
			{
				// S_OK / S_FALSE 均需配对 CoUninitialize
				int hr = CoInitializeEx(IntPtr.Zero, COINIT_MULTITHREADED);
				if (hr < 0)
				{
					throw new InvalidOperationException($"CoInitializeEx failed: 0x{hr:X8}");
				}
				try
				{
					DetectViaCom(out localEnum, out localName);
				}
				finally
				{
					CoUninitialize();
				}
			}
			catch (Exception e)
			{
				error = e;
			}
		});
		thread.IsBackground = true;
		thread.Start();
		// COM 检测正常 1-5ms；500ms 超时足以防御音频服务卡死，同时把最坏阻塞从 2s 降到 0.5s
		if (!thread.Join(TimeSpan.FromMilliseconds(500)) || error != null)
		{
			if (error != null)
			{
				throw error;
			}
			throw new TimeoutException("audio device detection timed out");
		}
		enumerator = localEnum;
		name = localName;
	}

	private static void DetectViaCom(out string enumerator, out string name)
	{
		enumerator = "";
		name = "";
		var clsid = ClsidMmDeviceEnumerator;
		var iid = IidImmDeviceEnumerator;
		var devEnum = CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_ALL, ref iid);
		if (devEnum == null)
		{
			throw new InvalidOperationException("CoCreateInstance(MMDeviceEnumerator) returned null");
		}

		// GetDefaultAudioEndpoint(eRender=0, eConsole=0)
		int hr = devEnum.GetDefaultAudioEndpoint(0, 0, out IMMDevice device);
		if (hr != 0 || device == null)
		{
			Marshal.ReleaseComObject(devEnum);
			throw new InvalidOperationException($"GetDefaultAudioEndpoint failed: 0x{hr:X8}");
		}

		try
		{
			// OpenPropertyStore(STGM_READ=0)
			hr = device.OpenPropertyStore(0, out IPropertyStore store);
			if (hr != 0 || store == null)
			{
				throw new InvalidOperationException($"OpenPropertyStore failed: 0x{hr:X8}");
			}

			try
			{
				enumerator = ReadStringProperty(store, DevpropkeyDeviceEnumeratorName);
				name = ReadStringProperty(store, DevpropkeyDeviceFriendlyName);
			}
			finally
			{
				Marshal.ReleaseComObject(store);
			}
		}
		finally
		{
			Marshal.ReleaseComObject(device);
		}
	}

	/// <summary>读取字符串型设备属性（VT_LPWSTR），其余类型返回空串</summary>
	private static string ReadStringProperty(IPropertyStore store, PROPERTYKEY key)
	{
		IntPtr pv = Marshal.AllocHGlobal(PropVariantSize);
		try
		{
			ZeroPropVariant(pv);
			int hr = store.GetValue(ref key, pv);
			if (hr != 0)
			{
				return "";
			}
			try
			{
				// PROPVARIANT: vt(2B) + 保留字段(6B) + 联合体（x64 下偏移 8）
				short vt = Marshal.ReadInt16(pv, 0);
				const short VtLpwstr = 31;
				if (vt == VtLpwstr)
				{
					IntPtr pwsz = Marshal.ReadIntPtr(pv, 8);
					if (pwsz != IntPtr.Zero)
					{
						return Marshal.PtrToStringUni(pwsz) ?? "";
					}
				}
				return "";
			}
			finally
			{
				PropVariantClear(pv);
			}
		}
		finally
		{
			Marshal.FreeHGlobal(pv);
		}
	}

	/// <summary>注册表兜底：端点 GUID → MMDevices\Audio\Render\{guid}\Properties 中读扁平化的 DEVPKEY 值</summary>
	private static void DetectViaRegistry(out string enumerator, out string name)
	{
		enumerator = "";
		name = "";
		if (!OperatingSystem.IsWindows())
		{
			return;
		}
		// 先用 COM 拿端点 GUID（此路径仅在 COM 属性读取失败时到达，枚举器本身通常可用）
		string endpointId = null;
		var error = "";
		var thread = new Thread(() =>
		{
			int hr = CoInitializeEx(IntPtr.Zero, COINIT_MULTITHREADED);
			if (hr < 0) { error = $"CoInitializeEx: 0x{hr:X8}"; return; }
			try
			{
				var clsid = ClsidMmDeviceEnumerator;
				var iid = IidImmDeviceEnumerator;
				var devEnum = CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_ALL, ref iid);
				if (devEnum == null) { error = "no enumerator"; return; }
				hr = devEnum.GetDefaultAudioEndpoint(0, 0, out IMMDevice device);
				if (hr != 0 || device == null) { error = $"GetDefaultAudioEndpoint: 0x{hr:X8}"; return; }
				try
				{
					hr = device.GetId(out string id);
					if (hr == 0) { endpointId = id; }
				}
				finally
				{
					Marshal.ReleaseComObject(device);
				}
			}
			finally
			{
				CoUninitialize();
			}
		});
		thread.IsBackground = true;
		thread.Start();
		thread.Join(TimeSpan.FromSeconds(2));
		if (string.IsNullOrEmpty(endpointId))
		{
			throw new InvalidOperationException($"cannot get endpoint id ({error})");
		}

		// 端点 ID 形如 "{0.0.0.00000000}.{xxxxxxxx-....}"，末段花括号内才是设备 GUID（注册表键名）
		int braceIdx = endpointId.LastIndexOf('{');
		if (braceIdx < 0 || braceIdx + 1 >= endpointId.Length)
		{
			return;
		}
		string endpointGuid = endpointId.Substring(braceIdx + 1).TrimEnd('}');
		string basePath = $@"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{{{endpointGuid}}}\Properties";
		using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(basePath))
		{
			if (key == null)
			{
				return;
			}
			enumerator = key.GetValue(DevicePropFmtidString + ",24") as string ?? "";
			name = key.GetValue(DevicePropFmtidString + ",14") as string ?? "";
		}
	}

	// ===== COM interop 声明（仅 Windows 运行时调用；net8.0/net9.0 均可编译）=====

	private const uint COINIT_MULTITHREADED = 0x0;
	private const uint CLSCTX_ALL = 0x17;
	private const int PropVariantSize = 24; // x64 下 sizeof(PROPVARIANT)
	private const string DevicePropFmtidString = "{a45c254e-df1c-4efd-8020-67d146a850e0}";

	private static readonly Guid ClsidMmDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
	private static readonly Guid IidImmDeviceEnumerator = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");

	// DEVPKEY_Device_FriendlyName（pid 14）与 DEVPKEY_Device_EnumeratorName（pid 24）
	private static readonly PROPERTYKEY DevpropkeyDeviceFriendlyName = new PROPERTYKEY
	{
		fmtid = new Guid(DevicePropFmtidString),
		pid = 14,
	};

	private static readonly PROPERTYKEY DevpropkeyDeviceEnumeratorName = new PROPERTYKEY
	{
		fmtid = new Guid(DevicePropFmtidString),
		pid = 24,
	};

	[StructLayout(LayoutKind.Sequential)]
	private struct PROPERTYKEY
	{
		public Guid fmtid;
		public int pid;
	}

	[DllImport("ole32.dll")]
	private static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);

	[DllImport("ole32.dll")]
	private static extern void CoUninitialize();

	[DllImport("ole32.dll", PreserveSig = false)]
	[return: MarshalAs(UnmanagedType.Interface)]
	private static extern IMMDeviceEnumerator CoCreateInstance(ref Guid rclsid, IntPtr pUnkOuter, uint dwClsContext, ref Guid riid);

	[DllImport("ole32.dll")]
	private static extern int PropVariantClear(IntPtr pvar);

	/// <summary>将 24 字节 PROPVARIANT 缓冲区清零（避免依赖平台特定 memset）</summary>
	private static void ZeroPropVariant(IntPtr pv)
	{
		Marshal.WriteInt64(pv, 0, 0);
		Marshal.WriteInt64(pv, 8, 0);
		Marshal.WriteInt64(pv, 16, 0);
	}

	// vtable 方法必须按接口定义顺序完整声明（COM 按位置绑定）
	[ComImport]
	[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
	[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
	private interface IMMDeviceEnumerator
	{
		[PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, out IntPtr ppDevices);
		[PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
		[PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
		[PreserveSig] int RegisterEndpointNotificationCallback(IntPtr pClient);
		[PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr pClient);
	}

	[ComImport]
	[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
	[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
	private interface IMMDevice
	{
		[PreserveSig] int Activate(ref Guid iid, uint dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
		[PreserveSig] int OpenPropertyStore(uint stgmAccess, out IPropertyStore ppProperties);
		[PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
		[PreserveSig] int GetState(out uint pdwState);
	}

	[ComImport]
	[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
	[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
	private interface IPropertyStore
	{
		[PreserveSig] int GetCount(out uint cProps);
		[PreserveSig] int GetAt(uint iProp, out PROPERTYKEY pkey);
		[PreserveSig] int GetValue(ref PROPERTYKEY key, IntPtr pv);
		[PreserveSig] int SetValue(ref PROPERTYKEY key, IntPtr propvar);
		[PreserveSig] int Commit();
	}
}
