//
//  PrivacyRulePresets+EuropeWest.swift
//  osaurus / PrivacyFilter
//
//  Western, Northern and Southern Europe. See
//  `PrivacyRulePresets.swift` for the tier contract.
//

import Foundation

extension PrivacyRulePresets {
    // MARK: United Kingdom

    public static let gbNINO = Preset(
        id: "gb.nino",
        name: "UK National Insurance number",
        summary: "Two letters, six digits, one letter (AB 12 34 56 C); invalid prefixes excluded.",
        pattern: #"\b(?!BG|GB|NK|KN|TN|NT|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z]\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b"#,
        category: .accountNumber,
        sample: "AB 12 34 56 C",
        counterexample: "BG 12 34 56 C",
        regionCode: "GB",
        kind: .nationalID,
        tier: .anchored
    )

    public static let gbNHS = Preset(
        id: "gb.nhs",
        name: "UK NHS number",
        summary: "10-digit NHS number (XXX XXX XXXX); modulus-11 verified.",
        pattern: #"\b\d{3}[ -]?\d{3}[ -]?\d{4}\b"#,
        category: .accountNumber,
        sample: "943 476 5919",
        counterexample: "943 476 5918",
        regionCode: "GB",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.ukNHS($0) }
    )

    public static let gbDrivingLicence = Preset(
        id: "gb.drivingLicence",
        name: "UK driving licence number",
        summary: "16-character DVLA licence number (surname, date-of-birth digits, initials).",
        pattern: #"\b[A-Z9]{5}\d[0156]\d(?:0[1-9]|[12]\d|3[01])\d[A-Z9]{2}\d[A-Z]{2}\b"#,
        category: .accountNumber,
        sample: "MORGA657054SM9IJ",
        counterexample: "MORGA6570",
        regionCode: "GB",
        kind: .driversLicense,
        tier: .anchored
    )

    public static let gbPassport = Preset(
        id: "gb.passport",
        name: "UK passport number",
        summary: "9-digit passport number written after “passport”.",
        pattern: #"(?i)\bpassport"# + anchorGap + #"(\d{9})\b"#,
        category: .accountNumber,
        sample: "Passport: 123456789",
        counterexample: "Passport: 1234",
        regionCode: "GB",
        kind: .passport,
        tier: .anchored
    )

    public static let gbSortCode = Preset(
        id: "gb.sortCode",
        name: "UK sort code",
        summary: "XX-XX-XX bank sort code written after “sort code”.",
        pattern: #"(?i)\bsort\s*code"# + anchorGap + #"(\d{2}-?\d{2}-?\d{2})\b"#,
        category: .accountNumber,
        sample: "Sort code: 12-34-56",
        counterexample: "Sort code: 12-34",
        regionCode: "GB",
        kind: .bankAccount,
        tier: .anchored
    )

    public static let gbUTR = Preset(
        id: "gb.utr",
        name: "UK Unique Taxpayer Reference",
        summary: "10-digit UTR written after “UTR”; check digit verified.",
        pattern: #"\bUTR"# + anchorGap + #"(\d{5}\s?\d{5})\b"#,
        category: .accountNumber,
        sample: "UTR: 1123456789",
        counterexample: "UTR: 2123456789",
        regionCode: "GB",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.ukUTR($0) }
    )

    // MARK: Ireland

    public static let iePPS = Preset(
        id: "ie.pps",
        name: "Irish PPS number",
        summary: "Seven digits + one or two letters; modulus-23 verified.",
        pattern: #"\b\d{7}[A-W][A-IW]?\b"#,
        category: .accountNumber,
        sample: "1234567T",
        counterexample: "1234567A",
        regionCode: "IE",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.irishPPS($0) }
    )

    // MARK: France

    public static let frNIR = Preset(
        id: "fr.nir",
        name: "French NIR (sécurité sociale)",
        summary: "15-digit numéro de sécurité sociale; mod-97 key verified.",
        pattern: #"\b[12]\s?\d{2}\s?(?:0[1-9]|1[0-2]|20|[3-9]\d)\s?(?:\d{2}|2[AB])\s?\d{3}\s?\d{3}\s?\d{2}\b"#,
        category: .accountNumber,
        sample: "2 55 08 14 168 025 38",
        counterexample: "2 55 08 14 168 025 39",
        regionCode: "FR",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.frenchNIR($0) }
    )

    public static let frSIREN = Preset(
        id: "fr.siren",
        name: "French SIREN / SIRET",
        summary: "9-digit SIREN or 14-digit SIRET written after the keyword; Luhn-verified.",
        pattern: #"(?i)\b(?:SIRET|SIREN)"# + anchorGap + #"(\d{3}\s?\d{3}\s?\d{3}(?:\s?\d{5})?)\b"#,
        category: .accountNumber,
        sample: "SIREN: 732 829 320",
        counterexample: "SIREN: 732 829 321",
        regionCode: "FR",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    public static let frPassport = Preset(
        id: "fr.passport",
        name: "French passport number",
        summary: "Two digits, two letters, five digits written after “passeport”.",
        pattern: #"(?i)\bpasse?port"# + anchorGap + #"(\d{2}[A-Z]{2}\d{5})\b"#,
        category: .accountNumber,
        sample: "Passeport: 12AB34567",
        counterexample: "Passeport: 12AB",
        regionCode: "FR",
        kind: .passport,
        tier: .anchored
    )

    // MARK: Germany

    public static let deSteuerId = Preset(
        id: "de.steuerId",
        name: "German Steuer-ID",
        summary: "11-digit steuerliche Identifikationsnummer; ISO 7064 check digit verified.",
        pattern: #"\b[1-9]\d\s?\d{3}\s?\d{3}\s?\d{3}\b"#,
        category: .accountNumber,
        sample: "86095742719",
        counterexample: "86095742718",
        regionCode: "DE",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.germanSteuerId($0) }
    )

    public static let deSozialversicherungsnummer = Preset(
        id: "de.svnr",
        name: "German Sozialversicherungsnummer",
        summary: "12-character pension insurance number (65 170839 J 003); check digit verified.",
        pattern: #"\b\d{2}\s?(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}\s?[A-Z]\s?\d{3}\b"#,
        category: .accountNumber,
        sample: "65 170839 J 003",
        counterexample: "65 170839 J 004",
        regionCode: "DE",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.germanSozialversicherungsnummer($0) }
    )

    public static let dePersonalausweis = Preset(
        id: "de.personalausweis",
        name: "German Personalausweis number",
        summary: "9-character ID card number (+ check digit) written after “Personalausweis” or “Ausweisnummer”.",
        pattern:
            #"(?i)\b(?:personalausweis(?:nummer)?|ausweisnummer|ausweis-?nr\.?)"# + anchorGap
            + #"([CFGHJKLMNPRTVWXYZ0-9]{9}\d?)\b"#,
        category: .accountNumber,
        sample: "Personalausweis: L01X00T471",
        counterexample: "Personalausweis: L01X00T472",
        regionCode: "DE",
        kind: .nationalID,
        tier: .validated,
        validator: { $0.count == 9 || PrivacyChecksums.icao9303($0) }
    )

    public static let deKrankenversichertennummer = Preset(
        id: "de.kvnr",
        name: "German Krankenversichertennummer",
        summary: "Letter + 9 digits written after “Krankenversichertennummer” or “KVNR”; check digit verified.",
        pattern: #"(?i)\b(?:krankenversichertennummer|KVNR|versichertennummer)"# + anchorGap + #"([A-Z]\d{9})\b"#,
        category: .accountNumber,
        sample: "KVNR: A123456780",
        counterexample: "KVNR: A123456781",
        regionCode: "DE",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.germanKrankenversichertennummer($0) }
    )

    public static let deBLZ = Preset(
        id: "de.blz",
        name: "German Bankleitzahl",
        summary: "8-digit bank code written after “BLZ”.",
        pattern: #"\bBLZ"# + anchorGap + #"(\d{3}\s?\d{3}\s?\d{2})\b"#,
        category: .accountNumber,
        sample: "BLZ: 370 400 44",
        counterexample: "BLZ: 370",
        regionCode: "DE",
        kind: .bankAccount,
        tier: .anchored
    )

    // MARK: Netherlands

    public static let nlBSN = Preset(
        id: "nl.bsn",
        name: "Dutch BSN",
        summary: "9-digit burgerservicenummer; 11-proef verified.",
        pattern: #"\b\d{9}\b"#,
        category: .accountNumber,
        sample: "111222333",
        counterexample: "123456789",
        regionCode: "NL",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.dutchBSN($0) }
    )

    // MARK: Belgium

    public static let beNationalRegister = Preset(
        id: "be.nationalRegister",
        name: "Belgian National Register number",
        summary: "YY.MM.DD-XXX.XX rijksregisternummer; mod-97 verified.",
        pattern: #"\b\d{2}\.?(?:0[1-9]|1[0-2])\.?(?:0[1-9]|[12]\d|3[01])[-.]?\d{3}\.?\d{2}\b"#,
        category: .accountNumber,
        sample: "85.07.30-033.28",
        counterexample: "85.07.30-033.29",
        regionCode: "BE",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.belgianNationalRegister($0) }
    )

    // MARK: Luxembourg

    public static let luNationalId = Preset(
        id: "lu.nationalId",
        name: "Luxembourg national identification number",
        summary: "13-digit matricule (YYYYMMDD + 5); Luhn and Verhoeff check digits verified.",
        pattern: #"\b(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{5}\b"#,
        category: .accountNumber,
        sample: "1990010112384",
        counterexample: "1990010112385",
        regionCode: "LU",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.luxembourgNationalId($0) }
    )

    // MARK: Switzerland

    public static let chAHV = Preset(
        id: "ch.ahv",
        name: "Swiss AHV / AVS number",
        summary: "756.XXXX.XXXX.XX social security number; EAN-13 check digit verified.",
        pattern: #"\b756\.?\d{4}\.?\d{4}\.?\d{2}\b"#,
        category: .accountNumber,
        sample: "756.9217.0769.85",
        counterexample: "756.9217.0769.86",
        regionCode: "CH",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.ean13($0) }
    )

    // MARK: Austria

    public static let atSVNR = Preset(
        id: "at.svnr",
        name: "Austrian Sozialversicherungsnummer",
        summary: "10-digit SVNR (XXXX DDMMYY); check digit verified.",
        pattern: #"\b\d{4}\s?(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}\b"#,
        category: .accountNumber,
        sample: "1237 010180",
        counterexample: "1238 010180",
        regionCode: "AT",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.austrianSVNR($0) }
    )

    // MARK: Liechtenstein

    public static let liPEID = Preset(
        id: "li.peid",
        name: "Liechtenstein PEID",
        summary: "Personenidentifikationsnummer written after “PEID”.",
        pattern: #"\bPEID"# + anchorGap + #"(\d{4,12})\b"#,
        category: .accountNumber,
        sample: "PEID: 1234567",
        counterexample: "PEID: 12",
        regionCode: "LI",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Spain

    public static let esDNI = Preset(
        id: "es.dni",
        name: "Spanish DNI",
        summary: "Eight digits + control letter; letter verified.",
        pattern: #"\b\d{8}[- ]?[A-HJ-NP-TV-Z]\b"#,
        category: .accountNumber,
        sample: "12345678Z",
        counterexample: "12345678A",
        regionCode: "ES",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.spanishDNI($0) }
    )

    public static let esNIE = Preset(
        id: "es.nie",
        name: "Spanish NIE",
        summary: "X/Y/Z + seven digits + control letter; letter verified.",
        pattern: #"\b[XYZ][- ]?\d{7}[- ]?[A-HJ-NP-TV-Z]\b"#,
        category: .accountNumber,
        sample: "X1234567L",
        counterexample: "X1234567A",
        regionCode: "ES",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.spanishNIE($0) }
    )

    public static let esNSS = Preset(
        id: "es.nss",
        name: "Spanish Seguridad Social number",
        summary: "12-digit NSS / NUSS written after the keyword; mod-97 verified.",
        pattern:
            #"(?i)\b(?:NSS|NUSS|n[úu]mero\s+de\s+(?:la\s+)?seguridad\s+social|afiliaci[óo]n)"# + anchorGap
            + #"(\d{2}[ /]?\d{8}[ /]?\d{2})\b"#,
        category: .accountNumber,
        sample: "NSS: 28 12345678 40",
        counterexample: "NSS: 28 12345678 41",
        regionCode: "ES",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.spanishNSS($0) }
    )

    // MARK: Portugal

    public static let ptNIF = Preset(
        id: "pt.nif",
        name: "Portuguese NIF",
        summary: "9-digit Número de Identificação Fiscal; check digit verified.",
        pattern: #"\b[1235689]\d{8}\b"#,
        category: .accountNumber,
        sample: "123456789",
        counterexample: "123456788",
        regionCode: "PT",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.portugueseNIF($0) }
    )

    public static let ptCartaoCidadao = Preset(
        id: "pt.cartaoCidadao",
        name: "Portuguese Cartão de Cidadão",
        summary: "Citizen card number (8 digits + check + 2 letters + digit) written after “cartão de cidadão”.",
        pattern: #"(?i)\bcart[ãa]o\s+de\s+cidad[ãa]o"# + anchorGap + #"(\d{8}\s?\d\s?[A-Z0-9]{2}\d)\b"#,
        category: .accountNumber,
        sample: "Cartão de Cidadão: 12345678 9 ZZ0",
        counterexample: "Cartão de Cidadão: 1234",
        regionCode: "PT",
        kind: .nationalID,
        tier: .anchored
    )

    public static let ptNISS = Preset(
        id: "pt.niss",
        name: "Portuguese NISS",
        summary: "11-digit social security number written after “NISS”; check digit verified.",
        pattern: #"\bNISS"# + anchorGap + #"([12]\d{10})\b"#,
        category: .accountNumber,
        sample: "NISS: 12345678902",
        counterexample: "NISS: 12345678903",
        regionCode: "PT",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.portugueseNISS($0) }
    )

    // MARK: Italy

    public static let itCodiceFiscale = Preset(
        id: "it.codiceFiscale",
        name: "Italian codice fiscale",
        summary: "16-character tax code; control character verified.",
        pattern: #"\b[A-Z]{6}\d{2}[A-EHLMPR-T](?:[04][1-9]|[1256]\d|[37][01])[A-Z]\d{3}[A-Z]\b"#,
        category: .accountNumber,
        sample: "RSSMRA85T10A562S",
        counterexample: "RSSMRA85T10A562T",
        regionCode: "IT",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.italianCodiceFiscale($0) }
    )

    public static let itPartitaIVA = Preset(
        id: "it.partitaIva",
        name: "Italian Partita IVA",
        summary: "11-digit VAT number written after “Partita IVA” or “P.IVA”; Luhn-verified.",
        pattern: #"(?i)\b(?:partita\s+IVA|P\.?\s?IVA)"# + anchorGap + #"(\d{11})\b"#,
        category: .accountNumber,
        sample: "P.IVA: 12345678903",
        counterexample: "P.IVA: 12345678904",
        regionCode: "IT",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    // MARK: Malta

    public static let mtIdCard = Preset(
        id: "mt.idCard",
        name: "Maltese ID card number",
        summary: "Seven digits followed by a letter (M, G, A, P, L, H, B, Z).",
        pattern: #"\b\d{7}[MGAPLHBZ]\b"#,
        category: .accountNumber,
        sample: "0123456M",
        counterexample: "0123456X",
        regionCode: "MT",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Cyprus

    public static let cyId = Preset(
        id: "cy.id",
        name: "Cypriot ID number",
        summary: "ID number written after “ID” / “identity card”.",
        pattern: #"(?i)\b(?:ID|identity\s+card|ταυτότητα)\s*(?:card\s*)?(?:no\.?|number|αρ\.?)"# + anchorGap
            + #"(\d{6,10})\b"#,
        category: .accountNumber,
        sample: "ID number: 01234567",
        counterexample: "ID number: 12",
        regionCode: "CY",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Greece

    public static let grAMKA = Preset(
        id: "gr.amka",
        name: "Greek AMKA",
        summary: "11-digit social security number (DDMMYY + 5) written after “AMKA”; Luhn-verified.",
        pattern: #"(?i)\b(?:AMKA|ΑΜΚΑ)"# + anchorGap + #"((?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{7})\b"#,
        category: .accountNumber,
        sample: "AMKA: 01019012341",
        counterexample: "AMKA: 01019012342",
        regionCode: "GR",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    public static let grAFM = Preset(
        id: "gr.afm",
        name: "Greek AFM",
        summary: "9-digit tax number written after “AFM” / “ΑΦΜ”; check digit verified.",
        pattern: #"(?i)\b(?:AFM|ΑΦΜ)"# + anchorGap + #"(\d{9})\b"#,
        category: .accountNumber,
        sample: "AFM: 123456783",
        counterexample: "AFM: 123456784",
        regionCode: "GR",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.greekAFM($0) }
    )

    // MARK: Sweden

    public static let sePersonnummer = Preset(
        id: "se.personnummer",
        name: "Swedish personnummer",
        summary: "YYMMDD-XXXX personal identity number (also samordningsnummer); Luhn-verified.",
        pattern: #"\b(?:\d{2})?\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]|[6-8]\d|9[01])[-+]?\d{4}\b"#,
        category: .accountNumber,
        sample: "811218-9876",
        counterexample: "811218-9877",
        regionCode: "SE",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.swedishPersonnummer($0) }
    )

    // MARK: Norway

    public static let noFodselsnummer = Preset(
        id: "no.fodselsnummer",
        name: "Norwegian fødselsnummer",
        summary: "11-digit national identity number (also D-number); both control digits verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01]|[4-6]\d|7[01])(?:0[1-9]|1[0-2]|4[1-9]|5[0-2])\d{2}\s?\d{5}\b"#,
        category: .accountNumber,
        sample: "01019012480",
        counterexample: "01019012481",
        regionCode: "NO",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.norwegianFodselsnummer($0) }
    )

    // MARK: Denmark

    public static let dkCPR = Preset(
        id: "dk.cpr",
        name: "Danish CPR number",
        summary: "DDMMYY-XXXX personal number (calendar date verified).",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}-\d{4}\b"#,
        category: .accountNumber,
        sample: "010190-1234",
        counterexample: "320190-1234",
        regionCode: "DK",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Finland

    public static let fiHETU = Preset(
        id: "fi.hetu",
        name: "Finnish henkilötunnus",
        summary: "DDMMYY-XXXC personal identity code; control character verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01])(?:0[1-9]|1[0-2])\d{2}[-+A-FYXWVU]\d{3}[0-9A-FHJ-NPR-Y]\b"#,
        category: .accountNumber,
        sample: "131052-308T",
        counterexample: "131052-308U",
        regionCode: "FI",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.finnishHETU($0) }
    )

    // MARK: Iceland

    public static let isKennitala = Preset(
        id: "is.kennitala",
        name: "Icelandic kennitala",
        summary: "DDMMYY-XXXX identification number; check digit verified.",
        pattern: #"\b(?:0[1-9]|[12]\d|3[01]|[4-6]\d|7[01])(?:0[1-9]|1[0-2])\d{2}-?\d{3}[089]\b"#,
        category: .accountNumber,
        sample: "010190-1269",
        counterexample: "010190-1279",
        regionCode: "IS",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.icelandicKennitala($0) }
    )

    static let europeWest: [Preset] = [
        gbNINO, gbNHS, gbDrivingLicence, gbPassport, gbSortCode, gbUTR,
        iePPS,
        frNIR, frSIREN, frPassport,
        deSteuerId, deSozialversicherungsnummer, dePersonalausweis, deKrankenversichertennummer, deBLZ,
        nlBSN,
        beNationalRegister,
        luNationalId,
        chAHV,
        atSVNR,
        liPEID,
        esDNI, esNIE, esNSS,
        ptNIF, ptCartaoCidadao, ptNISS,
        itCodiceFiscale, itPartitaIVA,
        mtIdCard,
        cyId,
        grAMKA, grAFM,
        sePersonnummer,
        noFodselsnummer,
        dkCPR,
        fiHETU,
        isKennitala,
    ]
}
