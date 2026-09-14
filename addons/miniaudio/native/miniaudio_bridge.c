// miniaudio_bridge.c
// 实现 miniaudio_bridge.h 中定义的 C API
//
// 编译方式: miniaudio.h 通过 git 子模块 vendored (miniaudio/ 目录, 见 .gitmodules),
// clone 时用 `git clone --recurse-submodules` 或 `git submodule update --init` 拉取.
// miniaudio 是单头文件库, 会自动检测平台后端.
//
// 编译示例 (Windows MSVC, x64):
//   cl /O2 /LD miniaudio_bridge.c /Fe:miniaudio_bridge.dll
// 编译示例 (Linux/macOS, x86_64):
//   gcc -O2 -fPIC -shared miniaudio_bridge.c -o libminiaudio_bridge.so
//   gcc -O2 -fPIC -shared miniaudio_bridge.c -o libminiaudio_bridge.dylib
// Android (arm64):
//   $NDK/toolchains/llvm/prebuilt/.../aarch64-linux-android24-clang \
//     -O2 -fPIC -shared miniaudio_bridge.c -o libminiaudio_bridge.so
// iOS (静态库):
//   xcrun -sdk iphoneos clang -arch arm64 -O2 -fPIC \
//     -shared miniaudio_bridge.c -o libminiaudio_bridge.dylib

// Enable OGG/Vorbis support: miniaudio only exposes Vorbis when stb_vorbis is
// compiled in first. stb_vorbis.c is the upstream single-file decoder
// (public domain / MIT, see file header).
#define STB_VORBIS_IMPLEMENTATION
#include "thirdparty/stb_vorbis/stb_vorbis.c"
/* stb_vorbis leaks these channel-map macros; clear them before Windows headers. */
#undef L
#undef C
#undef R
#undef PLAYBACK_MONO
#undef PLAYBACK_LEFT
#undef PLAYBACK_RIGHT

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio/miniaudio.h"

#include "miniaudio_bridge.h"
#include <stdlib.h>
#include <string.h>

// 内部 bridge 状态
typedef struct {
    ma_device      device;         // miniaudio 设备 (透明结构, 必须按值持有)
    ma_context     context;        // 上下文 (用于显式后端选择)
    ma_bridge_config config;       // 用户配置快照
    ma_bridge_data_proc dataCallback;
    void*          pUserData;
    int            initialized;
    int            started;
    int            hasDeviceId;    // 1=指定了具体设备, 0=用默认设备 (诊断用)
    char           backendName[64];

    // ---- vocal playback state (miniaudio decoder + ring buffer) ----
    ma_decoder     vocalDecoder;
    int            vocalDecoderValid;
    volatile int   vocalDecoderEof;
    ma_uint64      vocalDecoderTotalFrames; /* 0 = unknown */
    float*         vocalRing;
    ma_uint32      vocalRingCapacity;       /* power of two slots (one reserved) */
    ma_uint32      vocalRingMask;
    ma_uint32      vocalReadIndex;
    ma_uint32      vocalWriteIndex;
    volatile ma_uint64 vocalConsumedFrames; /* frames consumed by device callback */
    volatile ma_uint32 vocalSkipFrames;     /* frames to discard before mixing */
    volatile int   vocalPlaying;
    volatile int   vocalLoaded;
    volatile int   vocalEndReached;
    volatile int   vocalProducerStop;
    volatile float vocalVolume;
    ma_uint32      vocalUnderrunCount;
    ma_spinlock    vocalLock;
    ma_thread      vocalProducerThread;
    int            vocalProducerRunning;
    uint32_t       vocalSampleRate;
} ma_bridge;

// 全局设备名称 (由 ma_bridge_set_device_name 设置, ma_bridge_init 读取)
// 独占模式下用于指定正确的设备端点 (避免打开 HDMI 等错误设备).
// 空字符串 = 使用系统默认设备.
static char g_deviceName[256] = {0};

// ---------------------------------------------------------------------------
// 设备查找: 按名称查找设备 ID
// ---------------------------------------------------------------------------

// 枚举回调上下文
typedef struct {
    const char*    targetName;     // 要查找的设备名称
    ma_device_id*  pDeviceId;      // 找到后写入设备 ID
    int            found;          // 0 = 未找到, 1 = 找到
} FindDeviceContext;

static ma_bool32 find_device_callback(ma_context* pContext,
                                       ma_device_type deviceType,
                                       const ma_device_info* pInfo,
                                       void* pUserData)
{
    if (deviceType != ma_device_type_playback) return MA_TRUE;
    FindDeviceContext* pCtx = (FindDeviceContext*)pUserData;
    if (pInfo == NULL || pCtx == NULL) return MA_TRUE;

    if (strcmp(pCtx->targetName, pInfo->name) == 0) {
        if (pCtx->pDeviceId != NULL) {
            *pCtx->pDeviceId = pInfo->id;
        }
        pCtx->found = 1;
        return MA_FALSE; // 找到了, 停止枚举
    }
    return MA_TRUE; // 继续枚举
}

// 设备枚举回调上下文 (用于 ma_bridge_enumerate_devices)
typedef struct {
    ma_bridge_device_enum_proc userCallback;
    void*                      pUserData;
    int                        count;
} EnumDevicesContext;

static ma_bool32 enum_devices_callback(ma_context* pContext,
                                        ma_device_type deviceType,
                                        const ma_device_info* pInfo,
                                        void* pUserData)
{
    if (deviceType != ma_device_type_playback) return MA_TRUE;
    EnumDevicesContext* pCtx = (EnumDevicesContext*)pUserData;
    if (pCtx == NULL || pCtx->userCallback == NULL || pInfo == NULL) return MA_TRUE;

    int isDefault = (pInfo->isDefault == MA_TRUE) ? 1 : 0;
    int cont = pCtx->userCallback(pCtx->pUserData, pInfo->name, isDefault);
    pCtx->count++;
    return (cont != 0) ? MA_TRUE : MA_FALSE;
}

