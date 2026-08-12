import Foundation
import AVFoundation

/// "Mẹo" giúp app tiếp tục chạy khi bị đưa xuống nền (thoát ra ngoài nhưng không vuốt tắt hẳn),
/// bằng cách phát 1 đoạn âm thanh im lặng lặp vô hạn. iOS cho phép app đăng ký chế độ nền
/// "Audio" chạy KHÔNG GIỚI HẠN THỜI GIAN miễn là app thực sự đang phát âm thanh — đây là kỹ
/// thuật nhiều app gọi điện nội bộ / walkie-talkie dùng để giữ kết nối mạng sống khi người
/// dùng rời app. Cần bật key UIBackgroundModes = ["audio"] trong Info.plist (đã thêm sẵn).
///
/// GIỚI HẠN THẬT SỰ (không có cách nào lách được, cần nói rõ với người dùng):
/// - CHỈ có tác dụng khi app bị đưa xuống nền bình thường (bấm Home / chuyển app khác).
///   Nếu người dùng vuốt tắt hẳn app khỏi App Switcher, iOS luôn kill tiến trình ngay lập tức —
///   không app nào (kể cả app chính chủ) sống lại được sau hành động đó.
/// - iOS vẫn có quyền tắt app nếu máy quá nóng, sắp hết pin, hoặc cần giải phóng RAM gấp,
///   dù trường hợp này hiếm khi xảy ra với app đang phát âm thanh.
/// - Chạy nền lâu sẽ tốn pin hơn bình thường vì loa/audio session luôn ở trạng thái hoạt động —
///   chỉ nên bật khi thực sự đang kết nối tới server, và tắt ngay khi quay lại app hoặc ngắt kết nối.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let url = try Self.silentAudioFileURL()
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.02 // gần như im lặng nhưng không phải 0 tuyệt đối, tránh iOS coi là "không phát gì"
            p.prepareToPlay()
            p.play()
            player = p
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    /// Tạo (1 lần duy nhất, cache lại) 1 file WAV im lặng ~1 giây trong thư mục tạm, dùng để loop.
    private static func silentAudioFileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chatapp_silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 8000
        let seconds: UInt32 = 1
        let numSamples = sampleRate * seconds // 8-bit PCM mono, 1 byte/sample
        let dataSize = numSamples

        var data = Data()
        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)              // kích thước sub-chunk fmt
        appendLE16(1)                // PCM
        appendLE16(1)                // 1 kênh (mono)
        appendLE32(sampleRate)
        appendLE32(sampleRate)       // byteRate = sampleRate * blockAlign(1) cho 8-bit mono
        appendLE16(1)                // blockAlign
        appendLE16(8)                // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendLE32(dataSize)
        data.append(Data(repeating: 128, count: Int(dataSize))) // 128 = mức 0 của PCM 8-bit unsigned (im lặng)

        try data.write(to: url)
        return url
    }
}
