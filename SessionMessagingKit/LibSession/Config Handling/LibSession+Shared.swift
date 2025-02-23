// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

public extension LibSession {
    /// A `0` `priority` value indicates visible, but not pinned
    static let visiblePriority: Int32 = 0
    
    /// A negative `priority` value indicates hidden
    static let hiddenPriority: Int32 = -1
}

internal extension LibSession {
    /// This is a buffer period within which we will process messages which would result in a config change, any message which would normally
    /// result in a config change which was sent before `lastConfigMessage.timestamp - configChangeBufferPeriod` will not
    /// actually have it's changes applied (info messages would still be inserted though)
    static let configChangeBufferPeriod: TimeInterval = (2 * 60)
    
    static let columnsRelatedToThreads: [ColumnExpression] = [
        SessionThread.Columns.pinnedPriority,
        SessionThread.Columns.shouldBeVisible
    ]
    
    static func assignmentsRequireConfigUpdate(_ assignments: [ConfigColumnAssignment]) -> Bool {
        let targetColumns: Set<ColumnKey> = Set(assignments.map { ColumnKey($0.column) })
        let allColumnsThatTriggerConfigUpdate: Set<ColumnKey> = []
            .appending(contentsOf: columnsRelatedToUserProfile)
            .appending(contentsOf: columnsRelatedToContacts)
            .appending(contentsOf: columnsRelatedToConvoInfoVolatile)
            .appending(contentsOf: columnsRelatedToUserGroups)
            .appending(contentsOf: columnsRelatedToThreads)
            .map { ColumnKey($0) }
            .asSet()
        
        return !allColumnsThatTriggerConfigUpdate.isDisjoint(with: targetColumns)
    }
    
    static func shouldBeVisible(priority: Int32) -> Bool {
        return (priority >= LibSession.visiblePriority)
    }
    
