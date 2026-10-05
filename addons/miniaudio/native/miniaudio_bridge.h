// miniaudio_bridge.h
// MeltySynth + miniaudio 低延迟音频桥接层
// 暴露给 C# (MeltySynthPlayer.cs) 的 C API
//
// 设计目标:
//   1. 简化 miniaudio 的复杂初始化为几个入口点
//   2. 由 C# 侧通过 GCHandle 持有 bridge 实例,在 data_callback 中回查
//   3. WASAPI exclusive / AAudio MMAP 等低延迟特性通过 ma_bridge_init 参数启用
//   4. 回调签名与原 FMOD pcmreadcallback 概念对应: "请求 N 帧,填到 outBuf"
//
// 回调约定 (ma_bridge_data_proc):
//   - frameCount: 请求的帧数
//   - pOutput: 交错 float32 stereo 缓冲区, 容量 = frameCount * 2 * sizeof(float)
//   - pUserData: 初始化时传入的指针 (通常是 C# GCHandle 的 IntPtr)
//   - 回调内严禁调用 ma_bridge_* 中的 start/stop/init/uninit (会死锁)
//
// 平台支持:
//   Windows : WASAPI (shared/exclusive) / DirectSound / WinMM
//   macOS   : Core Audio
//   iOS     : Core Audio
//   Android : AAudio (API 26+) / OpenSL ES (回退)
//   Linux   : PulseAudio / ALSA

#ifndef MINIAUDIO_BRIDGE_H
#define MINIAUDIO_BRIDGE_H

#include <stdint.h>

// 动态库导出宏
// 编译 bridge 库时 (MSVC: /LD, GCC: -fPIC -shared) 定义 MA_BRIDGE_EXPORTS
// 使用方 (C# P/Invoke) 不定义, 使用 dllimport
#if defined(_WIN32) || defined(__WIN32__) || defined(WIN32)
    #ifdef MA_BRIDGE_EXPORTS
        #define MA_BRIDGE_API __declspec(dllexport)
    #else
        #define MA_BRIDGE_API __declspec(dllimport)
    #endif
#else
    #define MA_BRIDGE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 错误码
typedef enum {
    MA_BRIDGE_OK = 0,
    MA_BRIDGE_ERR_INIT = 1,         // 上下文或设备初始化失败
    MA_BRIDGE_ERR_DEVICE = 2,       // 设备启动失败
    MA_BRIDGE_ERR_INVALID_ARG = 3,  // 参数非法
    MA_BRIDGE_ERR_NOT_INITIALIZED = 4,
    MA_BRIDGE_ERR_ALREADY_INITIALIZED = 5,
    MA_BRIDGE_ERR_UNSUPPORTED = 6,  // 当前平台不支持请求的特性
} ma_bridge_result;

// 后端优先级 (用于覆盖 miniaudio 默认选择)
// 0 = 使用 miniaudio 默认; 非 0 = 显式指定
typedef enum {
    MA_BRIDGE_BACKEND_DEFAULT = 0,
    MA_BRIDGE_BACKEND_WASAPI = 1,        // Windows
    MA_BRIDGE_BACKEND_DSOUND = 2,        // Windows
    MA_BRIDGE_BACKEND_WINMM = 3,         // Windows
    MA_BRIDGE_BACKEND_COREAUDIO = 4,     // macOS / iOS
    MA_BRIDGE_BACKEND_AAUDIO = 5,        // Android (API 26+)
    MA_BRIDGE_BACKEND_OPENSL = 6,        // Android (旧版回退)
    MA_BRIDGE_BACKEND_PULSEAUDIO = 7,    // Linux
    MA_BRIDGE_BACKEND_ALSA = 8,          // Linux
} ma_bridge_backend;

// WASAPI 使用模式
typedef enum {
    MA_BRIDGE_WASAPI_SHARED = 0,        // 默认共享模式 (兼容性好)
    MA_BRIDGE_WASAPI_EXCLUSIVE = 1,     // 独占模式 (延迟最低, 但需要独占设备)
    MA_BRIDGE_WASAPI_LOOPBACK = 2,      // 环回 (不适用于本项目)
} ma_bridge_wasapi_mode;

