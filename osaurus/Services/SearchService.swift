//
//  SearchService.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Service for handling search functionality across the app
struct SearchService {

  /// Performs fuzzy matching - returns true if all characters in query
  /// appear in the same order in the target string
  static func fuzzyMatch(query: String, in target: String) -> Bool {
    let query = query.lowercased()
    let target = target.lowercased()

    var queryIndex = query.startIndex
    var targetIndex = target.startIndex

    while queryIndex < query.endIndex && targetIndex < target.endIndex {
      if query[queryIndex] == target[targetIndex] {
        queryIndex = query.index(after: queryIndex)
      }
      targetIndex = target.index(after: targetIndex)
    }

    return queryIndex == query.endIndex
  }

  /// Filters models based on fuzzy search query
  static func filterModels(_ models: [MLXModel], with searchText: String) -> [MLXModel] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return models }

    return models.filter { model in
      let searchTargets = [
        model.name.lowercased(),
        model.id.lowercased(),
        model.description.lowercased(),
        model.downloadURL.lowercased(),
      ]

      return searchTargets.contains { target in
        fuzzyMatch(query: query, in: target)
      }
    }
  }
}
