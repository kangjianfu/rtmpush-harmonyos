// common/RtmpClient.ets — 纯 ArkTS 实现的 RTMP 推流客户端（自研，无第三方 SDK）
// 覆盖：simple/digest(FP9) 握手、AMF0 编码、connect/createStream/publish、
//       Chunk 协议（format0 + 扩展时间戳 + 分块）、AVCC 视频标签、@setDataFrame 元数据
// 参考协议：RTMP Specification 1.0（Adobe）、librtmp（RTMPDump）
import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const FP9_SERVER_KEY = 'Genuine Adobe Flash Media Server 001'; // C1 签名
const FP9_CLIENT_KEY = 'Genuine Adobe Flash Player 001';       // S1 校验
const RTMP_HANDSHAKE_SIZE = 1536;

export interface RtmpUrlInfo {
  host: string;
  port: number;
  app: string;       // tcUrl 的 app 路径（如 basketball）
  streamKey: string; // publish 的流名（含 query，如 match-xxx?auth_key=...）
  tcUrl: string;
}

/** 解析 rtmp://host[:port]/app/streamKey?query */
export function parseRtmpUrl(url: string): RtmpUrlInfo {
  let u = url;
  let host = '';
  let port = 1935;
  let app = '';
  let streamKey = '';
  if (u.startsWith('rtmp://')) {
    u = u.slice(7);
  }
  const slash = u.indexOf('/');
  host = u.slice(0, slash);
  const rest = u.slice(slash + 1);
  if (host.includes(':')) {
    const idx = host.lastIndexOf(':');
    port = parseInt(host.slice(idx + 1)) || 1935;
    host = host.slice(0, idx);
  }
  // app 可能有多级路径（basketball），最后一级是流名
  const parts = rest.split('/');
  streamKey = parts.pop() ?? '';
  app = parts.join('/');
  return {
    host: host, port: port, app: app, streamKey: streamKey,
    tcUrl: `rtmp://${host}:${port}/${app}`
  };
}

// ---------------- 小工具 ----------------

class BufWriter {
  chunks: Uint8Array[] = [];
  private view: Uint8Array = new Uint8Array(8);

  u8(v: number): BufWriter {
    this.chunks.push(new Uint8Array([v & 0xff]));
    return this;
  }

  u16be(v: number): BufWriter {
    const b = new Uint8Array(2);
    b[0] = (v >> 8) & 0xff;
    b[1] = v & 0xff;
    this.chunks.push(b);
    return this;
  }

  u24be(v: number): BufWriter {
    const b = new Uint8Array(3);
    b[0] = (v >> 16) & 0xff;
    b[1] = (v >> 8) & 0xff;
    b[2] = v & 0xff;
    this.chunks.push(b);
    return this;
  }

  u32be(v: number): BufWriter {
    const b = new Uint8Array(4);
    b[0] = (v >>> 24) & 0xff;
    b[1] = (v >>> 16) & 0xff;
    b[2] = (v >>> 8) & 0xff;
    b[3] = v & 0xff;
    this.chunks.push(b);
    return this;
  }

  u32le(v: number): BufWriter {
    const b = new Uint8Array(4);
    b[0] = v & 0xff;
    b[1] = (v >>> 8) & 0xff;
    b[2] = (v >>> 16) & 0xff;
    b[3] = (v >>> 24) & 0xff;
    this.chunks.push(b);
    return this;
  }

  double(v: number): BufWriter {
    const dv = new DataView(this.view.buffer);
    dv.setFloat64(0, v, false);
    this.chunks.push(this.view.slice());
    return this;
  }

  bytes(b: Uint8Array | number[]): BufWriter {
    this.chunks.push(b instanceof Uint8Array ? b : new Uint8Array(b));
    return this;
  }

  str(s: string): BufWriter {
    const enc = new util.TextEncoder();
    this.chunks.push(enc.encodeInto(s));
    return this;
  }

  build(): Uint8Array {
    let total = 0;
    for (const c of this.chunks) {
      total += c.length;
    }
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of this.chunks) {
      out.set(c, off);
      off += c.length;
    }
    return out;
  }

  length(): number {
    let total = 0;
    for (const c of this.chunks) {
      total += c.length;
    }
    return total;
  }
}

