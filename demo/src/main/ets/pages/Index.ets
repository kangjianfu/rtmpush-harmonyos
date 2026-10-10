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

// demo/pages/Index.ets — rtmpush 演示：输入 RTMP 地址，相机+麦克风采集推流
// 覆盖 SDK 全功能：surface 零拷贝（失败回退 buffer）、H.264/H.265、AAC、动态码率
import { promptAction } from '@kit.ArkUI';
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { audio } from '@kit.AudioKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { RtmpClient, PushEncoder, VideoCodec, CODEC_FLAG_SYNC, CODEC_FLAG_CONFIG, splitAnnexB } from 'rtmpush';

const RESOLUTIONS: number[][] = [[960, 540], [1280, 720], [1920, 1080]];
const RES_LABELS: string[] = ['540p', '720p', '1080p'];
const CODEC_MIMES: VideoCodec[] = ['video/avc', 'video/hevc'];
const CODEC_LABELS: string[] = ['H.264', 'H.265'];
const FRAME_RATE = 15;
const BITRATE_KBPS = 2000;
const AUDIO_RATE = 44100;

@Entry
@Component
struct Index {
  @State pushUrl: string = '';
  @State pushing: boolean = false;
  @State statusText: string = '输入推流地址后开始';
  @State logs: string[] = [];
  @State fps: number = 0;
  @State resIndex: number = 1;
  @State codecIndex: number = 0;
  @State zeroCopy: boolean = true;

  private xController: XComponentController = new XComponentController();
  private xSurfaceId: string = '';
  private camInput: camera.CameraInput | null = null;
  private session: camera.VideoSession | null = null;
  private receiver: image.ImageReceiver | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private encoder: PushEncoder = new PushEncoder();
  private rtmp: RtmpClient = new RtmpClient();
  private usingSurface: boolean = false;
  private encoderSurfaceId: string = '';
  private configSent: boolean = false;
  private audioConfigSent: boolean = false;
  private frameCount: number = 0;
  private frameSkip: number = 0;
  private fpsTimer: number = -1;
  private starting: boolean = false;

  aboutToAppear(): void {
    this.rtmp.onLog = (msg: string) => {
      this.addLog(msg);
    };
    this.rtmp.onClosed = () => {
      this.addLog('连接断开，停止推流');
      this.stopAll();
    };
    this.rtmp.onError = (msg: string) => {
      this.addLog(msg);
      promptAction.showToast({ message: msg });
    };
    this.encoder.onVideoFrame((f) => {
      this.onEncodedVideo(f.data, f.flags, f.ptsUs);
    });
    this.encoder.onAudioFrame((f) => {
      this.onEncodedAudio(f.data, f.ptsUs);
    });
  }

  aboutToDisappear(): void {
    this.stopAll();
  }

  private addLog(msg: string): void {
    const line = `${new Date().toTimeString().slice(0, 8)} ${msg}`;
    this.logs = [line].concat(this.logs).slice(0, 40);
  }

  private videoW(): number {
    return RESOLUTIONS[this.resIndex][0];
  }

  private videoH(): number {
    return RESOLUTIONS[this.resIndex][1];
  }

  // ---------------- 编码帧 → RTMP ----------------

  private onEncodedVideo(data: ArrayBuffer, flags: number, ptsUs: number): void {
    if (!this.pushing) {
      return;
    }
    const bytes = new Uint8Array(data);
    if ((flags & CODEC_FLAG_CONFIG) !== 0) {
      if (!this.configSent) {
        if (this.codecIndex === 1) {
          const vps = this.extractNal(bytes, 32, true);
          const sps = this.extractNal(bytes, 33, true);
          const pps = this.extractNal(bytes, 34, true);
          if (vps.length > 0 && sps.length > 0 && pps.length > 0) {
            this.rtmp.sendHevcConfig(vps[0], sps[0], pps[0], this.videoW(), this.videoH(), FRAME_RATE);
            this.configSent = true;
          }
        } else {
          const sps = this.extractNal(bytes, 7, false);
          const pps = this.extractNal(bytes, 8, false);
          if (sps.length > 0 && pps.length > 0) {
            this.rtmp.sendVideoConfig(sps, pps, this.videoW(), this.videoH(), FRAME_RATE);
            this.configSent = true;
          }
        }
      }
      return;
    }
    this.rtmp.sendVideoFrame(bytes, (flags & CODEC_FLAG_SYNC) !== 0, ptsUs / 1000);
    this.frameCount += 1;
  }

  private onEncodedAudio(data: ArrayBuffer, ptsUs: number): void {
    if (!this.pushing) {
      return;
    }
    if (!this.audioConfigSent) {
      this.rtmp.sendAudioConfig();
      this.audioConfigSent = true;
    }
    this.rtmp.sendAudioFrame(new Uint8Array(data), ptsUs / 1000);
  }

