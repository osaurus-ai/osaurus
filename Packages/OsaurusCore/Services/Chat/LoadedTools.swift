//
//  LoadedTools.swift
//  osaurus
//
//  Named alias for the mid-session tool-name sets the compose pipeline
//  passes around (additionalToolNames + frozenAlwaysLoadedNames + the
//  per-session `SessionToolState.loadedToolNames` snapshot). Same
//  shape as `Set<String>`, but parameter lists read as
//  `additionalToolNames: LoadedTools` instead of an unlabeled
//  `Set<String>` that could mean any tool-name collection.
//

import Foundation

public typealias LoadedTools = Set<String>
