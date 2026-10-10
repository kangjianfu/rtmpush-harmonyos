# rtmpush — 鸿蒙原生 RTMP 推流库

纯 HarmonyOS 实现的 RTMP 推流 SDK，**无任何第三方依赖**。阿里云 / 腾讯云 / 即构的推流 SDK 均无鸿蒙版本，本库填补这一空白。

## 组成

| 模块 | 说明 |
|------|------|
| `RtmpClient` | 纯 ArkTS RTMP 客户端：simple/digest(FP9) 握手、AMF0、Chunk 协议、connect/createStream/publish、FLV tag 打包、@setDataFrame 元数据、实测吞吐统计（自适应码流用） |
| `PushEncoder` | native 硬编码器封装（NDK）：NV21 → H.264/H.265，PCM S16LE → AAC，运行中动态改码率（`OH_VideoEncoder_SetParameter`） |

## 特性

- H.264（老 FLV tag）+ **H.265（Enhanced RTMP v2，hvc1）**，hvcC 序列头手工构建
- AAC-LC 音频，自动发 AudioSpecificConfig 序列头
-  digest 握手（阿里云等需要 FP9 鉴权的服务器可用）
- 编码帧回调队列有上限，ArkTS 卡顿时丢帧防 OOM

## 快速开始

```ts
import { RtmpClient, PushEncoder, CODEC_FLAG_CONFIG, CODEC_FLAG_SYNC } from 'rtmpush';

const encoder = new PushEncoder();
const rtmp = new RtmpClient();

// 1. 编码回调：config 帧抽 SPS/PPS 发序列头，其余发数据帧
let configSent = false;
encoder.onVideoFrame((f) => {
  const bytes = new Uint8Array(f.data);
  if ((f.flags & CODEC_FLAG_CONFIG) !== 0 && !configSent) {
    // 从 annex-b config 帧里抽 SPS(7)/PPS(8)，调 rtmp.sendVideoConfig(...)
    configSent = true;
    return;
  }
  rtmp.sendVideoFrame(bytes, (f.flags & CODEC_FLAG_SYNC) !== 0, f.ptsUs / 1000);
});

// 2. 启动编码器（H.265 传 'video/hevc'）
encoder.createVideo(1280, 720, 15, 1500, 2000, 'video/avc');
encoder.createAudio(44100, 1, 64000);

// 3. 连接并推流
rtmp.setAudioInfo(44100, 1);
rtmp.onReady = () => { /* publish 成功，开始喂帧 */ };
await rtmp.connect('rtmp://your-server/app/streamKey');

// 相机帧（ImageReceiver NV21）→ encoder.pushVideoFrame(...)
// 麦克风 PCM（AudioCapturer readData）→ encoder.pushAudioFrame(...)
```

H.265 推流：`createVideo(..., 'video/hevc')`，config 帧里抽 VPS(32)/SPS(33)/PPS(34) 调 `rtmp.sendHevcConfig(vps, sps, pps, w, h, fps)`，推流前 `rtmp.setHevc(true)`。播放端需支持 Enhanced RTMP hvc1。

自适应码流：用 `rtmp.getSendRateKbps()` 拿最近 3 秒实测上行速率，低于目标码流时调 `encoder.setVideoBitrate(kbps)` 动态降码率（参考实现见体云赛事 App 的 LivePush 页）。

## 权限

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" },
  { "name": "ohos.permission.CAMERA" },
  { "name": "ohos.permission.MICROPHONE" }
]
```

## 已知限制

- 采集层（相机/麦克风）不在库内，需自行用 CameraKit/AudioKit 接入（保持库零业务耦合）
- 模拟器无 H.264 编码器，需真机调试
- H.265 播放兼容性取决于拉流端（可用阿里云直播云端转码转 H.264 兜底）

## License

Apache-2.0