  /** annex-b NAL 提取：AVC type=nal[0]&0x1f，HEVC type=(nal[0]>>1)&0x3f */
  private extractNal(annexb: Uint8Array, nalType: number, hevc: boolean): Uint8Array[] {
    const out: Uint8Array[] = [];
    for (const nal of splitAnnexB(annexb)) {
      if (nal.length === 0) {
        continue;
      }
      const t = hevc ? (nal[0] >> 1) & 0x3f : nal[0] & 0x1f;
      if (t === nalType) {
        out.push(nal);
      }
    }
    return out;
  }

  // ---------------- 主流程 ----------------

  private async startPush(): Promise<void> {
    if (this.starting || this.pushing) {
      return;
    }
    if (!this.pushUrl.startsWith('rtmp://')) {
      promptAction.showToast({ message: '请输入 rtmp:// 开头的推流地址' });
      return;
    }
    this.starting = true;
    try {
      this.statusText = '申请权限…';
      const atManager = abilityAccessCtrl.createAtManager();
      const ctx = getContext(this) as common.UIAbilityContext;
      const res = await atManager.requestPermissionsFromUser(ctx,
        ['ohos.permission.CAMERA', 'ohos.permission.MICROPHONE']);
      if (!res.authResults.every(v => v === 0)) {
        throw new Error('相机或麦克风权限被拒绝');
      }

      this.statusText = '启动编码器…';
      this.usingSurface = false;
      if (this.zeroCopy) {
        try {
          this.encoderSurfaceId = this.encoder.createVideoSurface(this.videoW(), this.videoH(),
            FRAME_RATE, BITRATE_KBPS, 2000, CODEC_MIMES[this.codecIndex]);
          this.usingSurface = true;
          this.addLog('编码器：零拷贝 surface 模式');
        } catch (e) {
          this.addLog('零拷贝不可用，回退 buffer 模式');
        }
      }
      if (!this.usingSurface) {
        this.encoder.createVideo(this.videoW(), this.videoH(), FRAME_RATE, BITRATE_KBPS, 2000,
          CODEC_MIMES[this.codecIndex]);
        this.addLog('编码器：buffer 模式');
      }
      this.encoder.createAudio(AUDIO_RATE, 1, 64000);
      this.addLog(`${CODEC_LABELS[this.codecIndex]} ${this.videoW()}x${this.videoH()}@${BITRATE_KBPS}k`);

      this.statusText = '启动相机…';
      await this.startCamera();
      await this.startAudio();

      this.statusText = '连接推流服务器…';
      this.rtmp.setAudioInfo(AUDIO_RATE, 1);
      this.rtmp.setHevc(this.codecIndex === 1);
      await this.rtmp.connect(this.pushUrl);

      this.pushing = true;
      this.statusText = '推流中';
      this.fpsTimer = setInterval(() => {
        this.fps = this.frameCount;
        this.frameCount = 0;
      }, 1000);
    } catch (e) {
      this.statusText = '启动失败';
      this.addLog(e instanceof Error ? e.message : String(e));
      promptAction.showToast({ message: e instanceof Error ? e.message : '启动失败' });
      this.stopAll();
    }
    this.starting = false;
  }

  /** 仅测试 RTMP 连接（不启编码器/相机，模拟器可用来验证握手与 publish） */
  private async testConnect(): Promise<void> {
    if (this.starting || this.pushing) {
      return;
    }
    if (!this.pushUrl.startsWith('rtmp://')) {
      promptAction.showToast({ message: '请输入 rtmp:// 开头的推流地址' });
      return;
    }
    this.starting = true;
    this.statusText = '测试连接…';
    const oldReady = this.rtmp.onReady;
    this.rtmp.onReady = () => {
      this.rtmp.onReady = oldReady; // 一次性包装，避免覆盖正常推流的回调
      this.addLog('publish 成功，协议链路完整');
      this.statusText = '连接测试通过';
    };
    try {
      await this.rtmp.connect(this.pushUrl);
      this.addLog('连接+握手完成，等待 publish 结果…');
      // 协议链路测完即断开
      setTimeout(() => {
        this.rtmp.close();
        if (this.statusText === '测试连接…') {
          this.statusText = '已连接（未收到 publish 确认）';
        }
      }, 3000);
    } catch (e) {
      this.statusText = '连接失败';
      this.addLog(e instanceof Error ? e.message : String(e));
      promptAction.showToast({ message: e instanceof Error ? e.message : '连接失败' });
    }
    this.starting = false;
  }

