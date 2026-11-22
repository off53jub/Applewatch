import SwiftUI

// 今日の画面の下の帯（s22 の 見21。2026-11-22）。片手で届くように、上にあった操作（使い方・確かめ待ち）を下の帯へ。
// 録る・印・会議・ライブ字幕の 1 行は前から下にある（ContentView.swift の recordBar）。歯車（設定）は、どのタブでも右上のまま。

/// 下の帯の上の段: 確かめ待ち（あるときだけ）と使い方
struct TodayReachRow: View {
    @Binding var showHelp: Bool
    /// 文字がとても大きいときは「1 枚 3 秒」を外し、文字を折り返す（文字最大で横にはみ出していた）
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let waiting = S20Book.shared.waitingCount
        HStack(spacing: LL.Space.s) {
            if waiting > 0 {
                NavigationLink {
                    ReviewDeckView()
                } label: {
                    HStack(spacing: LL.Space.s) {
                        Image(systemName: "hand.raised")
                        if typeSize.isAccessibilitySize {
                            Text("確かめ待ち \(LLNumber.count(waiting)) 件").font(.callout.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("確かめ待ち").font(.callout.weight(.semibold))
                            Text(LLNumber.count(waiting)).font(.callout.weight(.bold)).monospacedDigit()
                            Text("件・1 枚 3 秒").font(.caption).foregroundStyle(LL.dim)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, LL.Space.m)
                    .padding(.vertical, typeSize.isAccessibilitySize ? LL.Space.s : 0)
                    .frame(minHeight: 44)
                    .background(LL.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LL.accent, lineWidth: LL.Stroke.thin))
                }
                .accessibilityLabel("確かめ待ち \(waiting) 件。押すと答えるカードを開きます")
            } else {
                Spacer(minLength: 0)
            }
            Button {
                showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .tint(LL.dim)
            .accessibilityLabel("使い方")
        }
    }
}