// 初始化配置
typedef struct {
    uint32_t sampleRate;             // 0 = 使用设备原生采样率 (推荐 48000)
    uint32_t periodSizeInFrames;     // 每个 period 的帧数 (类似 FMOD DSP bufferlength)
    uint32_t periodCount;            // period 数量 (类似 FMOD numbuffers, 推荐 2)
    uint32_t channels;               // 通道数, 固定 2 (stereo)
    int      format;                 // 0 = f32 (本项目固定 f32)
    ma_bridge_backend backend;       // 后端选择
    int      wasapiExclusive;        // 1 = WASAPI 独占模式 (Windows)
    int      aaudioExclusive;        // 1 = AAudio 独占模式 (Android, 需要 MMAP 支持)
    int      noPreSilencedInputBuffer; // 兼容字段, 默认 0
    int      noClip;                 // miniaudio 默认会 clip, 0 = 启用 clip, 1 = 禁用 (本项目自己 SoftLimit)
    int      noDeviceStateChangedCallback; // 性能优化: 不监听设备插拔
    int      noAutoConvertSRC;       // WASAPI: 1 = 禁用 WASAPI 内部 SRC, 改用 miniaudio 重采样器.
                                      // 启用 IAudioClient3 低延迟共享模式的前提条件.
} ma_bridge_config;

// 数据回调: 由 miniaudio 音频线程调用, C# 侧实现
// 注意: 此回调在实时音频线程中执行, 严禁做以下操作:
//   - 分配内存 (malloc/new)
//   - 获取锁 (lock/_synthLock) - 除非非常快速
//   - 调用 ma_bridge_start / ma_bridge_stop
//   - 文件 I/O
typedef void (*ma_bridge_data_proc)(void* pUserData, float* pOutput, uint32_t frameCount);

// 设备枚举回调 (主线程调用, 可安全做 I/O)
// name: 设备名称 (UTF-8)
// isDefault: 1 = 系统默认设备, 0 = 非默认
// 返回 1 继续枚举, 0 停止
typedef int (*ma_bridge_device_enum_proc)(void* pUserData, const char* name, int isDefault);

// 默认配置 (periodSize=256, periodCount=2, 48kHz, stereo, f32, 共享模式)
MA_BRIDGE_API ma_bridge_config ma_bridge_config_init_default(void);

// 初始化播放设备. 成功后设备处于 stopped 状态, 需调用 ma_bridge_start
// pUserData 将被传回 data_callback
MA_BRIDGE_API ma_bridge_result ma_bridge_init(const ma_bridge_config* pConfig,
                                ma_bridge_data_proc dataCallback,
                                void* pUserData,
                                void** ppBridge);

// 启动播放 (从音频线程外调用)
MA_BRIDGE_API ma_bridge_result ma_bridge_start(void* pBridge);

// 停止播放 (从音频线程外调用)
MA_BRIDGE_API ma_bridge_result ma_bridge_stop(void* pBridge);

// 获取设备实际使用的 period size 和 period count (init 后调用)
// 注意: 实际值可能不同于请求值 (取决于驱动限制)
MA_BRIDGE_API ma_bridge_result ma_bridge_get_period_size(void* pBridge,
                                           uint32_t* pPeriodSize,
                                           uint32_t* pPeriodCount);

// 获取设备实际采样率
MA_BRIDGE_API ma_bridge_result ma_bridge_get_sample_rate(void* pBridge, uint32_t* pSampleRate);

// 获取设备报告的内部延迟 (帧数)
// 这是 miniaudio 设备从内部缓冲区到实际发声的延迟, 不含应用层 RingBuffer
// 某些后端可能不支持 (返回 MA_BRIDGE_ERR_UNSUPPORTED)
// 传 NULL 到 pLatencyInFrames 可查询是否支持 (仅检查返回值)
MA_BRIDGE_API ma_bridge_result ma_bridge_get_latency(void* pBridge, uint32_t* pLatencyInFrames);

// 获取当前后端名称 (用于日志, 返回静态字符串, 无需释放)
MA_BRIDGE_API const char* ma_bridge_get_backend_name(void* pBridge);

// 设置主音量 (线性, 0.0 ~ 1.0). 线程安全, 可在播放中调用
MA_BRIDGE_API ma_bridge_result ma_bridge_set_volume(void* pBridge, float volume);

// 销毁设备并释放资源 (从音频线程外调用)
MA_BRIDGE_API void ma_bridge_uninit(void* pBridge);
// ---------------------------------------------------------------------------
// Vocal playback (single non-looping track, mixed in the same output callback)
// ---------------------------------------------------------------------------
// Loads a WAV/MP3/OGG/FLAC file through ma_decoder, decodes it on a producer
// thread into a bounded ring buffer (~1 second), and mixes it into pOutput in
// ma_device_callback right after the C# data callback. The vocal clock is the
// same device callback clock as MIDI, so the two streams stay sample-aligned.