async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
  const symKey: cryptoFramework.SymKey = cryptoFramework.createSymKeyGenerator('HMAC').convertKeySync({ data: key });
  mac.initSync(symKey);
  mac.updateSync({ data: data });
  const res: cryptoFramework.DataBlob = mac.doFinalSync();
  return res.data;
}

function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    b[i] = Math.floor(Math.random() * 256);
  }
  return b;
}

// ---------------- AMF0 ----------------

function amfStr(w: BufWriter, s: string): void {
  w.u8(0x02);
  const enc = new util.TextEncoder();
  const b = enc.encodeInto(s);
  w.u16be(b.length);
  w.bytes(b);
}

function amfNumber(w: BufWriter, v: number): void {
  w.u8(0x00);
  w.double(v);
}

function amfBool(w: BufWriter, v: boolean): void {
  w.u8(0x01);
  w.u8(v ? 1 : 0);
}

// AMF0 对象/数组的 key：仅长度+UTF-8，无类型字节（与 amfStr 不同！）
function amfKey(w: BufWriter, s: string): void {
  const enc = new util.TextEncoder();
  const b = enc.encodeInto(s);
  w.u16be(b.length);
  w.bytes(b);
}

// ---------------- RTMP 消息类型 ----------------

const MSG_CHUNK_SIZE = 1;
const MSG_ABORT = 2;
const MSG_ACK = 3;
const MSG_USER_CONTROL = 4;
const MSG_WINDOW_ACK = 5;
const MSG_SET_PEER_BW = 6;
const MSG_AUDIO = 8;
const MSG_VIDEO = 9;
const MSG_AMF3_META = 15;
const MSG_AMF0_META = 18;
const MSG_AMF0_COMMAND = 20;

// ---------------- 客户端 ----------------

export type RtmpLog = (msg: string) => void;

interface SendStat {
  t: number;
  bytes: number;
}

interface ChunkMsg {
  ts: number;
  len: number;
  type: number;
  sid: number;
  got: number;
  buf: Uint8Array;
  extended: boolean;
}

interface DigestLoc {
  offset: number;
}

export class RtmpClient {
  onLog: RtmpLog = () => {};
  onReady: () => void = () => {}; // publish 成功后可开始推流
  onClosed: () => void = () => {}; // 连接意外断开（正常 close() 不触发），供上层做重连

  private tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
  private info: RtmpUrlInfo | null = null;
  private recvBuf: Uint8Array = new Uint8Array(0);
  private chunkSizeOut: number = 128;
  private chunkSizeIn: number = 128;
  private streamId: number = 0;
  private selfChunks: Map<number, ChunkMsg> = new Map();
  private awaiting: 'connect' | 'createStream' | 'publish' | '' = '';
  private ready: boolean = false;
  private baseSendTime: number = 0;
  private closing: boolean = false;
  private handshaking: boolean = true;
  private audioSampleRate: number = 0;
  private audioChannels: number = 0;
  private hevc: boolean = false; // H.265 走 Enhanced RTMP（hvc1），H.264 走老 FLV tag

  /** 有音频时先告知（影响 onMetaData 的 audiocodecid 与 AAC 序列头） */
  setAudioInfo(sampleRate: number, channels: number): void {
    this.audioSampleRate = sampleRate;
    this.audioChannels = channels;
  }

  /** H.265 推流（Enhanced RTMP），须在 sendHevcConfig 前调用 */
  setHevc(v: boolean): void {
    this.hevc = v;
  }

  async connect(url: string): Promise<void> {
    this.info = parseRtmpUrl(url);
    this.onLog(`连接 ${this.info.host}:${this.info.port}`);
    await this.tcp.connect({
      address: { address: this.info.host, port: this.info.port },
      timeout: 10000
    });
    this.tcp.on('message', (data: socket.SocketMessageInfo) => {
      if (data.message) {
        this.onData(new Uint8Array(data.message));
      }
    });
    this.tcp.on('close', () => {
      if (!this.closing) {
        this.ready = false;
        this.onLog('连接已断开');
        this.onClosed();
      }
    });
    this.tcp.on('error', () => {
      if (!this.closing) {
        this.ready = false;
        this.onLog('连接错误');
        this.onClosed();
      }
    });
    await this.doHandshake();
    await this.sendConnect();
  }

  /** 推流通道是否就绪（publish 成功） */
  isReady(): boolean {
    return this.ready;
  }