    static func performAndPushChange(
        _ db: Database,
        for variant: ConfigDump.Variant,
        publicKey: String,
        change: (UnsafeMutablePointer<config_object>?) throws -> ()
    ) throws {
        // Since we are doing direct memory manipulation we are using an `Atomic`
        // type which has blocking access in it's `mutate` closure
        let needsPush: Bool
        
        do {
            needsPush = try LibSession
                .config(for: variant, publicKey: publicKey)
                .mutate { conf in
                    guard conf != nil else { throw LibSessionError.nilConfigObject }
                    
                    // Peform the change
                    try change(conf)
                    
                    // If we don't need to dump the data the we can finish early
                    guard config_needs_dump(conf) else { return config_needs_push(conf) }
                    
                    try LibSession.createDump(
                        conf: conf,
                        for: variant,
                        publicKey: publicKey,
                        timestampMs: SnodeAPI.currentOffsetTimestampMs()
                    )?.save(db)
                    
                    return config_needs_push(conf)
                }
        }
        catch {
            SNLog("[LibSession] Failed to update/dump updated \(variant) config data due to error: \(error)")
            throw error
        }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(publicKey)) { db in
            ConfigurationSyncJob.enqueue(db, publicKey: publicKey)
        }
    }
    
    @discardableResult static func updatingThreads<T>(_ db: Database, _ updated: [T]) throws -> [T] {
        guard let updatedThreads: [SessionThread] = updated as? [SessionThread] else {
            throw StorageError.generic
        }
        
        // If we have no updated threads then no need to continue
        guard !updatedThreads.isEmpty else { return updated }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let groupedThreads: [SessionThread.Variant: [SessionThread]] = updatedThreads
            .grouped(by: \.variant)
        let urlInfo: [String: OpenGroupUrlInfo] = try OpenGroupUrlInfo
            .fetchAll(db, ids: updatedThreads.map { $0.id })
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        // Update the unread state for the threads first (just in case that's what changed)
        try LibSession.updateMarkedAsUnreadState(db, threads: updatedThreads)
        
        // Then update the `hidden` and `priority` values
        try groupedThreads.forEach { variant, threads in
            switch variant {
                case .contact:
                    // If the 'Note to Self' conversation is pinned then we need to custom handle it
                    // first as it's part of the UserProfile config
                    if let noteToSelf: SessionThread = threads.first(where: { $0.id == userPublicKey }) {
                        try LibSession.performAndPushChange(
                            db,
                            for: .userProfile,
                            publicKey: userPublicKey
                        ) { conf in
                            try LibSession.updateNoteToSelf(
                                priority: {
                                    guard noteToSelf.shouldBeVisible else { return LibSession.hiddenPriority }
                                    
                                    return noteToSelf.pinnedPriority
                                        .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                        .defaulting(to: LibSession.visiblePriority)
                                }(),
                                in: conf
                            )
                        }
                    }
                    
                    // Remove the 'Note to Self' convo from the list for updating contact priorities
                    let remainingThreads: [SessionThread] = threads.filter { $0.id != userPublicKey }
                    
                    guard !remainingThreads.isEmpty else { return }
                    
                    try LibSession.performAndPushChange(
                        db,
                        for: .contacts,
                        publicKey: userPublicKey
                    ) { conf in
                        try LibSession.upsert(
                            contactData: remainingThreads
                                .map { thread in
                                    SyncedContactInfo(
                                        id: thread.id,
                                        priority: {
                                            guard thread.shouldBeVisible else { return LibSession.hiddenPriority }
                                            
                                            return thread.pinnedPriority
                                                .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                .defaulting(to: LibSession.visiblePriority)
                                        }()
                                    )
                                },
                            in: conf
                        )
                    }
                    
                case .community:
                    try LibSession.performAndPushChange(
                        db,
                        for: .userGroups,
                        publicKey: userPublicKey
                    ) { conf in
                        try LibSession.upsert(
                            communities: threads
                                .compactMap { thread -> CommunityInfo? in
                                    urlInfo[thread.id].map { urlInfo in
                                        CommunityInfo(
                                            urlInfo: urlInfo,
                                            priority: thread.pinnedPriority
                                                .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                .defaulting(to: LibSession.visiblePriority)
                                        )
                                    }
                                },
                            in: conf
                        )
                    }
                    
                case .legacyGroup:
                    try LibSession.performAndPushChange(
                        db,
                        for: .userGroups,
                        publicKey: userPublicKey
                    ) { conf in
                        try LibSession.upsert(
                            legacyGroups: threads
                                .map { thread in
                                    LegacyGroupInfo(
                                        id: thread.id,
                                        priority: thread.pinnedPriority
                                            .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                            .defaulting(to: LibSession.visiblePriority)
                                    )
                                },
                            in: conf
                        )
                    }
                
                case .group:
                    break
            }
        }
        
        return updated
    }
    
    static func hasSetting(_ db: Database, forKey key: String) throws -> Bool {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Currently the only synced setting is 'checkForCommunityMessageRequests'
        switch key {
            case Setting.BoolKey.checkForCommunityMessageRequests.rawValue:
                return try LibSession
                    .config(for: .userProfile, publicKey: userPublicKey)
                    .wrappedValue
                    .map { conf -> Bool in (try LibSession.rawBlindedMessageRequestValue(in: conf) >= 0) }
                    .defaulting(to: false)
                
            default: return false
        }
    }
    
    static func updatingSetting(_ db: Database, _ updated: Setting?) throws {
        // Don't current support any nullable settings
        guard let updatedSetting: Setting = updated else { return }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        // Currently the only synced setting is 'checkForCommunityMessageRequests'
        switch updatedSetting.id {
            case Setting.BoolKey.checkForCommunityMessageRequests.rawValue:
                try LibSession.performAndPushChange(
                    db,
                    for: .userProfile,
                    publicKey: userPublicKey
                ) { conf in
                    try LibSession.updateSettings(
                        checkForCommunityMessageRequests: updatedSetting.unsafeValue(as: Bool.self),
                        in: conf
                    )
                }
                
            default: break
        }
    }
    
    static func kickFromConversationUIIfNeeded(removedThreadIds: [String]) {
        guard !removedThreadIds.isEmpty else { return }
        
        // If the user is currently navigating somewhere within the view hierarchy of a conversation
        // we just deleted then return to the home screen
        DispatchQueue.main.async {
            guard
                Singleton.hasAppContext,
                let rootViewController: UIViewController = Singleton.appContext.mainWindow?.rootViewController,
                let topBannerController: TopBannerController = (rootViewController as? TopBannerController),
                !topBannerController.children.isEmpty,
                let navController: UINavigationController = topBannerController.children[0] as? UINavigationController
            else { return }
            
            // Extract the ones which will respond to LibSession changes
            let targetViewControllers: [any LibSessionRespondingViewController] = navController
                .viewControllers
                .compactMap { $0 as? LibSessionRespondingViewController }
            let presentedNavController: UINavigationController? = (navController.presentedViewController as? UINavigationController)
            let presentedTargetViewControllers: [any LibSessionRespondingViewController] = (presentedNavController?
                .viewControllers
                .compactMap { $0 as? LibSessionRespondingViewController })
                .defaulting(to: [])
            
            // Make sure we have a conversation list and that one of the removed conversations are
            // in the nav hierarchy
            let rootNavControllerNeedsPop: Bool = (
                targetViewControllers.count > 1 &&
                targetViewControllers.contains(where: { $0.isConversationList }) &&
                targetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            let presentedNavControllerNeedsPop: Bool = (
                presentedTargetViewControllers.count > 1 &&
                presentedTargetViewControllers.contains(where: { $0.isConversationList }) &&
                presentedTargetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            
            // Force the UI to refresh if needed (most screens should do this automatically via database
            // observation, but a couple of screens don't so need to be done manually)
            targetViewControllers
                .appending(contentsOf: presentedTargetViewControllers)
                .filter { $0.isConversationList }
                .forEach { $0.forceRefreshIfNeeded() }
            
            switch (rootNavControllerNeedsPop, presentedNavControllerNeedsPop) {
                case (true, false):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = navController.viewControllers
                            .last(where: { viewController in
                                ((viewController as? LibSessionRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if navController.presentedViewController != nil {
                        navController.dismiss(animated: false) {
                            navController.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        navController.popToViewController(targetViewController, animated: true)
                    }
                    
                case (false, true):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = presentedNavController?
                            .viewControllers
                            .last(where: { viewController in
                                ((viewController as? LibSessionRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if presentedNavController?.presentedViewController != nil {
                        presentedNavController?.dismiss(animated: false) {
                            presentedNavController?.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        presentedNavController?.popToViewController(targetViewController, animated: true)
                    }
                    
                default: break
            }
        }
    }
    
    static func canPerformChange(
        _ db: Database,
        threadId: String,
        targetConfig: ConfigDump.Variant,
        changeTimestampMs: Int64
    ) -> Bool {
        let targetPublicKey: String = {
            switch targetConfig {
                default: return getUserHexEncodedPublicKey(db)
            }
        }()
        
        let configDumpTimestampMs: Int64 = (try? ConfigDump
            .filter(
                ConfigDump.Columns.variant == targetConfig &&
                ConfigDump.Columns.publicKey == targetPublicKey
            )
            .select(.timestampMs)
            .asRequest(of: Int64.self)
            .fetchOne(db))
            .defaulting(to: 0)
        
        // Ensure the change occurred after the last config message was handled (minus the buffer period)
        return (changeTimestampMs >= (configDumpTimestampMs - Int64(LibSession.configChangeBufferPeriod * 1000)))
    }
    
    static func checkLoopLimitReached(_ loopCounter: inout Int, for variant: ConfigDump.Variant, maxLoopCount: Int = 50000) throws {
        loopCounter += 1
        
        guard loopCounter < maxLoopCount else {
            SNLog("[LibSession] Got stuck in infinite loop processing '\(variant)' data")
            throw LibSessionError.processingLoopLimitReached
        }
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func conversationInConfig(
        _ db: Database? = nil,
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool
    ) -> Bool {
        // Currently blinded conversations cannot be contained in the config, so there is no point checking (it'll always be
        // false)
        guard
            threadVariant == .community || (
                SessionId(from: threadId)?.prefix != .blinded15 &&
                SessionId(from: threadId)?.prefix != .blinded25
            )
        else { return false }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let configVariant: ConfigDump.Variant = {
            switch threadVariant {
                case .contact: return (threadId == userPublicKey ? .userProfile : .contacts)
                case .legacyGroup, .group, .community: return .userGroups
            }
        }()
        
        return LibSession
            .config(for: configVariant, publicKey: userPublicKey)
            .wrappedValue
            .map { conf in
                guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else { return false }
                
                switch threadVariant {
                    case .contact:
                        // The 'Note to Self' conversation is stored in the 'userProfile' config
                        guard threadId != userPublicKey else {
                            return (
                                !visibleOnly ||
                                LibSession.shouldBeVisible(priority: user_profile_get_nts_priority(conf))
                            )
                        }
                        
                        var contact: contacts_contact = contacts_contact()
                        
                        guard contacts_get(conf, &contact, &cThreadId) else {
                            LibSessionError.clear(conf)
                            return false
                        }
                        
                        /// If the user opens a conversation with an existing contact but doesn't send them a message
                        /// then the one-to-one conversation should remain hidden so we want to delete the `SessionThread`
                        /// when leaving the conversation
                        return (!visibleOnly || LibSession.shouldBeVisible(priority: contact.priority))
                        
                    case .community:
                        let maybeUrlInfo: OpenGroupUrlInfo? = Storage.shared
                            .read { db in try OpenGroupUrlInfo.fetchAll(db, ids: [threadId]) }?
                            .first
                        
                        guard
                            let urlInfo: OpenGroupUrlInfo = maybeUrlInfo,
                            var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                            var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8)
                        else { return false }
                        
                        var community: ugroups_community_info = ugroups_community_info()
                        
                        /// Not handling the `hidden` behaviour for communities so just indicate the existence
                        let result: Bool = user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                        LibSessionError.clear(conf)
                        
                        return result
                        
                    case .legacyGroup:
                        let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                        LibSessionError.clear(conf)
                        
                        /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
                        if groupInfo != nil {
                            ugroups_legacy_group_free(groupInfo)
                            return true
                        }
                        
                        return false
                        
                    case .group:
                        return false
                }
            }
            .defaulting(to: false)
    }
}

// MARK: - ColumnKey

internal extension LibSession {
    struct ColumnKey: Equatable, Hashable {
        let sourceType: Any.Type
        let columnName: String
        
        init(_ column: ColumnExpression) {
            self.sourceType = type(of: column)
            self.columnName = column.name
        }
        
        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(sourceType).hash(into: &hasher)
            columnName.hash(into: &hasher)
        }
        
        static func == (lhs: ColumnKey, rhs: ColumnKey) -> Bool {
            return (
                lhs.sourceType == rhs.sourceType &&
                lhs.columnName == rhs.columnName
            )
        }
    }
}

// MARK: - PriorityVisibilityInfo

extension LibSession {
    struct PriorityVisibilityInfo: Codable, FetchableRecord, Identifiable {
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
        let shouldBeVisible: Bool
    }
}

// MARK: - LibSessionRespondingViewController

public protocol LibSessionRespondingViewController {
    var isConversationList: Bool { get }
    
    func isConversation(in threadIds: [String]) -> Bool
    func forceRefreshIfNeeded()
}

public extension LibSessionRespondingViewController {
    var isConversationList: Bool { false }
    
    func isConversation(in threadIds: [String]) -> Bool { return false }
    func forceRefreshIfNeeded() {}
}
