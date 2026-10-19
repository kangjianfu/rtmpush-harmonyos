# Changelog

## 0.2.1

性能与弱网优化：

- **弱网背压**：发送队列按字节计数，超过阈值（默认 2MB，`setMaxPendingBytes()` 可调）时按 GOP 丢视频帧（丢一帧后持续到下个关键帧，防花屏），拥塞时音频同样丢弃；关键帧是恢复点，始终发送；新增 `getPendingBytes()`/`getDropStats()` 观测接口
- **编码输出零拷贝**：native 编码帧经 `napi_create_external_arraybuffer` 直通 ArkTS，每帧少一次完整 memcpy
- **发送范围修正**：`subarray` 数据不再误发整个底层 buffer（简单握手的 C2 会多发字节）；完整 buffer 仍零拷贝
- **H.265 Enhanced RTMP 封装修正**：byte0 按规范使用 IsExHeader 位（0x80）；此前误用 0x08，导致标准服务器与 rtmpull 拉流端都会丢弃 H.265 帧
- **编码器输入 buffer 槽缓存**：相机帧间隙不再造成编码器输入饿死；超输入 buffer 的 NV21 帧整帧丢弃（原截断会花屏）
- **弱网音频丢块保持时间轴**：PCM 队列丢块时同步推进 pts，避免音画逐渐失步
- native tsfn 生命周期与竞态修复（每次推流会话不再泄漏 threadsafe function）
- RtmpClient：旧 socket 迟到数据不再污染重连后的新连接；`rtmps://` 明确报错；无路径 URL 解析修正
- demo：状态行显示发送积压 KB

## 0.2.0

修复与协议完善（建议所有用户升级）：

- **H.265 修复**：Enhanced RTMP 视频头改为规范的单字节布局（`FrameType | 0x08 | PacketType`），修掉序列头/媒体帧中多出的错位字节；`onMetaData` 的 `videocodecid` 改用 FourCC `hvc1` 数值；`connect` 声明 `fourCcList` 能力
- **digest（FP9）握手重写**：与 librtmp 算法对齐（digest 偏移 = 4 字节求和 % 728、C1/S1 校验用 30/36 字节 key、C2 用完整 62/68 字节密钥且长度修正为 1536 字节）
- **时间戳**：视频 pts 从采集侧经编码器透传到 RTMP 层，音/视频各自以首帧归零；`sendVideoFrame`/`sendAudioFrame` 接受毫秒 pts
- **稳定性**：修复 `pushFrame` 在编码器未运行时的 native 崩溃（nullptr 返回值）；`stopEncoder`/`stopAudioEncoder` 不再持锁销毁编码器（消除与回调线程的死锁风险）；surface 模式释放 `OHNativeWindow`
- **健壮性**：`RtmpClient` 实例可重复 `connect()`（断线重连无需换实例）；annex-b 拆分兼容 3 字节起始码 `00 00 01`；响应 PingRequest、按 Window Acknowledgement Size 回 ACK；`_error`/publish 被拒通过新增的 `onError` 回调上报；demo buffer 模式修正为 NV21（`YCRCB_420_SP`）
- 编码器输出回调在无法投递时正确归还 buffer；重复创建编码器时给出明确报错

## 0.1.0

首个公开版本：H.264/H.265 + AAC 推流、surface 零拷贝、动态码率、demo App。