// ---------------------------------------------------------------------------
// 默认配置
// ---------------------------------------------------------------------------
ma_bridge_config ma_bridge_config_init_default(void)
{
    ma_bridge_config cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.sampleRate = 48000;
    cfg.periodSizeInFrames = 256;   // 低延迟默认值
    cfg.periodCount = 2;
    cfg.channels = 2;
    cfg.format = 0;                 // f32
    cfg.backend = MA_BRIDGE_BACKEND_DEFAULT;
    cfg.wasapiExclusive = 0;
    cfg.aaudioExclusive = 0;
    cfg.noPreSilencedInputBuffer = 0;
    cfg.noClip = 1;                 // 本项目在 C# 侧用 SoftLimit, 禁用 miniaudio 内部 clip
    cfg.noDeviceStateChangedCallback = 1; // 性能优化
    cfg.noAutoConvertSRC = 0;       // 默认禁用, 仅在需要 IAudioClient3 时启用
    return cfg;
}

// ---------------------------------------------------------------------------
// 辅助: 后端枚举转换
// ---------------------------------------------------------------------------
static ma_backend to_ma_backend(ma_bridge_backend b)
{
    switch (b) {
        case MA_BRIDGE_BACKEND_WASAPI:    return ma_backend_wasapi;
        case MA_BRIDGE_BACKEND_DSOUND:    return ma_backend_dsound;
        case MA_BRIDGE_BACKEND_WINMM:     return ma_backend_winmm;
        case MA_BRIDGE_BACKEND_COREAUDIO: return ma_backend_coreaudio;
        case MA_BRIDGE_BACKEND_AAUDIO:    return ma_backend_aaudio;
        case MA_BRIDGE_BACKEND_OPENSL:    return ma_backend_opensl;
        case MA_BRIDGE_BACKEND_PULSEAUDIO:return ma_backend_pulseaudio;
        case MA_BRIDGE_BACKEND_ALSA:      return ma_backend_alsa;
        default: return ma_backend_wasapi; // 仅作占位, 实际使用 NULL (自动)
    }
}

// ---------------------------------------------------------------------------
// 设备数据回调 (miniaudio → C#)
// miniaudio 的 ma_device_data_proc 签名:
//   void(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount)
// 转换为本桥的 ma_bridge_data_proc 签名:
//   void(void* pUserData, float* pOutput, uint32_t frameCount)
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Vocal playback helpers
// ---------------------------------------------------------------------------
#define MA_BRIDGE_VOCAL_CHANNELS 2
#define MA_BRIDGE_VOCAL_CHUNK_FRAMES 4096

static ma_uint32 vocal_next_pow2(ma_uint32 v)
{
    if (v < 2) return 2;
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    return v + 1;
}

static void vocal_start_producer(ma_bridge* p);
static void vocal_stop_producer(ma_bridge* p);

static ma_uint32 vocal_ring_used(ma_bridge* p)
{
    ma_uint32 r, w;
    if (p->vocalRing == NULL || p->vocalRingCapacity == 0) return 0;
    ma_spinlock_lock(&p->vocalLock);
    r = p->vocalReadIndex;
    w = p->vocalWriteIndex;
    ma_spinlock_unlock(&p->vocalLock);
    return (w - r) & p->vocalRingMask;
}

static int vocal_has_ogg_extension(const char* pFilePath)
{
    const char* dot = strrchr(pFilePath, '.');
    if (dot == NULL || dot[1] == '\0' || dot[2] == '\0' || dot[3] == '\0') {
        return 0;
    }
    char c1 = dot[1] | 0x20;
    char c2 = dot[2] | 0x20;
    char c3 = dot[3] | 0x20;
    return c1 == 'o' && c2 == 'g' && c3 == 'g' && dot[4] == '\0';
}

static ma_result vocal_init_decoder_file(ma_decoder* pDecoder,
                                         const char* pFilePath,
                                         const ma_decoder_config* pConfig)
{
#if defined(_WIN32) || defined(__WIN32__) || defined(WIN32)
    int wideLen = MultiByteToWideChar(CP_UTF8, 0, pFilePath, -1, NULL, 0);
    if (wideLen <= 0) {
        return MA_INVALID_ARGS;
    }
    wchar_t* pWide = (wchar_t*)malloc((size_t)wideLen * sizeof(wchar_t));
    if (pWide == NULL) {
        return MA_OUT_OF_MEMORY;
    }
    MultiByteToWideChar(CP_UTF8, 0, pFilePath, -1, pWide, wideLen);
    ma_result mr = ma_decoder_init_file_w(pWide, pConfig, pDecoder);
    free(pWide);
    return mr;
#else
    return ma_decoder_init_file(pFilePath, pConfig, pDecoder);
#endif
}