  private pushReceived(data: Uint8Array): void {
    const merged = new Uint8Array(this.recvBuf.length + data.length);
    merged.set(this.recvBuf);
    merged.set(data, this.recvBuf.length);
    this.recvBuf = merged;
  }

  /** 从缓冲解析一个完整 chunk 消息（循环消费） */
  private tryParse(): void {
    for (;;) {
      if (this.recvBuf.length < 1) {
        return;
      }
      const b0 = this.recvBuf[0];
      const fmt = b0 >> 6;
      let csid = b0 & 0x3f;
      let off = 1;
      if (csid === 0) {
        if (this.recvBuf.length < 2) return;
        csid = 64 + this.recvBuf[1];
        off = 2;
      } else if (csid === 1) {
        if (this.recvBuf.length < 3) return;
        csid = 64 + this.recvBuf[1] + 256 * this.recvBuf[2];
        off = 3;
      }
      const prev = this.selfChunks.get(csid);
      let ts = 0;
      let len = prev ? prev.len : 0;
      let type = prev ? prev.type : 0;
      let sid = prev ? prev.sid : 0;
      let headerLen = 0;
      if (fmt === 0) {
        headerLen = 11;
      } else if (fmt === 1) {
        headerLen = 7;
      } else if (fmt === 2) {
        headerLen = 3;
      } else {
        headerLen = 0;
      }
      if (this.recvBuf.length < off + headerLen) {
        return;
      }
      // 直接按下标读（Uint8Array 下标认 byteOffset；DataView(buffer) 不认，subarray 场景会读错）
      const b = this.recvBuf;
      let extended = false;
      if (fmt <= 2) {
        ts = (b[off] << 16) | (b[off + 1] << 8) | b[off + 2];
        extended = ts === 0xffffff;
      } else {
        ts = prev ? prev.ts : 0;
        extended = prev ? prev.extended : false;
      }
      if (fmt <= 1) {
        len = (b[off + 3] << 16) | (b[off + 4] << 8) | b[off + 5];
        type = b[off + 6];
      }
      if (fmt === 0) {
        sid = b[off + 7] | (b[off + 8] << 8) | (b[off + 9] << 16) | (b[off + 10] << 24);
      }
      let extBytes = 0;
      if (extended && fmt <= 2) {
        extBytes = 4;
        if (this.recvBuf.length < off + headerLen + 4) {
          return;
        }
      }
      const bodyOff = off + headerLen + extBytes;
      // 本轮最多读到 min(chunkSizeIn, 剩余消息体)
      const msg = prev ?? { ts: ts, len: len, type: type, sid: sid, got: 0, buf: new Uint8Array(0), extended: extended };
      // eslint-disable-next-line
      const readLen = Math.min(this.chunkSizeIn, msg.len - msg.got);
      if (this.recvBuf.length < bodyOff + readLen) {
        return;
      }
      if (!prev) {
        msg.buf = new Uint8Array(msg.len);
      }
      msg.buf.set(this.recvBuf.subarray(bodyOff, bodyOff + readLen), msg.got);
      msg.got += readLen;
      if (extended) {
        msg.extended = true;
      }
      this.recvBuf = this.recvBuf.subarray(bodyOff + readLen);
      if (msg.got >= msg.len) {
        this.selfChunks.delete(csid);
        this.handleMessage(csid, msg);
      } else {
        this.selfChunks.set(csid, msg);
      }
    }
  }

  private onData(data: Uint8Array): void {
    if (this.closing) {
      return;
    }
    this.pushReceived(data);
    if (!this.handshaking) {
      this.tryParse();
    }
  }

  private handleMessage(csid: number, msg: ChunkMsg): void {
    if (msg.type === MSG_CHUNK_SIZE) {
      if (msg.buf.length >= 4) {
        const dv = new DataView(msg.buf.buffer);
        this.chunkSizeIn = dv.getUint32(0, false);
        this.onLog(`对端块大小 ${this.chunkSizeIn}`);
      }
      return;
    }
    if (msg.type === MSG_WINDOW_ACK || msg.type === MSG_SET_PEER_BW || msg.type === MSG_USER_CONTROL || msg.type === MSG_ACK) {
      return;
    }
    if (msg.type === MSG_AMF0_COMMAND) {
      this.handleCommand(msg.buf);
    }
  }

