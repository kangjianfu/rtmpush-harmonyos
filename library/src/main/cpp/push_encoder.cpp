/*
 * Copyright 2026 Shichuangyun (Beijing) Technology Co., Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// push_encoder.cpp — 原生 H.264/H.265 编码器，NAPI 桥接到 ArkTS
// buffer 模式：ArkTS ImageReceiver 拿 NV21 帧 → pushFrame 入队 → onNeedInputData 消费
// surface 模式（零拷贝）：相机画面直通编码器 surface，无内存拷贝；CreateEncoderSurface 返回 surfaceId
// 输出统一：onNeedOutputData 拿到 H.264/H.265 → tsfn 回调 ArkTS onFrame(bytes, flags, pts)
#include <napi/native_api.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_audioencoder.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avmemory.h>
#include <multimedia/player_framework/avcodec_audio_channel_layout.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <cstring>
#include <mutex>
#include <queue>
#include <string>
#include <vector>

#define LOG_TAG "PushEncoder"
#define LOGI(...) OH_LOG_INFO(LOG_APP, LOG_TAG ": " __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, LOG_TAG ": " __VA_ARGS__)

namespace {

struct RawFrame {
    std::vector<uint8_t> data;
    int64_t pts; // 采集 pts（微秒），透传给编码器，保证输出 pts 同源
};

struct EncoderCtx {
    OH_AVCodec *codec = nullptr;
    napi_threadsafe_function tsfn = nullptr;
    std::queue<RawFrame> pending;               // 待编码 NV21 帧（buffer 模式）
    std::mutex mtx;
    bool running = false;
    bool surfaceMode = false;                   // surface 零拷贝模式（相机直通）
    OHNativeWindow *window = nullptr;
    size_t queuedBytes = 0;                     // 队列总字节数（4K 一帧 12MB，按字节限长）
};

constexpr size_t MAX_QUEUED_BYTES = 64 * 1024 * 1024; // 帧队列上限 64MB

EncoderCtx g_ctx;

struct FrameEvent {
    std::vector<uint8_t> data;
    int64_t pts;
    int32_t flags;
};

// ---- 编码器回调 ----

void OnError(OH_AVCodec *codec, int32_t err, void *userData) {
    LOGE("encoder error %{public}d", err);
}

void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
    LOGI("stream changed");
}

void OnNeedInputData(OH_AVCodec *codec, uint32_t index, OH_AVMemory *data, void *userData) {
    std::lock_guard<std::mutex> lock(g_ctx.mtx);
    if (!g_ctx.running || g_ctx.pending.empty() || !data) {
        return; // 没帧就跳过这轮（buffer 自动回收）
    }
    RawFrame frame = std::move(g_ctx.pending.front());
    g_ctx.pending.pop();
    g_ctx.queuedBytes -= frame.data.size();
    uint8_t *addr = OH_AVMemory_GetAddr(data);
    int32_t cap = OH_AVMemory_GetSize(data);
    int32_t len = std::min(static_cast<int32_t>(frame.data.size()), cap);
    std::memcpy(addr, frame.data.data(), len);
    OH_AVCodecBufferAttr attr;
    attr.pts = frame.pts; // 采集 pts 透传，输出帧 pts 与音频同源可对齐
    attr.size = len;
    attr.offset = 0;
    attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
    OH_VideoEncoder_PushInputData(codec, index, attr);
}

void OnNeedOutputData(OH_AVCodec *codec, uint32_t index, OH_AVMemory *data, OH_AVCodecBufferAttr *attr, void *userData) {
    napi_threadsafe_function tsfn;
    {
        std::lock_guard<std::mutex> lock(g_ctx.mtx);
        tsfn = g_ctx.tsfn; // SetFrameCallback 可能并发释放，持锁读取
    }
    if (!attr || !data || !tsfn) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index); // 不消费也必须还 buffer，否则编码器停摆
        return;
    }
    uint8_t *addr = OH_AVMemory_GetAddr(data);
    FrameEvent *ev = new FrameEvent();
    ev->pts = attr->pts;
    ev->flags = attr->flags;
    ev->data.assign(addr + attr->offset, addr + attr->offset + attr->size);
    if (napi_call_threadsafe_function(tsfn, ev, napi_tsfn_nonblocking) != napi_ok) {
        delete ev; // 队列满：丢帧防内存膨胀
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

// 按 mime 建编码器（video/avc 或 video/hevc），失败则枚举能力里的具体 codec 名逐个尝试
OH_AVCodec *CreateVideoEncoderByMime(const char *mime) {
    OH_AVCodec *codec = OH_VideoEncoder_CreateByMime(mime);
    if (codec) {
        return codec;
    }
    LOGE("CreateByMime(%{public}s) failed, probing capabilities", mime);
    const OH_AVCodecCategory cats[2] = { HARDWARE, SOFTWARE };
    for (int c = 0; c < 2 && !codec; c++) {
        OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory(mime, true, cats[c]);
        if (!cap) {
            continue;
        }
        const char *name = OH_AVCapability_GetName(cap);
        LOGE("cap cat=%{public}d name=%{public}s", c, name ? name : "(null)");
        if (name) {
            codec = OH_VideoEncoder_CreateByName(name);
            if (codec) {
                LOGI("created encoder by name %{public}s", name);
            }
        }
    }
    return codec;
}

// 停掉并销毁视频编码器（Stop/Destroy 可能等回调线程，不能持 g_ctx.mtx 调用，否则与回调死锁）
void StopVideoInternal() {
    OH_AVCodec *codec = nullptr;
    OHNativeWindow *window = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_ctx.mtx);
        g_ctx.running = false;
        codec = g_ctx.codec;
        g_ctx.codec = nullptr;
        window = g_ctx.window;
        g_ctx.window = nullptr;
        g_ctx.surfaceMode = false;
        g_ctx.pending = std::queue<RawFrame>();
        g_ctx.queuedBytes = 0;
    }
    if (codec) {
        OH_VideoEncoder_Stop(codec);
        OH_VideoEncoder_Destroy(codec);
    }
    if (window) {
        OH_NativeWindow_DestroyNativeWindow(window);
    }
}

// ---- NAPI 接口 ----

napi_value CreateEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width, height, fps, bitrate, iInterval;
    napi_get_value_int32(env, args[0], &width);
    napi_get_value_int32(env, args[1], &height);
    napi_get_value_int32(env, args[2], &fps);
    napi_get_value_int32(env, args[3], &bitrate);
    napi_get_value_int32(env, args[4], &iInterval);
    // 第 6 参：编码格式 mime（缺省 video/avc）
    char mime[32] = "video/avc";
    if (argc >= 6) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[5], mime, sizeof(mime), &len);
    }

    std::lock_guard<std::mutex> lock(g_ctx.mtx);
    g_ctx.pending = std::queue<RawFrame>();
    g_ctx.queuedBytes = 0;

    if (g_ctx.codec) {
        LOGE("createEncoder called while running, stop the old one first");
        napi_throw_error(env, nullptr, "编码器已在运行，请先 stopEncoder");
        return nullptr;
    }

    OH_AVCodec *codec = CreateVideoEncoderByMime(mime);
    if (!codec) {
        LOGE("no %{public}s encoder available on this device", mime);
        napi_throw_error(env, nullptr, "本设备不支持所选编码格式（模拟器常见）");
        return nullptr;
    }
    OH_AVFormat *format = OH_AVFormat_CreateVideoFormat(mime, width, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, bitrate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, fps);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, iInterval);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, 3); // NV21
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_VBR); // 同码率画质更好

    OH_AVCodecAsyncCallback cb = { OnError, OnStreamChanged, OnNeedInputData, OnNeedOutputData };
    OH_VideoEncoder_SetCallback(codec, cb, nullptr);
    OH_AVErrCode ret = OH_VideoEncoder_Configure(codec, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        LOGE("configure failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "configure failed");
        return nullptr;
    }
    ret = OH_VideoEncoder_Prepare(codec);
    if (ret != AV_ERR_OK) {
        LOGE("prepare failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "prepare failed");
        return nullptr;
    }
    ret = OH_VideoEncoder_Start(codec);
    if (ret != AV_ERR_OK) {
        LOGE("start failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "start failed");
        return nullptr;
    }
    g_ctx.codec = codec;
    g_ctx.running = true;
    LOGI("encoder started %{public}dx%{public}d fps=%{public}d", width, height, fps);

    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

// surface 零拷贝模式：相机直通编码器，返回编码器输入 surface 的 id（供相机 PreviewOutput 用）
// 顺序：Create → SetCallback → Configure → GetSurface → Prepare → Start
napi_value CreateEncoderSurface(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width, height, fps, bitrate, iInterval;
    napi_get_value_int32(env, args[0], &width);
    napi_get_value_int32(env, args[1], &height);
    napi_get_value_int32(env, args[2], &fps);
    napi_get_value_int32(env, args[3], &bitrate);
    napi_get_value_int32(env, args[4], &iInterval);
    char mime[32] = "video/avc";
    if (argc >= 6) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[5], mime, sizeof(mime), &len);
    }

    std::lock_guard<std::mutex> lock(g_ctx.mtx);
    if (g_ctx.codec) {
        LOGE("createEncoderSurface called while running, stop the old one first");
        napi_throw_error(env, nullptr, "编码器已在运行，请先 stopEncoder");
        return nullptr;
    }
    OH_AVCodec *codec = CreateVideoEncoderByMime(mime);
    if (!codec) {
        napi_throw_error(env, nullptr, "本设备不支持所选编码格式");
        return nullptr;
    }
    OH_AVFormat *format = OH_AVFormat_CreateVideoFormat(mime, width, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, bitrate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, fps);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, iInterval);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_VBR);

    OH_AVCodecAsyncCallback cb = { OnError, OnStreamChanged, OnNeedInputData, OnNeedOutputData };
    OH_VideoEncoder_SetCallback(codec, cb, nullptr);
    OH_AVErrCode ret = OH_VideoEncoder_Configure(codec, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        LOGE("surface configure failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "configure failed");
        return nullptr;
    }
    OHNativeWindow *window = nullptr;
    ret = OH_VideoEncoder_GetSurface(codec, &window);
    if (ret != AV_ERR_OK || !window) {
        LOGE("get surface failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "get surface failed");
        return nullptr;
    }
    uint64_t surfaceId = 0;
    OH_NativeWindow_GetSurfaceId(window, &surfaceId);
    ret = OH_VideoEncoder_Prepare(codec);
    if (ret != AV_ERR_OK) {
        LOGE("surface prepare failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "prepare failed");
        return nullptr;
    }
    ret = OH_VideoEncoder_Start(codec);
    if (ret != AV_ERR_OK) {
        LOGE("surface start failed %{public}d", ret);
        OH_VideoEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "start failed");
        return nullptr;
    }
    g_ctx.codec = codec;
    g_ctx.window = window;
    g_ctx.surfaceMode = true;
    g_ctx.running = true;
    LOGI("surface encoder started %{public}dx%{public}d fps=%{public}d sid=%{public}llu",
         width, height, fps, (unsigned long long)surfaceId);

    napi_value out;
    napi_create_string_utf8(env, std::to_string(surfaceId).c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

// 喂一帧 NV21（ArkTS → 队列，pts 微秒随帧透传给编码器）
napi_value PushFrame(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void *data = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, args[0], &data, &len);
    int64_t pts;
    napi_get_value_int64(env, args[1], &pts);

    napi_value out;
    std::lock_guard<std::mutex> lock(g_ctx.mtx);
    if (!g_ctx.running || !g_ctx.codec) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    // 队列按字节限长 64MB（4K 一帧约 12MB），满了丢最旧
    while (!g_ctx.pending.empty() && g_ctx.queuedBytes + len > MAX_QUEUED_BYTES) {
        g_ctx.queuedBytes -= g_ctx.pending.front().data.size();
        g_ctx.pending.pop();
    }
    RawFrame frame;
    frame.data.resize(len);
    std::memcpy(frame.data.data(), data, len);
    frame.pts = pts;
    g_ctx.pending.push(std::move(frame));
    g_ctx.queuedBytes += len;
    napi_get_boolean(env, true, &out);
    return out;
}

// 输出帧回调桥：tsfn → ArkTS
void CallArkTsFrame(napi_env env, napi_value jsCb, void *context, void *data) {
    FrameEvent *ev = static_cast<FrameEvent *>(data);
    if (!ev) {
        return;
    }
    napi_value buffer;
    void *bufData = nullptr;
    napi_create_arraybuffer(env, ev->data.size(), &bufData, &buffer);
    std::memcpy(bufData, ev->data.data(), ev->data.size());
    napi_value pts, flags;
    napi_create_int64(env, ev->pts, &pts);
    napi_create_int32(env, ev->flags, &flags);
    napi_value argv[3] = { buffer, pts, flags };
    napi_call_function(env, nullptr, jsCb, 3, argv, nullptr);
    delete ev;
}

napi_value SetFrameCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_ctx.tsfn) {
        napi_release_threadsafe_function(g_ctx.tsfn, napi_tsfn_release);
        g_ctx.tsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "push_encoder_frame", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name, 90, 1, nullptr, nullptr, nullptr, CallArkTsFrame, &g_ctx.tsfn);
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

napi_value StopEncoder(napi_env env, napi_callback_info info) {
    StopVideoInternal();
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

// 立即请求一个关键帧（新观众起播/降码率后画质快速恢复）
napi_value RequestKeyFrame(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_ctx.mtx);
    napi_value out;
    if (!g_ctx.running || !g_ctx.codec) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_REQUEST_I_FRAME, 1);
    OH_AVErrCode ret = OH_VideoEncoder_SetParameter(g_ctx.codec, format);
    OH_AVFormat_Destroy(format);
    napi_get_boolean(env, ret == AV_ERR_OK, &out);
    return out;
}

// 运行中动态改码率（自适应码流用），kbps
napi_value SetVideoBitrate(napi_env env, napi_callback_info info) {    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t kbps;
    napi_get_value_int32(env, args[0], &kbps);
    std::lock_guard<std::mutex> lock(g_ctx.mtx);
    napi_value out;
    if (!g_ctx.running || !g_ctx.codec) {
        napi_get_boolean(env, false, &out);
        return out;
    }
    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, kbps * 1000);
    OH_AVErrCode ret = OH_VideoEncoder_SetParameter(g_ctx.codec, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        LOGE("set bitrate failed %{public}d", ret);
        napi_get_boolean(env, false, &out);
        return out;
    }
    LOGI("bitrate -> %{public}dkbps", kbps);
    napi_get_boolean(env, true, &out);
    return out;
}

napi_value IsRunning(napi_env env, napi_callback_info info) {
    napi_value out;
    napi_get_boolean(env, g_ctx.running, &out);
    return out;
}

// ==================== 音频编码器（AAC） ====================

struct AudioEncoderCtx {
    OH_AVCodec *codec = nullptr;
    napi_threadsafe_function tsfn = nullptr;
    std::queue<std::vector<uint8_t>> pending; // 待编码 PCM（S16LE）
    std::mutex mtx;
    bool running = false;
    int64_t ptsUs = 0;
    int32_t sampleRate = 44100;
    int32_t channels = 1;
};

AudioEncoderCtx g_audio;

void OnAudioError(OH_AVCodec *codec, int32_t err, void *userData) {
    LOGE("audio encoder error %{public}d", err);
}

void OnAudioStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
    LOGI("audio stream changed");
}

void OnAudioNeedInputData(OH_AVCodec *codec, uint32_t index, OH_AVMemory *data, void *userData) {
    std::lock_guard<std::mutex> lock(g_audio.mtx);
    if (!g_audio.running || g_audio.pending.empty() || !data) {
        return;
    }
    std::vector<uint8_t> pcm = std::move(g_audio.pending.front());
    g_audio.pending.pop();
    uint8_t *addr = OH_AVMemory_GetAddr(data);
    int32_t cap = OH_AVMemory_GetSize(data);
    int32_t len = std::min(static_cast<int32_t>(pcm.size()), cap);
    std::memcpy(addr, pcm.data(), len);
    OH_AVCodecBufferAttr attr;
    attr.pts = g_audio.ptsUs;
    attr.size = len;
    attr.offset = 0;
    attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
    int64_t samples = len / (2 * g_audio.channels);
    g_audio.ptsUs += samples * 1000000 / g_audio.sampleRate;
    OH_AudioEncoder_PushInputData(codec, index, attr);
}

void OnAudioNeedOutputData(OH_AVCodec *codec, uint32_t index, OH_AVMemory *data, OH_AVCodecBufferAttr *attr, void *userData) {
    napi_threadsafe_function tsfn;
    {
        std::lock_guard<std::mutex> lock(g_audio.mtx);
        tsfn = g_audio.tsfn;
    }
    if (!attr || !data || !tsfn) {
        OH_AudioCodec_FreeOutputBuffer(codec, index);
        return;
    }
    uint8_t *addr = OH_AVMemory_GetAddr(data);
    FrameEvent *ev = new FrameEvent();
    ev->pts = attr->pts;
    ev->flags = attr->flags;
    ev->data.assign(addr + attr->offset, addr + attr->offset + attr->size);
    if (napi_call_threadsafe_function(tsfn, ev, napi_tsfn_nonblocking) != napi_ok) {
        delete ev; // 队列满：丢帧防内存膨胀
    }
    OH_AudioCodec_FreeOutputBuffer(codec, index);
}

napi_value CreateAudioEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sampleRate, channels, bitrate;
    napi_get_value_int32(env, args[0], &sampleRate);
    napi_get_value_int32(env, args[1], &channels);
    napi_get_value_int32(env, args[2], &bitrate);

    std::lock_guard<std::mutex> lock(g_audio.mtx);
    if (g_audio.codec) {
        napi_throw_error(env, nullptr, "音频编码器已在运行，请先 stopAudioEncoder");
        return nullptr;
    }
    g_audio.pending = std::queue<std::vector<uint8_t>>();
    g_audio.ptsUs = 0;
    g_audio.sampleRate = sampleRate;
    g_audio.channels = channels;

    OH_AVCodec *codec = OH_AudioEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_AAC);
    if (!codec) {
        LOGE("create audio encoder failed");
        napi_throw_error(env, nullptr, "本设备不支持 AAC 编码");
        return nullptr;
    }
    OH_AVFormat *format = OH_AVFormat_CreateAudioFormat(OH_AVCODEC_MIMETYPE_AUDIO_AAC, sampleRate, channels);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, bitrate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_CHANNEL_LAYOUT,
                             static_cast<int64_t>(channels == 1 ? MONO : STEREO));

    OH_AVCodecAsyncCallback cb = { OnAudioError, OnAudioStreamChanged, OnAudioNeedInputData, OnAudioNeedOutputData };
    OH_AudioEncoder_SetCallback(codec, cb, nullptr);
    OH_AVErrCode ret = OH_AudioEncoder_Configure(codec, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        LOGE("audio configure failed %{public}d", ret);
        OH_AudioEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "AAC 编码器配置失败");
        return nullptr;
    }
    ret = OH_AudioEncoder_Prepare(codec);
    if (ret != AV_ERR_OK) {
        LOGE("audio prepare failed %{public}d", ret);
        OH_AudioEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "AAC 编码器准备失败");
        return nullptr;
    }
    ret = OH_AudioEncoder_Start(codec);
    if (ret != AV_ERR_OK) {
        LOGE("audio start failed %{public}d", ret);
        OH_AudioEncoder_Destroy(codec);
        napi_throw_error(env, nullptr, "AAC 编码器启动失败");
        return nullptr;
    }
    g_audio.codec = codec;
    g_audio.running = true;
    LOGI("audio encoder started rate=%{public}d ch=%{public}d bitrate=%{public}d", sampleRate, channels, bitrate);

    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

napi_value PushPcm(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void *data = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, args[0], &data, &len);

    std::lock_guard<std::mutex> lock(g_audio.mtx);
    if (!g_audio.running || !g_audio.codec) {
        napi_value out;
        napi_get_boolean(env, false, &out);
        return out;
    }
    // PCM 队列限长（readData 每块约几毫秒，限 100 块防堆积导致音画漂移）
    if (g_audio.pending.size() >= 100) {
        g_audio.pending.pop();
    }
    std::vector<uint8_t> pcm(len);
    std::memcpy(pcm.data(), data, len);
    g_audio.pending.push(std::move(pcm));
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

napi_value SetAudioFrameCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_audio.tsfn) {
        napi_release_threadsafe_function(g_audio.tsfn, napi_tsfn_release);
        g_audio.tsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "push_encoder_audio_frame", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name, 300, 1, nullptr, nullptr, nullptr, CallArkTsFrame, &g_audio.tsfn);
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

napi_value StopAudioEncoder(napi_env env, napi_callback_info info) {
    OH_AVCodec *codec = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_audio.mtx);
        g_audio.running = false;
        codec = g_audio.codec;
        g_audio.codec = nullptr;
        g_audio.pending = std::queue<std::vector<uint8_t>>();
    }
    // Stop/Destroy 在锁外执行，避免与编码器回调线程死锁
    if (codec) {
        OH_AudioEncoder_Stop(codec);
        OH_AudioEncoder_Destroy(codec);
    }
    napi_value out;
    napi_get_boolean(env, true, &out);
    return out;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "createEncoder", nullptr, CreateEncoder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createEncoderSurface", nullptr, CreateEncoderSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pushFrame", nullptr, PushFrame, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setFrameCallback", nullptr, SetFrameCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopEncoder", nullptr, StopEncoder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVideoBitrate", nullptr, SetVideoBitrate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "requestKeyFrame", nullptr, RequestKeyFrame, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "createAudioEncoder", nullptr, CreateAudioEncoder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pushPcm", nullptr, PushPcm, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setAudioFrameCallback", nullptr, SetAudioFrameCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopAudioEncoder", nullptr, StopAudioEncoder, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

extern "C" __attribute__((constructor)) void RegisterPushEncoderModule() {
    static napi_module pushEncoderModule = {
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = nullptr,
        .nm_register_func = Init,
        .nm_modname = "push_encoder",
        .nm_priv = nullptr,
        .reserved = { 0 },
    };
    napi_module_register(&pushEncoderModule);
}
