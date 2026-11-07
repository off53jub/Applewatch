import Photos
import SwiftUI
import UIKit

/// その会話の時間（と前後5分）に撮った写真を、記録の日の画面で会話の横に小さく並べる（2026-11-07）。
///
/// - 写真は PhotoKit で、この iPhone の中だけで読む。外には送らない・記録にも保存しない（画面を開いたときに、その場で探して見せるだけ）。
/// - 写真の許可が無ければ何も出さない。許可を求めるのは設定の画面からだけ（記録の画面を開いても、許可の画面は出さない）。
/// - 「選んだ写真だけ」の許可なら、選んだ写真の中から出す。
enum DayPhotos {
    /// 設定「会話の横に写真を出す」（初めはオン。許可が無ければ、オンでも出さない）
    static let enabledKey = "dayPhotosOn"
    /// 会話の前後にこれだけ広げて探す
    static let margin: TimeInterval = 5 * 60
    /// 1つの会話に並べる数の上限
    static let limit = 24

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 写真を読んでよいか（すべて・選んだ写真だけ）
    static var isAllowed: Bool { allowed(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    static func allowed(_ status: PHAuthorizationStatus) -> Bool { status == .authorized || status == .limited }

    /// 許可を求められるか（Info.plist に NSPhotoLibraryUsageDescription がある。無いまま求めると iOS がアプリを終わらせる）
    static var canAsk: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String).map { !$0.isEmpty } ?? false
    }

    /// 出すか（設定がオンで、許可がある）
    static var isShown: Bool { isOn && isAllowed }

    /// 探す時間（会話の始まりの5分前から、終わりの5分後まで）
    static func window(start: Date, end: Date) -> ClosedRange<Date> {
        let from = start.addingTimeInterval(-margin)
        let to = max(end, start).addingTimeInterval(margin)
        return from...to
    }

    /// 1日の会話それぞれの探す時間（同じ始まりの会話は1つ）
    static func windows(_ conversations: [(start: Date, end: Date)]) -> [Date: ClosedRange<Date>] {
        var result: [Date: ClosedRange<Date>] = [:]
        for c in conversations { result[c.start] = window(start: c.start, end: c.end) }
        return result
    }

    /// その時間に撮った写真（古い順。動画・スクリーンショットは除く）。許可が無ければ空
    @MainActor
    static func assets(in range: ClosedRange<Date>, limit: Int = DayPhotos.limit) -> [PHAsset] {
        guard isAllowed else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
                                        PHAssetMediaType.image.rawValue, range.lowerBound as NSDate, range.upperBound as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = limit * 2
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, stop in
            if asset.mediaSubtypes.contains(.photoScreenshot) { return }
            assets.append(asset)
            if assets.count >= limit { stop.pointee = true }
        }
        return assets
    }

    /// 写真の画像（小さい写真は端末の中にあるものだけ。大きく見るときは、iCloud の写真も取ってくる。
    /// iCloud から取ってくるのは、自分の写真をこの iPhone に読むだけで、どこにも送らない）
    nonisolated static func image(_ asset: PHAsset, size: CGSize, fit: Bool = false, network: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        options.isSynchronous = false
        let once = Once()
        return await withCheckedContinuation { continuation in
            // highQualityFormat なので答えは1回だけのはずだが、念のため初めの1回だけ受け取る
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: fit ? .aspectFit : .aspectFill,
                                                  options: options) { image, _ in
                guard once.first() else { return }
                continuation.resume(returning: image)
            }
        }
    }

    /// 初めの1回だけ true
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }
}

/// 並べる写真1枚
struct DayPhoto: Identifiable {
    let id: String
    let asset: PHAsset
    let taken: Date?
    let thumbnail: UIImage
}

/// 会話の横に並べる写真の列。押すと大きく見る
struct ConversationPhotoStrip: View {
    let photos: [DayPhoto]
    @State private var shown: DayPhoto?

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(photos) { photo in
                    Button {
                        shown = photo
                    } label: {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    // List の行の中でも、押した写真だけが反応するように
                    .buttonStyle(.borderless)
                    .accessibilityLabel(photo.taken.map { "\(Self.clock.string(from: $0)) の写真" } ?? "写真")
                }
            }
        }
        .sheet(item: $shown) { photo in
            PhotoPager(photos: photos, first: photo.id)
        }
    }
}

/// 写真を大きく見る（横に送ると、同じ会話のほかの写真）
private struct PhotoPager: View {
    let photos: [DayPhoto]
    @State private var selection: String
    @Environment(\.dismiss) private var dismiss

    init(photos: [DayPhoto], first: String) {
        self.photos = photos
        _selection = State(initialValue: first)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(photos) { photo in
                    LargePhoto(photo: photo).tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        guard let taken = photos.first(where: { $0.id == selection })?.taken else { return "写真" }
        return taken.formatted(date: .omitted, time: .shortened)
    }
}

private struct LargePhoto: View {
    let photo: DayPhoto
    @State private var image: UIImage?

    var body: some View {
        Image(uiImage: image ?? photo.thumbnail)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: photo.id) {
                image = await DayPhotos.image(photo.asset, size: CGSize(width: 2048, height: 2048), fit: true, network: true)
            }
    }
}

extension DayPhotos {
    /// 会話ごとの写真（始まりの時刻ごと）。許可が無い・設定がオフなら空
    @MainActor
    static func load(_ conversations: [(start: Date, end: Date)], scale: CGFloat) async -> [Date: [DayPhoto]] {
        guard isShown else { return [:] }
        var result: [Date: [DayPhoto]] = [:]
        let side = 56 * max(1, scale)
        for (start, range) in windows(conversations) {
            var photos: [DayPhoto] = []
            for asset in assets(in: range) {
                if Task.isCancelled { return result }
                guard let thumbnail = await image(asset, size: CGSize(width: side, height: side), network: false) else { continue }
                photos.append(DayPhoto(id: asset.localIdentifier, asset: asset, taken: asset.creationDate, thumbnail: thumbnail))
            }
            if !photos.isEmpty { result[start] = photos }
        }
        return result
    }
}

// MARK: - 設定の画面

/// 設定の「写真」。会話の横に写真を出すか・写真の許可
struct DayPhotoSettingsSection: View {
    @State private var on = DayPhotos.isOn
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        Section {
            Toggle("会話の横に写真を出す", isOn: $on)
                .onChange(of: on) { _, value in DayPhotos.isOn = value }
            LabeledContent("写真の許可", value: statusText)
            if status == .notDetermined, !DayPhotos.canAsk {
                // Info.plist に写真の説明が無い版で許可を求めると、アプリが落ちる
                Text("この版では、まだ写真の許可を求められません（次の版から）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == .notDetermined {
                Button("写真の許可を求める") {
                    Task {
                        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    }
                }
            } else if status == .denied || status == .restricted || status == .limited {
                Button(status == .limited ? "選ぶ写真を変える（設定アプリ）" : "設定アプリで許可する") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("写真")
        } footer: {
            Text("記録の日の画面で、それぞれの会話の時間（と前後5分）に撮った写真を、会話の横に小さく並べます。押すと大きく見られます。写真はこの iPhone の中で、画面を開いたときに探して見せるだけです。ほかへは送らず、記録にも保存しません。許可が無いときは出しません。")
        }
        .onAppear { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    }

    private var statusText: String {
        switch status {
        case .authorized: "すべての写真"
        case .limited: "選んだ写真だけ"
        case .denied: "許可していない"
        case .restricted: "使えない（制限されている）"
        case .notDetermined: "まだ聞いていない"
        @unknown default: "分からない"
        }
    }
}
