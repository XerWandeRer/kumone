# macOS 输出设备与 AirPlay

## 为什么 `AVRoutePickerView` 在 macOS 上是死的

`RoutePickerButton` 原本在两个平台都用 `AVRoutePickerView`。这个视图路由的是
**AVFoundation 的播放对象**（`AVPlayer` / `AVSampleBufferAudioRenderer`）。
双 deck 引擎（`PlaybackEngine`，`AVAudioEngine` 图）落地之后，进程里已经没有
AVPlayer 了 —— 于是 macOS 上点开这个按钮、选中 AirPlay 音箱，什么也不会发生。
用户的判断（"现在似乎是完全不 work 的"）是准确的。

iOS 不同：那里的路由是 `AVAudioSession` 的事，而 `AVAudioEngine` 正是通过
session 渲染的，所以系统 picker 仍然有效 —— iOS 保留原实现。

## macOS 的做法

CoreAudio 设备层：

- 枚举 `kAudioHardwarePropertyDevices`，保留有输出通道的设备
  （`AudioOutputDevices.current()`）。
- 系统暴露出来的 AirPlay 接收端在这个列表里就是一台普通设备，
  `kAudioDevicePropertyTransportType` 为 `kAudioDeviceTransportTypeAirPlay`
  （'airp'），菜单里排在最后并标注 `(AirPlay)`。
- 选中后把引擎输出单元指过去：`engine.outputNode.auAudioUnit.setDeviceID(_:)`
  （即 `kAudioOutputUnitProperty_CurrentDevice` 的类型化形式），
  见 `PlaybackEngine.setOutputDevice(_:)`。

**这里不做 AirPlay 发现。** CoreAudio 只在 macOS 自己把接收端具体化之后
（用户在"声音"设置 / 控制中心里选过，或系统另行暴露）才发布这台设备。
撰写本文时开发机上的输出设备是 `OF27UT Pro`（`hdmi`）、`External Headphones`
与 `Mac mini Speakers`（均为 `bltn`），没有任何 `airp` 设备 —— 因为当时没有
选过 AirPlay 接收端。所以菜单里永远保留 **系统默认** 一项：它跟随系统路由，
控制中心里选的 AirPlay 也就是从这条路进来的。

## 切换设备时发生了什么

输出设备只能在输出单元停止时更换，而更换会像硬件变化一样清空每个 player
node 的调度。因此复用同一条恢复路径：`handleConfigurationChange()`
重建三条链、重装 `mainMixerNode` 上的采样 tap（AudioSpectrum）、
把每个 deck 从缓存位置重新排程。切换同样跑在引擎的串行 `queue` 上，与它自己
触发的 `AVAudioEngineConfigurationChange` 天然串行化，两条路径互不阻塞。

设备消失（AirPlay 音箱中途走远）时回落到系统默认并弹 toast，而不是留在一台
死设备上变成静音。选择以 UID 持久化（`settings.outputDeviceUID`），
数值型 `AudioDeviceID` 跨启动不稳定，不能存。

## 已知问题：AirPlay 延迟与 seam 感知时刻（v1 不补偿）

AirPlay 设备有很大的输出缓冲（典型 ~2 秒）。播放位置的计算读的是 player node
的时钟，位于该缓冲的**上游**，所以：

- 过渡点在**流里**的位置仍然正确，衔接本身不会错位、不会双响；
- 但听众听到的整体被延后，**用户感知到的 seam 时刻会偏移一个 AirPlay 延迟**；
- 调试面板的倒计时会"提前"归零 —— 它报的是流的时刻，不是空气里的时刻。

v1 不做补偿：补偿需要把输出延迟接进位置数学，而这个延迟随设备与网络变化，
估错会让本地播放也一起错位。先记录，不猜。
