//
//  PrivacyRulePresets+AsiaPacific.swift
//  osaurus / PrivacyFilter
//
//  South, East and Southeast Asia, Oceania and Central Asia. See
//  `PrivacyRulePresets.swift` for the tier contract.
//

import Foundation

extension PrivacyRulePresets {
    // MARK: India

    public static let inAadhaar = Preset(
        id: "in.aadhaar",
        name: "Indian Aadhaar number",
        summary: "12-digit Aadhaar (XXXX XXXX XXXX); Verhoeff check digit verified.",
        pattern: #"\b[2-9]\d{3}[ -]?\d{4}[ -]?\d{4}\b"#,
        category: .accountNumber,
        sample: "2345 6789 0124",
        counterexample: "2345 6789 0125",
        regionCode: "IN",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.verhoeff($0) }
    )

    public static let inPAN = Preset(
        id: "in.pan",
        name: "Indian PAN",
        summary: "10-character Permanent Account Number (ABCDE1234F).",
        pattern: #"\b[A-Z]{3}[ABCFGHLJPT][A-Z]\d{4}[A-Z]\b"#,
        category: .accountNumber,
        sample: "ABCPE1234F",
        counterexample: "ABCDE1234",
        regionCode: "IN",
        kind: .taxID,
        tier: .anchored
    )

    public static let inVoterId = Preset(
        id: "in.voterId",
        name: "Indian Voter ID (EPIC)",
        summary: "Three letters + seven digits electoral photo ID number.",
        pattern: #"\b[A-Z]{3}\d{7}\b"#,
        category: .accountNumber,
        sample: "ABC1234567",
        counterexample: "ABC12345",
        regionCode: "IN",
        kind: .nationalID,
        tier: .anchored
    )

    public static let inIFSC = Preset(
        id: "in.ifsc",
        name: "Indian IFSC code",
        summary: "11-character bank branch code (SBIN0001234).",
        pattern: #"\b[A-Z]{4}0[A-Z0-9]{6}\b"#,
        category: .accountNumber,
        sample: "SBIN0001234",
        counterexample: "SBIN1001234",
        regionCode: "IN",
        kind: .bankAccount,
        tier: .anchored
    )

    public static let inGSTIN = Preset(
        id: "in.gstin",
        name: "Indian GSTIN",
        summary: "15-character GST identification number; mod-36 check digit verified.",
        pattern: #"\b\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]\b"#,
        category: .accountNumber,
        sample: "27AAPFU0939F1ZV",
        counterexample: "27AAPFU0939F1ZW",
        regionCode: "IN",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.mod36($0) }
    )

    // MARK: Pakistan / Bangladesh / Sri Lanka / Nepal

    public static let pkCNIC = Preset(
        id: "pk.cnic",
        name: "Pakistani CNIC",
        summary: "13-digit national identity card number (XXXXX-XXXXXXX-X).",
        pattern: #"\b[1-7]\d{4}-\d{7}-\d\b"#,
        category: .accountNumber,
        sample: "42101-1234567-1",
        counterexample: "42101-1234567",
        regionCode: "PK",
        kind: .nationalID,
        tier: .anchored
    )

    public static let bdNID = Preset(
        id: "bd.nid",
        name: "Bangladeshi NID",
        summary: "10-, 13- or 17-digit national ID written after “NID”.",
        pattern: #"\bNID"# + anchorGap + #"(\d{17}|\d{13}|\d{10})\b"#,
        category: .accountNumber,
        sample: "NID: 1234567890",
        counterexample: "NID: 12345",
        regionCode: "BD",
        kind: .nationalID,
        tier: .anchored
    )

    public static let lkNIC = Preset(
        id: "lk.nic",
        name: "Sri Lankan NIC",
        summary: "Old 9-digit + V/X or new 12-digit national identity card number; day-of-year verified.",
        pattern: #"\b(?:\d{9}[VX]|(?:19|20)\d{10})\b"#,
        category: .accountNumber,
        sample: "901234567V",
        counterexample: "909994567V",
        regionCode: "LK",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.sriLankanNIC($0) }
    )

    public static let npCitizenship = Preset(
        id: "np.citizenship",
        name: "Nepali citizenship number",
        summary: "Citizenship certificate number written after “citizenship”.",
        pattern: #"(?i)\bcitizenship(?:\s+(?:certificate|card))?"# + anchorGap + #"([\d\-/]{6,20}\d)\b"#,
        category: .accountNumber,
        sample: "Citizenship number: 12-01-70-01234",
        counterexample: "Citizenship number: 12",
        regionCode: "NP",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: China / Hong Kong / Macao / Taiwan

    public static let cnResidentId = Preset(
        id: "cn.residentId",
        name: "Chinese Resident Identity Card number",
        summary: "18-character 身份证 number; ISO 7064 MOD 11-2 check verified.",
        pattern: #"\b[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dX]\b"#,
        category: .accountNumber,
        sample: "11010519491231002X",
        counterexample: "110105194912310021",
        regionCode: "CN",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.chineseResidentId($0) }
    )

    public static let cnPassport = Preset(
        id: "cn.passport",
        name: "Chinese passport number",
        summary: "E/G + 8 characters written after “passport” / “护照”.",
        pattern: #"(?i)\b(?:passport|护照(?:号码?)?)"# + anchorGap + #"([EG][A-Z0-9]\d{7})\b"#,
        category: .accountNumber,
        sample: "护照: EA1234567",
        counterexample: "护照: EA12",
        regionCode: "CN",
        kind: .passport,
        tier: .anchored
    )

    public static let hkHKID = Preset(
        id: "hk.hkid",
        name: "Hong Kong Identity Card",
        summary: "HKID (A123456(3)); check digit verified.",
        pattern: #"\b[A-Z]{1,2}\d{6}\(?[\dA]\)?"#,
        category: .accountNumber,
        sample: "A123456(3)",
        counterexample: "A123456(4)",
        regionCode: "HK",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.hongKongHKID($0) }
    )

    public static let moBIR = Preset(
        id: "mo.bir",
        name: "Macao BIR number",
        summary: "Resident identity card number written after “BIR” / “居民身份證”.",
        pattern: #"(?i)\b(?:BIR|居民身份證|居民身份证)"# + anchorGap + #"(\d{7}\(?\d\)?)"#,
        category: .accountNumber,
        sample: "BIR: 1234567(8)",
        counterexample: "BIR: 1234",
        regionCode: "MO",
        kind: .nationalID,
        tier: .anchored
    )

    public static let twNationalId = Preset(
        id: "tw.nationalId",
        name: "Taiwan National ID",
        summary: "Letter + 9 digits identification number; check digit verified.",
        pattern: #"\b[A-Z][12]\d{8}\b"#,
        category: .accountNumber,
        sample: "A123456789",
        counterexample: "A123456780",
        regionCode: "TW",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.taiwanNationalId($0) }
    )

    public static let twARC = Preset(
        id: "tw.arc",
        name: "Taiwan ARC / UI number",
        summary: "Resident certificate number written after “ARC” / “居留證”.",
        pattern: #"(?i)\b(?:ARC|UI\s*(?:no\.?|number)|居留證(?:號碼?)?)"# + anchorGap + #"([A-Z][A-D8-9]\d{8})\b"#,
        category: .accountNumber,
        sample: "ARC: AC12345678",
        counterexample: "ARC: AC12",
        regionCode: "TW",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Japan

    public static let jpMyNumber = Preset(
        id: "jp.myNumber",
        name: "Japanese My Number",
        summary: "12-digit 個人番号 (XXXX XXXX XXXX); check digit verified.",
        pattern: #"\b\d{4}[ -]?\d{4}[ -]?\d{4}\b"#,
        category: .accountNumber,
        sample: "1234 5678 9018",
        counterexample: "1234 5678 9019",
        regionCode: "JP",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.japaneseMyNumber($0) }
    )

    public static let jpPassport = Preset(
        id: "jp.passport",
        name: "Japanese passport number",
        summary: "Two letters + seven digits written after “passport” / “旅券”.",
        pattern: #"(?i)\b(?:passport|旅券(?:番号)?|パスポート(?:番号)?)"# + anchorGap + #"([A-Z]{2}\d{7})\b"#,
        category: .accountNumber,
        sample: "旅券番号: TK1234567",
        counterexample: "旅券番号: TK12",
        regionCode: "JP",
        kind: .passport,
        tier: .anchored
    )

    public static let jpDriversLicense = Preset(
        id: "jp.driversLicense",
        name: "Japanese driver's licence number",
        summary: "12-digit 運転免許証 number written after the keyword.",
        pattern: #"(?i)\b(?:運転免許証?(?:番号)?|driver'?s?\s+licen[cs]e)"# + anchorGap + #"(\d{12})\b"#,
        category: .accountNumber,
        sample: "運転免許証番号: 123456789012",
        counterexample: "運転免許証番号: 1234",
        regionCode: "JP",
        kind: .driversLicense,
        tier: .anchored
    )

    public static let jpBankAccount = Preset(
        id: "jp.bankAccount",
        name: "Japanese bank account",
        summary: "Branch code + 7-digit account number written after “口座番号”.",
        pattern: #"(?i)\b(?:口座番号|account\s+(?:no\.?|number))"# + anchorGap + #"((?:\d{3}[ -]?)?\d{7})\b"#,
        category: .accountNumber,
        sample: "口座番号: 123-1234567",
        counterexample: "口座番号: 123",
        regionCode: "JP",
        kind: .bankAccount,
        tier: .anchored
    )

    // MARK: Korea

    public static let krRRN = Preset(
        id: "kr.rrn",
        name: "Korean Resident Registration Number",
        summary: "13-digit 주민등록번호 (YYMMDD-XXXXXXX); check digit verified.",
        pattern: #"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[- ]?[1-8]\d{6}\b"#,
        category: .accountNumber,
        sample: "900101-1234568",
        counterexample: "900101-1234569",
        regionCode: "KR",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.koreanRRN($0) }
    )

    public static let krPassport = Preset(
        id: "kr.passport",
        name: "Korean passport number",
        summary: "M/S/R/D + 8 characters written after “passport” / “여권”.",
        pattern: #"(?i)\b(?:passport|여권(?:번호)?)"# + anchorGap + #"([MSRDO][A-Z0-9]\d{7})\b"#,
        category: .accountNumber,
        sample: "여권번호: M12345678",
        counterexample: "여권번호: M123",
        regionCode: "KR",
        kind: .passport,
        tier: .anchored
    )

    public static let krAlienRegistration = Preset(
        id: "kr.alienRegistration",
        name: "Korean Alien Registration Number",
        summary: "13-digit 외국인등록번호 (YYMMDD-5/6/7/8XXXXXX) written after the keyword.",
        pattern: #"(?i)\b(?:외국인등록번호|alien\s+registration(?:\s+(?:no\.?|number|card))?)"# + anchorGap
            + #"(\d{6}[- ]?[5-8]\d{6})\b"#,
        category: .accountNumber,
        sample: "외국인등록번호: 900101-5123456",
        counterexample: "외국인등록번호: 9001",
        regionCode: "KR",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Mongolia

    public static let mnRegister = Preset(
        id: "mn.register",
        name: "Mongolian register number",
        summary: "Two Cyrillic letters + eight digits (УБ12345678).",
        pattern: #"\b[А-ЯӨҮ]{2}\d{8}\b"#,
        category: .accountNumber,
        sample: "УБ12345678",
        counterexample: "УБ1234",
        regionCode: "MN",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Singapore / Malaysia / Indonesia / Thailand / Philippines / Vietnam

    public static let sgNRIC = Preset(
        id: "sg.nric",
        name: "Singapore NRIC / FIN",
        summary: "S/T/F/G/M + 7 digits + check letter; check letter verified.",
        pattern: #"\b[STFGM]\d{7}[A-Z]\b"#,
        category: .accountNumber,
        sample: "S1234567D",
        counterexample: "S1234567E",
        regionCode: "SG",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.singaporeNRIC($0) }
    )

    public static let myMyKad = Preset(
        id: "my.myKad",
        name: "Malaysian MyKad number",
        summary: "12-digit NRIC (YYMMDD-PB-XXXX) with a valid birth date.",
        pattern:
            #"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])-?(?:0[1-9]|[1-5]\d|6[0-8]|7[1-9]|8[2-9]|9[0-3])-?\d{4}\b"#,
        category: .accountNumber,
        sample: "900101-14-5678",
        counterexample: "901301-14-5678",
        regionCode: "MY",
        kind: .nationalID,
        tier: .anchored
    )

    public static let idNIK = Preset(
        id: "id.nik",
        name: "Indonesian NIK",
        summary: "16-digit Nomor Induk Kependudukan with a valid birth date (day +40 for women).",
        pattern: #"\b[1-9]\d{5}(?:0[1-9]|[12]\d|3[01]|4[1-9]|[56]\d|7[01])(?:0[1-9]|1[0-2])\d{2}\d{4}\b"#,
        category: .accountNumber,
        sample: "3171010101900001",
        counterexample: "3171013201900001",
        regionCode: "ID",
        kind: .nationalID,
        tier: .anchored
    )

    public static let idNPWP = Preset(
        id: "id.npwp",
        name: "Indonesian NPWP",
        summary: "15-digit tax number (XX.XXX.XXX.X-XXX.XXX) written after “NPWP”.",
        pattern: #"\bNPWP"# + anchorGap + #"(\d{2}\.?\d{3}\.?\d{3}\.?\d-?\d{3}\.?\d{3})\b"#,
        category: .accountNumber,
        sample: "NPWP: 01.234.567.8-901.000",
        counterexample: "NPWP: 01.234",
        regionCode: "ID",
        kind: .taxID,
        tier: .anchored
    )

    public static let thNationalId = Preset(
        id: "th.nationalId",
        name: "Thai National ID",
        summary: "13-digit เลขประจำตัวประชาชน; mod-11 check digit verified.",
        pattern: #"\b[1-8][ -]?\d{4}[ -]?\d{5}[ -]?\d{2}[ -]?\d\b"#,
        category: .accountNumber,
        sample: "1-1012-34567-89-7",
        counterexample: "1-1012-34567-89-8",
        regionCode: "TH",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.thaiNationalId($0) }
    )

    public static let phTIN = Preset(
        id: "ph.tin",
        name: "Philippine TIN",
        summary: "9- or 12-digit tax identification number written after “TIN”.",
        pattern: #"\bTIN"# + anchorGap + #"(\d{3}-?\d{3}-?\d{3}(?:-?\d{3})?)\b"#,
        category: .accountNumber,
        sample: "TIN: 123-456-789-000",
        counterexample: "TIN: 123-456",
        regionCode: "PH",
        kind: .taxID,
        tier: .anchored
    )

    public static let phSSS = Preset(
        id: "ph.sss",
        name: "Philippine SSS number",
        summary: "10-digit SSS number (XX-XXXXXXX-X) written after “SSS”.",
        pattern: #"\bSSS"# + anchorGap + #"(\d{2}-?\d{7}-?\d)\b"#,
        category: .accountNumber,
        sample: "SSS: 34-1234567-8",
        counterexample: "SSS: 34-12",
        regionCode: "PH",
        kind: .nationalID,
        tier: .anchored
    )

    public static let phPhilHealth = Preset(
        id: "ph.philHealth",
        name: "PhilHealth number",
        summary: "12-digit PhilHealth number (XX-XXXXXXXXX-X) written after “PhilHealth”.",
        pattern: #"(?i)\bPhilHealth"# + anchorGap + #"(\d{2}-?\d{9}-?\d)\b"#,
        category: .accountNumber,
        sample: "PhilHealth: 12-345678901-2",
        counterexample: "PhilHealth: 12-34",
        regionCode: "PH",
        kind: .healthID,
        tier: .anchored
    )

    public static let phUMID = Preset(
        id: "ph.umid",
        name: "Philippine UMID / PhilSys number",
        summary: "12-digit UMID CRN or 16-digit PhilSys PSN written after the keyword.",
        pattern: #"(?i)\b(?:UMID|CRN|PhilSys|PSN|PhilID)"# + anchorGap
            + #"(\d{4}-?\d{4}-?\d{4}-?\d{4}|\d{4}-?\d{7}-?\d)\b"#,
        category: .accountNumber,
        sample: "UMID: 0111-1234567-8",
        counterexample: "UMID: 0111",
        regionCode: "PH",
        kind: .nationalID,
        tier: .anchored
    )

    public static let vnCCCD = Preset(
        id: "vn.cccd",
        name: "Vietnamese CCCD / CMND",
        summary: "12-digit CCCD or 9-digit CMND written after the keyword.",
        pattern: #"(?i)\b(?:CCCD|CMND|căn\s+cước|chứng\s+minh)"# + anchorGap + #"(\d{12}|\d{9})\b"#,
        category: .accountNumber,
        sample: "CCCD: 079123456789",
        counterexample: "CCCD: 0791",
        regionCode: "VN",
        kind: .nationalID,
        tier: .anchored
    )

    public static let khId = Preset(
        id: "kh.id",
        name: "Cambodian ID card number",
        summary: "9-digit identity card number written after “ID”.",
        pattern: #"(?i)\b(?:ID|identity)\s*(?:card\s*)?(?:no\.?|number)"# + anchorGap + #"(\d{9})\b"#,
        category: .accountNumber,
        sample: "ID number: 012345678",
        counterexample: "ID number: 0123",
        regionCode: "KH",
        kind: .nationalID,
        tier: .anchored
    )

    public static let laId = Preset(
        id: "la.id",
        name: "Lao ID card number",
        summary: "Identity card number written after “ID”.",
        pattern: #"(?i)\b(?:ID|identity)\s*(?:card\s*)?(?:no\.?|number)"# + anchorGap + #"(\d{6,12})\b"#,
        category: .accountNumber,
        sample: "ID number: 01234567890",
        counterexample: "ID number: 01",
        regionCode: "LA",
        kind: .nationalID,
        tier: .anchored
    )

    public static let mmNRC = Preset(
        id: "mm.nrc",
        name: "Myanmar NRC number",
        summary: "National Registration Card number (12/ABC(N)123456) written after “NRC”.",
        pattern: #"\bNRC"# + anchorGap + #"(\d{1,2}/[A-Za-z]{3,8}\((?:N|E|P|C|T)\)\d{6})"#,
        category: .accountNumber,
        sample: "NRC: 12/YaKaNa(N)123456",
        counterexample: "NRC: 12/YaKaNa",
        regionCode: "MM",
        kind: .nationalID,
        tier: .anchored
    )

    public static let bnIC = Preset(
        id: "bn.ic",
        name: "Bruneian IC number",
        summary: "8-digit identity card number (XX-XXXXXX) written after “IC”.",
        pattern: #"\bIC"# + anchorGap + #"(\d{2}-?\d{6})\b"#,
        category: .accountNumber,
        sample: "IC: 01-234567",
        counterexample: "IC: 01",
        regionCode: "BN",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Australia

    public static let auTFN = Preset(
        id: "au.tfn",
        name: "Australian TFN",
        summary: "9-digit Tax File Number (XXX XXX XXX); weighted check verified.",
        pattern: #"\b\d{3}[ -]?\d{3}[ -]?\d{3}\b"#,
        category: .accountNumber,
        sample: "123 456 782",
        counterexample: "123 456 783",
        regionCode: "AU",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.australianTFN($0) }
    )

    public static let auMedicare = Preset(
        id: "au.medicare",
        name: "Australian Medicare number",
        summary: "10-digit Medicare number (+ IRN); check digit verified.",
        pattern: #"\b[2-6]\d{3}[ -]?\d{5}[ -]?\d(?:[ -]?\d)?\b"#,
        category: .accountNumber,
        sample: "2123 45670 1",
        counterexample: "2123 45671 1",
        regionCode: "AU",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.australianMedicare($0) }
    )

    public static let auABN = Preset(
        id: "au.abn",
        name: "Australian ABN",
        summary: "11-digit Australian Business Number (XX XXX XXX XXX); mod-89 verified.",
        pattern: #"\b\d{2}[ -]?\d{3}[ -]?\d{3}[ -]?\d{3}\b"#,
        category: .accountNumber,
        sample: "51 824 753 556",
        counterexample: "51 824 753 557",
        regionCode: "AU",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.australianABN($0) }
    )

    public static let auBSB = Preset(
        id: "au.bsb",
        name: "Australian BSB + account",
        summary: "6-digit BSB (XXX-XXX) and optional account number written after “BSB”.",
        pattern: #"\bBSB"# + anchorGap
            + #"(\d{3}-?\d{3}(?:[ ,]+(?:acc(?:ount)?\.?\s*(?:no\.?|number)?\s*[:#]?\s*)?\d{6,10})?)\b"#,
        category: .accountNumber,
        sample: "BSB: 062-000 12345678",
        counterexample: "BSB: 062",
        regionCode: "AU",
        kind: .bankAccount,
        tier: .anchored
    )

    public static let auDriversLicence = Preset(
        id: "au.driversLicence",
        name: "Australian driver licence number",
        summary: "State licence number (6–10 alphanumerics) written after “licence”.",
        pattern: #"(?i)\b(?:driver'?s?\s+)?licen[cs]e(?:\s+(?:no\.?|number|#))?"# + anchorGap + #"([A-Z0-9]{6,10})\b"#,
        category: .accountNumber,
        sample: "Driver licence: 12345678",
        counterexample: "Driver licence: 123",
        regionCode: "AU",
        kind: .driversLicense,
        tier: .anchored
    )

    // MARK: New Zealand

    public static let nzIRD = Preset(
        id: "nz.ird",
        name: "New Zealand IRD number",
        summary: "8- or 9-digit IRD number (XX-XXX-XXX); weighted check verified.",
        pattern: #"\b\d{2,3}-?\d{3}-?\d{3}\b"#,
        category: .accountNumber,
        sample: "49-091-850",
        counterexample: "49-091-851",
        regionCode: "NZ",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.newZealandIRD($0) }
    )

    public static let nzNHI = Preset(
        id: "nz.nhi",
        name: "New Zealand NHI number",
        summary: "7-character National Health Index (ZZZ0016); check digit verified.",
        pattern: #"\b[A-HJ-NP-Z]{3}\d{4}\b"#,
        category: .accountNumber,
        sample: "ZZZ0016",
        counterexample: "ZZZ0017",
        regionCode: "NZ",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.newZealandNHI($0) }
    )

    public static let nzBankAccount = Preset(
        id: "nz.bankAccount",
        name: "New Zealand bank account",
        summary: "XX-XXXX-XXXXXXX-XX(X) bank account number.",
        pattern: #"\b\d{2}-\d{4}-\d{7}-\d{2,3}\b"#,
        category: .accountNumber,
        sample: "12-3456-7890123-00",
        counterexample: "12-3456-789",
        regionCode: "NZ",
        kind: .bankAccount,
        tier: .anchored
    )

    // MARK: Fiji / Papua New Guinea

    public static let fjTIN = Preset(
        id: "fj.tin",
        name: "Fijian TIN",
        summary: "9-digit tax identification number written after “TIN”.",
        pattern: #"\bTIN"# + anchorGap + #"(\d{2}-?\d{5}-?\d-?\d)\b"#,
        category: .accountNumber,
        sample: "TIN: 12-34567-0-1",
        counterexample: "TIN: 12",
        regionCode: "FJ",
        kind: .taxID,
        tier: .anchored
    )

    public static let pgTIN = Preset(
        id: "pg.tin",
        name: "Papua New Guinean TIN",
        summary: "9-digit tax identification number written after “TIN”.",
        pattern: #"\bTIN"# + anchorGap + #"(\d{9})\b"#,
        category: .accountNumber,
        sample: "TIN: 500123456",
        counterexample: "TIN: 500",
        regionCode: "PG",
        kind: .taxID,
        tier: .anchored
    )

    // MARK: Central Asia

    public static let kzIIN = Preset(
        id: "kz.iin",
        name: "Kazakh IIN / BIN",
        summary: "12-digit individual or business identification number; check digit verified.",
        pattern: #"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{6}\b"#,
        category: .accountNumber,
        sample: "900101300126",
        counterexample: "900101300127",
        regionCode: "KZ",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.kazakhIIN($0) }
    )

    public static let uzPINFL = Preset(
        id: "uz.pinfl",
        name: "Uzbek PINFL / JShShIR",
        summary: "14-digit personal identification number written after the keyword.",
        pattern: #"(?i)\b(?:PINFL|ПИНФЛ|JShShIR|ЖШШИР)"# + anchorGap + #"(\d{14})\b"#,
        category: .accountNumber,
        sample: "PINFL: 30101900123456",
        counterexample: "PINFL: 3010",
        regionCode: "UZ",
        kind: .nationalID,
        tier: .anchored
    )

    public static let kgPIN = Preset(
        id: "kg.pin",
        name: "Kyrgyz PIN",
        summary: "14-digit personal identification number written after “PIN” / “ПИН”.",
        pattern: #"(?i)\b(?:PIN|ПИН|ИНН)"# + anchorGap + #"([12]\d{13})\b"#,
        category: .accountNumber,
        sample: "ПИН: 10101199001234",
        counterexample: "ПИН: 1010",
        regionCode: "KG",
        kind: .nationalID,
        tier: .anchored
    )

    public static let tjPersonalNumber = Preset(
        id: "tj.personalNumber",
        name: "Tajik personal number",
        summary: "Identification number written after “ИНН” / “personal number”.",
        pattern: #"(?i)\b(?:ИНН|personal\s+(?:number|no\.?|id))"# + anchorGap + #"(\d{9,14})\b"#,
        category: .accountNumber,
        sample: "ИНН: 123456789",
        counterexample: "ИНН: 1234",
        regionCode: "TJ",
        kind: .nationalID,
        tier: .anchored
    )

    public static let tmPersonalNumber = Preset(
        id: "tm.personalNumber",
        name: "Turkmen personal number",
        summary: "Identification number written after “passport” / “personal number”.",
        pattern: #"(?i)\b(?:passport|personal\s+(?:number|no\.?|id))"# + anchorGap
            + #"([A-Z]-?[A-Z]{2}\s?\d{6,7}|\d{9,14})\b"#,
        category: .accountNumber,
        sample: "Passport: I-AS 1234567",
        counterexample: "Passport: I-",
        regionCode: "TM",
        kind: .nationalID,
        tier: .anchored
    )

    static let asiaPacific: [Preset] = [
        inAadhaar, inPAN, inVoterId, inIFSC, inGSTIN,
        pkCNIC, bdNID, lkNIC, npCitizenship,
        cnResidentId, cnPassport, hkHKID, moBIR, twNationalId, twARC,
        jpMyNumber, jpPassport, jpDriversLicense, jpBankAccount,
        krRRN, krPassport, krAlienRegistration,
        mnRegister,
        sgNRIC, myMyKad, idNIK, idNPWP, thNationalId,
        phTIN, phSSS, phPhilHealth, phUMID,
        vnCCCD, khId, laId, mmNRC, bnIC,
        auTFN, auMedicare, auABN, auBSB, auDriversLicence,
        nzIRD, nzNHI, nzBankAccount,
        fjTIN, pgTIN,
        kzIIN, uzPINFL, kgPIN, tjPersonalNumber, tmPersonalNumber,
    ]
}