  private async startCamera(): Promise<void> {
    const ctx = getContext(this);
    const camManager = camera.getCameraManager(ctx);
    const devices = camManager.getSupportedCameras();
    if (devices.length === 0) {
      throw new Error('无可用摄像头（模拟器不支持）');
    }
    const device = devices.find(d => d.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK)
      ?? devices[0];
    const input = camManager.createCameraInput(device);
    this.camInput = input;
    await input.open();

    const mode = camera.SceneMode.NORMAL_VIDEO;
    const capability = camManager.getSupportedOutputCapability(device, mode);
    if (!capability.previewProfiles || capability.previewProfiles.length === 0) {
      throw new Error('相机不支持预览输出');
    }
    const profile = capability.previewProfiles.find(
      p => p.size.width === this.videoW() && p.size.height === this.videoH())
      ?? capability.previewProfiles[capability.previewProfiles.length - 1];

    let frameSurfaceId: string;
    if (this.usingSurface) {
      frameSurfaceId = this.encoderSurfaceId;
    } else {
      const receiver = image.createImageReceiver(this.videoW(), this.videoH(),
        image.ImageFormat.YCBCR_422_SP, 8); // ImageReceiver 仅支持 4:2:2 SP，喂帧前降采样成 NV21
      this.receiver = receiver;
      receiver.on('imageArrival', () => {
        this.onCameraFrame(receiver);
      });
      frameSurfaceId = await receiver.getReceivingSurfaceId();
    }

    const session: camera.VideoSession = camManager.createSession(camera.SceneMode.NORMAL_VIDEO);
    this.session = session;
    session.beginConfig();
    session.addInput(input);
    session.addOutput(camManager.createPreviewOutput(profile, this.xSurfaceId));
    session.addOutput(camManager.createPreviewOutput(profile, frameSurfaceId));
    await session.commitConfig();
    session.start();
    this.addLog('相机已启动');
  }

  private async onCameraFrame(receiver: image.ImageReceiver): Promise<void> {
    if (!this.pushing) {
      try {
        const img = await receiver.readNextImage();
        img.release();
      } catch (e) { /* 忽略 */ }
      return;
    }
    this.frameSkip += 1;
    if (this.frameSkip % 2 === 0) {
      try {
        const img = await receiver.readNextImage();
        img.release();
      } catch (e) { /* 忽略 */ }
      return;
    }
    try {
      const img = await receiver.readNextImage();
      const y = await img.getComponent(image.ComponentType.YUV_Y);
      const vu = await img.getComponent(image.ComponentType.YUV_V);
      const yBytes = new Uint8Array(y.byteBuffer);
      const vuBytes = new Uint8Array(vu.byteBuffer);
      // 4:2:2 SP（Y + 全高 VU）→ NV21（Y + 半高 VU）：VU 平面隔行取样
      const w = this.videoW();
      const h = this.videoH();
      const frame = new Uint8Array(w * h * 3 / 2);
      frame.set(yBytes.subarray(0, w * h));
      const vuOut = frame.subarray(w * h);
      for (let r = 0; r < h / 2; r++) {
        vuOut.set(vuBytes.subarray(r * 2 * w, r * 2 * w + w), r * w);
      }
      img.release();
      this.encoder.pushVideoFrame(frame.buffer, Date.now() * 1000);
    } catch (e) { /* 忽略 */ }
  }