static ma_thread_result MA_THREADCALL vocal_producer_entry(void* pData)
{
    ma_bridge* p = (ma_bridge*)pData;
    if (p == NULL) {
        return (ma_thread_result)0;
    }

    while (!p->vocalProducerStop) {
        if (!p->vocalLoaded || !p->vocalDecoderValid || p->vocalEndReached) {
            ma_sleep(4);
            continue;
        }

        if (p->vocalDecoderEof) {
            ma_uint32 used = vocal_ring_used(p);
            if (used == 0) {
                ma_spinlock_lock(&p->vocalLock);
                if (p->vocalDecoderEof && p->vocalReadIndex == p->vocalWriteIndex) {
                    p->vocalEndReached = 1;
                    p->vocalPlaying = 0;
                }
                ma_spinlock_unlock(&p->vocalLock);
            } else {
                ma_sleep(4);
            }
            continue;
        }

        ma_uint32 used = vocal_ring_used(p);
        if (p->vocalRingCapacity == 0 ||
            (p->vocalRingCapacity - 1 - used) < MA_BRIDGE_VOCAL_CHUNK_FRAMES) {
            /* 环满：播放中按消费 1 个 chunk 周期的量级休眠（4096帧@48k≈85ms，
             * 取 25ms 保证余量 ≥60ms 不欠载）；预载/暂停期短眠尽快填满。 */
            ma_sleep(p->vocalPlaying ? 25 : 4);
            continue;
        }

        /* 高水位节流：播放中保持环半满（65536/2=32768帧≈683ms 盈余）。
         * 半满后解码节奏 ≈ 每消费 ~4096 帧补一次（约 85ms 周期），
         * 唤醒率从 ~500次/s 降到 ~40次/s，且任何时刻至少 0.6s 缓冲兜底欠载。
         * underrun 后环空（used≈0 < 半满）立即补解码，无额外延迟。 */
        if (p->vocalPlaying && used >= (p->vocalRingCapacity >> 1)) {
            ma_sleep(25);
            continue;
        }

        float chunk[MA_BRIDGE_VOCAL_CHUNK_FRAMES * MA_BRIDGE_VOCAL_CHANNELS];
        ma_uint64 framesRead = 0;
        ma_result readResult = ma_decoder_read_pcm_frames(&p->vocalDecoder, chunk,
                                                          MA_BRIDGE_VOCAL_CHUNK_FRAMES,
                                                          &framesRead);
        if (readResult != MA_SUCCESS || framesRead == 0) {
            p->vocalDecoderEof = 1;
            continue;
        }

        ma_spinlock_lock(&p->vocalLock);
        ma_uint32 idx = p->vocalWriteIndex;
        ma_uint64 i;
        for (i = 0; i < framesRead; ++i) {
            p->vocalRing[idx * MA_BRIDGE_VOCAL_CHANNELS + 0] =
                chunk[i * MA_BRIDGE_VOCAL_CHANNELS + 0];
            p->vocalRing[idx * MA_BRIDGE_VOCAL_CHANNELS + 1] =
                chunk[i * MA_BRIDGE_VOCAL_CHANNELS + 1];
            idx = (idx + 1) & p->vocalRingMask;
        }
        p->vocalWriteIndex = idx;
        ma_spinlock_unlock(&p->vocalLock);
    }

    return (ma_thread_result)0;
}

static void vocal_start_producer(ma_bridge* p)
{
    if (p == NULL || p->vocalProducerRunning || !p->vocalLoaded) {
        return;
    }
    p->vocalProducerStop = 0;
    /* 低优先级：解码线程在 Android 上持续占用 ~15-35% 核（MP3 每 85ms 音频解码一次），
     * 与高优先级 AAudio 音频回调争抢 CPU 并加重发热降频。环缓冲水位半满时约有 683ms
     * 盈余，解码延迟完全不敏感，把优先级降到 low 让调度器优先保证音频回调线程。 */
    if (ma_thread_create(&p->vocalProducerThread, ma_thread_priority_low, 0,
                         vocal_producer_entry, p, NULL) != MA_SUCCESS) {
        p->vocalProducerRunning = 0;
        return;
    }
    p->vocalProducerRunning = 1;
}

static void vocal_stop_producer(ma_bridge* p)
{
    if (p == NULL || !p->vocalProducerRunning) {
        return;
    }
    p->vocalProducerStop = 1;
    ma_thread_wait(&p->vocalProducerThread);
    p->vocalProducerRunning = 0;
}

static void vocal_mix(ma_bridge* p, float* pOutput, ma_uint32 frameCount)
{
    if (!p->vocalLoaded || !p->vocalDecoderValid || !p->vocalPlaying || p->vocalEndReached) {
        return;
    }

    float volume = p->vocalVolume;
    ma_uint32 outPos = 0;

    /* Phase 1: discard frames that belong to MIDI post-seek silence. */
    while (outPos < frameCount && p->vocalSkipFrames > 0) {
        ma_uint32 r, w, avail, n;
        ma_spinlock_lock(&p->vocalLock);
        r = p->vocalReadIndex;
        w = p->vocalWriteIndex;
        ma_spinlock_unlock(&p->vocalLock);

        avail = (w - r) & p->vocalRingMask;
        if (avail == 0) {
            p->vocalUnderrunCount++;
            break;
        }
        n = avail;
        if (n > p->vocalSkipFrames) n = p->vocalSkipFrames;
        if (n > frameCount - outPos) n = frameCount - outPos;

        ma_spinlock_lock(&p->vocalLock);
        p->vocalReadIndex = (r + n) & p->vocalRingMask;
        p->vocalSkipFrames -= n;
        p->vocalConsumedFrames += n;
        ma_spinlock_unlock(&p->vocalLock);
        outPos += n;
    }

    /* If skip frames are still pending (ring underrun), do not mix yet. */
    if (p->vocalSkipFrames > 0) {
        return;
    }

    /* Phase 2: mix vocal into the same output buffer as MIDI. */
    while (outPos < frameCount) {
        ma_uint32 r, w, avail, n, i;
        ma_spinlock_lock(&p->vocalLock);
        r = p->vocalReadIndex;
        w = p->vocalWriteIndex;
        ma_spinlock_unlock(&p->vocalLock);

        avail = (w - r) & p->vocalRingMask;
        if (avail == 0) {
            p->vocalUnderrunCount++;
            break;
        }
        n = avail;
        if (n > frameCount - outPos) n = frameCount - outPos;

        for (i = 0; i < n; ++i) {
            ma_uint32 idx = (r + i) & p->vocalRingMask;
            pOutput[(outPos + i) * MA_BRIDGE_VOCAL_CHANNELS + 0] +=
                p->vocalRing[idx * MA_BRIDGE_VOCAL_CHANNELS + 0] * volume;
            pOutput[(outPos + i) * MA_BRIDGE_VOCAL_CHANNELS + 1] +=
                p->vocalRing[idx * MA_BRIDGE_VOCAL_CHANNELS + 1] * volume;
        }

        ma_spinlock_lock(&p->vocalLock);
        p->vocalReadIndex = (r + n) & p->vocalRingMask;
        p->vocalConsumedFrames += n;
        ma_spinlock_unlock(&p->vocalLock);
        outPos += n;
    }

    /* Natural end: only when the decoder is done and the ring is drained. */
    if (p->vocalDecoderEof) {
        ma_spinlock_lock(&p->vocalLock);
        if (p->vocalDecoderEof && p->vocalReadIndex == p->vocalWriteIndex && p->vocalPlaying) {
            p->vocalEndReached = 1;
            p->vocalPlaying = 0;
        }
        ma_spinlock_unlock(&p->vocalLock);
    }
}

