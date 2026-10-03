//
//  PrivacyRulePresets+Americas.swift
//  osaurus / PrivacyFilter
//
//  North, Central and South America. See `PrivacyRulePresets.swift`
//  for the tier contract and `PrivacyChecksums.swift` for the
//  check-digit algorithms referenced here.
//

import Foundation

extension PrivacyRulePresets {
    // MARK: United States

    /// US SSN — XXX-XX-XXXX. Rejects the SSA-reserved blocks (000 /
    /// 666 / 9xx area, 00 group, 0000 serial). Was a built-in before
    /// the catalogue became region-aware; the schema-2 migration
    /// keeps it on for existing users.
    public static let usSSN = Preset(
        id: "us.ssn",
        name: "US Social Security Number",
        summary: "XXX-XX-XXXX, excluding the reserved 000 / 666 / 9xx area and 00 / 0000 blocks.",
        pattern: #"\b(?!000|666|9\d{2})\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#,
        category: .accountNumber,
        sample: "123-45-6789",
        counterexample: "000-12-3456",
        regionCode: "US",
        kind: .nationalID,
        tier: .anchored
    )

    public static let usITIN = Preset(
        id: "us.itin",
        name: "US ITIN",
        summary: "Individual Taxpayer Identification Number — 9XX-(50–65, 70–88, 90–92, 94–99)-XXXX.",
        pattern: #"\b9\d{2}-(?:5\d|6[0-5]|7\d|8[0-8]|9[0-24-9])-\d{4}\b"#,
        category: .accountNumber,
        sample: "912-70-1234",
        counterexample: "912-01-1234",
        regionCode: "US",
        kind: .taxID,
        tier: .anchored
    )

    public static let usEIN = Preset(
        id: "us.ein",
        name: "US EIN",
        summary: "Employer Identification Number (XX-XXXXXXX) written after “EIN” or “employer identification number”.",
        pattern: #"(?i)\b(?:EIN|employer\s+identification\s+(?:number|no\.?)|federal\s+tax\s+id)"# + anchorGap
            + #"(\d{2}-\d{7})\b"#,
        category: .accountNumber,
        sample: "EIN: 12-3456789",
        counterexample: "EIN: 123-456789",
        regionCode: "US",
        kind: .taxID,
        tier: .anchored
    )

    public static let usMedicareMBI = Preset(
        id: "us.medicareMBI",
        name: "US Medicare Beneficiary Identifier",
        summary: "11-character MBI (e.g. 1EG4-TE5-MK73) in the CMS letter/digit layout.",
        pattern:
            #"\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9]\d-?[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9]\d-?[AC-HJKMNP-RT-Y]{2}\d{2}\b"#,
        category: .accountNumber,
        sample: "1EG4-TE5-MK73",
        counterexample: "1EG4-TE5-MK7",
        regionCode: "US",
        kind: .healthID,
        tier: .anchored
    )

    public static let usABARouting = Preset(
        id: "us.abaRouting",
        name: "US ABA routing number",
        summary: "9-digit bank routing transit number written after “routing” or “ABA”; checksum-verified.",
        pattern: #"(?i)\b(?:ABA|routing(?:\s+transit)?(?:\s+(?:number|no\.?|#))?|RTN)"# + anchorGap + #"(\d{9})\b"#,
        category: .accountNumber,
        sample: "Routing: 021000021",
        counterexample: "Routing: 021000022",
        regionCode: "US",
        kind: .bankAccount,
        tier: .validated,
        validator: { PrivacyChecksums.usABARouting($0) }
    )

    /// US driver's license — generic across states (6–12
    /// alphanumerics anchored by "DL" / "driver's license").
    public static let driversLicense = Preset(
        id: "driversLicense",
        name: "US Driver's License",
        summary: "DL-prefixed license numbers (6–12 alphanumerics).",
        pattern: #"(?i)\b(?:DL|driver'?s?\s*license)"# + anchorGap + #"([A-Z0-9]{6,12})\b"#,
        category: .accountNumber,
        sample: "DL: A1234567",
        counterexample: "DL: A12",
        regionCode: "US",
        kind: .driversLicense,
        tier: .anchored
    )

