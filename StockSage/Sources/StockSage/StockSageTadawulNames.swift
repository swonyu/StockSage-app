import Foundation

// MARK: - Tadawul bilingual company names (owner request, 2026-07-16)
//
// Tadawul tickers are NUMERIC (2222.SR, 1120.SR …) — unreadable at a glance. This table maps
// every `.SR` symbol in the analyzed universe to its company name in English AND Arabic so the
// board/cards/sheet can show "2222.SR · Aramco · أرامكو" instead of a bare number.
//
// Curated by hand for the 29 `.SR` names in `StockSageUniverse.worldwide` (28 listings + TASI).
// These are Tadawul's blue-chip listings; names are the companies' own English/Arabic brandings
// as listed on the Saudi Exchange. DISPLAY-ONLY: nothing keys on these strings — every engine
// path keys on the symbol. An unknown `.SR` symbol returns nil (never a guessed name), so a
// future universe addition shows its plain symbol until this table is extended.

enum StockSageTadawulNames {

    struct BilingualName: Sendable, Equatable {
        let english: String
        let arabic: String
    }

    /// nil for non-Tadawul symbols and for any `.SR` symbol not in the curated table —
    /// the display falls back to the plain symbol, never a fabricated name.
    nonisolated static func name(for symbol: String) -> BilingualName? {
        table[symbol.uppercased()]
    }

    /// One-line display suffix: "Aramco · أرامكو" (nil when unknown). The caller keeps the
    /// symbol as the PRIMARY identifier — engine keys, journals, and broker tickets all speak
    /// symbols; the name is a reading aid, not an identity.
    nonisolated static func displayLine(for symbol: String) -> String? {
        guard let n = name(for: symbol) else { return nil }
        return "\(n.english) · \(n.arabic)"
    }

    private nonisolated static let table: [String: BilingualName] = [
        // Banks — البنوك
        "1010.SR": .init(english: "Riyad Bank", arabic: "بنك الرياض"),
        "1060.SR": .init(english: "Saudi Awwal Bank (SAB)", arabic: "البنك السعودي الأول"),
        "1080.SR": .init(english: "Arab National Bank", arabic: "البنك العربي الوطني"),
        "1120.SR": .init(english: "Al Rajhi Bank", arabic: "مصرف الراجحي"),
        "1140.SR": .init(english: "Bank Albilad", arabic: "بنك البلاد"),
        "1150.SR": .init(english: "Alinma Bank", arabic: "مصرف الإنماء"),
        "1180.SR": .init(english: "Saudi National Bank (SNB)", arabic: "البنك الأهلي السعودي"),
        // Energy & materials — الطاقة والمواد
        "2222.SR": .init(english: "Saudi Aramco", arabic: "أرامكو السعودية"),
        "2010.SR": .init(english: "SABIC", arabic: "سابك"),
        "2020.SR": .init(english: "SABIC Agri-Nutrients", arabic: "سابك للمغذيات الزراعية"),
        "1211.SR": .init(english: "Ma'aden", arabic: "معادن"),
        "2290.SR": .init(english: "Yansab", arabic: "ينساب"),
        "2330.SR": .init(english: "Advanced Petrochemical", arabic: "المتقدمة للبتروكيماويات"),
        "2350.SR": .init(english: "Saudi Kayan", arabic: "كيان السعودية"),
        "2380.SR": .init(english: "Petro Rabigh", arabic: "بترو رابغ"),
        "3030.SR": .init(english: "Saudi Cement", arabic: "أسمنت السعودية"),
        // Telecom & utilities — الاتصالات والمرافق
        "7010.SR": .init(english: "stc (Saudi Telecom)", arabic: "إس تي سي — الاتصالات السعودية"),
        "7020.SR": .init(english: "Mobily", arabic: "موبايلي — اتحاد اتصالات"),
        "7030.SR": .init(english: "Zain KSA", arabic: "زين السعودية"),
        "5110.SR": .init(english: "Saudi Electricity", arabic: "الشركة السعودية للكهرباء"),
        // Consumer, health, insurance, transport — الاستهلاكية والصحة والتأمين والنقل
        "2280.SR": .init(english: "Almarai", arabic: "المراعي"),
        "6010.SR": .init(english: "NADEC", arabic: "نادك"),
        "4190.SR": .init(english: "Jarir Marketing", arabic: "جرير"),
        "4013.SR": .init(english: "Dr. Sulaiman Al Habib", arabic: "مجموعة د. سليمان الحبيب الطبية"),
        "4014.SR": .init(english: "Dallah Healthcare", arabic: "دلة الصحية"),
        "8010.SR": .init(english: "Tawuniya", arabic: "التعاونية للتأمين"),
        "8210.SR": .init(english: "Bupa Arabia", arabic: "بوبا العربية"),
        "4030.SR": .init(english: "Bahri", arabic: "البحري"),
        // Index — المؤشر
        "^TASI.SR": .init(english: "TASI — All Share Index", arabic: "المؤشر العام تاسي"),
    ]
}
