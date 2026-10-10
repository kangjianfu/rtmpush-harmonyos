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

// common/RtmpClient.ets — 纯 ArkTS 实现的 RTMP 推流客户端（自研，无第三方 SDK）
// 覆盖：simple/digest(FP9) 握手、AMF0 编码、connect/createStream/publish、
//       Chunk 协议（format0 + 扩展时间戳 + 分块）、AVCC 视频标签、@setDataFrame 元数据
// 参考协议：RTMP Specification 1.0（Adobe）、librtmp（RTMPDump）
import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

// FP9 digest 握手密钥（与 librtmp handshake.h 一致）：
// - C1/S1 的 digest 用 30/36 字节字符串部分做 HMAC key
// - C2 的签名用完整密钥（字符串 + 32 字节后缀，FP 62 字节 / FMS 68 字节）
const FP9_SERVER_KEY = 'Genuine Adobe Flash Media Server 001'; // S1 校验
const FP9_CLIENT_KEY = 'Genuine Adobe Flash Player 001';       // C1 签名、C2 响应
const FP9_KEY_SUFFIX: number[] = [
  0xf0, 0xee, 0xc2, 0x4a, 0x80, 0x68, 0xbe, 0xe8, 0x2e, 0x00, 0xd0, 0xd1, 0x02, 0x9e, 0x7e, 0x57,
  0x6e, 0xec, 0x5d, 0x2d, 0x29, 0x80, 0x6f, 0xab, 0x93, 0xb8, 0xe6, 0x36, 0xcf, 0xeb, 0x31, 0xae
];
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

function fp9Key(s: string, withSuffix: boolean): Uint8Array {
  const head = new util.TextEncoder().encodeInto(s);
  if (!withSuffix) {
    return head;
  }
  const out = new Uint8Array(head.length + FP9_KEY_SUFFIX.length);
  out.set(head);
  out.set(new Uint8Array(FP9_KEY_SUFFIX), head.length);
  return out;
}

// librtmp CalculateDigest：HMAC-SHA256(key, 握手包中除 digest 外的 1536-32 字节)
async function fp9Digest(sig: Uint8Array, digestPos: number, key: Uint8Array): Promise<Uint8Array> {
  const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
  const symKey: cryptoFramework.SymKey = cryptoFramework.createSymKeyGenerator('HMAC').convertKeySync({ data: key });
  mac.initSync(symKey);
  mac.updateSync({ data: sig.subarray(0, digestPos) });
  mac.updateSync({ data: sig.subarray(digestPos + 32) });
  return mac.doFinalSync().data;
}

// librtmp GetDigestOffset1/2：digest 偏移 = 4 字节求和 % 728 + 基址（12 或 776）
function digestOffset1(sig: Uint8Array): number {
  return (sig[8] + sig[9] + sig[10] + sig[11]) % 728 + 12;
}

function digestOffset2(sig: Uint8Array): number {
  return (sig[772] + sig[773] + sig[774] + sig[775]) % 728 + 776;
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

/** annex-b 拆 NAL：兼容 00 00 00 01 与 00 00 01 两种起始码 */
export function splitAnnexB(data: Uint8Array): Uint8Array[] {
  const nals: Uint8Array[] = [];
  const n = data.length;
  let start = -1;
  let i = 0;
  while (i + 2 < n) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      if (start >= 0) {
        // 剥掉上一 NAL 末尾的起始码前导零
        let end = i;
        while (end > start && data[end - 1] === 0) {
          end--;
        }
        if (end > start) {
          nals.push(data.subarray(start, end));
        }
      }
      start = i + 3;
      i += 3;
    } else {
      i++;
    }
  }
  if (start >= 0 && start < n) {
    nals.push(data.subarray(start));
  }
  return nals;
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