  private handleCommand(buf: Uint8Array): void {
    const dec = new util.TextDecoder('utf-8');
    let off = 0;
    // 只解析第一个 AMF0 string（命令名）
    if (buf.length < 3 || buf[off] !== 0x02) {
      return;
    }
    const nameLen = (buf[1] << 8) | buf[2];
    const name = dec.decodeToString(buf.subarray(3, 3 + nameLen));
    this.onLog(`命令 ${name}`);
    if (name === '_result') {
      if (this.awaiting === 'connect') {
        this.awaiting = '';
        this.sendCreateStream();
      } else if (this.awaiting === 'createStream') {
        this.awaiting = '';
        // txn 后第一个 number 即 streamId
        const sid = this.findStreamId(buf);
        this.streamId = sid;
        this.sendPublish();
      }
    } else if (name === 'onStatus') {
      // 解析 NetStream.Publish.Start
      const text = dec.decodeToString(buf);
      if (text.includes('Publish.Start') || text.includes('NetStream.Publish')) {
        if (!this.ready) {
          this.ready = true;
          this.baseSendTime = Date.now();
          this.sendSetChunkSize(60000);
          this.onLog('推流通道就绪');
          this.onReady();
        }
      }
    }
  }

  private findStreamId(buf: Uint8Array): number {
    // 跳过命令名(string) + txn(number)，找第一个 number
    let off = 0;
    if (buf[off] === 0x02) {
      const l = (buf[1] << 8) | buf[2];
      off = 3 + l;
    }
    if (buf[off] === 0x00) {
      off += 9; // txn number
    }
    if (buf[off] === 0x00) {
      const dv = new DataView(buf.buffer);
      return dv.getFloat64(off + 1, false);
    }
    return 1;
  }

  // ---------------- 握手 ----------------

  private async doHandshake(): Promise<void> {
    const c1 = randomBytes(RTMP_HANDSHAKE_SIZE);
    const c0c1 = new BufWriter().u8(3).bytes(c1).build();
    await this.sendRaw(c0c1);
    // 等 S0S1S2（至少 3073 字节）
    const resp = await this.waitBytes(3073, 10000);
    // S0 = resp[0]; S1 = resp[1..1537]; S2 = resp[1537..3073]
    const s1 = resp.subarray(1, 1 + RTMP_HANDSHAKE_SIZE);
    const digestInfo = this.findDigestOffset(s1);
    if (digestInfo.offset >= 0) {
      this.onLog('服务器要求 digest 握手');
      // 校验 S1 digest（用 client key）
      const s1Copy = new Uint8Array(s1);
      s1Copy.set(new Uint8Array(32), digestInfo.offset);
      const expect = await hmacSha256(new util.TextEncoder().encodeInto(FP9_CLIENT_KEY), s1Copy);
      const actual = s1.subarray(digestInfo.offset, digestInfo.offset + 32);
      if (!this.bytesEqual(expect, actual)) {
        this.onLog('S1 digest 校验失败（继续，部分服务器不校验）');
      }
      // C2 = digest(S1 原样) 放入 random 区，结构：time(4)+time2(4)+random(1508)+digest(32)
      const timeDv = new DataView(s1.buffer);
      const s1time = timeDv.getUint32(0, false);
      const now = (Date.now() / 1000) & 0x7fffffff;
      const c2Random = randomBytes(1508);
      const c2head = new BufWriter().u32be(s1time).u32be(now).bytes(c2Random).build();
      const c2digest = await hmacSha256(new util.TextEncoder().encodeInto(FP9_SERVER_KEY), c2head);
      await this.sendRaw(new BufWriter().bytes(c2head).bytes(c2digest).build());
    } else {
      // simple 握手：C2 原样回 S1
      await this.sendRaw(s1);
    }
    this.onLog('握手完成');
    this.handshaking = false;
    this.baseSendTime = Date.now();
    // 握手响应里可能已附带控制消息
    this.tryParse();
  }

  private findDigestOffset(s1: Uint8Array): DigestLoc {
    // FP9：digest offset 存放在 1536-8 的两组四字节（772/776），均为 little-endian
    const dv = new DataView(s1.buffer);
    const scheme0 = dv.getUint32(772, true) % 764;
    const scheme1 = dv.getUint32(776, true) % 764;
    const offset = 8 + (scheme0 <= scheme1 ? scheme0 : scheme1 + 764);
    if (offset >= 0 && offset + 32 <= RTMP_HANDSHAKE_SIZE) {
      return { offset: offset };
    }
    return { offset: -1 };
  }