static void ma_device_callback(ma_device* pDevice,
                                void* pOutput,
                                const void* pInput,
                                ma_uint32 frameCount)
{
    ma_bridge* pBridge = (ma_bridge*)pDevice->pUserData;
    if (pBridge == NULL || pBridge->dataCallback == NULL) {
        // 回调未就绪, 输出静音
        if (pOutput != NULL) {
            memset(pOutput, 0, (size_t)frameCount * 2 * sizeof(float));
        }
        return;
    }
    pBridge->dataCallback(pBridge->pUserData, (float*)pOutput, (uint32_t)frameCount);
    vocal_mix(pBridge, (float*)pOutput, (uint32_t)frameCount);
}

// ---------------------------------------------------------------------------
// 初始化
// ---------------------------------------------------------------------------
ma_bridge_result ma_bridge_init(const ma_bridge_config* pConfig,
                                ma_bridge_data_proc dataCallback,
                                void* pUserData,
                                void** ppBridge)
{
    if (pConfig == NULL || dataCallback == NULL || ppBridge == NULL) {
        return MA_BRIDGE_ERR_INVALID_ARG;
    }

    ma_bridge* pBridge = (ma_bridge*)calloc(1, sizeof(ma_bridge));
    if (pBridge == NULL) {
        return MA_BRIDGE_ERR_INIT;
    }

    pBridge->config = *pConfig;
    pBridge->dataCallback = dataCallback;
    pBridge->pUserData = pUserData;

    ma_result mr;

    // ---- 1. 上下文初始化 (仅当显式指定后端时使用) ----
    if (pConfig->backend != MA_BRIDGE_BACKEND_DEFAULT) {
        ma_backend backends[1] = { to_ma_backend(pConfig->backend) };
        mr = ma_context_init(backends, 1, NULL, &pBridge->context);
        if (mr != MA_SUCCESS) {
            // 回退到自动后端选择
            mr = ma_context_init(NULL, 0, NULL, &pBridge->context);
            if (mr != MA_SUCCESS) {
                free(pBridge);
                return MA_BRIDGE_ERR_INIT;
            }
        }
    }
    // 否则: 不创建显式 context, 让 ma_device_init 内部用 NULL context (自动)

    // 确定 context 指针 (显式后端用 &pBridge->context, 否则 NULL 让 miniaudio 内部创建)
    ma_context* pCtx = (pConfig->backend != MA_BRIDGE_BACKEND_DEFAULT) ? &pBridge->context : NULL;

    // ---- 2. 设备配置 ----
    ma_device_config devCfg = ma_device_config_init(ma_device_type_playback);
    devCfg.playback.format   = ma_format_f32;
    devCfg.playback.channels = pConfig->channels ? pConfig->channels : 2;
    devCfg.sampleRate        = pConfig->sampleRate;
    devCfg.periodSizeInFrames= pConfig->periodSizeInFrames;
    devCfg.periods           = pConfig->periodCount;   // miniaudio 字段名为 periods
    devCfg.dataCallback      = ma_device_callback;
    devCfg.pUserData         = pBridge;

    // 性能 / 兼容标志
    // noPreSilencedOutputBuffer: 回调自己填满整个输出缓冲区, 跳过 miniaudio 预清零以节省一点 CPU
    devCfg.noPreSilencedOutputBuffer = (ma_bool8)(pConfig->noPreSilencedInputBuffer ? MA_TRUE : MA_FALSE);
    // noClip: 本项目在 C# 侧用 SoftLimit 做软限幅, 禁用 miniaudio 内部硬 clip
    devCfg.noClip            = (ma_bool8)(pConfig->noClip ? MA_TRUE : MA_FALSE);

    // WASAPI: noAutoConvertSRC
    // 禁用 WASAPI 内部 SRC (AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM), 改用 miniaudio 重采样器.
    // 这是启用 IAudioClient3 低延迟共享模式的前提条件.
    // IAudioClient3 可以让共享模式使用小 period (如 128 帧), 达到接近独占模式的延迟,
    // 但不需要独占设备, 避免了 Realtek 等驱动独占模式的兼容性问题.
    // 注意: 启用 noAutoConvertSRC 后, 如果请求采样率 ≠ 设备原生采样率,
    // miniaudio 会用内部重采样器做 SRC. 为避免重采样开销, 建议请求采样率 = 设备原生采样率.
#if defined(_WIN32) || defined(__WIN32__) || defined(WIN32)
    if (pConfig->noAutoConvertSRC) {
        devCfg.wasapi.noAutoConvertSRC = MA_TRUE;
        fprintf(stderr, "[miniaudio_bridge] noAutoConvertSRC=true (enable IAudioClient3 low-latency shared mode)\n");
        fflush(stderr);
    }
#endif

    // 按名称选择设备 (用于独占模式选择正确的端点)
    // g_deviceName 由 ma_bridge_set_device_name 设置, 通常从环境变量 MINIAUDIO_DEVICE_NAME 读取.
    // 如果未设置或找不到匹配设备, 使用系统默认设备 (pDeviceID = NULL).
    // 独占模式下 WASAPI 直接绑定设备, 不会自动路由, 因此必须选择正确的端点.
    // 共享模式下 Windows 音频引擎会自动路由, 不需要指定设备.
    //
    // 注意: 即使 pCtx==NULL (默认后端), 也要创建临时 context 用于设备枚举.
    // 设备 ID 在同一后端内跨 context 稳定, 可用于 pCtx=NULL 的 ma_device_init.
    // 之前的 bug: pCtx!=NULL 条件导致默认后端时设备查找被跳过,
    // 独占模式可能打开错误端点 (如 Steam Streaming Speakers) 导致无声音.
    ma_device_id deviceId;
    int hasDeviceId = 0;
    if (g_deviceName[0] != '\0') {
        ma_context* pEnumCtx = pCtx;
        ma_context tempCtx;
        int tempCtxCreated = 0;
        if (pEnumCtx == NULL) {
            if (ma_context_init(NULL, 0, NULL, &tempCtx) == MA_SUCCESS) {
                pEnumCtx = &tempCtx;
                tempCtxCreated = 1;
            }
        }
        if (pEnumCtx != NULL) {
            FindDeviceContext findCtx;
            findCtx.targetName = g_deviceName;
            findCtx.pDeviceId  = &deviceId;
            findCtx.found      = 0;
            ma_context_enumerate_devices(pEnumCtx, find_device_callback, &findCtx);
            if (findCtx.found) {
                devCfg.playback.pDeviceID = &deviceId;
                hasDeviceId = 1;
            }
        }
        if (tempCtxCreated) {
            ma_context_uninit(&tempCtx);
        }
    }

    // WASAPI 独占模式 (仅 Windows + WASAPI 后端生效)
    // 独占模式通过 shareMode 字段控制, 不是 wasapi.usage
#if defined(_WIN32) || defined(__WIN32__) || defined(WIN32)
    if (pConfig->wasapiExclusive) {
        devCfg.playback.shareMode = ma_share_mode_exclusive;
        devCfg.wasapi.usage       = ma_wasapi_usage_pro_audio;  // 提高线程优先级
        // 独占模式必须使用设备原生采样率, miniaudio 不做 SRC.
        // 如果请求采样率 ≠ 设备原生采样率, 设备初始化"成功"但实际无声音.
        // 设 sampleRate=0 让 miniaudio 自动选择设备原生采样率.
        fprintf(stderr, "[miniaudio_bridge] Exclusive mode: setting sampleRate=0 (device native rate)\n");
        fflush(stderr);
        devCfg.sampleRate = 0;

        // 独占模式: 强制 periodCount=1.
        // WASAPI 独占模式要求 hnsBufferDuration = hnsPeriodicity, 即缓冲区 = 1 个 period.
        // 某些 Realtek 驱动在 periodCount=2 时初始化"成功"但实际无声音.
        // periodCount=1 确保缓冲区 = period, 符合独占模式规范.
        fprintf(stderr, "[miniaudio_bridge] Exclusive mode: forcing periodCount=1\n");
        fflush(stderr);
        devCfg.periods = 1;
    }
#endif

    // AAudio 低延迟模式 (仅 Android)
    // AAudio 没有 "exclusive" 概念, 这里使用 game usage 获取低延迟路径
#if defined(__ANDROID__)
    if (pConfig->aaudioExclusive) {
        devCfg.aaudio.usage = ma_aaudio_usage_game;
        // 让 AAudio 使用请求的 bufferCapacityInFrames / framesPerDataCallback（256×2 ≈ 11ms）
        // 否则 AAudio 回退到系统默认大缓冲
        devCfg.aaudio.allowSetBufferCapacity = MA_TRUE;
    }
#endif

    // ---- 3. 设备初始化 ----
    fprintf(stderr, "[miniaudio_bridge] Before ma_device_init: sampleRate=%u, periodSize=%u, periods=%u, channels=%u, shareMode=%d\n",
            devCfg.sampleRate, devCfg.periodSizeInFrames, devCfg.periods, devCfg.playback.channels, (int)devCfg.playback.shareMode);
    fflush(stderr);

    mr = ma_device_init(pCtx, &devCfg, &pBridge->device);
    fprintf(stderr, "[miniaudio_bridge] ma_device_init result=%d, device.sampleRate=%u, internalPeriodSize=%u, internalPeriods=%u, shareMode=%d, channels=%u\n",
            (int)mr,
            pBridge->device.sampleRate,
            pBridge->device.playback.internalPeriodSizeInFrames,
            pBridge->device.playback.internalPeriods,
            (int)pBridge->device.playback.shareMode,
            pBridge->device.playback.channels);
    fflush(stderr);

    if (mr != MA_SUCCESS) {
        // 回退 1: 如果启用了 WASAPI 独占模式, 尝试回退到共享模式
        // (独占模式在某些设备/驱动上不可用, 或设备已被其他应用占用)
        int wasExclusive = 0;
#if defined(_WIN32) || defined(__WIN32__) || defined(WIN32)
        if (pConfig->wasapiExclusive) {
            wasExclusive = 1;
            devCfg.playback.shareMode = ma_share_mode_shared;
            devCfg.wasapi.usage       = ma_wasapi_usage_default;
            mr = ma_device_init(pCtx, &devCfg, &pBridge->device);
        }
#endif
        // 回退 2: 如果显式 WASAPI 后端失败, 不回退到 DirectSound (period=1440, 30ms 延迟).
        // DirectSound 延迟极高, 回退到它毫无意义. 直接报错让上层处理.
        // (之前会自动回退, 导致 period=1440×2=60ms, 比 FMOD 还差)
        if (mr != MA_SUCCESS) {
            if (pCtx != NULL) {
                ma_context_uninit(&pBridge->context);
            }
            free(pBridge);
            return MA_BRIDGE_ERR_DEVICE;
        }
        if (wasExclusive) {
            strncpy(pBridge->backendName, "wasapi (shared fallback)", sizeof(pBridge->backendName) - 1);
        }
    }

    pBridge->initialized = 1;
    pBridge->hasDeviceId = hasDeviceId;  // 保存诊断标志

    // 记录后端名称
    const char* name = ma_get_backend_name(pBridge->device.pContext->backend);
    if (name != NULL) {
        strncpy(pBridge->backendName, name, sizeof(pBridge->backendName) - 1);
        pBridge->backendName[sizeof(pBridge->backendName) - 1] = '\0';
    } else {
        strncpy(pBridge->backendName, "unknown", sizeof(pBridge->backendName) - 1);
    }

    *ppBridge = pBridge;
    return MA_BRIDGE_OK;
}

