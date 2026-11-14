//
//  PrivacyRulePresets+MiddleEastAfrica.swift
//  osaurus / PrivacyFilter
//
//  Gulf, Levant, Iran, North Africa and Sub-Saharan Africa. See
//  `PrivacyRulePresets.swift` for the tier contract.
//

import Foundation

extension PrivacyRulePresets {
    // MARK: Israel

    public static let ilTeudatZehut = Preset(
        id: "il.teudatZehut",
        name: "Israeli Teudat Zehut",
        summary: "9-digit identity number; Luhn check digit verified.",
        pattern: #"\b\d{9}\b"#,
        category: .accountNumber,
        sample: "123456782",
        counterexample: "123456783",
        regionCode: "IL",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    // MARK: Saudi Arabia

    public static let saNationalId = Preset(
        id: "sa.nationalId",
        name: "Saudi National ID / Iqama",
        summary: "10-digit number starting with 1 (citizen) or 2 (resident); Luhn-verified.",
        pattern: #"\b[12]\d{9}\b"#,
        category: .accountNumber,
        sample: "1000000008",
        counterexample: "1000000009",
        regionCode: "SA",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    // MARK: United Arab Emirates

    public static let aeEmiratesId = Preset(
        id: "ae.emiratesId",
        name: "Emirates ID",
        summary: "784-YYYY-XXXXXXX-X identity number; Luhn-verified.",
        pattern: #"\b784-?(?:19|20)\d{2}-?\d{7}-?\d\b"#,
        category: .accountNumber,
        sample: "784-1980-1234567-8",
        counterexample: "784-1980-1234567-9",
        regionCode: "AE",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    // MARK: Qatar / Kuwait / Bahrain / Oman

    public static let qaQID = Preset(
        id: "qa.qid",
        name: "Qatar ID (QID)",
        summary: "11-digit QID starting with 2 or 3 written after “QID” / “Qatar ID”.",
        pattern: #"(?i)\b(?:QID|Qatar(?:i)?\s+ID)"# + anchorGap + #"([23]\d{10})\b"#,
        category: .accountNumber,
        sample: "QID: 28012345678",
        counterexample: "QID: 2801",
        regionCode: "QA",
        kind: .nationalID,
        tier: .anchored
    )

    public static let kwCivilId = Preset(
        id: "kw.civilId",
        name: "Kuwaiti Civil ID",
        summary: "12-digit civil number; check digit verified.",
        pattern: #"\b[123]\d{11}\b"#,
        category: .accountNumber,
        sample: "290010112346",
        counterexample: "290010112347",
        regionCode: "KW",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.kuwaitiCivilId($0) }
    )

    public static let bhCPR = Preset(
        id: "bh.cpr",
        name: "Bahraini CPR number",
        summary: "9-digit personal number written after “CPR”.",
        pattern: #"\bCPR"# + anchorGap + #"(\d{9})\b"#,
        category: .accountNumber,
        sample: "CPR: 901234567",
        counterexample: "CPR: 9012",
        regionCode: "BH",
        kind: .nationalID,
        tier: .anchored
    )

    public static let omCivilNumber = Preset(
        id: "om.civilNumber",
        name: "Omani civil number",
        summary: "8-digit civil number written after “civil number” / “ID”.",
        pattern: #"(?i)\b(?:civil\s+(?:number|no\.?|id)|ID\s*(?:card\s*)?(?:no\.?|number))"# + anchorGap
            + #"(\d{8})\b"#,
        category: .accountNumber,
        sample: "Civil number: 12345678",
        counterexample: "Civil number: 1234",
        regionCode: "OM",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Jordan / Lebanon / Iraq

    public static let joNationalNumber = Preset(
        id: "jo.nationalNumber",
        name: "Jordanian national number",
        summary: "10-digit national number written after “national number” / “الرقم الوطني”.",
        pattern: #"(?i)\b(?:national\s+(?:number|no\.?|id)|الرقم\s+الوطني)"# + anchorGap + #"([129]\d{9})\b"#,
        category: .accountNumber,
        sample: "National number: 9901234567",
        counterexample: "National number: 9901",
        regionCode: "JO",
        kind: .nationalID,
        tier: .anchored
    )

    public static let lbId = Preset(
        id: "lb.id",
        name: "Lebanese ID number",
        summary: "Identity card / register number written after “ID” / “سجل”.",
        pattern: #"(?i)\b(?:ID\s*(?:card\s*)?(?:no\.?|number)|register\s+(?:number|no\.?)|رقم\s+(?:الهوية|السجل))"#
            + anchorGap + #"(\d{4,12})\b"#,
        category: .accountNumber,
        sample: "ID number: 00123456",
        counterexample: "ID number: 00",
        regionCode: "LB",
        kind: .nationalID,
        tier: .anchored
    )

    public static let iqId = Preset(
        id: "iq.id",
        name: "Iraqi national card number",
        summary: "12-digit unified national card number written after “national card” / “البطاقة الوطنية”.",
        pattern: #"(?i)\b(?:national\s+(?:card|ID)(?:\s+(?:number|no\.?))?|البطاقة\s+الوطنية)"# + anchorGap
            + #"(\d{12})\b"#,
        category: .accountNumber,
        sample: "National card: 199012345678",
        counterexample: "National card: 1990",
        regionCode: "IQ",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Iran

    public static let irMelliCode = Preset(
        id: "ir.melliCode",
        name: "Iranian کد ملی (Melli code)",
        summary: "10-digit national code; check digit verified.",
        pattern: #"\b\d{3}-?\d{6}-?\d\b"#,
        category: .accountNumber,
        sample: "001-234567-9",
        counterexample: "001-234567-8",
        regionCode: "IR",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.iranianMelliCode($0) }
    )

    // MARK: Egypt

    public static let egNationalId = Preset(
        id: "eg.nationalId",
        name: "Egyptian National ID",
        summary: "14-digit national number (century, birth date, governorate code).",
        pattern:
            #"\b[23]\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])"#
            + #"(?:0[1-4]|1[1-9]|2[1-9]|3[1-5]|88)\d{5}\b"#,
        category: .accountNumber,
        sample: "29001011201234",
        counterexample: "29001014001234",
        regionCode: "EG",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Morocco / Algeria / Tunisia / Libya / Sudan

    public static let maCIN = Preset(
        id: "ma.cin",
        name: "Moroccan CIN",
        summary: "One or two letters + 5–7 digits written after “CIN” / “CNIE”.",
        pattern: #"(?i)\b(?:CIN|CNIE|carte\s+(?:nationale|d'identité))"# + anchorGap + #"([A-Z]{1,2}\d{5,7})\b"#,
        category: .accountNumber,
        sample: "CIN: AB123456",
        counterexample: "CIN: AB",
        regionCode: "MA",
        kind: .nationalID,
        tier: .anchored
    )

    public static let dzNIN = Preset(
        id: "dz.nin",
        name: "Algerian NIN",
        summary: "18-digit national identification number written after “NIN”.",
        pattern: #"(?i)\b(?:NIN|num[ée]ro\s+d'identification\s+nationale?)"# + anchorGap + #"(\d{18})\b"#,
        category: .accountNumber,
        sample: "NIN: 109900101234567890",
        counterexample: "NIN: 1099",
        regionCode: "DZ",
        kind: .nationalID,
        tier: .anchored
    )

    public static let tnCIN = Preset(
        id: "tn.cin",
        name: "Tunisian CIN",
        summary: "8-digit carte d'identité nationale number written after “CIN”.",
        pattern: #"(?i)\b(?:CIN|carte\s+d'identit[ée])"# + anchorGap + #"([01]\d{7})\b"#,
        category: .accountNumber,
        sample: "CIN: 01234567",
        counterexample: "CIN: 0123",
        regionCode: "TN",
        kind: .nationalID,
        tier: .anchored
    )

    public static let lyNationalNumber = Preset(
        id: "ly.nationalNumber",
        name: "Libyan national number",
        summary: "12-digit national number written after “national number” / “الرقم الوطني”.",
        pattern: #"(?i)\b(?:national\s+(?:number|no\.?|id)|الرقم\s+الوطني)"# + anchorGap + #"([12]\d{11})\b"#,
        category: .accountNumber,
        sample: "National number: 119900123456",
        counterexample: "National number: 1199",
        regionCode: "LY",
        kind: .nationalID,
        tier: .anchored
    )

    public static let sdNationalNumber = Preset(
        id: "sd.nationalNumber",
        name: "Sudanese national number",
        summary: "11-digit national number written after “national number” / “الرقم الوطني”.",
        pattern: #"(?i)\b(?:national\s+(?:number|no\.?|id)|الرقم\s+الوطني)"# + anchorGap + #"(\d{11})\b"#,
        category: .accountNumber,
        sample: "National number: 12345678901",
        counterexample: "National number: 1234",
        regionCode: "SD",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: South Africa

    public static let zaId = Preset(
        id: "za.id",
        name: "South African ID number",
        summary: "13-digit identity number (YYMMDD SSSS C A Z); Luhn-verified.",
        pattern: #"\b\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\s?\d{4}\s?[01]\s?\d\s?\d\b"#,
        category: .accountNumber,
        sample: "9001015001083",
        counterexample: "9001015001084",
        regionCode: "ZA",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    // MARK: Nigeria

    public static let ngNIN = Preset(
        id: "ng.nin",
        name: "Nigerian NIN",
        summary: "11-digit National Identification Number written after “NIN”.",
        pattern: #"\bNIN"# + anchorGap + #"(\d{11})\b"#,
        category: .accountNumber,
        sample: "NIN: 12345678901",
        counterexample: "NIN: 1234",
        regionCode: "NG",
        kind: .nationalID,
        tier: .anchored
    )

    public static let ngBVN = Preset(
        id: "ng.bvn",
        name: "Nigerian BVN",
        summary: "11-digit Bank Verification Number written after “BVN”.",
        pattern: #"\bBVN"# + anchorGap + #"(\d{11})\b"#,
        category: .accountNumber,
        sample: "BVN: 22123456789",
        counterexample: "BVN: 2212",
        regionCode: "NG",
        kind: .bankAccount,
        tier: .anchored
    )

    // MARK: Kenya

    public static let keId = Preset(
        id: "ke.id",
        name: "Kenyan ID / Huduma number",
        summary: "7- or 8-digit national ID number written after “ID” / “Huduma”.",
        pattern: #"(?i)\b(?:ID\s*(?:card\s*)?(?:no\.?|number)|Huduma(?:\s+(?:namba|number|no\.?))?)"# + anchorGap
            + #"(\d{7,8})\b"#,
        category: .accountNumber,
        sample: "ID number: 12345678",
        counterexample: "ID number: 1234",
        regionCode: "KE",
        kind: .nationalID,
        tier: .anchored
    )

    public static let keKRAPIN = Preset(
        id: "ke.kraPin",
        name: "Kenyan KRA PIN",
        summary: "A/P + 9 digits + letter tax PIN (A123456789B).",
        pattern: #"\b[AP]\d{9}[A-Z]\b"#,
        category: .accountNumber,
        sample: "A123456789B",
        counterexample: "A12345678B",
        regionCode: "KE",
        kind: .taxID,
        tier: .anchored
    )

    // MARK: Ghana

    public static let ghGhanaCard = Preset(
        id: "gh.ghanaCard",
        name: "Ghana Card number",
        summary: "GHA-XXXXXXXXX-X personal identification number.",
        pattern: #"\bGHA-?\d{9}-?\d\b"#,
        category: .accountNumber,
        sample: "GHA-123456789-0",
        counterexample: "GHA-1234",
        regionCode: "GH",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: East / Southern / West / Central Africa

    public static let etId = Preset(
        id: "et.id",
        name: "Ethiopian Fayda / ID number",
        summary: "12-digit Fayda number or kebele ID written after the keyword.",
        pattern: #"(?i)\b(?:Fayda|FIN|ID\s*(?:card\s*)?(?:no\.?|number))"# + anchorGap
            + #"(\d{4}[ -]?\d{4}[ -]?\d{4}|\d{6,12})\b"#,
        category: .accountNumber,
        sample: "Fayda: 1234 5678 9012",
        counterexample: "Fayda: 1234",
        regionCode: "ET",
        kind: .nationalID,
        tier: .anchored
    )

    public static let tzNIDA = Preset(
        id: "tz.nida",
        name: "Tanzanian NIDA number",
        summary: "20-digit national identification number (YYYYMMDD-XXXXX-XXXXX-XX).",
        pattern: #"\b(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])-?\d{5}-?\d{5}-?\d{2}\b"#,
        category: .accountNumber,
        sample: "19900101-12345-00001-23",
        counterexample: "19901301-12345-00001-23",
        regionCode: "TZ",
        kind: .nationalID,
        tier: .anchored
    )

    public static let ugNIN = Preset(
        id: "ug.nin",
        name: "Ugandan NIN",
        summary: "14-character national identification number (CM/CF + 12 alphanumerics).",
        pattern: #"\bC[MF]\d{2}[A-Z0-9]{10}\b"#,
        category: .accountNumber,
        sample: "CM90012345ABCD",
        counterexample: "CM9001",
        regionCode: "UG",
        kind: .nationalID,
        tier: .anchored
    )

    public static let rwNID = Preset(
        id: "rw.nid",
        name: "Rwandan national ID",
        summary: "16-digit national identity number (1 YYYY 8/7 XXXXXXX X XX).",
        pattern: #"\b[123]\s?(?:19|20)\d{2}\s?[78]\s?\d{7}\s?\d\s?\d{2}\b"#,
        category: .accountNumber,
        sample: "1 1990 8 0012345 0 12",
        counterexample: "1 1990 8 0012",
        regionCode: "RW",
        kind: .nationalID,
        tier: .anchored
    )

    public static let zmNRC = Preset(
        id: "zm.nrc",
        name: "Zambian NRC number",
        summary: "National Registration Card number (XXXXXX/XX/1).",
        pattern: #"\b\d{6}/\d{2}/[1-3]\b"#,
        category: .accountNumber,
        sample: "123456/78/1",
        counterexample: "123456/78",
        regionCode: "ZM",
        kind: .nationalID,
        tier: .anchored
    )

    public static let zwNationalId = Preset(
        id: "zw.nationalId",
        name: "Zimbabwean national ID",
        summary: "XX-XXXXXX-L-XX national registration number.",
        pattern: #"\b\d{2}-?\d{6,7}-?[A-Z]-?\d{2}\b"#,
        category: .accountNumber,
        sample: "63-123456-A-42",
        counterexample: "63-123456",
        regionCode: "ZW",
        kind: .nationalID,
        tier: .anchored
    )

    public static let mwNationalId = Preset(
        id: "mw.nationalId",
        name: "Malawian national ID",
        summary: "8-character national ID written after “ID” / “national ID”.",
        pattern: #"(?i)\b(?:national\s+ID|ID\s*(?:card\s*)?(?:no\.?|number))"# + anchorGap + #"([A-Z0-9]{8})\b"#,
        category: .accountNumber,
        sample: "National ID: AB12CD34",
        counterexample: "National ID: AB1",
        regionCode: "MW",
        kind: .nationalID,
        tier: .anchored
    )

    public static let mzBI = Preset(
        id: "mz.bi",
        name: "Mozambican BI",
        summary: "13-character Bilhete de Identidade number written after “BI”.",
        pattern: #"(?i)\b(?:BI|bilhete\s+de\s+identidade)"# + anchorGap + #"(\d{12}[A-Z])\b"#,
        category: .accountNumber,
        sample: "BI: 110100123456A",
        counterexample: "BI: 1101",
        regionCode: "MZ",
        kind: .nationalID,
        tier: .anchored
    )

    public static let aoBI = Preset(
        id: "ao.bi",
        name: "Angolan BI",
        summary: "14-character Bilhete de Identidade number (9 digits + 2 letters + 3 digits).",
        pattern: #"\b\d{9}[A-Z]{2}\d{3}\b"#,
        category: .accountNumber,
        sample: "001234567LA041",
        counterexample: "001234567LA",
        regionCode: "AO",
        kind: .nationalID,
        tier: .anchored
    )

    public static let cmCNI = Preset(
        id: "cm.cni",
        name: "Cameroonian CNI",
        summary: "Carte nationale d'identité number written after “CNI”.",
        pattern: #"(?i)\b(?:CNI|carte\s+nationale\s+d'identit[ée])"# + anchorGap + #"(\d{9,12})\b"#,
        category: .accountNumber,
        sample: "CNI: 123456789",
        counterexample: "CNI: 1234",
        regionCode: "CM",
        kind: .nationalID,
        tier: .anchored
    )

    public static let ciCNI = Preset(
        id: "ci.cni",
        name: "Ivorian CNI",
        summary: "CI + 9 digits identity card number.",
        pattern: #"\bCI\d{9}\b"#,
        category: .accountNumber,
        sample: "CI123456789",
        counterexample: "CI1234",
        regionCode: "CI",
        kind: .nationalID,
        tier: .anchored
    )

    public static let snCNI = Preset(
        id: "sn.cni",
        name: "Senegalese CNI / NIN",
        summary: "13- or 14-digit national identification number written after “CNI” / “NIN”.",
        pattern: #"(?i)\b(?:CNI|NIN|carte\s+nationale\s+d'identit[ée])"# + anchorGap
            + #"([12]\s?\d{3}\s?(?:19|20)\d{2}\s?\d{5}|\d{13,14})\b"#,
        category: .accountNumber,
        sample: "CNI: 1 234 1990 12345",
        counterexample: "CNI: 1 234",
        regionCode: "SN",
        kind: .nationalID,
        tier: .anchored
    )

    public static let bwOmang = Preset(
        id: "bw.omang",
        name: "Botswana Omang number",
        summary: "9-digit Omang number (5th digit 1 or 2) written after “Omang” / “ID”.",
        pattern: #"(?i)\b(?:Omang|ID\s*(?:card\s*)?(?:no\.?|number))"# + anchorGap + #"(\d{4}[12]\d{4})\b"#,
        category: .accountNumber,
        sample: "Omang: 123412345",
        counterexample: "Omang: 1234",
        regionCode: "BW",
        kind: .nationalID,
        tier: .anchored
    )

    public static let naId = Preset(
        id: "na.id",
        name: "Namibian ID number",
        summary: "11-digit ID number (YYMMDD + 5) written after “ID”.",
        pattern: #"(?i)\bID\s*(?:card\s*)?(?:no\.?|number)"# + anchorGap
            + #"(\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{5})\b"#,
        category: .accountNumber,
        sample: "ID number: 90010100123",
        counterexample: "ID number: 9001",
        regionCode: "NA",
        kind: .nationalID,
        tier: .anchored
    )

    public static let muNIC = Preset(
        id: "mu.nic",
        name: "Mauritian NIC",
        summary: "14-character National Identity Card number (letter + DDMMYY + 6 digits + check character).",
        pattern: #"\b[A-Z](?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}\d{6}[A-Z0-9]\b"#,
        category: .accountNumber,
        sample: "A010190123456Z",
        counterexample: "A011390123456Z",
        regionCode: "MU",
        kind: .nationalID,
        tier: .anchored
    )

    static let middleEastAfrica: [Preset] = [
        ilTeudatZehut,
        saNationalId,
        aeEmiratesId,
        qaQID, kwCivilId, bhCPR, omCivilNumber,
        joNationalNumber, lbId, iqId,
        irMelliCode,
        egNationalId,
        maCIN, dzNIN, tnCIN, lyNationalNumber, sdNationalNumber,
        zaId,
        ngNIN, ngBVN,
        keId, keKRAPIN,
        ghGhanaCard,
        etId, tzNIDA, ugNIN, rwNID, zmNRC, zwNationalId, mwNationalId, mzBI, aoBI,
        cmCNI, ciCNI, snCNI, bwOmang, naId, muNIC,
    ]
}
