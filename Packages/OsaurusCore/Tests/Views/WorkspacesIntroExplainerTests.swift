//
//  WorkspacesIntroExplainerTests.swift
//  osaurusTests
//
//  Locks the sizing contract of the Workspaces tab's embedded explainer:
//  the diagram scales as one piece to the width its host offers, caps at
//  the design size, floors at the legibility minimum, and the canvas row
//  the host lays out is exactly as tall as the scaled drawing.
//

import CoreGraphics
import Testing

@testable import OsaurusCore

@MainActor
struct WorkspacesIntroExplainerTests {

    /// A pane at or wider than the design width keeps the designed size.
    @Test func scale_capsAtDesignSize() {
        let design = WorkspacesIntroExplainer.canvasDesignSize.width
        #expect(WorkspacesIntroExplainer.scale(fittingWidth: design) == 1)
        #expect(WorkspacesIntroExplainer.scale(fittingWidth: design + 400) == 1)
    }

    /// A narrower pane shrinks the diagram proportionally. The default
    /// Management window (1060pt, 240pt sidebar, 24pt padding) leaves
    /// roughly 772pt.
    @Test func scale_isProportionalBelowDesignWidth() {
        let scale = WorkspacesIntroExplainer.scale(fittingWidth: 772)
        #expect(abs(scale - 772.0 / 912.0) < 0.001)
        #expect(WorkspacesIntroExplainer.canvasDesignSize.width * scale <= 772)
    }

    /// Below the legibility floor the scale stops shrinking; a tiny or
    /// zero width never yields a zero or negative scale.
    @Test func scale_floorsAtMinimum() {
        let minimum = WorkspacesIntroExplainer.minimumScale
        #expect(WorkspacesIntroExplainer.scale(fittingWidth: 300) == minimum)
        #expect(WorkspacesIntroExplainer.scale(fittingWidth: 0) == minimum)
    }

    /// The canvas row's height follows the same scale as its width, so the
    /// placeholder the host lays out matches the scaled drawing exactly.
    @Test func canvasHeight_tracksScale() {
        let design = WorkspacesIntroExplainer.canvasDesignSize
        #expect(WorkspacesIntroExplainer.canvasHeight(fittingWidth: design.width) == design.height)
        #expect(WorkspacesIntroExplainer.canvasHeight(fittingWidth: design.width * 2) == design.height)
        #expect(abs(WorkspacesIntroExplainer.canvasHeight(fittingWidth: 456) - design.height * 0.5) < 0.001)
        #expect(
            WorkspacesIntroExplainer.canvasHeight(fittingWidth: 100)
                == design.height * WorkspacesIntroExplainer.minimumScale
        )
    }
}