// ---------------------------------------------------------------------------
// 启动 / 停止
// ---------------------------------------------------------------------------
ma_bridge_result ma_bridge_start(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (p->started) {
        return MA_BRIDGE_OK;
    }
    ma_result mr = ma_device_start(&p->device);
    if (mr != MA_SUCCESS) {
        return MA_BRIDGE_ERR_DEVICE;
    }
    p->started = 1;

    // 设备启动状态诊断 (排查独占模式无声音问题)
    // 使用 stderr + Godot 的 print 可见性更好
    {
        ma_device_state state = ma_device_get_state(&p->device);
        const char* stateStr = "unknown";
        switch (state) {
            case ma_device_state_uninitialized: stateStr = "uninitialized"; break;
            case ma_device_state_stopped:       stateStr = "stopped"; break;
            case ma_device_state_starting:      stateStr = "starting"; break;
            case ma_device_state_started:       stateStr = "started"; break;
            case ma_device_state_stopping:      stateStr = "stopping"; break;
            default: break;
        }
        const char* shareStr = "unknown";
        switch ((int)p->device.playback.shareMode) {
            case 0: shareStr = "shared"; break;
            case 1: shareStr = "exclusive"; break;
            case 2: shareStr = "loopback"; break;
            default: break;
        }
        fprintf(stderr, "[miniaudio_bridge] Device started: state=%s, sampleRate=%u, "
               "periodSize=%u, periods=%u, shareMode=%d(%s), channels=%u\n",
               stateStr,
               p->device.sampleRate,
               p->device.playback.internalPeriodSizeInFrames,
               p->device.playback.internalPeriods,
               (int)p->device.playback.shareMode,
               shareStr,
               p->device.playback.channels);
        fflush(stderr);
    }

    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_stop(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->started) {
        return MA_BRIDGE_OK;
    }
    ma_result mr = ma_device_stop(&p->device);
    if (mr != MA_SUCCESS) {
        return MA_BRIDGE_ERR_DEVICE;
    }
    p->started = 0;
    return MA_BRIDGE_OK;
}

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------
ma_bridge_result ma_bridge_get_period_size(void* pBridge,
                                           uint32_t* pPeriodSize,
                                           uint32_t* pPeriodCount)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized || pPeriodSize == NULL || pPeriodCount == NULL) {
        return MA_BRIDGE_ERR_INVALID_ARG;
    }
    *pPeriodSize = p->device.playback.internalPeriodSizeInFrames;
    *pPeriodCount = p->device.playback.internalPeriods;
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_get_sample_rate(void* pBridge, uint32_t* pSampleRate)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized || pSampleRate == NULL) {
        return MA_BRIDGE_ERR_INVALID_ARG;
    }
    *pSampleRate = p->device.sampleRate;
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_get_latency(void* pBridge, uint32_t* pLatencyInFrames)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    // 此版本 miniaudio 没有 ma_device_get_latency, 用内部 buffer 大小估算延迟.
    // WASAPI 独占模式回调触发时: 1 个 period 正在播放, (periodCount-1) 个已排队.
    // 实际设备延迟 = periodSize × (periodCount - 0.5) (平均延迟).
    // 之前用 periodSize × periodCount 偏高 (把整个缓冲区算作延迟).
    ma_uint32 periodSize = p->device.playback.internalPeriodSizeInFrames;
    ma_uint32 periods = (ma_uint32)p->device.playback.internalPeriods;
    if (periodSize == 0 || periods == 0) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }
    // periods >= 2 时用 (periods - 0.5), periods == 1 时用 0.5 (至少半个 period 延迟)
    double latencyPeriods = (periods >= 2) ? ((double)periods - 0.5) : 0.5;
    ma_uint32 latencyFrames = (ma_uint32)(periodSize * latencyPeriods);
    if (pLatencyInFrames != NULL) {
        *pLatencyInFrames = latencyFrames;
    }
    return MA_BRIDGE_OK;
}