  private async startAudio(): Promise<void> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const capturer = await audio.createAudioCapturer({ streamInfo: streamInfo, capturerInfo: capturerInfo });
    this.capturer = capturer;
    capturer.on('readData', (data: ArrayBuffer) => {
      this.encoder.pushAudioFrame(data);
    });
    await capturer.start();
    this.addLog('麦克风已启动');
  }

  /** 扫码输入（系统扫码界面，识别二维码里的 RTMP 地址） */
  private async scanUrl(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(ctx);
      const text = result.originalValue ?? '';
      if (text.startsWith('rtmp://')) {
        this.pushUrl = text;
        this.addLog('扫码成功');
      } else if (text.length > 0) {
        promptAction.showToast({ message: '二维码内容不是 RTMP 地址' });
      }
    } catch (e) {
      // 用户取消或设备不支持（模拟器无相机）
    }
  }

  /** 从剪贴板粘贴推流地址 */
  private pasteUrl(): void {
    try {
      const pb = pasteboard.getSystemPasteboard();
      if (pb.hasDataSync()) {
        const text = pb.getDataSync().getPrimaryText();
        if (text && text.startsWith('rtmp://')) {
          this.pushUrl = text;
          this.addLog('已粘贴推流地址');
          return;
        }
      }
      promptAction.showToast({ message: '剪贴板里没有 RTMP 地址' });
    } catch (e) { /* 忽略 */ }
  }

  private stopAll(): void {
    this.pushing = false;
    if (this.fpsTimer >= 0) {
      clearInterval(this.fpsTimer);
      this.fpsTimer = -1;
    }
    try {
      this.session?.stop();
      this.session?.release();
    } catch (e) { /* 忽略 */ }
    this.session = null;
    try {
      this.receiver?.release();
    } catch (e) { /* 忽略 */ }
    this.receiver = null;
    try {
      this.capturer?.stop();
      this.capturer?.release();
    } catch (e) { /* 忽略 */ }
    this.capturer = null;
    try {
      this.camInput?.close();
    } catch (e) { /* 忽略 */ }
    this.camInput = null;
    this.encoder.stop();
    try {
      this.rtmp.close();
    } catch (e) { /* 忽略 */ }
    this.statusText = '已停止';
    this.configSent = false;
    this.audioConfigSent = false;
  }

  build() {
    Column({ space: 10 }) {
      // 头部：品牌名 + 副标题
      Column({ space: 2 }) {
        Text('rtmpush')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
        Text('鸿蒙原生 RTMP 推流库 · 演示')
          .fontSize(12)
          .fontColor('#9ca3af')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 12, bottom: 2 })

      XComponent({ id: 'demo_preview', type: XComponentType.SURFACE, controller: this.xController })
        .width('100%')
        .aspectRatio(16 / 9)
        .borderRadius(16)
        .clip(true)
        .backgroundColor(Color.Black)
        .onLoad(() => {
          this.xSurfaceId = this.xController.getXComponentSurfaceId();
        })

      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        ForEach(RES_LABELS, (label: string, idx: number) => {
          Text(label)
            .fontSize(12)
            .fontColor(this.resIndex === idx ? Color.White : '#374151')
            .backgroundColor(this.resIndex === idx ? '#0a59f7' : '#e5e7eb')
            .borderRadius(999)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 6 })
            .onClick(() => {
              this.resIndex = idx;
            })
        }, (label: string) => label)
        ForEach(CODEC_LABELS, (label: string, idx: number) => {
          Text(label)
            .fontSize(12)
            .fontColor(this.codecIndex === idx ? Color.White : '#374151')
            .backgroundColor(this.codecIndex === idx ? '#0a59f7' : '#e5e7eb')
            .borderRadius(999)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 6 })
            .onClick(() => {
              this.codecIndex = idx;
            })
        }, (label: string) => label)
        Text(this.zeroCopy ? '零拷贝' : 'buffer')
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor(this.zeroCopy ? '#16a34a' : '#9ca3af')
          .borderRadius(999)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            this.zeroCopy = !this.zeroCopy;
          })
      }
      .width('100%')

      // 推流地址（多行大文本框，整行占满）
      TextArea({ placeholder: 'rtmp://服务器/app/流名?auth_key=...', text: this.pushUrl })
        .width('100%')
        .height(110)
        .fontSize(14)
        .backgroundColor(Color.White)
        .borderRadius(16)
        .enabled(!this.pushing)
        .onChange((v: string) => {
          this.pushUrl = v;
        })

      Row({ space: 8 }) {
        Button('扫码输入')
          .height(44)
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor('#16a34a')
          .borderRadius(12)
          .layoutWeight(1)
          .enabled(!this.pushing)
          .onClick(() => {
            this.scanUrl();
          })
        Button('粘贴地址')
          .height(44)
          .fontSize(14)
          .fontColor('#374151')
          .backgroundColor('#e5e7eb')
          .borderRadius(12)
          .layoutWeight(1)
          .enabled(!this.pushing)
          .onClick(() => {
            this.pasteUrl();
          })
        Button('仅测连接')
          .height(44)
          .fontSize(14)
          .fontColor('#374151')
          .backgroundColor('#e5e7eb')
          .borderRadius(12)
          .layoutWeight(1)
          .enabled(!this.pushing)
          .onClick(() => {
            this.testConnect();
          })
      }
      .width('100%')

      // 状态行：状态点 + 文字 + fps
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 })
          .fill(this.pushing ? '#dc2626' : '#d1d5db')
        Text(this.statusText)
          .fontSize(13)
          .fontColor(this.pushing ? '#dc2626' : '#6b7280')
          .layoutWeight(1)
        Text(`${this.fps}fps`)
          .fontSize(12)
          .fontColor(this.pushing ? '#dc2626' : '#9ca3af')
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      // 主按钮：全宽渐变
      Button(this.pushing ? '停止推流' : '开始推流')
        .width('100%')
        .height(56)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .borderRadius(16)
        .linearGradient({
          angle: 90,
          colors: this.pushing
            ? [['#ef4444', 0], ['#b91c1c', 1]]
            : [['#3b82f6', 0], ['#0a59f7', 1]]
        })
        .onClick(() => {
          if (this.pushing) {
            this.stopAll();
          } else {
            this.startPush();
          }
        })

      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.logs, (l: string) => {
            Text(l)
              .fontSize(10)
              .fontColor('#6b7280')
              .width('100%')
          }, (l: string) => l)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .backgroundColor(Color.White)
      .borderRadius(16)
      .padding(10)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
    .backgroundColor('#f5f5f7')
  }
}