    /// US passport — 9 digits, optionally preceded by a single
    /// capital letter (newer issuances).
    public static let passport = Preset(
        id: "passport",
        name: "US Passport Number",
        summary: "9 digits, optionally preceded by a single letter, anchored on the word \"passport\".",
        pattern: #"(?i)\bpassport"# + anchorGap + #"([A-Z]?\d{9})\b"#,
        category: .accountNumber,
        sample: "Passport: 123456789",
        counterexample: "Passport: 12345",
        regionCode: "US",
        kind: .passport,
        tier: .anchored
    )

    // MARK: Canada

    public static let caSIN = Preset(
        id: "ca.sin",
        name: "Canadian SIN",
        summary: "9-digit Social Insurance Number (XXX XXX XXX); Luhn-verified.",
        pattern: #"\b[1-79]\d{2}[- ]?\d{3}[- ]?\d{3}\b"#,
        category: .accountNumber,
        sample: "130 692 544",
        counterexample: "130 692 545",
        regionCode: "CA",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.canadianSIN($0) }
    )

    public static let caPassport = Preset(
        id: "ca.passport",
        name: "Canadian passport number",
        summary: "Two letters + six digits written after “passport”.",
        pattern: #"(?i)\bpassport"# + anchorGap + #"([A-Z]{2}\d{6})\b"#,
        category: .accountNumber,
        sample: "Passport: AB123456",
        counterexample: "Passport: AB12",
        regionCode: "CA",
        kind: .passport,
        tier: .anchored
    )

    public static let caHealthCard = Preset(
        id: "ca.healthCard",
        name: "Canadian provincial health card",
        summary:
            "Health card numbers written after “health card”, “OHIP”, “RAMQ”, “MSP”, “AHCIP” or “carte d'assurance maladie”.",
        pattern:
            #"(?i)\b(?:health\s+card|OHIP|RAMQ|MSP|AHCIP|carte\s+d'assurance\s+maladie)"# + anchorGap
            + #"((?=[A-Z0-9\-]*\d)[A-Z0-9][A-Z0-9\-]{6,14}[A-Z0-9])\b"#,
        category: .accountNumber,
        sample: "OHIP: 1234-567-890-AB",
        counterexample: "health card renewal",
        regionCode: "CA",
        kind: .healthID,
        tier: .anchored
    )

    public static let caTransitNumber = Preset(
        id: "ca.transitNumber",
        name: "Canadian bank transit number",
        summary: "5-digit branch transit number written after “transit”.",
        pattern: #"(?i)\btransit(?:\s+(?:number|no\.?))?"# + anchorGap + #"(\d{5})\b"#,
        category: .accountNumber,
        sample: "Transit: 12345",
        counterexample: "Transit: 12",
        regionCode: "CA",
        kind: .bankAccount,
        tier: .anchored
    )

    // MARK: Mexico

    public static let mxCURP = Preset(
        id: "mx.curp",
        name: "Mexican CURP",
        summary: "18-character Clave Única de Registro de Población; check digit verified.",
        pattern:
            #"\b[A-Z][AEIOUX][A-Z]{2}\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[HM](?:AS|BC|BS|CC|CL|CM|CS|CH|DF|DG|GT|GR|HG|JC|MC|MN|MS|NT|NL|OC|PL|QT|QR|SP|SL|SR|TC|TS|TL|VZ|YN|ZS|NE)[B-DF-HJ-NP-TV-Z]{3}[A-Z0-9]\d\b"#,
        category: .accountNumber,
        sample: "GODE561231HDFRRL06",
        counterexample: "GODE561231HDFRRL07",
        regionCode: "MX",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.mexicanCURP($0) }
    )

    public static let mxRFC = Preset(
        id: "mx.rfc",
        name: "Mexican RFC",
        summary: "Registro Federal de Contribuyentes (12–13 characters) written after “RFC”.",
        pattern: #"\bRFC"# + anchorGap + #"([A-ZÑ&]{3,4}\d{6}[A-Z0-9]{3})\b"#,
        category: .accountNumber,
        sample: "RFC: GODE561231GR8",
        counterexample: "RFC: GODE5612",
        regionCode: "MX",
        kind: .taxID,
        tier: .anchored
    )

    public static let mxCLABE = Preset(
        id: "mx.clabe",
        name: "Mexican CLABE",
        summary: "18-digit interbank account number; check digit verified.",
        pattern: #"\b\d{18}\b"#,
        category: .accountNumber,
        sample: "012180000118359713",
        counterexample: "012180000118359714",
        regionCode: "MX",
        kind: .bankAccount,
        tier: .validated,
        validator: { PrivacyChecksums.mexicanCLABE($0) }
    )

    public static let mxINE = Preset(
        id: "mx.ine",
        name: "Mexican INE / IFE voter key",
        summary: "18-character clave de elector written after “INE”, “IFE” or “clave de elector”.",
        pattern: #"(?i)\b(?:INE|IFE|clave\s+de\s+elector)"# + anchorGap + #"([A-Z]{6}\d{8}[HM]\d{3})\b"#,
        category: .accountNumber,
        sample: "Clave de elector: GMVLMR80070109M100",
        counterexample: "INE: GMVLMR80",
        regionCode: "MX",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Brazil

    public static let brCPF = Preset(
        id: "br.cpf",
        name: "Brazilian CPF",
        summary: "11-digit Cadastro de Pessoas Físicas (XXX.XXX.XXX-XX); both check digits verified.",
        pattern: #"\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b"#,
        category: .accountNumber,
        sample: "529.982.247-25",
        counterexample: "111.111.111-11",
        regionCode: "BR",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.brazilianCPF($0) }
    )

    public static let brCNPJ = Preset(
        id: "br.cnpj",
        name: "Brazilian CNPJ",
        summary: "14-digit company registration (XX.XXX.XXX/XXXX-XX); check digits verified.",
        pattern: #"\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b"#,
        category: .accountNumber,
        sample: "11.222.333/0001-81",
        counterexample: "11.222.333/0001-82",
        regionCode: "BR",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.brazilianCNPJ($0) }
    )

    public static let brRG = Preset(
        id: "br.rg",
        name: "Brazilian RG",
        summary: "Registro Geral identity number written after “RG”.",
        pattern: #"\bRG"# + anchorGap + #"(\d{1,2}\.?\d{3}\.?\d{3}-?[0-9X])\b"#,
        category: .accountNumber,
        sample: "RG: 12.345.678-9",
        counterexample: "RG: 12",
        regionCode: "BR",
        kind: .nationalID,
        tier: .anchored
    )

    public static let brPIS = Preset(
        id: "br.pis",
        name: "Brazilian PIS / PASEP / NIS",
        summary: "11-digit social programme number written after “PIS”, “PASEP”, “NIS” or “NIT”; check digit verified.",
        pattern: #"\b(?:PIS|PASEP|NIS|NIT)(?:/(?:PASEP|NIS|NIT))?"# + anchorGap + #"(\d{3}\.?\d{5}\.?\d{2}-?\d)\b"#,
        category: .accountNumber,
        sample: "PIS: 123.45678.90-0",
        counterexample: "PIS: 123.45678.90-1",
        regionCode: "BR",
        kind: .healthID,
        tier: .validated,
        validator: { PrivacyChecksums.brazilianPIS($0) }
    )

    public static let brCNH = Preset(
        id: "br.cnh",
        name: "Brazilian CNH",
        summary: "11-digit driver's licence number written after “CNH”.",
        pattern: #"\bCNH"# + anchorGap + #"(\d{11})\b"#,
        category: .accountNumber,
        sample: "CNH: 12345678901",
        counterexample: "CNH: 1234",
        regionCode: "BR",
        kind: .driversLicense,
        tier: .anchored
    )

    // MARK: Argentina

    public static let arCUIT = Preset(
        id: "ar.cuit",
        name: "Argentine CUIT / CUIL",
        summary: "11-digit tax / labour key (XX-XXXXXXXX-X); check digit verified.",
        pattern: #"\b(?:20|23|24|27|30|33|34)-?\d{8}-?\d\b"#,
        category: .accountNumber,
        sample: "20-12345678-6",
        counterexample: "20-12345678-7",
        regionCode: "AR",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.argentineCUIT($0) }
    )

    public static let arDNI = Preset(
        id: "ar.dni",
        name: "Argentine DNI",
        summary: "7–8 digit Documento Nacional de Identidad written after “DNI”.",
        pattern: #"\bDNI"# + anchorGap + #"(\d{1,2}\.?\d{3}\.?\d{3})\b"#,
        category: .accountNumber,
        sample: "DNI: 12.345.678",
        counterexample: "DNI: 12",
        regionCode: "AR",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Chile

    public static let clRUT = Preset(
        id: "cl.rut",
        name: "Chilean RUT / RUN",
        summary: "Rol Único Tributario (XX.XXX.XXX-X); check digit verified.",
        pattern: #"\b\d{1,2}\.?\d{3}\.?\d{3}-[\dkK]\b"#,
        category: .accountNumber,
        sample: "12.345.678-5",
        counterexample: "12.345.678-9",
        regionCode: "CL",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.chileanRUT($0) }
    )

    // MARK: Colombia

    public static let coCedula = Preset(
        id: "co.cedula",
        name: "Colombian cédula de ciudadanía",
        summary: "6–10 digit cédula written after “cédula” or “C.C.”.",
        pattern: #"(?i)\b(?:c[ée]dula(?:\s+de\s+ciudadan[íi]a)?|C\.C\.)"# + anchorGap
            + #"(\d{1,3}(?:\.\d{3}){2,3}|\d{6,10})\b"#,
        category: .accountNumber,
        sample: "Cédula: 1.234.567.890",
        counterexample: "Cédula: 12",
        regionCode: "CO",
        kind: .nationalID,
        tier: .anchored
    )

    public static let coNIT = Preset(
        id: "co.nit",
        name: "Colombian NIT",
        summary: "Número de Identificación Tributaria written after “NIT”; check digit verified.",
        pattern: #"\bNIT"# + anchorGap + #"(\d{3}\.?\d{3}\.?\d{3}-?\d)\b"#,
        category: .accountNumber,
        sample: "NIT: 900.123.456-8",
        counterexample: "NIT: 900.123.456-9",
        regionCode: "CO",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.colombianNIT($0) }
    )

    // MARK: Peru

    public static let peDNI = Preset(
        id: "pe.dni",
        name: "Peruvian DNI",
        summary: "8-digit Documento Nacional de Identidad written after “DNI”.",
        pattern: #"\bDNI"# + anchorGap + #"(\d{8})\b"#,
        category: .accountNumber,
        sample: "DNI: 12345678",
        counterexample: "DNI: 1234",
        regionCode: "PE",
        kind: .nationalID,
        tier: .anchored
    )

    public static let peRUC = Preset(
        id: "pe.ruc",
        name: "Peruvian RUC",
        summary: "11-digit Registro Único de Contribuyentes (10/15/16/17/20 prefix); check digit verified.",
        pattern: #"\b(?:10|15|16|17|20)\d{9}\b"#,
        category: .accountNumber,
        sample: "20123456786",
        counterexample: "20123456787",
        regionCode: "PE",
        kind: .taxID,
        tier: .validated,
        validator: { PrivacyChecksums.peruvianRUC($0) }
    )

    // MARK: Ecuador

    public static let ecCedula = Preset(
        id: "ec.cedula",
        name: "Ecuadorian cédula",
        summary: "10-digit cédula de identidad (province 01–24 / 30); check digit verified.",
        pattern: #"\b(?:0[1-9]|1\d|2[0-4]|30)[0-5]\d{7}\b"#,
        category: .accountNumber,
        sample: "1712345675",
        counterexample: "1712345676",
        regionCode: "EC",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.ecuadorianCedula($0) }
    )

    // MARK: Uruguay

    public static let uyCI = Preset(
        id: "uy.ci",
        name: "Uruguayan cédula de identidad",
        summary: "X.XXX.XXX-X cédula; check digit verified.",
        pattern: #"\b\d\.\d{3}\.\d{3}-\d\b|\b\d{7}-\d\b"#,
        category: .accountNumber,
        sample: "1.234.567-2",
        counterexample: "1.234.567-3",
        regionCode: "UY",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.uruguayanCI($0) }
    )

    // MARK: Venezuela

    public static let veCedula = Preset(
        id: "ve.cedula",
        name: "Venezuelan cédula",
        summary: "V- / E- prefixed cédula de identidad (V-12.345.678).",
        pattern: #"\b[VE]-\d{1,2}\.?\d{3}\.?\d{3}\b"#,
        category: .accountNumber,
        sample: "V-12.345.678",
        counterexample: "V-12",
        regionCode: "VE",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Guatemala

    public static let gtCUI = Preset(
        id: "gt.cui",
        name: "Guatemalan CUI / DPI",
        summary: "13-digit Código Único de Identificación written after “CUI” or “DPI”; check digit verified.",
        pattern: #"\b(?:CUI|DPI)"# + anchorGap + #"(\d{4}\s?\d{5}\s?\d{4})\b"#,
        category: .accountNumber,
        sample: "DPI: 1234 56789 0101",
        counterexample: "DPI: 1234 56788 0101",
        regionCode: "GT",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.guatemalanCUI($0) }
    )

    // MARK: Costa Rica

    public static let crCedula = Preset(
        id: "cr.cedula",
        name: "Costa Rican cédula",
        summary: "X-XXXX-XXXX cédula written after “cédula”.",
        pattern: #"(?i)\bc[ée]dula"# + anchorGap + #"(\d-?\d{4}-?\d{4})\b"#,
        category: .accountNumber,
        sample: "Cédula: 1-1234-5678",
        counterexample: "Cédula: 1-12",
        regionCode: "CR",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Panama

    public static let paCedula = Preset(
        id: "pa.cedula",
        name: "Panamanian cédula",
        summary: "Province-prefixed cédula (8-123-4567, PE-12-345, E-8-12345) written after “cédula”.",
        pattern: #"(?i)\bc[ée]dula"# + anchorGap + #"((?:PE|E|N|\d{1,2}(?:AV|PI)?)-\d{1,4}-\d{1,6})\b"#,
        category: .accountNumber,
        sample: "Cédula: 8-123-4567",
        counterexample: "Cédula: 8",
        regionCode: "PA",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Dominican Republic

    public static let doCedula = Preset(
        id: "do.cedula",
        name: "Dominican cédula",
        summary: "XXX-XXXXXXX-X cédula; Luhn-verified.",
        pattern: #"\b\d{3}-\d{7}-\d\b"#,
        category: .accountNumber,
        sample: "001-1234567-3",
        counterexample: "001-1234567-4",
        regionCode: "DO",
        kind: .nationalID,
        tier: .validated,
        validator: { PrivacyChecksums.luhn($0) }
    )

    // MARK: Bolivia

    public static let boCI = Preset(
        id: "bo.ci",
        name: "Bolivian CI",
        summary: "6–8 digit carnet de identidad written after “CI” or “cédula de identidad”.",
        pattern: #"\b(?:CI|[Cc][ée]dula\s+de\s+[Ii]dentidad)"# + anchorGap
            + #"(\d{6,8}(?:[- ]?(?:LP|CB|SC|OR|PT|TJ|CH|BE|PD))?)\b"#,
        category: .accountNumber,
        sample: "CI: 1234567 LP",
        counterexample: "CI: 123",
        regionCode: "BO",
        kind: .nationalID,
        tier: .anchored
    )

    // MARK: Paraguay

    public static let pyCI = Preset(
        id: "py.ci",
        name: "Paraguayan cédula",
        summary: "6–7 digit cédula de identidad written after “C.I.” or “cédula”.",
        pattern: #"(?i)\b(?:C\.I\.|c[ée]dula)"# + anchorGap + #"(\d{1,2}\.?\d{3}\.?\d{3})\b"#,
        category: .accountNumber,
        sample: "C.I.: 1.234.567",
        counterexample: "C.I.: 12",
        regionCode: "PY",
        kind: .nationalID,
        tier: .anchored
    )

    static let americas: [Preset] = [
        usSSN, usITIN, usEIN, usMedicareMBI, usABARouting, driversLicense, passport,
        caSIN, caPassport, caHealthCard, caTransitNumber,
        mxCURP, mxRFC, mxCLABE, mxINE,
        brCPF, brCNPJ, brRG, brPIS, brCNH,
        arCUIT, arDNI,
        clRUT,
        coCedula, coNIT,
        peDNI, peRUC,
        ecCedula,
        uyCI,
        veCedula,
        gtCUI,
        crCedula,
        paCedula,
        doCedula,
        boCI,
        pyCI,
    ]
}
