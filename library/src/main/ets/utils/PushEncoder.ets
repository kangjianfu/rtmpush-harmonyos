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

// PushEncoder.ets — native 编码器的 ArkTS 封装（libpush_encoder.so）
// 视频：NV21 帧 → H.264/H.265 硬编；音频：PCM S16LE → AAC 硬编。均为 buffer 模式异步回调。
import pushEncoder from 'libpush_encoder.so';

export interface EncodedFrame {
  data: ArrayBuffer;
  ptsUs: number;
  flags: number;
}

/** 编码输出 flags（与 native AVCODEC_BUFFER_FLAGS 对应） */
export const CODEC_FLAG_SYNC: number = 2;   // 关键帧
export const CODEC_FLAG_CONFIG: number = 8; // 配置帧（SPS/PPS 或 VPS/SPS/PPS）

export type VideoCodec = 'video/avc' | 'video/hevc';

interface NativeModule {
  createEncoder(width: number, height: number, fps: number, bitrate: number, iIntervalMs: number, mime?: string): boolean;
  createEncoderSurface(width: number, height: number, fps: number, bitrate: number, iIntervalMs: number, mime?: string): string;
  pushFrame(data: ArrayBufferLike, ptsUs: number): boolean;
  setFrameCallback(cb: (data: ArrayBuffer, ptsUs: number, flags: number) => void): boolean;
  stopEncoder(): boolean;
  setVideoBitrate(kbps: number): boolean;
  requestKeyFrame(): boolean;
  isRunning(): boolean;
  createAudioEncoder(sampleRate: number, channels: number, bitrate: number): boolean;
  pushPcm(data: ArrayBufferLike): boolean;
  setAudioFrameCallback(cb: (data: ArrayBuffer, ptsUs: number, flags: number) => void): boolean;
  stopAudioEncoder(): boolean;
}

const native: NativeModule = pushEncoder as NativeModule;

export class PushEncoder {
  private videoCb: (f: EncodedFrame) => void = () => {};
  private audioCb: (f: EncodedFrame) => void = () => {};
  private videoCbSet = false;
  private audioCbSet = false;

  /** 视频编码输出回调（在 createVideo 前后设置均可） */
  onVideoFrame(cb: (f: EncodedFrame) => void): void {
    this.videoCb = cb;
    if (!this.videoCbSet) {
      this.videoCbSet = true;
      native.setFrameCallback((data: ArrayBuffer, ptsUs: number, flags: number) => {
        this.videoCb({ data: data, ptsUs: ptsUs, flags: flags });
      });
    }
  }

  /** 音频编码输出回调 */
  onAudioFrame(cb: (f: EncodedFrame) => void): void {
    this.audioCb = cb;
    if (!this.audioCbSet) {
      this.audioCbSet = true;
      native.setAudioFrameCallback((data: ArrayBuffer, ptsUs: number, flags: number) => {
        this.audioCb({ data: data, ptsUs: ptsUs, flags: flags });
      });
    }
  }

  /** 创建并启动视频编码器（buffer 模式，喂 NV21）。失败抛异常（设备不支持该格式、编码器已在运行等） */
  createVideo(width: number, height: number, fps: number, bitrateKbps: number,
    iFrameIntervalMs: number = 2000, codec: VideoCodec = 'video/avc'): void {
    native.createEncoder(width, height, fps, bitrateKbps * 1000, iFrameIntervalMs, codec);
  }

  /**
   * 创建并启动视频编码器（surface 零拷贝模式）。
   * 返回编码器输入 surfaceId，直接交给相机 PreviewOutput，画面直通编码器、无内存拷贝。
   * 失败抛异常（调用方应回退 buffer 模式）。
   */
  createVideoSurface(width: number, height: number, fps: number, bitrateKbps: number,
    iFrameIntervalMs: number = 2000, codec: VideoCodec = 'video/avc'): string {
    return native.createEncoderSurface(width, height, fps, bitrateKbps * 1000, iFrameIntervalMs, codec);
  }

  /** 喂一帧 NV21（Y 平面 + VU 交错平面拼接）。surface 模式下不应调用 */
  pushVideoFrame(nv21: ArrayBufferLike, ptsUs: number): boolean {
    return native.pushFrame(nv21, ptsUs);
  }

  /** 运行中动态改视频码率（自适应码流用），返回是否成功 */
  setVideoBitrate(kbps: number): boolean {
    return native.setVideoBitrate(kbps);
  }

  /** 立即请求一个关键帧（新观众起播、降码率后画质快速恢复） */
  requestKeyFrame(): boolean {
    return native.requestKeyFrame();
  }

  /** 创建并启动 AAC 音频编码器（输入 PCM S16LE） */
  createAudio(sampleRate: number = 44100, channels: number = 1, bitrateBps: number = 64000): void {
    native.createAudioEncoder(sampleRate, channels, bitrateBps);
  }

  /** 喂一段 PCM S16LE */
  pushAudioFrame(pcm: ArrayBufferLike): boolean {
    return native.pushPcm(pcm);
  }

  isRunning(): boolean {
    return native.isRunning();
  }

  /** 停止并销毁视频 + 音频编码器 */
  stop(): void {
    try {
      native.stopEncoder();
    } catch (e) { /* 忽略 */ }
    try {
      native.stopAudioEncoder();
    } catch (e) { /* 忽略 */ }
  }
}
