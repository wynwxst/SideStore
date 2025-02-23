//
//  MergePolicy.swift
//  AltStore
//
//  Created by Riley Testut on 7/23/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData

import Roxas

open class MergePolicy: RSTRelationshipPreservingMergePolicy
{
    open override func resolve(constraintConflicts conflicts: [NSConstraintConflict]) throws
    {
        guard conflicts.allSatisfy({ $0.databaseObject != nil }) else {
            for conflict in conflicts
            {
                switch conflict.conflictingObjects.first
                {
                case is StoreApp where conflict.conflictingObjects.count == 2:
                    // Modified cached StoreApp while replacing it with new one, causing context-level conflict.
                    // Most likely, we set up a relationship between the new StoreApp and a NewsItem,
                    // causing cached StoreApp to delete it's NewsItem relationship, resulting in (resolvable) conflict.
                    
                    if let previousApp = conflict.conflictingObjects.first(where: { !$0.isInserted }) as? StoreApp
                    {
                        // Delete previous permissions (same as below).
                        for permission in previousApp.permissions
                        {
                            permission.managedObjectContext?.delete(permission)
                        }
                        
                        // Delete previous versions (different than below).
                        for case let appVersion as AppVersion in previousApp._versions where appVersion.app == nil
                        {
                            appVersion.managedObjectContext?.delete(appVersion)
                        }
                    }
                    
                case is AppVersion where conflict.conflictingObjects.count == 2:
                    // Occurs first time fetching sources after migrating from pre-AppVersion database model.
                    let conflictingAppVersions = conflict.conflictingObjects.lazy.compactMap { $0 as? AppVersion }
                    
                    // Primary AppVersion == AppVersion whose latestVersionApp.latestVersion points back to itself.
                    if let primaryAppVersion = conflictingAppVersions.first(where: { $0.latestSupportedVersionApp?.latestSupportedVersion == $0 }),
                       let secondaryAppVersion = conflictingAppVersions.first(where: { $0 != primaryAppVersion })
                    {
                        secondaryAppVersion.managedObjectContext?.delete(secondaryAppVersion)
                        print("[ALTLog] Resolving AppVersion context-level conflict. Most likely due to migrating from pre-AppVersion model version.", primaryAppVersion)
                    }
                    
                default:
                    // Unknown context-level conflict.
                    assertionFailure("MergePolicy is only intended to work with database-level conflicts.")
                }
            }
            
            try super.resolve(constraintConflicts: conflicts)
                        
            return
        }
        
        for conflict in conflicts
        {
            switch conflict.databaseObject
            {
            case let databaseObject as StoreApp:
                // Delete previous permissions
                for permission in databaseObject.permissions
                {
                    permission.managedObjectContext?.delete(permission)
                }
                
                if let contextApp = conflict.conflictingObjects.first as? StoreApp
                {
                    let contextVersions = Set(contextApp._versions.lazy.compactMap { $0 as? AppVersion }.map { $0.version })
                    for case let appVersion as AppVersion in databaseObject._versions where !contextVersions.contains(appVersion.version)
                    {
                        print("[ALTLog] Deleting cached app version: \(appVersion.appBundleID + "_" + appVersion.version), not in:", contextApp.versions.map { $0.appBundleID + "_" + $0.version })
                        appVersion.managedObjectContext?.delete(appVersion)
                    }
                }
                
            case let databaseObject as Source:
                guard let conflictedObject = conflict.conflictingObjects.first as? Source else { break }

                let bundleIdentifiers = Set(conflictedObject.apps.map { $0.bundleIdentifier })
                let newsItemIdentifiers = Set(conflictedObject.newsItems.map { $0.identifier })

                for app in databaseObject.apps
                {
                    if !bundleIdentifiers.contains(app.bundleIdentifier)
                    {
                        // No longer listed in Source, so remove it from database.
                        app.managedObjectContext?.delete(app)
                    }
                }
                
                for newsItem in databaseObject.newsItems
                {
                    if !newsItemIdentifiers.contains(newsItem.identifier)
                    {
                        // No longer listed in Source, so remove it from database.
                        newsItem.managedObjectContext?.delete(newsItem)
                    }
                }
                
            default: break
            }
        }
        
        try super.resolve(constraintConflicts: conflicts)
    }
}