export class RtmpClient {
  onLog: RtmpLog = () => {};
  onReady: () => void = () => {}; // publish 成功后可开始推流
  onClosed: () => void = () => {}; // 连接意外断开（正常 close() 不触发），供上层做重连
  onError: (msg: string) => void = () => {}; // 协议层错误（publish 被拒、_error 等）

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
  private videoBaseTs: number = -1; // 首帧媒体 ts，音/视频各自归零对齐到推流起点
  private audioBaseTs: number = -1;
  private winAckSize: number = 2500000; // 对端 Window Acknowledgement Size（常见默认值）
  private totalBytesIn: number = 0;
  private bytesInSinceAck: number = 0;

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
    // 支持同一实例重连：关掉旧 socket、重建并复位全部协议状态
    try {
      this.tcp.close();
    } catch (e) { /* 旧连接可能已断开，忽略 */ }
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.closing = false;
    this.handshaking = true;
    this.ready = false;
    this.recvBuf = new Uint8Array(0);
    this.selfChunks.clear();
    this.chunkSizeIn = 128;
    this.chunkSizeOut = 128;
    this.streamId = 0;
    this.awaiting = '';
    this.sendStats = [];
    this.sendQueue = Promise.resolve();
    this.videoBaseTs = -1;
    this.audioBaseTs = -1;
    this.totalBytesIn = 0;
    this.bytesInSinceAck = 0;

