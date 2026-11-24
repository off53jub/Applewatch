import AppIntents
import SwiftUI
import WidgetKit

/// コントロールセンターの「録り方の組を替える」（2026-11-25。s26 の 軽3。動きは Shared/Intents/S26UIntents.swift）
struct S26UPresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.off53jub.lifelog.control.preset") {
            ControlWidgetButton(action: S26UNextPresetIntent()) {
                Label("LifeLog 録り方", systemImage: "dial.medium")
            }
        }
        .displayName("録り方の組を替える")
        .description("電池優先・早さ優先・精度優先を順に替えます。LifeLog を開かずに動きます。")
    }
}
