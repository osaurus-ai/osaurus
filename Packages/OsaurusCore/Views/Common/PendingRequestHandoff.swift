//
//  PendingRequestHandoff.swift
//  osaurus
//
//  One-shot requests (a template to import, a parked setup, a detail page
//  to open) travel through `@Published` properties on
//  `ManagementStateManager`: whoever asks sets the property, and the view
//  that owns the request reads it and clears it.
//

import Combine
import SwiftUI

extension View {
    /// Runs `action` whenever `publisher` emits, one main-actor turn later.
    ///
    /// `@Published` emits in willSet, so an action that reads the property
    /// back during the emission sees the old value: a request set while
    /// its view is already on screen would be missed until the next one
    /// arrives. The turn also keeps sheet presentation out of the replay
    /// SwiftUI delivers mid-render on subscribe.
    func onPendingRequest<P: Publisher>(
        _ publisher: P, perform action: @escaping @MainActor () -> Void
    ) -> some View where P.Failure == Never {
        onReceive(publisher) { _ in
            DispatchQueue.main.async { action() }
        }
    }
}
