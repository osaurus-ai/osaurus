//
//  PrivacyChecksumsTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Known-good / known-bad vectors for every check-digit algorithm in
//  `PrivacyChecksums`. Each "bad" value is the good one with its final
//  digit bumped (or a published invalid example), so a broken weight
//  table or off-by-one fails loudly instead of letting a preset match
//  garbage — or miss real IDs.
//

import Testing

@testable import OsaurusCore

@Suite("PrivacyChecksums")
struct PrivacyChecksumsTests {
    private typealias C = PrivacyChecksums

    private func check(_ f: (String) -> Bool, good: [String], bad: [String], _ name: String) {
        for g in good { #expect(f(g), "\(name) should accept \(g)") }
        for b in bad { #expect(!f(b), "\(name) should reject \(b)") }
    }

    @Test func generic() {
        check(
            C.luhn,
            good: ["4111 1111 1111 1111", "79927398713", "123456782"],
            bad: ["4111 1111 1111 1112", "", "abc"],
            "luhn"
        )
        check(C.verhoeff, good: ["234567890124", "2363"], bad: ["234567890125", "2364"], "verhoeff")
        check(C.iso7064Mod11_10, good: ["69435151530", "86095742719"], bad: ["69435151531"], "iso7064 11,10")
        check(C.chineseResidentId, good: ["11010519491231002X"], bad: ["110105194912310021"], "cn id")
        check(C.ean13, good: ["756.9217.0769.85", "4006381333931"], bad: ["756.9217.0769.86"], "ean13")
        check(
            C.iban,
            good: ["GB82 WEST 1234 5698 7654 32", "DE89 3704 0044 0532 0130 00"],
            bad: ["GB82 WEST 1234 5698 7654 33", "DE00 3704 0044 0532 0130 00"],
            "iban"
        )
        check(C.icao9303, good: ["L01X00T471"], bad: ["L01X00T472"], "icao9303")
        check(C.mod36, good: ["27AAPFU0939F1ZV"], bad: ["27AAPFU0939F1ZW"], "mod36")
    }

    @Test func americas() {
        check(C.usABARouting, good: ["021000021", "011000015"], bad: ["021000022"], "aba")
        // 046 454 286 is Luhn-valid but SINs never start with 0 or 8.
        check(C.canadianSIN, good: ["130 692 544"], bad: ["130 692 545", "046 454 286", "846 454 286"], "sin")
        check(C.mexicanCURP, good: ["GODE561231HDFRRL06"], bad: ["GODE561231HDFRRL07"], "curp")
        check(C.mexicanCLABE, good: ["012180000118359713"], bad: ["012180000118359714"], "clabe")
        check(C.brazilianCPF, good: ["529.982.247-25"], bad: ["529.982.247-26", "111.111.111-11"], "cpf")
        check(C.brazilianCNPJ, good: ["11.222.333/0001-81"], bad: ["11.222.333/0001-82"], "cnpj")
        check(C.brazilianPIS, good: ["12345678900"], bad: ["12345678901"], "pis")
        check(C.argentineCUIT, good: ["20123456786"], bad: ["20123456787"], "cuit")
        check(C.chileanRUT, good: ["12.345.678-5"], bad: ["12.345.678-6"], "rut")
        check(C.colombianNIT, good: ["9001234568"], bad: ["9001234569"], "nit")
        check(C.peruvianRUC, good: ["20123456786"], bad: ["20123456787"], "ruc")
        check(C.ecuadorianCedula, good: ["1712345675"], bad: ["1712345676"], "cedula ec")
        check(C.uruguayanCI, good: ["12345672"], bad: ["12345673"], "ci uy")
        // The check digit covers the first 8 digits; the trailing 4 are
        // department / municipality codes.
        check(C.guatemalanCUI, good: ["1234 56789 0101"], bad: ["1234 56788 0101"], "cui")
    }

    @Test func europeWest() {
        check(C.ukNHS, good: ["943 476 5919"], bad: ["943 476 5918"], "nhs")
        check(C.ukUTR, good: ["1123456789"], bad: ["2123456789"], "utr")
        check(C.irishPPS, good: ["1234567T"], bad: ["1234567A"], "pps")
        check(C.frenchNIR, good: ["2 55 08 14 168 025 38"], bad: ["2 55 08 14 168 025 39"], "nir")
        check(C.germanSteuerId, good: ["86095742719"], bad: ["86095742718", "11111111111"], "steuer-id")
        check(C.germanSozialversicherungsnummer, good: ["65 170839 J 003"], bad: ["65 170839 J 004"], "svnr de")
        check(C.germanKrankenversichertennummer, good: ["A123456780"], bad: ["A123456781"], "kvnr")
        check(C.dutchBSN, good: ["111222333"], bad: ["123456789"], "bsn")
        check(C.belgianNationalRegister, good: ["85.07.30-033.28"], bad: ["85.07.30-033.29"], "be nrn")
        check(C.luxembourgNationalId, good: ["1990010112384"], bad: ["1990010112385"], "lu id")
        check(C.austrianSVNR, good: ["1237 010180"], bad: ["1238 010180"], "svnr at")
        check(C.spanishDNI, good: ["12345678Z"], bad: ["12345678A"], "dni")
        check(C.spanishNIE, good: ["X1234567L"], bad: ["X1234567A"], "nie")
        check(C.spanishNSS, good: ["28 12345678 40"], bad: ["28 12345678 41"], "nss")
        check(C.portugueseNIF, good: ["123456789"], bad: ["123456788"], "nif")
        check(C.portugueseNISS, good: ["12345678902"], bad: ["12345678903"], "niss")
        check(C.italianCodiceFiscale, good: ["RSSMRA85T10A562S"], bad: ["RSSMRA85T10A562T"], "codice fiscale")
        check(C.greekAFM, good: ["123456783"], bad: ["123456784"], "afm")
        check(C.swedishPersonnummer, good: ["811218-9876", "19811218-9876"], bad: ["811218-9877"], "personnummer")
        check(C.norwegianFodselsnummer, good: ["01019012480"], bad: ["01019012481"], "fødselsnummer")
        check(C.finnishHETU, good: ["131052-308T"], bad: ["131052-308U"], "hetu")
        check(C.icelandicKennitala, good: ["010190-1269"], bad: ["010190-1279"], "kennitala")
    }

    @Test func europeEast() {
        check(C.balticPersonalCode, good: ["37605030299", "39001011237"], bad: ["37605030298"], "baltic")
        check(C.latvianPersonasKods, good: ["010190-12349"], bad: ["010190-12348"], "personas kods")
        check(C.polishPESEL, good: ["44051401359"], bad: ["44051401358"], "pesel")
        check(C.polishNIP, good: ["123-456-78-83"], bad: ["123-456-78-84"], "nip")
        check(C.polishDowodOsobisty, good: ["ABA 212345"], bad: ["ABA 312345"], "dowód")
        check(C.czechSlovakRodneCislo, good: ["780123/3550", "855612/1233"], bad: ["780123/3551"], "rodné číslo")
        check(C.hungarianTAJ, good: ["123 456 788"], bad: ["123 456 789"], "taj")
        check(C.hungarianSzemelyiSzam, good: ["1 900101 1249"], bad: ["1 900101 1248"], "személyi szám")
        check(C.hungarianAdoazonosito, good: ["8123456786"], bad: ["8123456787"], "adóazonosító")
        check(C.jmbg, good: ["0101990500003", "0101990710008"], bad: ["0101990500004"], "jmbg")
        check(C.bulgarianEGN, good: ["7523169263"], bad: ["7523169264"], "egn")
        check(C.romanianCNP, good: ["1800101221144"], bad: ["1800101221145"], "cnp")
        check(C.moldovanIDNP, good: ["2000123456788"], bad: ["2000123456789"], "idnp")
        check(C.ukrainianRNTRC, good: ["3012345670"], bad: ["3012345671"], "rntrc")
        check(C.russianSNILS, good: ["112-233-445 95"], bad: ["112-233-445 96"], "snils")
        check(C.russianINN, good: ["7701234560"], bad: ["7701234561"], "inn")
        check(C.turkishTCKimlik, good: ["10000000146"], bad: ["10000000147"], "tc kimlik")
    }

    @Test func asiaPacific() {
        check(C.hongKongHKID, good: ["A123456(3)"], bad: ["A123456(4)"], "hkid")
        check(C.taiwanNationalId, good: ["A123456789"], bad: ["A123456780"], "tw id")
        check(C.japaneseMyNumber, good: ["1234 5678 9018"], bad: ["1234 5678 9019"], "my number")
        check(C.koreanRRN, good: ["900101-1234568"], bad: ["900101-1234569"], "rrn")
        check(C.singaporeNRIC, good: ["S1234567D"], bad: ["S1234567E"], "nric")
        check(C.thaiNationalId, good: ["1-1012-34567-89-7"], bad: ["1-1012-34567-89-8"], "th id")
        check(C.australianTFN, good: ["123 456 782"], bad: ["123 456 783"], "tfn")
        check(C.australianMedicare, good: ["2123 45670 1"], bad: ["2123 45671 1"], "medicare")
        check(C.australianABN, good: ["51 824 753 556"], bad: ["51 824 753 557"], "abn")
        check(C.newZealandIRD, good: ["49-091-850"], bad: ["49-091-851"], "ird")
        check(C.newZealandNHI, good: ["ZZZ0016"], bad: ["ZZZ0017"], "nhi")
        check(C.kazakhIIN, good: ["900101300126"], bad: ["900101300127"], "iin")
        check(C.sriLankanNIC, good: ["901234567V", "199012345678"], bad: ["909994567V"], "nic")
    }

    @Test func middleEastAfrica() {
        check(C.kuwaitiCivilId, good: ["290010112346"], bad: ["290010112347"], "civil id")
        check(C.iranianMelliCode, good: ["001-234567-9"], bad: ["001-234567-8", "1111111111"], "melli")
    }
}
