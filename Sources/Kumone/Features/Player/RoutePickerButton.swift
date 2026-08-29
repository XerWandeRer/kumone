import AVKit
import SwiftUI

/// The output-route control in the transport row.
///
/// Two different things behind one name, because the two platforms route
/// audio in genuinely different ways:
///
/// - **iOS** keeps the system picker (`AVRoutePickerView`). Routing there is
///   an `AVAudioSession` matter, and the session is what an `AVAudioEngine`
///   renders through — so picking an AirPlay route in the system sheet moves
///   this app's audio, and the picker is the right (and only sanctioned) UI.
/// - **macOS** shows an in-app output-device menu (`OutputDeviceMenu`).
///   `AVRoutePickerView` on the Mac routes an `AVPlayer` /
///   `AVSampleBufferAudioRenderer`; Kumone's playback is an AVAudioEngine
///   graph and has had no AVPlayer since the dual-deck engine landed, so the
///   button here was inert — selecting an AirPlay speaker did nothing at all.
///   The Mac equivalent is choosing the CoreAudio output device the engine
///   renders to; see `AudioOutputDevices`.
struct RoutePickerButton: View {
    var diameter: CGFloat = 40
    var glyphSize: CGFloat = 15
    /// iOS only: bumping this opens the system route sheet programmatically.
    var request = 0
    /// White-on-glass (now-playing) vs. accent-aware (player bar).
    var tint: Color = .white.opacity(0.8)
    var background: Color = .white.opacity(0.1)

    var body: some View {
        #if os(macOS)
        OutputDeviceMenu(
            diameter: diameter, glyphSize: glyphSize, tint: tint, background: background)
        #else
        RoutePickerRepresentable(
            tint: PlatformColor(tint), glyphSize: glyphSize, request: request
        )
            .frame(width: diameter, height: diameter)
            .background(background, in: Circle())
            .help("AirPlay")
        #endif
    }
}

#if os(iOS)
private struct RoutePickerRepresentable: UIViewRepresentable {
    let tint: UIColor
    let glyphSize: CGFloat
    let request: Int

    final class Coordinator {
        var request: Int
        init(request: Int) { self.request = request }
    }

    func makeCoordinator() -> Coordinator { Coordinator(request: request) }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = tint
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false // audio routing, not screen mirroring
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        guard request != context.coordinator.request else { return }
        context.coordinator.request = request
        DispatchQueue.main.async {
            view.subviews.compactMap { $0 as? UIButton }.first?
                .sendActions(for: .touchUpInside)
        }
    }
}
#endif

#if os(macOS)
/// macOS output picker: 系统默认 plus every CoreAudio output device, with
/// AirPlay endpoints grouped last and marked with the AirPlay glyph.
///
/// "系统默认" is not a device — it follows whatever macOS is routing to, which
/// is also how an AirPlay receiver picked in Control Centre reaches Kumone
/// even when no 'airp' device is enumerated here.
struct OutputDeviceMenu: View {
    var diameter: CGFloat = 40
    var glyphSize: CGFloat = 15
    var tint: Color = .white.opacity(0.8)
    var background: Color = .white.opacity(0.1)

    @ObservedObject private var controller = AudioOutputController.shared

    private var isRouted: Bool { controller.isRoutedAway }

    var body: some View {
        Menu {
            Button {
                controller.select(.systemDefault)
            } label: {
                Label(
                    "系统默认",
                    systemImage: controller.selection == .systemDefault
                        ? "checkmark" : "speaker.wave.2")
            }
            if !controller.devices.isEmpty {
                Divider()
            }
            ForEach(controller.devices) { device in
                Button {
                    controller.select(.device(uid: device.uid))
                } label: {
                    Label(
                        device.isAirPlay ? "\(device.name) (AirPlay)" : device.name,
                        systemImage: controller.selection == .device(uid: device.uid)
                            ? "checkmark" : device.symbolName)
                }
            }
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(isRouted ? Theme.accent : tint)
                .frame(width: diameter, height: diameter)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: diameter, height: diameter)
        .help("输出设备：\(controller.currentDisplayName)")
    }
}
#endif
