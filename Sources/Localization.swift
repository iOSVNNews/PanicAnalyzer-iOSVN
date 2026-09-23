//  Localization.swift
//  Tiếng Việt / English / 中文 cho các thông báo từ phía native.
//  Ngôn ngữ do màn Cài đặt trong app chọn (lưu ở UserDefaults), mặc định theo iPhone.

import Foundation

enum Loc {
    static let languageKey = "appLanguage"
    static let supported = ["vi", "en", "zh"]

    static var lang: String {
        if let saved = UserDefaults.standard.string(forKey: languageKey), supported.contains(saved) {
            return saved
        }
        let preferred = (Locale.preferredLanguages.first ?? "vi").lowercased()
        if preferred.hasPrefix("zh") { return "zh" }
        if preferred.hasPrefix("vi") { return "vi" }
        return "en"
    }

    static func setLanguage(_ value: String) {
        guard supported.contains(value) else { return }
        UserDefaults.standard.set(value, forKey: languageKey)
    }

    /// Picks the string for the current language.
    static func s(_ vi: String, _ en: String, _ zh: String) -> String {
        switch lang {
        case "en": return en
        case "zh": return zh
        default: return vi
        }
    }
}