    this.info = parseRtmpUrl(url);
    this.onLog(`连接 ${this.info.host}:${this.info.port}`);
    await tcp.connect({
      address: { address: this.info.host, port: this.info.port },
      timeout: 10000
    });
    tcp.on('message', (data: socket.SocketMessageInfo) => {
      if (data.message) {
        this.onData(new Uint8Array(data.message));
      }
    });
    tcp.on('close', () => {
      // 旧 socket 的迟到事件不影响新连接
      if (this.tcp !== tcp || this.closing) {
        return;
      }
      this.ready = false;
      this.onLog('连接已断开');
      this.onClosed();
    });
    tcp.on('error', (err) => {
      if (this.tcp !== tcp || this.closing) {
        return;
      }
      this.ready = false;
      this.onLog(`连接错误 ${JSON.stringify(err)}`);
      this.onClosed();
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
      if (extended) {
        // 扩展时间戳消息的所有 chunk（含 fmt=3 续块）都带 4 字节扩展时间戳
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
    // 按对端要求的窗口回 ACK，避免严格服务器暂停发送
    this.totalBytesIn += data.length;
    this.bytesInSinceAck += data.length;
    if (!this.handshaking && this.bytesInSinceAck >= this.winAckSize) {
      this.bytesInSinceAck = 0;
      const w = new BufWriter();
      w.u32be(this.totalBytesIn >>> 0);
      this.sendMessage(2, MSG_ACK, 0, w.build());
    }
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
    if (msg.type === MSG_WINDOW_ACK) {
      if (msg.buf.length >= 4) {
        this.winAckSize = new DataView(msg.buf.buffer).getUint32(0, false);
      }
      return;
    }
    if (msg.type === MSG_USER_CONTROL) {
      // PingRequest(6) → PongResponse(7)，不回的话部分服务器会按超时断流
      if (msg.buf.length >= 6) {
        const dv = new DataView(msg.buf.buffer);
        if (dv.getUint16(0, false) === 6) {
          const w = new BufWriter();
          w.u16be(7);
          w.bytes(msg.buf.subarray(2, 6));
          this.sendMessage(2, MSG_USER_CONTROL, 0, w.build());
        }
      }
      return;
    }
    if (msg.type === MSG_SET_PEER_BW || msg.type === MSG_ACK) {
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
    } else if (name === '_error') {
      this.onLog(`服务器返回 _error（awaiting=${this.awaiting || '无'}）`);
      this.awaiting = '';
      this.onError('RTMP 命令被服务器拒绝');
    } else if (name === 'onStatus') {
      // 解析 NetStream.Publish.Start
      const text = dec.decodeToString(buf);
      if (text.includes('Publish.Start')) {
        if (!this.ready) {
          this.ready = true;
          this.baseSendTime = Date.now();
          this.sendSetChunkSize(60000);
          this.onLog('推流通道就绪');
          this.onReady();
        }
      } else if (text.includes('NetStream.Publish') || text.includes('NetConnection.Connect.Failed')
        || text.includes('NetConnection.Connect.Rejected')) {
        // Publish.BadName / Publish.Denied / Connect.Failed 等
        this.ready = false;
        const detail = this.extractOnStatusCode(buf);
        this.onLog(`onStatus: ${detail}`);
        this.onError(`推流被服务器拒绝：${detail}`);
      }
    }
  }

  /** 从 onStatus 的 AMF0 字节里提取 code 字符串（尽力而为，用于日志和错误上报） */
  private extractOnStatusCode(buf: Uint8Array): string {
    const text = new util.TextDecoder('utf-8').decodeToString(buf);
    const m = text.match(/Net(?:Stream|Connection)\.[A-Za-z.]+/);
    return m ? m[0] : '未知错误';
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
    // C1：版本 10.0.45.2 声明支持 FP9（librtmp 行为），并自带 digest；
    // 服务器若不支持 digest，S1 版本字节为 0，走 simple 握手
    const c1 = randomBytes(RTMP_HANDSHAKE_SIZE);
    new DataView(c1.buffer).setUint32(0, (Date.now() / 1000) & 0x7fffffff, false);
    c1[4] = 10;
    c1[5] = 0;
    c1[6] = 45;
    c1[7] = 2;
    const c1DigestPos = digestOffset1(c1);
    c1.set(await fp9Digest(c1, c1DigestPos, fp9Key(FP9_CLIENT_KEY, false)), c1DigestPos);
    await this.sendRaw(new BufWriter().u8(3).bytes(c1).build());

    // 等 S0S1S2（至少 3073 字节）
    const resp = await this.waitBytes(3073, 10000);
    // S0 = resp[0]; S1 = resp[1..1537]; S2 = resp[1537..3073]
    const s1 = resp.subarray(1, 1 + RTMP_HANDSHAKE_SIZE);

    // 校验 S1 digest（key 为 FMS key 的 36 字节字符串部分），两种 scheme 各试一次
    let digestPos = -1;
    if (s1[4] !== 0) {
      const fmsKey = fp9Key(FP9_SERVER_KEY, false);
      for (const pos of [digestOffset1(s1), digestOffset2(s1)]) {
        const expect = await fp9Digest(s1, pos, fmsKey);
        if (this.bytesEqual(expect, s1.subarray(pos, pos + 32))) {
          digestPos = pos;
          break;
        }
      }
    }

    if (digestPos >= 0) {
      this.onLog('服务器要求 digest 握手');
      // C2（1536 字节）：末尾 32 字节 = HMAC(key=HMAC(key=FP62, S1 digest), data=C2 前 1504 字节)
      const c2 = randomBytes(RTMP_HANDSHAKE_SIZE);
      const digestResp = await hmacSha256(fp9Key(FP9_CLIENT_KEY, true), s1.subarray(digestPos, digestPos + 32));
      const sig = await hmacSha256(digestResp, c2.subarray(0, RTMP_HANDSHAKE_SIZE - 32));
      c2.set(sig, RTMP_HANDSHAKE_SIZE - 32);
      await this.sendRaw(c2);
    } else {
      if (s1[4] !== 0) {
        this.onLog('S1 digest 校验失败，按 simple 握手继续');
      }
      // simple 握手：C2 原样回 S1
      await this.sendRaw(s1);
    }
    this.onLog('握手完成');
    this.handshaking = false;
    this.baseSendTime = Date.now();
    // 握手响应里可能已附带控制消息
    this.tryParse();
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
    if (this.hevc) {
      // Enhanced RTMP：声明支持 hvc1 FourCC（规范要求，部分服务器据此放行 H.265）
      amfKey(w, 'fourCcList');
      w.u8(0x0a); // strict array
      w.u32be(1);
      amfStr(w, 'hvc1');
    }
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
    await this.sendMessage(4, MSG_VIDEO, this.streamId, body.build(), 0);
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
    // Enhanced RTMP：HEVC 用 FourCC 'hvc1' 的数值（0x68766331），AVC 保持 7
    amfNumber(meta, this.hevc ? 0x68766331 : 7);
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
    await this.sendMessage(4, MSG_AMF0_META, this.streamId, meta.build(), 0);
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
    await this.sendMessage(5, MSG_AUDIO, this.streamId, body.build(), 0);
    this.onLog('已发送 AAC 序列头');
  }

  /** 发送一帧 AAC（raw，无 ADTS），pts 毫秒（缺省按发送时刻） */
  async sendAudioFrame(aac: Uint8Array, ptsMs?: number): Promise<void> {
    const body = new BufWriter();
    body.u8(0xaf);
    body.u8(0x01); // AAC raw
    body.bytes(aac);
    await this.sendMessage(5, MSG_AUDIO, this.streamId, body.build(), this.normTs(ptsMs, false));
  }

  /** 发送一帧 H.264/H.265（annex-b），isKey 关键帧，dts 毫秒（缺省按发送时刻） */
  async sendVideoFrame(annexb: Uint8Array, isKey: boolean, dts?: number): Promise<void> {
    // annex-b → AVCC（长度前缀）
    const nals = splitAnnexB(annexb);
    if (nals.length === 0) {
      return;
    }
    const body = new BufWriter();
    if (this.hevc) {
      // Enhanced RTMP：FrameType(高4位) | 0x08(ExHeader 标志) | PacketType(低3位)，单字节
      body.u8(((isKey ? 1 : 2) << 4) | 0x08 | 0x01); // PacketType=1 CodedFrames
      body.bytes([0x68, 0x76, 0x63, 0x31]); // 'hvc1'
      body.u24be(0); // composition time offset（无 B 帧恒为 0）
    } else {
      body.u8(((isKey ? 1 : 2) << 4) | 7);
      body.u8(0x01); // NALU
      body.u24be(0); // composition time
    }
    for (const nal of nals) {
      body.u32be(nal.length);
      body.bytes(nal);
    }
    await this.sendMessage(4, MSG_VIDEO, this.streamId, body.build(), this.normTs(dts, true));
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
    body.u8(0x18); // FrameType=1(关键帧) | ExHeader(0x08) | PacketType=0(SequenceStart)，单字节
    body.bytes([0x68, 0x76, 0x63, 0x31]); // 'hvc1'
    body.bytes(hvcc.build());
    await this.sendMessage(4, MSG_VIDEO, this.streamId, body.build(), 0);
    this.onLog('已发送 VPS/SPS/PPS（hvcC）');

    // onMetaData 与 AVC 共用
    await this.sendMeta(width, height, frameRate);
  }

  // ---------------- 底层发送 ----------------

  /** 媒体时间戳归一化：音/视频各自以首帧为 0（缺省退化为发送时刻） */
  private normTs(ptsMs: number | undefined, isVideo: boolean): number {
    if (ptsMs === undefined || !isFinite(ptsMs)) {
      return Date.now() - this.baseSendTime;
    }
    if (isVideo) {
      if (this.videoBaseTs < 0) {
        this.videoBaseTs = ptsMs;
      }
      return Math.max(0, Math.round(ptsMs - this.videoBaseTs));
    }
    if (this.audioBaseTs < 0) {
      this.audioBaseTs = ptsMs;
    }
    return Math.max(0, Math.round(ptsMs - this.audioBaseTs));
  }

  private async sendSetChunkSize(size: number): Promise<void> {
    const w = new BufWriter();
    w.u32be(size);
    await this.sendMessage(2, MSG_CHUNK_SIZE, 0, w.build());
    this.chunkSizeOut = size;
  }

  private async sendMessage(csid: number, type: number, streamId: number, body: Uint8Array, tsMs?: number): Promise<void> {
    const w = new BufWriter();
    const ts = tsMs ?? (Date.now() - this.baseSendTime);
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
    this.ready = false;
    try {
      await this.tcp.close();
    } catch (e) { /* 忽略 */ }
  }
}
