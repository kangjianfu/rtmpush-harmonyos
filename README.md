# rtmpush — 鸿蒙原生 RTMP 推流库

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE) [![Platform](https://img.shields.io/badge/platform-HarmonyOS%20NEXT-blueviolet)](https://developer.huawei.com/consumer/cn/harmonyos) [![Deps](https://img.shields.io/badge/dependencies-0-brightgreen)](oh-package.json5)

纯 HarmonyOS 实现的 RTMP 推流 SDK，**无任何第三方依赖**。阿里云 / 腾讯云 / 即构的推流 SDK 均无鸿蒙版本，本库填补这一空白。

## 集成方式

**方式一：ohpm 本地引用**（本仓库 clone 到项目旁）

```json5
// 你模块的 oh-package.json5
"dependencies": { "rtmpush": "file:../rtmpush/library" }
```

**方式二：git submodule**（推荐，版本可锁定）

```bash
git submodule add https://github.com/kangjianfu/rtmpush-harmonyos.git deps/rtmpush-harmonyos
# oh-package.json5 里："rtmpush": "file:../deps/rtmpush-harmonyos/library"
```

## 独立构建

```bash
# DevEco Studio 直接打开本仓库；或命令行：
hvigorw assembleHar --mode module -p module=library@default -p product=default --no-daemon
# 产物：library/build/default/outputs/default/library.har
```

## Demo App（可独立安装验证）

`demo/` 是一个完整的演示 App：输入 RTMP 推流地址 → 相机+麦克风采集 → 推流，覆盖库的全部功能（零拷贝/H.265/AAC）。可直接 `hvigorw assembleHap` 出包安装到真机验证，不依赖任何业务后端。

```bash
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
hdc install demo/build/default/outputs/default/demo-default-unsigned.hap
```

## 组成

| 模块 | 说明 |
|------|------|
| `RtmpClient` | 纯 ArkTS RTMP 客户端：simple/digest(FP9) 握手、AMF0、Chunk 协议、connect/createStream/publish、FLV tag 打包、@setDataFrame 元数据、实测吞吐统计（自适应码流用） |
| `PushEncoder` | native 硬编码器封装（NDK）：NV21 → H.264/H.265，PCM S16LE → AAC，运行中动态改码率（`OH_VideoEncoder_SetParameter`） |

## 特性

- H.264（老 FLV tag）+ **H.265（Enhanced RTMP，hvc1）**，hvcC 序列头手工构建
- AAC-LC 音频，自动发 AudioSpecificConfig 序列头
- digest 握手（FP9，与 librtmp 算法一致，阿里云等需要鉴权握手的服务器可用）
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

自适应码流：每 1~2 秒调用 `rtmp.getSendRateKbps()` 获取最近 3 秒实测上行速率（`-1` 表示样本不足，此时不要调整码率）。连续低于当前视频码率时，调用 `encoder.setVideoBitrate(kbps)` 逐级降码率；网络恢复后再逐级回升，并设置最短调整间隔，避免码率频繁抖动。

断线重连：挂 `rtmp.onClosed` 回调，断开后用同一实例重新 `connect()` 即可（相机/编码器不用停），重连成功后记得重发视频/音频序列头并 `encoder.requestKeyFrame()`（新通道没有对端状态）。建议指数退避（1s 起、30s 封顶）。

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

## 路线图

- ~~v0.2 Surface 零拷贝编码~~ 已完成：`createVideoSurface()` 返回编码器 surfaceId 交给相机，画面直通编码器零拷贝；失败自动回退 buffer 模式
- 弱网增强：RTT 探测、丢帧统计上报

## License

Apache-2.0（见 [LICENSE](LICENSE)、[NOTICE](NOTICE)）

---

由 [视创新云（北京）科技有限公司](https://www.widk.cn) 开源