const char* ma_bridge_get_backend_name(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return "uninitialized";
    }
    return p->backendName;
}

ma_bridge_result ma_bridge_set_volume(void* pBridge, float volume)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    // ma_device_set_master_volume 内部原子写入, 线程安全
    ma_result mr = ma_device_set_master_volume(&p->device, volume);
    return (mr == MA_SUCCESS) ? MA_BRIDGE_OK : MA_BRIDGE_ERR_DEVICE;
}

// ---------------------------------------------------------------------------
// Vocal control API
// ---------------------------------------------------------------------------
void ma_bridge_vocal_unload(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL) {
        return;
    }
    vocal_stop_producer(p);
    if (p->vocalDecoderValid) {
        ma_decoder_uninit(&p->vocalDecoder);
    }
    if (p->vocalRing != NULL) {
        free(p->vocalRing);
    }
    p->vocalRing = NULL;
    p->vocalRingCapacity = 0;
    p->vocalRingMask = 0;
    p->vocalReadIndex = 0;
    p->vocalWriteIndex = 0;
    p->vocalConsumedFrames = 0;
    p->vocalSkipFrames = 0;
    p->vocalPlaying = 0;
    p->vocalEndReached = 0;
    p->vocalDecoderEof = 0;
    p->vocalDecoderValid = 0;
    p->vocalDecoderTotalFrames = 0;
    p->vocalLoaded = 0;
}

