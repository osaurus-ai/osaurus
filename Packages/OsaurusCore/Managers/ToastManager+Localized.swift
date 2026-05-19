//
//  ToastManager+Localized.swift
//  osaurus
//
//  Convenience methods that route titles/messages through the OsaurusCore
//  string catalog (`bundle: .module`). Prefer these over the raw String
//  variants for any static UI copy.
//

import Foundation

extension ToastManager {
    /// Show a success toast with a localized title (and optional message).
    @discardableResult
    public func successLocalized(
        _ titleKey: String.LocalizationValue,
        message messageKey: String.LocalizationValue? = nil,
        timeout: TimeInterval? = nil
    ) -> UUID {
        success(L(titleKey), message: messageKey.map { L($0) }, timeout: timeout)
    }

    /// Show an info toast with a localized title (and optional message).
    @discardableResult
    public func infoLocalized(
        _ titleKey: String.LocalizationValue,
        message messageKey: String.LocalizationValue? = nil,
        timeout: TimeInterval? = nil
    ) -> UUID {
        info(L(titleKey), message: messageKey.map { L($0) }, timeout: timeout)
    }

    /// Show a warning toast with a localized title (and optional message).
    @discardableResult
    public func warningLocalized(
        _ titleKey: String.LocalizationValue,
        message messageKey: String.LocalizationValue? = nil,
        timeout: TimeInterval? = nil
    ) -> UUID {
        warning(L(titleKey), message: messageKey.map { L($0) }, timeout: timeout)
    }

    /// Show an error toast with a localized title (and optional message).
    @discardableResult
    public func errorLocalized(
        _ titleKey: String.LocalizationValue,
        message messageKey: String.LocalizationValue? = nil,
        timeout: TimeInterval? = nil
    ) -> UUID {
        error(L(titleKey), message: messageKey.map { L($0) }, timeout: timeout)
    }

    /// Show a loading toast with a localized title (and optional message).
    @discardableResult
    public func loadingLocalized(
        _ titleKey: String.LocalizationValue,
        message messageKey: String.LocalizationValue? = nil,
        progress: Double? = nil
    ) -> UUID {
        loading(L(titleKey), message: messageKey.map { L($0) }, progress: progress)
    }
}