// Load vocal file (UTF-8 path). Previous vocal state is unloaded first.
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_load(void* pBridge, const char* pFilePath);

// Unload vocal file and release decoder/ring resources.
MA_BRIDGE_API void ma_bridge_vocal_unload(void* pBridge);

// Start or resume vocal mixing. If the previous playback reached the natural
// end, playback restarts from frame 0.
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_play(void* pBridge);

// Pause vocal mixing (ring position is retained).
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_pause(void* pBridge);

// Stop vocal and rewind to frame 0.
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_stop(void* pBridge);

// Seek to an exact PCM frame index (clamped to the known length).
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_seek(void* pBridge, uint64_t frameIndex);

// Set vocal volume (linear, 0.0 ~ 4.0). Thread-safe.
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_set_volume(void* pBridge, float volume);

// Current consumed position in milliseconds (same clock as the output device).
MA_BRIDGE_API double ma_bridge_vocal_get_position_ms(void* pBridge);

// Total length in milliseconds, or -1 when the decoder cannot report it.
MA_BRIDGE_API int64_t ma_bridge_vocal_get_length_ms(void* pBridge);

// 1 while vocal mixing is active and not at its natural end.
MA_BRIDGE_API int ma_bridge_vocal_is_playing(void* pBridge);

// 1 after the vocal has reached its natural end (sticky until seek/stop/unload).
MA_BRIDGE_API int ma_bridge_vocal_is_finished(void* pBridge);

// Number of callback underruns (diagnostics; 0 is healthy).
MA_BRIDGE_API uint32_t ma_bridge_vocal_get_underrun_count(void* pBridge);

// 欠载期间设备已推进、但未混音的人声帧数（累加；用于观察漂移量是否被即时修正）。
MA_BRIDGE_API uint64_t ma_bridge_vocal_get_underrun_frames(void* pBridge);

// 待从 ring 丢弃以追平设备时钟的帧数（诊断；理想稳态为 0）。
MA_BRIDGE_API uint32_t ma_bridge_vocal_get_catchup_frames(void* pBridge);

// Discard the next N frames from the ring without mixing them. Used to keep
// vocal aligned with MIDI post-seek silence.
MA_BRIDGE_API ma_bridge_result ma_bridge_vocal_skip_frames(void* pBridge, uint32_t frames);

// 获取 miniaudio 版本字符串 (用于日志)
MA_BRIDGE_API const char* ma_bridge_get_version(void);

// ---------------------------------------------------------------------------
// 设备枚举与选择 (用于独占模式选择正确的设备端点)
// ---------------------------------------------------------------------------

// 设置下次 ma_bridge_init 使用的设备名称 (UTF-8).
// 传入 NULL 或空字符串恢复为默认设备.
// 名称需匹配 ma_bridge_enumerate_devices 返回的 name 字段.
// 注意: 此函数设置全局状态, 在 ma_bridge_init 前调用.
MA_BRIDGE_API void ma_bridge_set_device_name(const char* pName);

// 枚举播放设备, 对每个设备调用 callback.
// 返回设备数量, -1 = 错误 (bridge 未初始化).
// 必须在 ma_bridge_init 后调用 (需要 context).
MA_BRIDGE_API int ma_bridge_enumerate_devices(void* pBridge,
                                               ma_bridge_device_enum_proc callback,
                                               void* pUserData);

// ---------------------------------------------------------------------------
// 诊断函数 (用于排查独占模式无声音问题)
// ---------------------------------------------------------------------------

// 获取设备运行时状态: -1=未初始化, 0=uninitialized, 1=stopped, 2=starting, 3=started, 4=stopping
MA_BRIDGE_API int ma_bridge_get_device_state(void* pBridge);

// 获取 shareMode: -1=未初始化, 0=shared, 1=exclusive
MA_BRIDGE_API int ma_bridge_get_share_mode(void* pBridge);

// 获取是否指定了 pDeviceID: -1=未初始化, 1=指定了具体设备, 0=用默认设备
MA_BRIDGE_API int ma_bridge_has_device_id(void* pBridge);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MINIAUDIO_BRIDGE_H