ma_bridge_result ma_bridge_vocal_load(void* pBridge, const char* pFilePath)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (pFilePath == NULL || pFilePath[0] == '\0') {
        return MA_BRIDGE_ERR_INVALID_ARG;
    }

    ma_bridge_vocal_unload(p);

    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32,
                                                   MA_BRIDGE_VOCAL_CHANNELS,
                                                   p->device.sampleRate);
    ma_result mr = vocal_init_decoder_file(&p->vocalDecoder, pFilePath, &cfg);
    if (mr != MA_SUCCESS) {
        fprintf(stderr, "[miniaudio_bridge] vocal load failed: %d (%s)\n", (int)mr, pFilePath);
        fflush(stderr);
        return MA_BRIDGE_ERR_INIT;
    }

    p->vocalDecoderValid = 1;
    p->vocalDecoderEof = 0;
    p->vocalDecoderTotalFrames = 0;
    ma_uint64 totalFrames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&p->vocalDecoder, &totalFrames) == MA_SUCCESS) {
        if (vocal_has_ogg_extension(pFilePath)) {
            /* stb_vorbis reports the length in source frames; after resampling
             * to the device rate this value is wrong. Treat OGG length as
             * unknown so callers skip seek clamping. */
            p->vocalDecoderTotalFrames = 0;
        } else {
            p->vocalDecoderTotalFrames = totalFrames;
        }
    }

    ma_uint32 capacity = vocal_next_pow2(p->device.sampleRate);
    if (capacity < 4096) {
        capacity = 4096;
    }
    float* ring = (float*)malloc((size_t)capacity * MA_BRIDGE_VOCAL_CHANNELS * sizeof(float));
    if (ring == NULL) {
        ma_decoder_uninit(&p->vocalDecoder);
        p->vocalDecoderValid = 0;
        return MA_BRIDGE_ERR_INIT;
    }
    memset(ring, 0, (size_t)capacity * MA_BRIDGE_VOCAL_CHANNELS * sizeof(float));

    p->vocalRing = ring;
    p->vocalRingCapacity = capacity;
    p->vocalRingMask = capacity - 1;
    p->vocalReadIndex = 0;
    p->vocalWriteIndex = 0;
    p->vocalConsumedFrames = 0;
    p->vocalSkipFrames = 0;
    p->vocalPlaying = 0;
    p->vocalEndReached = 0;
    p->vocalUnderrunCount = 0;
    p->vocalVolume = 1.0f;
    p->vocalSampleRate = p->device.sampleRate;
    p->vocalLoaded = 1;

    vocal_start_producer(p);
    fprintf(stderr, "[miniaudio_bridge] vocal loaded: sr=%u totalFrames=%llu\n",
            p->vocalSampleRate, (unsigned long long)p->vocalDecoderTotalFrames);
    fflush(stderr);
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_vocal_play(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->vocalLoaded || !p->vocalDecoderValid) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }
    if (p->vocalEndReached) {
        ma_bridge_result seekResult = ma_bridge_vocal_seek(p, 0);
        if (seekResult != MA_BRIDGE_OK) {
            return seekResult;
        }
    }
    p->vocalPlaying = 1;
    vocal_start_producer(p);
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_vocal_pause(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->vocalLoaded) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }
    p->vocalPlaying = 0;
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_vocal_stop(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->vocalLoaded) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }

    vocal_stop_producer(p);
    p->vocalPlaying = 0;
    ma_spinlock_lock(&p->vocalLock);
    p->vocalReadIndex = 0;
    p->vocalWriteIndex = 0;
    p->vocalConsumedFrames = 0;
    p->vocalSkipFrames = 0;
    p->vocalEndReached = 0;
    p->vocalDecoderEof = 0;
    ma_spinlock_unlock(&p->vocalLock);

    if (ma_decoder_seek_to_pcm_frame(&p->vocalDecoder, 0) != MA_SUCCESS) {
        fprintf(stderr, "[miniaudio_bridge] vocal stop seek to 0 failed\n");
        fflush(stderr);
    }
    vocal_start_producer(p);
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_vocal_seek(void* pBridge, uint64_t frameIndex)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->vocalLoaded || !p->vocalDecoderValid) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }
    if (p->vocalDecoderTotalFrames > 0 && frameIndex > p->vocalDecoderTotalFrames) {
        frameIndex = p->vocalDecoderTotalFrames;
    }

    int wasPlaying = p->vocalPlaying;
    vocal_stop_producer(p);
    p->vocalPlaying = 0;

    ma_result mr = ma_decoder_seek_to_pcm_frame(&p->vocalDecoder, frameIndex);
    if (mr != MA_SUCCESS) {
        fprintf(stderr, "[miniaudio_bridge] vocal seek failed: %d (frame=%llu)\n",
                (int)mr, (unsigned long long)frameIndex);
        fflush(stderr);
        p->vocalPlaying = wasPlaying;
        vocal_start_producer(p);
        return MA_BRIDGE_ERR_DEVICE;
    }

    ma_spinlock_lock(&p->vocalLock);
    p->vocalReadIndex = 0;
    p->vocalWriteIndex = 0;
    p->vocalConsumedFrames = frameIndex;
    p->vocalSkipFrames = 0;
    p->vocalEndReached = 0;
    p->vocalDecoderEof = 0;
    ma_spinlock_unlock(&p->vocalLock);

    p->vocalPlaying = wasPlaying;
    vocal_start_producer(p);
    return MA_BRIDGE_OK;
}

