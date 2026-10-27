//
//  VolumeAvailableCapacityCache+DiskCache.swift
//  osaurus
//
//  Hands the runtime's disk cache cap the purgeable-inclusive free space.
//

import MLXLMCommon

extension VolumeAvailableCapacityCache {
    /// The runtime sizes the SSD cache (Automatic share, the "exceeds
    /// available space" advisory) from free space. It reads the strict figure
    /// and never issues the CacheDelete-prone query itself, so give it the
    /// same background-refreshed, purgeable-inclusive figure the Models tab
    /// shows.
    static func installAsDiskCacheFreeSpaceProvider() {
        DiskCacheVolumeSnapshot.setPurgeableInclusiveFreeBytesProvider { path in
            shared.cachedBytes(forPath: path)
        }
    }
}
