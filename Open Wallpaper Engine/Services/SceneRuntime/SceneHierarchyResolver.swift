//
//  SceneHierarchyResolver.swift
//  Open Wallpaper Engine
//
//  Validates Wallpaper Engine parent links before SpriteKit nodes are attached.
//

import Foundation

struct SceneHierarchyRecord: Equatable {
    let id: Int?
    let parentID: Int?
    let sourceIndex: Int
}

enum SceneHierarchyFallbackReason: Equatable {
    case missingParent(Int)
    case duplicateID(Int)
    case cycle
}

enum SceneHierarchyAttachment: Equatable {
    case root(localZ: Double, reason: SceneHierarchyFallbackReason?)
    case parent(parentRecordIndex: Int, localZ: Double)
}

enum SceneHierarchyResolver {
    static func resolve(
        _ records: [SceneHierarchyRecord]
    ) -> [SceneHierarchyAttachment] {
        var firstRecordIndexByID: [Int: Int] = [:]
        var duplicateRecordIndices = Set<Int>()

        for (recordIndex, record) in records.enumerated() {
            guard let id = record.id else { continue }
            if firstRecordIndexByID[id] == nil {
                firstRecordIndexByID[id] = recordIndex
            } else {
                duplicateRecordIndices.insert(recordIndex)
            }
        }

        return records.enumerated().map { recordIndex, record in
            if duplicateRecordIndices.contains(recordIndex), let id = record.id {
                return .root(
                    localZ: Double(record.sourceIndex),
                    reason: .duplicateID(id)
                )
            }

            guard let parentID = record.parentID else {
                return .root(localZ: Double(record.sourceIndex), reason: nil)
            }
            guard let parentRecordIndex = firstRecordIndexByID[parentID] else {
                return .root(
                    localZ: Double(record.sourceIndex),
                    reason: .missingParent(parentID)
                )
            }
            guard !containsCycle(
                startingAt: recordIndex,
                records: records,
                firstRecordIndexByID: firstRecordIndexByID
            ) else {
                return .root(localZ: Double(record.sourceIndex), reason: .cycle)
            }

            let parentSourceIndex = records[parentRecordIndex].sourceIndex
            return .parent(
                parentRecordIndex: parentRecordIndex,
                localZ: Double(record.sourceIndex - parentSourceIndex)
            )
        }
    }

    private static func containsCycle(
        startingAt recordIndex: Int,
        records: [SceneHierarchyRecord],
        firstRecordIndexByID: [Int: Int]
    ) -> Bool {
        var visited = Set<Int>()
        var currentIndex: Int? = recordIndex

        while let index = currentIndex {
            guard visited.insert(index).inserted else { return true }
            guard
                let parentID = records[index].parentID,
                let parentIndex = firstRecordIndexByID[parentID]
            else {
                return false
            }
            currentIndex = parentIndex
        }

        return false
    }
}