ma_bridge_result ma_bridge_vocal_set_volume(void* pBridge, float volume)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->vocalLoaded) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 4.0f) volume = 4.0f;
    p->vocalVolume = volume;
    return MA_BRIDGE_OK;
}

double ma_bridge_vocal_get_position_ms(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->vocalLoaded || p->vocalSampleRate == 0) {
        return 0.0;
    }
    return (double)p->vocalConsumedFrames * 1000.0 / (double)p->vocalSampleRate;
}

int64_t ma_bridge_vocal_get_length_ms(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->vocalLoaded || p->vocalDecoderTotalFrames == 0 ||
        p->vocalSampleRate == 0) {
        return -1;
    }
    return (int64_t)(p->vocalDecoderTotalFrames * 1000 / p->vocalSampleRate);
}

int ma_bridge_vocal_is_playing(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->vocalLoaded) {
        return 0;
    }
    return (p->vocalPlaying && !p->vocalEndReached) ? 1 : 0;
}

int ma_bridge_vocal_is_finished(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->vocalLoaded) {
        return 0;
    }
    return p->vocalEndReached ? 1 : 0;
}

uint32_t ma_bridge_vocal_get_underrun_count(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->vocalLoaded) {
        return 0;
    }
    return p->vocalUnderrunCount;
}

ma_bridge_result ma_bridge_vocal_skip_frames(void* pBridge, uint32_t frames)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return MA_BRIDGE_ERR_NOT_INITIALIZED;
    }
    if (!p->vocalLoaded) {
        return MA_BRIDGE_ERR_UNSUPPORTED;
    }
    p->vocalSkipFrames += frames;
    return MA_BRIDGE_OK;
}

// ---------------------------------------------------------------------------
// 销毁
// ---------------------------------------------------------------------------
void ma_bridge_uninit(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL) {
        return;
    }
    if (p->initialized) {
        if (p->started) {
            ma_device_stop(&p->device);
            p->started = 0;
        }
        ma_bridge_vocal_unload(p);
        ma_device_uninit(&p->device);
        if (p->config.backend != MA_BRIDGE_BACKEND_DEFAULT) {
            ma_context_uninit(&p->context);
        }
        p->initialized = 0;
    }
    free(p);
}

// ---------------------------------------------------------------------------
// 版本
// ---------------------------------------------------------------------------
const char* ma_bridge_get_version(void)
{
    return MA_VERSION_STRING;
}

// ---------------------------------------------------------------------------
// 设备枚举与选择
// ---------------------------------------------------------------------------

void ma_bridge_set_device_name(const char* pName)
{
    if (pName == NULL || pName[0] == '\0') {
        g_deviceName[0] = '\0';
        return;
    }
    strncpy(g_deviceName, pName, sizeof(g_deviceName) - 1);
    g_deviceName[sizeof(g_deviceName) - 1] = '\0';
}

int ma_bridge_enumerate_devices(void* pBridge,
                                 ma_bridge_device_enum_proc callback,
                                 void* pUserData)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized || callback == NULL) {
        return -1;
    }

    ma_context* pCtx = p->device.pContext;
    if (pCtx == NULL) {
        return -1;
    }

    EnumDevicesContext ctx;
    ctx.userCallback = callback;
    ctx.pUserData    = pUserData;
    ctx.count        = 0;

    ma_result mr = ma_context_enumerate_devices(pCtx, enum_devices_callback, &ctx);
    if (mr != MA_SUCCESS) {
        return -1;
    }
    return ctx.count;
}

// ---------------------------------------------------------------------------
// 诊断: 获取设备运行时状态 (用于排查独占模式无声音问题)
// 返回值:
//   -1 = bridge 未初始化
//   ma_device_state 枚举值: 0=uninitialized, 1=stopped, 2=starting, 3=started, 4=stopping
// ---------------------------------------------------------------------------
int ma_bridge_get_device_state(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return -1;
    }
    return (int)ma_device_get_state(&p->device);
}

// 诊断: 获取 shareMode (0=shared, 1=exclusive)
int ma_bridge_get_share_mode(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return -1;
    }
    return (int)p->device.playback.shareMode;
}

// 诊断: 获取是否指定了 pDeviceID (1=指定了具体设备, 0=用默认设备)
int ma_bridge_has_device_id(void* pBridge)
{
    ma_bridge* p = (ma_bridge*)pBridge;
    if (p == NULL || !p->initialized) {
        return -1;
    }
    return p->hasDeviceId;
}
