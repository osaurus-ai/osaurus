//
//  ModelListTab.swift
//  osaurus
//
//  Tab options for filtering models in the model browser.
//  Supports All, Suggested, and Downloaded views.
//

import Foundation

/// Represents the different tabs available in the model browser view.
///
/// Each tab filters the model list differently:
/// - **all**: Shows all available models from the MLX community
/// - **suggested**: Shows a curated list of recommended models
/// - **downloaded**: Shows only models that have been downloaded to the local machine
enum ModelListTab: CaseIterable {
  /// All available models from Hugging Face
  case all
  
  /// Curated list of recommended models
  case suggested
  
  /// Only models downloaded locally
  case downloaded

  /// Display name for the tab
  var title: String {
    switch self {
    case .all: return "All Models"
    case .suggested: return "Suggested"
    case .downloaded: return "Downloaded"
    }
  }
}