  private bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }

  // ---------------- 命令 ----------------

  private async sendConnect(): Promise<void> {
    this.awaiting = 'connect';
    const w = new BufWriter();
    amfStr(w, 'connect');
    amfNumber(w, 1);
    w.u8(0x03); // object
    amfKey(w, 'app');
    amfStr(w, this.info?.app ?? '');
    amfKey(w, 'tcUrl');
    amfStr(w, this.info?.tcUrl ?? '');
    amfKey(w, 'flashVer');
    amfStr(w, 'FMLE/3.0 (compatible; FMSc/1.0)');
    amfKey(w, 'fpad');
    amfBool(w, false);
    amfKey(w, 'capabilities');
    amfNumber(w, 15);
    w.u16be(0);
    w.u8(0x09); // object end
    await this.sendMessage(3, MSG_AMF0_COMMAND, 0, w.build());
    this.onLog('connect 已发送');
  }

  private async sendCreateStream(): Promise<void> {
    this.awaiting = 'createStream';
    const w = new BufWriter();
    amfStr(w, 'createStream');
    amfNumber(w, 2);
    w.u8(0x05); // null
    await this.sendMessage(3, MSG_AMF0_COMMAND, 0, w.build());
  }

  private async sendPublish(): Promise<void> {
    this.awaiting = 'publish';
    const w = new BufWriter();
    amfStr(w, 'publish');
    amfNumber(w, 3);
    w.u8(0x05);
    amfStr(w, this.info?.streamKey ?? '');
    amfStr(w, 'live');
    await this.sendMessage(8, MSG_AMF0_COMMAND, this.streamId, w.build());
    this.onLog(`publish ${this.info?.streamKey ?? ''}`);
  }

  // ---------------- 推流数据 ----------------

  /** 发送视频序列头（SPS/PPS，annex-b）与元数据 */
  async sendVideoConfig(spsList: Uint8Array[], ppsList: Uint8Array[], width: number, height: number, frameRate: number): Promise<void> {
    const sps = spsList[0];
    const pps = ppsList[0];
    if (!sps || !pps) {
      return;
    }
    // AVC sequence header
    const body = new BufWriter();
    body.u8(0x17).u8(0x00).u24be(0);
    body.u8(0x01); // configurationVersion
    body.u8(sps[1]); // AVCProfileIndication
    body.u8(sps[2]); // profile_compatibility
    body.u8(sps[3]); // AVCLevelIndication
    body.u8(0xff); // lengthSizeMinusOne=3
    body.u8(0xe0 | 1); // numOfSPS
    body.u16be(sps.length);
    body.bytes(sps);
    body.u8(1); // numOfPPS
    body.u16be(pps.length);
    body.bytes(pps);
    await this.sendMessage(4, MSG_VIDEO, this.streamId, body.build());
    this.onLog('已发送 SPS/PPS');

    await this.sendMeta(width, height, frameRate);
  }

  /** @setDataFrame onMetaData（AVC/HEVC 共用，videocodecid 随 hevc 标志） */
  private async sendMeta(width: number, height: number, frameRate: number): Promise<void> {
    const hasAudio = this.audioSampleRate > 0;
    const meta = new BufWriter();
    amfStr(meta, '@setDataFrame');
    amfStr(meta, 'onMetaData');
    meta.u8(0x08); // ECMA array
    meta.u32be(hasAudio ? 7 : 5);
    amfKey(meta, 'width');
    amfNumber(meta, width);
    amfKey(meta, 'height');
    amfNumber(meta, height);
    amfKey(meta, 'framerate');
    amfNumber(meta, frameRate);
    amfKey(meta, 'videocodecid');
    amfNumber(meta, this.hevc ? 12 : 7);
    amfKey(meta, 'audiocodecid');
    amfNumber(meta, hasAudio ? 10 : 0);
    if (hasAudio) {
      amfKey(meta, 'audiosamplerate');
      amfNumber(meta, this.audioSampleRate);
      amfKey(meta, 'audiochannels');
      amfNumber(meta, this.audioChannels);
    }
    meta.u16be(0);
    meta.u8(0x09);
    await this.sendMessage(4, MSG_AMF0_META, this.streamId, meta.build());
  }

  /** 发送 AAC 序列头（AudioSpecificConfig，profile=LC）。须先于音频帧发送 */
  async sendAudioConfig(): Promise<void> {
    if (this.audioSampleRate <= 0) {
      return;
    }
    const freqTable: number[] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000];
    let idx = freqTable.indexOf(this.audioSampleRate);
    if (idx < 0) {
      idx = 4; // 44100
    }
    const asc = (2 << 11) | (idx << 7) | (this.audioChannels << 3);
    const body = new BufWriter();
    body.u8(0xaf); // soundFormat=10(AAC) | rate=3(44k) | size=1(16bit) | type=1(stereo 占位，实际声道以 ASC 为准)
    body.u8(0x00); // AAC sequence header
    body.u16be(asc);
    await this.sendMessage(5, MSG_AUDIO, this.streamId, body.build());
    this.onLog('已发送 AAC 序列头');
  }

  /** 发送一帧 AAC（raw，无 ADTS） */
  async sendAudioFrame(aac: Uint8Array): Promise<void> {
    const body = new BufWriter();
    body.u8(0xaf);
    body.u8(0x01); // AAC raw
    body.bytes(aac);
    await this.sendMessage(5, MSG_AUDIO, this.streamId, body.build());
  }

  /** 发送一帧 H.264/H.265（annex-b），isKey 关键帧，dts 毫秒 */
  async sendVideoFrame(annexb: Uint8Array, isKey: boolean, dts: number): Promise<void> {
    // annex-b → AVCC（长度前缀）
    const nals: Uint8Array[] = [];
    let start = -1;
    for (let i = 0; i + 3 < annexb.length; i++) {
      if (annexb[i] === 0 && annexb[i + 1] === 0 && annexb[i + 2] === 0 && annexb[i + 3] === 1) {
        if (start >= 0) {
          nals.push(annexb.subarray(start, i));
        }
        start = i + 4;
        i += 3;
      }
    }
    if (start >= 0) {
      nals.push(annexb.subarray(start));
    }
    if (nals.length === 0) {
      return;
    }
    const body = new BufWriter();
    if (this.hevc) {
      // Enhanced RTMP v2：FrameType|ExHeader|PacketType(CodedFrames) + fourcc 'hvc1'
      body.u8(((isKey ? 1 : 2) << 4) | 0x08);
      body.u8(0x80); // PacketType=1 (CodedFrames) 的低位
      body.bytes([0x68, 0x76, 0x63, 0x31]); // 'hvc1'
      body.u24be(0); // composition time
    } else {
      body.u8(((isKey ? 1 : 2) << 4) | 7);
      body.u8(0x01); // NALU
      body.u24be(0); // composition time
    }
    for (const nal of nals) {
      body.u32be(nal.length);
      body.bytes(nal);
    }
    await this.sendMessage(4, MSG_VIDEO, this.streamId, body.build());
  }

  /** 发送 H.265 序列头（VPS/SPS/PPS → hvcC，Enhanced RTMP PacketType=0） */
  async sendHevcConfig(vps: Uint8Array, sps: Uint8Array, pps: Uint8Array,
    width: number, height: number, frameRate: number): Promise<void> {
    // hvcC：profile_tier_level 取自 SPS（2 字节 NAL 头之后）
    const hvcc = new BufWriter();
    hvcc.u8(1); // configurationVersion
    hvcc.u8(sps.length > 3 ? sps[3] : 0x01); // profile_space|tier|profile_idc
    for (let i = 4; i <= 8; i++) {
      hvcc.u8(sps.length > i ? sps[i] : 0); // profile_compatibility_flags
    }
    for (let i = 9; i <= 14; i++) {
      hvcc.u8(sps.length > i ? sps[i] : 0); // constraint_indicator_flags
    }
    hvcc.u8(sps.length > 15 ? sps[15] : 0x1e); // level_idc
    hvcc.u16be(0xf000); // min_spatial_segmentation_idc
    hvcc.u8(0xfc); // parallelismType
    hvcc.u8(0xfd); // chromaFormat=1 (4:2:0)
    hvcc.u8(0xf8); // bitDepthLumaMinus8
    hvcc.u8(0xf8); // bitDepthChromaMinus8
    hvcc.u16be(0); // avgFrameRate
    hvcc.u8(0x0f); // numTemporalLayers=1, temporalIdNested=1, lengthSizeMinusOne=3
    hvcc.u8(3); // numOfArrays
    const nalTypes: number[] = [32, 33, 34];
    const nalData: Uint8Array[] = [vps, sps, pps];
    for (let i = 0; i < 3; i++) {
      hvcc.u8(0x80 | nalTypes[i]); // completeness=1
      hvcc.u16be(1);
      hvcc.u16be(nalData[i].length);
      hvcc.bytes(nalData[i]);
    }
    const body = new BufWriter();
    body.u8(0x18); // FrameType=1 | ExHeader | PacketType=0(SequenceStart) 高位
    body.u8(0x00); // PacketType 低位
    body.bytes([0x68, 0x76, 0x63, 0x31]); // 'hvc1'
    body.bytes(hvcc.build());
    await this.sendMessage(4, MSG_VIDEO, this.streamId, body.build());
    this.onLog('已发送 VPS/SPS/PPS（hvcC）');

    // onMetaData 与 AVC 共用
    await this.sendMeta(width, height, frameRate);
  }

  // ---------------- 底层发送 ----------------

  private async sendSetChunkSize(size: number): Promise<void> {
    const w = new BufWriter();
    w.u32be(size);
    await this.sendMessage(2, MSG_CHUNK_SIZE, 0, w.build());
    this.chunkSizeOut = size;
  }

  private async sendMessage(csid: number, type: number, streamId: number, body: Uint8Array): Promise<void> {
    const w = new BufWriter();
    const ts = Date.now() - this.baseSendTime;
    const fmt0Header = new BufWriter();
    fmt0Header.u8(csid & 0x3f); // fmt=0, csid<63
    if (ts >= 0xffffff) {
      fmt0Header.u24be(0xffffff);
    } else {
      fmt0Header.u24be(ts);
    }
    fmt0Header.u24be(body.length);
    fmt0Header.u8(type);
    fmt0Header.u32le(streamId);
    if (ts >= 0xffffff) {
      fmt0Header.u32be(ts);
    }
    // 分块：首块带 fmt0 头，续块只带 fmt=3 头
    let sent = 0;
    let first = true;
    while (sent < body.length) {
      const n = Math.min(this.chunkSizeOut, body.length - sent);
      if (first) {
        w.bytes(fmt0Header.build());
      } else {
        w.u8(0xc0 | (csid & 0x3f));
        if (ts >= 0xffffff) {
          w.u32be(ts);
        }
      }
      w.bytes(body.subarray(sent, sent + n));
      sent += n;
      first = false;
    }
    await this.sendRaw(w.build());
  }

  private sendQueue: Promise<void> = Promise.resolve();
  private sendStats: SendStat[] = [];

  private sendRaw(data: Uint8Array): Promise<void> {
    // 串行化发送，避免交错；完成后记账用于吞吐统计（自适应码流）
    this.sendQueue = this.sendQueue.then(() => {
      return this.tcp.send({ data: data.buffer });
    }).then(() => {
      this.sendStats.push({ t: Date.now(), bytes: data.length });
      const cutoff = Date.now() - 4000;
      while (this.sendStats.length > 0 && this.sendStats[0].t < cutoff) {
        this.sendStats.shift();
      }
    }).catch(() => {
      // 发送失败（断线）：吞掉让队列存活；断线重连由 onClosed 触发
      this.ready = false;
    });
    return this.sendQueue;
  }

  /** 最近 3 秒实际发送速率（kbps）；样本不足返回 -1 */
  getSendRateKbps(): number {
    const cutoff = Date.now() - 3000;
    const recent = this.sendStats.filter(s => s.t >= cutoff);
    if (recent.length < 2) {
      return -1;
    }
    const span = (recent[recent.length - 1].t - recent[0].t) / 1000;
    if (span <= 0.2) {
      return -1;
    }
    let bytes = 0;
    for (const s of recent) {
      bytes += s.bytes;
    }
    return Math.round(bytes * 8 / 1000 / span);
  }

  private waitBytes(n: number, timeoutMs: number): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      const start = Date.now();
      const timer = setInterval(() => {
        if (this.recvBuf.length >= n) {
          clearInterval(timer);
          const out = this.recvBuf.subarray(0, n);
          this.recvBuf = this.recvBuf.subarray(n);
          resolve(out);
        } else if (Date.now() - start > timeoutMs) {
          clearInterval(timer);
          reject(new Error('握手超时'));
        }
      }, 20);
    });
  }

  async close(): Promise<void> {
    this.closing = true;
    try {
      await this.tcp.close();
    } catch (e) { /* 忽略 */ }
  }
}
