//
//  PrivacyRulePresets+EuropeEast.swift
//  osaurus / PrivacyFilter
//
//  Baltics, Central and Eastern Europe, the Balkans, Türkiye and the
//  Caucasus. See `PrivacyRulePresets.swift` for the tier contract.
//

import Foundation

extension PrivacyRulePresets {
    // MARK: Estonia / Latvia / Lithuania

    public static let eeIsikukood = Preset(
        id: "ee.isikukood",
        name: "Estonian isikukood",
        summary: "11-digit personal code (GYYMMDDSSSC); check digit verified.",
        pattern: #"\b[1-6]\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}\b"#,
        category: .accountNumber,
        sample: "37605030299",
        counterexample: "37605030298",
        regionCode: "EE",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.balticPersonalCode($0) }
    )

    public static let lvPersonasKods = Preset(
        id: "lv.personasKods",
        name: "Latvian personas kods",
        summary: "DDMMYY-XNNNC personal code (or new 32XXXXXXXXX form); check digit verified.",
        pattern: #"\b(?:(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}-?[0-2]\d{4}|32\d{9})\b"#,
        category: .accountNumber,
        sample: "010190-12349",
        counterexample: "010190-12348",
        regionCode: "LV",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.latvianPersonasKods($0) }
    )

    public static let ltAsmensKodas = Preset(
        id: "lt.asmensKodas",
        name: "Lithuanian asmens kodas",
        summary: "11-digit personal code (GYYMMDDSSSC); check digit verified.",
        pattern: #"\b[1-6]\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}\b"#,
        category: .accountNumber,
        sample: "39001011237",
        counterexample: "39001011236",
        regionCode: "LT",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.balticPersonalCode($0) }
    )

    // MARK: Poland

    public static let plPESEL = Preset(
        id: "pl.pesel",
        name: "Polish PESEL",
        summary: "11-digit national identification number; check digit verified.",
        pattern: #"\b\d{2}(?:[02468][1-9]|[13579][012])(?:0[1-9]|[12]\d|3[01])\d{5}\b"#,
        category: .accountNumber,
        sample: "44051401359",
        counterexample: "44051401358",
        regionCode: "PL",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.polishPESEL($0) }
    )

    public static let plNIP = Preset(
        id: "pl.nip",
        name: "Polish NIP",
        summary: "10-digit tax identification number written after “NIP”; check digit verified.",
        pattern: #"\bNIP"# + anchorGap
            + #"(\d{3}[- ]?\d{3}[- ]?\d{2}[- ]?\d{2}|\d{3}[- ]?\d{2}[- ]?\d{2}[- ]?\d{3})\b"#,
        category: .accountNumber,
        sample: "NIP: 123-456-78-83",
        counterexample: "NIP: 123-456-78-84",
        regionCode: "PL",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.polishNIP($0) }
    )

    public static let plDowod = Preset(
        id: "pl.dowod",
        name: "Polish dowód osobisty number",
        summary: "Three letters + six digits (ABA 212345); check digit verified.",
        pattern: #"\b[A-Z]{3}\s?\d{6}\b"#,
        category: .accountNumber,
        sample: "ABA 212345",
        counterexample: "ABA 312345",
        regionCode: "PL",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.polishDowodOsobisty($0) }
    )

    // MARK: Czechia / Slovakia

    public static let czRodneCislo = Preset(
        id: "cz.rodneCislo",
        name: "Czech rodné číslo",
        summary: "YYMMDD/XXXX birth number; divisible-by-11 check verified.",
        pattern: #"\b\d{2}(?:0[1-9]|1[0-2]|5[1-9]|6[0-2])(?:0[1-9]|[12]\d|3[01])\s?/?\s?\d{4}\b"#,
        category: .accountNumber,
        sample: "780123/3550",
        counterexample: "780123/3551",
        regionCode: "CZ",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.czechSlovakRodneCislo($0) }
    )

    public static let skRodneCislo = Preset(
        id: "sk.rodneCislo",
        name: "Slovak rodné číslo",
        summary: "YYMMDD/XXXX birth number; divisible-by-11 check verified.",
        pattern: #"\b\d{2}(?:0[1-9]|1[0-2]|5[1-9]|6[0-2])(?:0[1-9]|[12]\d|3[01])\s?/?\s?\d{4}\b"#,
        category: .accountNumber,
        sample: "855612/1233",
        counterexample: "855612/1234",
        regionCode: "SK",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.czechSlovakRodneCislo($0) }
    )

    // MARK: Hungary

    public static let huTAJ = Preset(
        id: "hu.taj",
        name: "Hungarian TAJ",
        summary: "9-digit social security number written after “TAJ”; check digit verified.",
        pattern: #"\bTAJ"# + anchorGap + #"(\d{3}[ -]?\d{3}[ -]?\d{3})\b"#,
        category: .accountNumber,
        sample: "TAJ: 123 456 788",
        counterexample: "TAJ: 123 456 789",
        regionCode: "HU",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.hungarianTAJ($0) }
    )

    public static let huSzemelyiSzam = Preset(
        id: "hu.szemelyiSzam",
        name: "Hungarian személyi szám",
        summary: "11-digit personal identification number (G-YYMMDD-SSSC); check digit verified.",
        pattern: #"\b[1-8][ -]?\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[ -]?\d{4}\b"#,
        category: .accountNumber,
        sample: "1 900101 1249",
        counterexample: "1 900101 1248",
        regionCode: "HU",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.hungarianSzemelyiSzam($0) }
    )

    public static let huAdoazonosito = Preset(
        id: "hu.adoazonosito",
        name: "Hungarian adóazonosító jel",
        summary: "10-digit tax identification number starting with 8; check digit verified.",
        pattern: #"\b8\d{9}\b"#,
        category: .accountNumber,
        sample: "8123456786",
        counterexample: "8123456787",
        regionCode: "HU",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.hungarianAdoazonosito($0) }
    )

    // MARK: Slovenia / Croatia / Serbia / Bosnia / Montenegro / North Macedonia

    public static let siEMSO = Preset(
        id: "si.emso",
        name: "Slovenian EMŠO",
        summary: "13-digit unique master citizen number (region code 50); check digit verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{3}5\d{5}\b"#,
        category: .accountNumber,
        sample: "0101990500003",
        counterexample: "0101990500004",
        regionCode: "SI",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.jmbg($0) }
    )

    public static let hrOIB = Preset(
        id: "hr.oib",
        name: "Croatian OIB",
        summary: "11-digit personal identification number; ISO 7064 check digit verified.",
        pattern: #"\b\d{11}\b"#,
        category: .accountNumber,
        sample: "69435151530",
        counterexample: "69435151531",
        regionCode: "HR",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.iso7064Mod11_10($0) }
    )

    public static let rsJMBG = Preset(
        id: "rs.jmbg",
        name: "Serbian JMBG",
        summary: "13-digit unique master citizen number (region 70–89); check digit verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{3}[78]\d{5}\b"#,
        category: .accountNumber,
        sample: "0101990710008",
        counterexample: "0101990710009",
        regionCode: "RS",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.jmbg($0) }
    )

    public static let baJMBG = Preset(
        id: "ba.jmbg",
        name: "Bosnian JMBG",
        summary: "13-digit unique master citizen number (region 10–19); check digit verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{3}1\d{5}\b"#,
        category: .accountNumber,
        sample: "0101990100005",
        counterexample: "0101990100006",
        regionCode: "BA",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.jmbg($0) }
    )

    public static let meJMBG = Preset(
        id: "me.jmbg",
        name: "Montenegrin JMBG",
        summary: "13-digit unique master citizen number (region 20–29); check digit verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{3}2\d{5}\b"#,
        category: .accountNumber,
        sample: "0101990210005",
        counterexample: "0101990210006",
        regionCode: "ME",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.jmbg($0) }
    )

    public static let mkJMBG = Preset(
        id: "mk.jmbg",
        name: "North Macedonian JMBG / EMBG",
        summary: "13-digit unique master citizen number (region 41–49); check digit verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{3}4[1-9]\d{4}\b"#,
        category: .accountNumber,
        sample: "0101990410004",
        counterexample: "0101990410005",
        regionCode: "MK",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.jmbg($0) }
    )

    // MARK: Albania

    public static let alNID = Preset(
        id: "al.nid",
        name: "Albanian NID",
        summary: "Letter + 8 digits + letter personal identification number (I05101999A).",
        pattern: #"\b[A-Z]\d{8}[A-Z]\b"#,
        category: .accountNumber,
        sample: "I05101999A",
        counterexample: "I0510199A",
        regionCode: "AL",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Bulgaria

    public static let bgEGN = Preset(
        id: "bg.egn",
        name: "Bulgarian EGN",
        summary: "10-digit unified civil number; check digit verified.",
        pattern: #"\b\d{2}(?:[0-4]\d|5[0-2])(?:0[1-9]|[12]\d|3[01])\d{4}\b"#,
        category: .accountNumber,
        sample: "7523169263",
        counterexample: "7523169264",
        regionCode: "BG",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.bulgarianEGN($0) }
    )

    // MARK: Romania

    public static let roCNP = Preset(
        id: "ro.cnp",
        name: "Romanian CNP",
        summary: "13-digit cod numeric personal; check digit verified.",
        pattern: #"\b[1-9]\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|[1-4]\d|5[12])\d{4}\b"#,
        category: .accountNumber,
        sample: "1800101221144",
        counterexample: "1800101221145",
        regionCode: "RO",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.romanianCNP($0) }
    )

    // MARK: Moldova

    public static let mdIDNP = Preset(
        id: "md.idnp",
        name: "Moldovan IDNP",
        summary: "13-digit personal number written after “IDNP”; check digit verified.",
        pattern: #"\bIDNP"# + anchorGap + #"(\d{13})\b"#,
        category: .accountNumber,
        sample: "IDNP: 2000123456788",
        counterexample: "IDNP: 2000123456789",
        regionCode: "MD",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.moldovanIDNP($0) }
    )

    // MARK: Ukraine

    public static let uaRNTRC = Preset(
        id: "ua.rntrc",
        name: "Ukrainian RNTRC / ІПН",
        summary: "10-digit taxpayer number written after “РНОКПП”, “ІПН” or “RNTRC”; check digit verified.",
        pattern: #"(?i)\b(?:РНОКПП|ІПН|ІНН|RNTRC|RNOKPP|IPN)"# + anchorGap + #"(\d{10})\b"#,
        category: .accountNumber,
        sample: "ІПН: 3012345670",
        counterexample: "ІПН: 3012345671",
        regionCode: "UA",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.ukrainianRNTRC($0) }
    )

    public static let uaPassport = Preset(
        id: "ua.passport",
        name: "Ukrainian passport number",
        summary:
            "Two Cyrillic letters + six digits, or the 9-digit ID-card number, written after “паспорт” / “passport”.",
        pattern: #"(?i)\b(?:паспорт|passport)"# + anchorGap + #"([А-ЯІЇЄ]{2}\s?\d{6}|\d{9})\b"#,
        category: .accountNumber,
        sample: "Паспорт: АА 123456",
        counterexample: "Паспорт: АА",
        regionCode: "UA",
        kind: .passport,
        tier: .anchored
    )

    // MARK: Belarus

    public static let byPersonalNumber = Preset(
        id: "by.personalNumber",
        name: "Belarusian personal number",
        summary: "14-character identification number (3120575A001PB4).",
        pattern: #"\b\d{7}[ABCKEMH]\d{3}[A-Z]{2}\d\b"#,
        category: .accountNumber,
        sample: "3120575A001PB4",
        counterexample: "3120575A001PB",
        regionCode: "BY",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Russia

    public static let ruSNILS = Preset(
        id: "ru.snils",
        name: "Russian SNILS",
        summary: "XXX-XXX-XXX XX pension insurance number; check digits verified.",
        pattern: #"\b\d{3}-\d{3}-\d{3}[ -]?\d{2}\b"#,
        category: .accountNumber,
        sample: "112-233-445 95",
        counterexample: "112-233-445 96",
        regionCode: "RU",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.russianSNILS($0) }
    )

    public static let ruINN = Preset(
        id: "ru.inn",
        name: "Russian INN",
        summary: "10- or 12-digit taxpayer number written after “ИНН” / “INN”; check digits verified.",
        pattern: #"(?i)\b(?:ИНН|INN)"# + anchorGap + #"(\d{12}|\d{10})\b"#,
        category: .accountNumber,
        sample: "ИНН: 7701234560",
        counterexample: "ИНН: 7701234561",
        regionCode: "RU",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.russianINN($0) }
    )

    public static let ruPassport = Preset(
        id: "ru.passport",
        name: "Russian internal passport",
        summary: "Series + number (XX XX XXXXXX) written after “паспорт” / “passport”.",
        pattern: #"(?i)\b(?:паспорт|passport)(?:\s+(?:серия|series))?"# + anchorGap + #"(\d{2}\s?\d{2}\s?\d{6})\b"#,
        category: .accountNumber,
        sample: "Паспорт: 45 04 123456",
        counterexample: "Паспорт: 45 04",
        regionCode: "RU",
        kind: .passport,
        tier: .anchored
    )

    // MARK: Türkiye

    public static let trTCKimlik = Preset(
        id: "tr.tcKimlik",
        name: "Turkish T.C. Kimlik No",
        summary: "11-digit national identity number; both check digits verified.",
        pattern: #"\b[1-9]\d{10}\b"#,
        category: .accountNumber,
        sample: "10000000146",
        counterexample: "10000000147",
        regionCode: "TR",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.turkishTCKimlik($0) }
    )

    // MARK: Georgia / Armenia / Azerbaijan

    public static let gePersonalNumber = Preset(
        id: "ge.personalNumber",
        name: "Georgian personal number",
        summary: "11-digit personal number written after “personal number” / “პირადი ნომერი”.",
        pattern: #"(?i)\b(?:personal\s+(?:number|no\.?|id)|პირადი\s+ნომერი)"# + anchorGap + #"(\d{11})\b"#,
        category: .accountNumber,
        sample: "Personal number: 01001012345",
        counterexample: "Personal number: 0100",
        regionCode: "GE",
        kind: .nationalID,
        tier: .anchored
    )

    public static let amSocialCard = Preset(
        id: "am.socialCard",
        name: "Armenian social card number",
        summary: "10-digit public services number written after “social card” / “ՀԾՀ”.",
        pattern: #"(?i)\b(?:social\s+(?:card|services)\s+(?:number|no\.?)|ՀԾՀ|public\s+services\s+number)"# + anchorGap
            + #"(\d{10})\b"#,
        category: .accountNumber,
        sample: "Social card number: 1234567890",
        counterexample: "Social card number: 1234",
        regionCode: "AM",
        kind: .nationalID,
        tier: .anchored
    )

    public static let azFIN = Preset(
        id: "az.fin",
        name: "Azerbaijani FIN",
        summary: "7-character identification number written after “FIN”.",
        pattern: #"\bFIN"# + anchorGap + #"([A-Z0-9]{7})\b"#,
        category: .accountNumber,
        sample: "FIN: 1ABC2D3",
        counterexample: "FIN: 1ABC",
        regionCode: "AZ",
        kind: .nationalID,
        tier: .anchored
    )

    static let europeEast: [Preset] = [
        eeIsikukood, lvPersonasKods, ltAsmensKodas,
        plPESEL, plNIP, plDowod,
        czRodneCislo, skRodneCislo,
        huTAJ, huSzemelyiSzam, huAdoazonosito,
        siEMSO, hrOIB, rsJMBG, baJMBG, meJMBG, mkJMBG,
        alNID,
        bgEGN,
        roCNP,
        mdIDNP,
        uaRNTRC, uaPassport,
        byPersonalNumber,
        ruSNILS, ruINN, ruPassport,
        trTCKimlik,
        gePersonalNumber, amSocialCard, azFIN,
    ]
}
