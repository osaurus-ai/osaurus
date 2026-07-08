//
//  ChatSessionDataTitleTests.swift
//  osaurusTests
//
//  Regression coverage for titles generated from attachment-only chats.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatSessionDataTitleTests {
    @Test func attachmentOnlyTitleUsesBasenameWithoutPrivatePath() {
        let attachment = Attachment.document(
            filename: "/Users/mmeding/private/assessment.txt",
            content: "rubric details",
            fileSize: 13
        )
        let title = ChatSessionData.generateTitle(
            from: [ChatTurnData(role: .user, content: "", attachments: [attachment])]
        )

        #expect(title == "assessment.txt")
        #expect(title.contains("/Users/mmeding") == false)
    }

    @Test func attachmentOnlyTitleFallsBackToTypeForUnnamedMedia() {
        let title = ChatSessionData.generateTitle(
            from: [
                ChatTurnData(
                    role: .user,
                    content: "   ",
                    attachments: [
                        Attachment.image(Data([0x01])),
                        Attachment.video(Data([0x02]), filename: nil),
                    ]
                )
            ]
        )

        #expect(title == "image and video")
    }

    @Test func attachmentOnlyTitleSummarizesThreeOrMoreAttachments() {
        let title = ChatSessionData.generateTitle(
            from: [
                ChatTurnData(
                    role: .user,
                    content: "",
                    attachments: [
                        Attachment.document(filename: "", content: "a", fileSize: 1),
                        Attachment.audio(Data([0x01]), format: "wav", filename: nil),
                        Attachment.image(Data([0x02])),
                    ]
                )
            ]
        )

        #expect(title == "attachment and 2 attachments")
    }
}
