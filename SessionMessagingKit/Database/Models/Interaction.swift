// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct Interaction: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "interaction" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    internal static let linkPreviewForeignKey = ForeignKey(
        [Columns.linkPreviewUrl],
        to: [LinkPreview.Columns.url]
    )
    public static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    public static let profile = hasOne(Profile.self, using: Profile.interactionForeignKey)
    public static let interactionAttachments = hasMany(
        InteractionAttachment.self,
        using: InteractionAttachment.interactionForeignKey
    )
    public static let attachments = hasMany(
        Attachment.self,
        through: interactionAttachments,
        using: InteractionAttachment.attachment
    )
    public static let quote = hasOne(Quote.self, using: Quote.interactionForeignKey)
    
    /// Whenever using this `linkPreview` association make sure to filter the result using
    /// `.filter(literal: Interaction.linkPreviewFilterLiteral)` to ensure the correct LinkPreview is returned
    public static let linkPreview = hasOne(LinkPreview.self, using: LinkPreview.interactionForeignKey)
    public static func linkPreviewFilterLiteral(
        timestampColumn: SQL = SQL(stringLiteral: Interaction.Columns.timestampMs.name)
    ) -> SQL {
        let linkPreview: TypedTableAlias<LinkPreview> = TypedTableAlias()
        
        return "(ROUND((\(Interaction.self).\(timestampColumn) / 1000 / 100000) - 0.5) * 100000) = \(linkPreview[.timestamp])"
    }
    public static let recipientStates = hasMany(RecipientState.self, using: RecipientState.interactionForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case serverHash
        case threadId
        case authorId
        
        case variant
        case body
        case timestampMs
        case receivedAtTimestampMs
        case wasRead
        case hasMention
        
        case expiresInSeconds
        case expiresStartedAtMs
        case linkPreviewUrl
        
        // Open Group specific properties
        
        case openGroupServerMessageId
        case openGroupWhisperMods
        case openGroupWhisperTo
    }
    
    public enum Variant: Int, Codable, Hashable, DatabaseValueConvertible {
        case standardIncoming
        case standardOutgoing
        case standardIncomingDeleted
        
        // Info Message Types (spacing the values out to make it easier to extend)
        case infoClosedGroupCreated = 1000
        case infoClosedGroupUpdated
        case infoClosedGroupCurrentUserLeft
        
        case infoDisappearingMessagesUpdate = 2000
        
        case infoScreenshotNotification = 3000
        case infoMediaSavedNotification
        
        case infoMessageRequestAccepted = 4000
        
        // MARK: - Convenience
        
        public var isInfoMessage: Bool {
            switch self {
                case .infoClosedGroupCreated, .infoClosedGroupUpdated, .infoClosedGroupCurrentUserLeft,
                    .infoDisappearingMessagesUpdate, .infoScreenshotNotification, .infoMediaSavedNotification,
                    .infoMessageRequestAccepted:
                    return true
                    
                case .standardIncoming, .standardOutgoing, .standardIncomingDeleted:
                    return false
            }
        }
    }
    
    /// The `id` value is auto incremented by the database, if the `Interaction` hasn't been inserted into
    /// the database yet this value will be `nil`
    public var id: Int64? = nil
    
    /// The hash returned by the server when this message was created on the server
    ///
    /// **Notes:**
    /// - This will only be populated for `standardIncoming`/`standardOutgoing` interactions from
    /// either `contact` or `closedGroup` threads
    /// - This value will differ for "sync" messages (messages we resend to the current to ensure it appears
    /// on all linked devices) because the data in the message is slightly different
    public let serverHash: String?
    
    /// The id of the thread that this interaction belongs to (used to expose the `thread` variable)
    public let threadId: String
    
    /// The id of the user who sent the interaction, also used to expose the `profile` variable)
    ///
    /// **Note:** For any "info" messages this value will always be the current user public key (this is because these
    /// messages are created locally based on control messages and the initiator of a control message doesn't always
    /// get transmitted)
    public let authorId: String
    
    /// The type of interaction
    public let variant: Variant
    
    /// The body of this interaction
    public let body: String?
    
    /// When the interaction was created in milliseconds since epoch
    ///
    /// **Notes:**
    /// - This value will be `0` if it hasn't been set yet
    /// - The code sorts messages using this value
    /// - This value will ber overwritten by the `serverTimestamp` for open group messages
    public let timestampMs: Int64
    
    /// When the interaction was received in milliseconds since epoch
    ///
    /// **Note:** This value will be `0` if it hasn't been set yet
    public let receivedAtTimestampMs: Int64
    
    /// A flag indicating whether the interaction has been read (this is a flag rather than a timestamp because
    /// we couldn’t know if a read timestamp is accurate)
    ///
    /// **Note:** This flag is not applicable to standardOutgoing or standardIncomingDeleted interactions
    public let wasRead: Bool
    
    /// A flag indicating whether the current user was mentioned in this interaction (or the associated quote)
    public let hasMention: Bool
    
    /// The number of seconds until this message should expire
    public let expiresInSeconds: TimeInterval?
    
    /// The timestamp in milliseconds since 1970 at which this messages expiration timer started counting
    /// down (this is stored in order to allow the `expiresInSeconds` value to be updated before a
    /// message has expired)
    public let expiresStartedAtMs: Double?
    
    /// This value is the url for the link preview for this interaction
    ///
    /// **Note:** This is also used for open group invitations
    public let linkPreviewUrl: String?
    
    // Open Group specific properties
    
    /// The `openGroupServerMessageId` value will only be set for messages from SOGS
    public let openGroupServerMessageId: Int64?
    
    /// This flag indicates whether this interaction is a whisper to the mods of an Open Group
    public let openGroupWhisperMods: Bool
    
    /// This value is the id of the user within an Open Group who is the target of this whisper interaction
    public let openGroupWhisperTo: String?
    
    // MARK: - Relationships
         
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: Interaction.thread)
    }
    
    public var profile: QueryInterfaceRequest<Profile> {
        request(for: Interaction.profile)
    }
    
    /// Depending on the data associated to this interaction this array will represent different things, these
    /// cases are mutually exclusive:
    ///
    /// **Quote:** The thumbnails associated to the `Quote`
    /// **LinkPreview:** The thumbnails associated to the `LinkPreview`
    /// **Other:** The files directly attached to the interaction
    public var attachments: QueryInterfaceRequest<Attachment> {
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        
        return request(for: Interaction.attachments)
            .order(interactionAttachment[.albumIndex])
    }

    public var quote: QueryInterfaceRequest<Quote> {
        request(for: Interaction.quote)
    }

    public var linkPreview: QueryInterfaceRequest<LinkPreview> {
        /// **Note:** This equation **MUST** match the `linkPreviewFilterLiteral` logic
        let roundedTimestamp: Double = (round(((Double(timestampMs) / 1000) / 100000) - 0.5) * 100000)
        
        return request(for: Interaction.linkPreview)
            .filter(LinkPreview.Columns.timestamp == roundedTimestamp)
    }
    
    public var recipientStates: QueryInterfaceRequest<RecipientState> {
        request(for: Interaction.recipientStates)
    }
    
    // MARK: - Initialization
    
    internal init(
        id: Int64? = nil,
        serverHash: String?,
        threadId: String,
        authorId: String,
        variant: Variant,
        body: String?,
        timestampMs: Int64,
        receivedAtTimestampMs: Int64,
        wasRead: Bool,
        hasMention: Bool,
        expiresInSeconds: TimeInterval?,
        expiresStartedAtMs: Double?,
        linkPreviewUrl: String?,
        openGroupServerMessageId: Int64?,
        openGroupWhisperMods: Bool,
        openGroupWhisperTo: String?
    ) {
        self.id = id
        self.serverHash = serverHash
        self.threadId = threadId
        self.authorId = authorId
        self.variant = variant
        self.body = body
        self.timestampMs = timestampMs
        self.receivedAtTimestampMs = receivedAtTimestampMs
        self.wasRead = wasRead
        self.hasMention = hasMention
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
        self.linkPreviewUrl = linkPreviewUrl
        self.openGroupServerMessageId = openGroupServerMessageId
        self.openGroupWhisperMods = openGroupWhisperMods
        self.openGroupWhisperTo = openGroupWhisperTo
    }
    
    public init(
        serverHash: String? = nil,
        threadId: String,
        authorId: String,
        variant: Variant,
        body: String? = nil,
        timestampMs: Int64 = 0,
        wasRead: Bool = false,
        hasMention: Bool = false,
        expiresInSeconds: TimeInterval? = nil,
        expiresStartedAtMs: Double? = nil,
        linkPreviewUrl: String? = nil,
        openGroupServerMessageId: Int64? = nil,
        openGroupWhisperMods: Bool = false,
        openGroupWhisperTo: String? = nil
    ) throws {
        self.serverHash = serverHash
        self.threadId = threadId
        self.authorId = authorId
        self.variant = variant
        self.body = body
        self.timestampMs = timestampMs
        self.receivedAtTimestampMs = {
            switch variant {
                case .standardIncoming, .standardOutgoing: return Int64(Date().timeIntervalSince1970 * 1000)

                /// For TSInteractions which are not `standardIncoming` and `standardOutgoing` use the `timestampMs` value
                default: return timestampMs
            }
        }()
        self.wasRead = wasRead
        self.hasMention = hasMention
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
        self.linkPreviewUrl = linkPreviewUrl
        self.openGroupServerMessageId = openGroupServerMessageId
        self.openGroupWhisperMods = openGroupWhisperMods
        self.openGroupWhisperTo = openGroupWhisperTo
    }
    
    // MARK: - Custom Database Interaction
    
    public mutating func insert(_ db: Database) throws {
        try performInsert(db)
        
        // Since we need to do additional logic upon insert we can just set the 'id' value
        // here directly instead of in the 'didInsert' method (if you look at the docs the
        // 'db.lastInsertedRowID' value is the row id of the newly inserted row which the
        // interaction uses as it's id)
        let interactionId: Int64 = db.lastInsertedRowID
        self.id = interactionId
        
        guard let thread: SessionThread = try? SessionThread.fetchOne(db, id: threadId) else {
            SNLog("Inserted an interaction but couldn't find it's associated thead")
            return
        }
        
        switch variant {
            case .standardOutgoing:
                // New outgoing messages should immediately determine their recipient list
                // from current thread state
                switch thread.variant {
                    case .contact:
                        try RecipientState(
                            interactionId: interactionId,
                            recipientId: threadId,  // Will be the contact id
                            state: .sending
                        ).insert(db)
                        
                    case .closedGroup:
                        guard
                            let closedGroup: ClosedGroup = try? thread.closedGroup.fetchOne(db),
                            let members: [GroupMember] = try? closedGroup.members.fetchAll(db)
                        else {
                            SNLog("Inserted an interaction but couldn't find it's associated thread members")
                            return
                        }
                        
                        try members.forEach { member in
                            try RecipientState(
                                interactionId: interactionId,
                                recipientId: member.profileId,
                                state: .sending
                            ).insert(db)
                        }
                        
                    case .openGroup:
                        // Since we use the 'RecipientState' type to manage the message state
                        // we need to ensure we have a state for all threads; so for open groups
                        // we just use the open group id as the 'recipientId' value
                        try RecipientState(
                            interactionId: interactionId,
                            recipientId: threadId,  // Will be the open group id
                            state: .sending
                        ).insert(db)
                }
                
            default: break
        }
    }
}

// MARK: - Mutation

public extension Interaction {
    func with(
        serverHash: String? = nil,
        authorId: String? = nil,
        timestampMs: Int64? = nil,
        wasRead: Bool? = nil,
        hasMention: Bool? = nil,
        expiresInSeconds: TimeInterval? = nil,
        expiresStartedAtMs: Double? = nil,
        openGroupServerMessageId: Int64? = nil
    ) -> Interaction {
        return Interaction(
            id: id,
            serverHash: (serverHash ?? self.serverHash),
            threadId: threadId,
            authorId: (authorId ?? self.authorId),
            variant: variant,
            body: body,
            timestampMs: (timestampMs ?? self.timestampMs),
            receivedAtTimestampMs: receivedAtTimestampMs,
            wasRead: (wasRead ?? self.wasRead),
            hasMention: (hasMention ?? self.hasMention),
            expiresInSeconds: (expiresInSeconds ?? self.expiresInSeconds),
            expiresStartedAtMs: (expiresStartedAtMs ?? self.expiresStartedAtMs),
            linkPreviewUrl: linkPreviewUrl,
            openGroupServerMessageId: (openGroupServerMessageId ?? self.openGroupServerMessageId),
            openGroupWhisperMods: openGroupWhisperMods,
            openGroupWhisperTo: openGroupWhisperTo
        )
    }
}

// MARK: - GRDB Interactions

public extension Interaction {
    /// This will update the `wasRead` state the the interaction
    ///
    /// - Parameters
    ///   - interactionId: The id of the specific interaction to mark as read
    ///   - threadId: The id of the thread the interaction belongs to
    ///   - includingOlder: Setting this to `true` will updated the `wasRead` flag for all older interactions as well
    ///   - trySendReadReceipt: Setting this to `true` will schedule a `ReadReceiptJob`
    static func markAsRead(
        _ db: Database,
        interactionId: Int64?,
        threadId: String,
        includingOlder: Bool,
        trySendReadReceipt: Bool
    ) throws {
        guard let interactionId: Int64 = interactionId else { return }

        // Once all of the below is done schedule the jobs
        func scheduleJobs(interactionIds: [Int64]) {
            // Add the 'DisappearingMessagesJob' if needed - this will update any expiring
            // messages `expiresStartedAtMs` values
            JobRunner.upsert(
                db,
                job: DisappearingMessagesJob.updateNextRunIfNeeded(
                    db,
                    interactionIds: interactionIds,
                    startedAtMs: (Date().timeIntervalSince1970 * 1000)
                )
            )
            
            // If we want to send read receipts then try to add the 'SendReadReceiptsJob'
            if trySendReadReceipt {
                JobRunner.upsert(
                    db,
                    job: SendReadReceiptsJob.createOrUpdateIfNeeded(
                        db,
                        threadId: threadId,
                        interactionIds: interactionIds
                    )
                )
            }
        }
        
        // If we aren't including older interactions then update and save the current one
        guard includingOlder else {
            _ = try Interaction
                .filter(id: interactionId)
                .updateAll(db, Columns.wasRead.set(to: true))
            
            scheduleJobs(interactionIds: [interactionId])
            return
        }
        
        let interactionQuery = Interaction
            .filter(Columns.threadId == threadId)
            .filter(Columns.id <= interactionId)
            .filter(Columns.wasRead == false)
            // The `wasRead` flag doesn't apply to `standardOutgoing` or `standardIncomingDeleted`
            .filter(Columns.variant != Variant.standardOutgoing && Columns.variant != Variant.standardIncomingDeleted)
        let interactionIdsToMarkAsRead: [Int64] = try interactionQuery
            .select(.id)
            .asRequest(of: Int64.self)
            .fetchAll(db)
        
        // Don't bother continuing if there are not interactions to mark as read
        guard !interactionIdsToMarkAsRead.isEmpty else { return }
        
        // Update the `wasRead` flag to true
        try interactionQuery.updateAll(db, Columns.wasRead.set(to: true))
        
        // Retrieve the interaction ids we want to update
        scheduleJobs(interactionIds: interactionIdsToMarkAsRead)
    }
    
    /// This method flags sent messages as read for the specified recipients
    ///
    /// **Note:** This method won't update the 'wasRead' flag (it will be updated via the above method)
    static func markAsRead(_ db: Database, recipientId: String, timestampMsValues: [Double], readTimestampMs: Double) throws {
        guard db[.areReadReceiptsEnabled] == true else { return }
        
        try RecipientState
            .filter(RecipientState.Columns.recipientId == recipientId)
            .joining(
                required: RecipientState.interaction
                    .filter(Columns.variant == Variant.standardOutgoing)
                    .filter(timestampMsValues.contains(Columns.timestampMs))
            )
            .updateAll(
                db,
                RecipientState.Columns.readTimestampMs.set(to: readTimestampMs),
                RecipientState.Columns.state.set(to: RecipientState.State.sent)
            )
    }
}

// MARK: - Search Queries

public extension Interaction {
    static func idsForTermWithin(threadId: String, pattern: FTS5Pattern) -> SQLRequest<Int64> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let interactionFullTextSearch: SQL = SQL(stringLiteral: Interaction.fullTextSearchTableName)
        
        let request: SQLRequest<Int64> = """
            SELECT \(interaction[.id])
            FROM \(Interaction.self)
            JOIN \(interactionFullTextSearch) ON (
                \(interactionFullTextSearch).rowid = \(interaction.alias[Column.rowID]) AND
                \(interactionFullTextSearch).\(SQL(stringLiteral: Interaction.Columns.body.name)) MATCH \(pattern)
            )
            WHERE \(SQL("\(interaction[.threadId]) = \(threadId)"))
        
            ORDER BY \(interaction[.timestampMs].desc)
        """
        
        return request
    }
}

// MARK: - Convenience

public extension Interaction {
    static let oversizeTextMessageSizeThreshold: UInt = (2 * 1024)
    
    // MARK: - Variables
    
    var isExpiringMessage: Bool {
        guard variant == .standardIncoming || variant == .standardOutgoing else { return false }
        
        return (expiresInSeconds ?? 0 > 0)
    }
    
    var openGroupWhisper: Bool { return (openGroupWhisperMods || (openGroupWhisperTo != nil)) }
    
    var notificationIdentifiers: [String] {
        [
            notificationIdentifier(isBackgroundPoll: true),
            notificationIdentifier(isBackgroundPoll: false)
        ]
    }
    
    // MARK: - Functions
    
    func notificationIdentifier(isBackgroundPoll: Bool) -> String {
        // When the app is in the background we want the notifications to be grouped to prevent spam
        guard isBackgroundPoll else { return threadId }
        
        return "\(threadId)-\(id ?? 0)"
    }
    
    func markingAsDeleted() -> Interaction {
        return Interaction(
            id: id,
            serverHash: nil,
            threadId: threadId,
            authorId: authorId,
            variant: .standardIncomingDeleted,
            body: nil,
            timestampMs: timestampMs,
            receivedAtTimestampMs: receivedAtTimestampMs,
            wasRead: wasRead,
            hasMention: hasMention,
            expiresInSeconds: expiresInSeconds,
            expiresStartedAtMs: expiresStartedAtMs,
            linkPreviewUrl: linkPreviewUrl,
            openGroupServerMessageId: openGroupServerMessageId,
            openGroupWhisperMods: openGroupWhisperMods,
            openGroupWhisperTo: openGroupWhisperTo
        )
    }
    
    func isUserMentioned(_ db: Database) -> Bool {
        guard variant == .standardIncoming else { return false }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        return (
            (
                body != nil &&
                (body ?? "").contains("@\(userPublicKey)")
            ) || (
                (try? quote.fetchOne(db))?.authorId == userPublicKey
            )
        )
    }
    
    /// Use the `Interaction.previewText` method directly where possible rather than this method as it
    /// makes it's own database queries
    func previewText(_ db: Database) -> String {
        switch variant {
            case .standardIncoming, .standardOutgoing:
                return Interaction.previewText(
                    variant: self.variant,
                    body: self.body,
                    attachmentDescriptionInfo: try? attachments
                        .select(.id, .variant, .contentType, .sourceFilename)
                        .asRequest(of: Attachment.DescriptionInfo.self)
                        .fetchOne(db),
                    attachmentCount: try? attachments.fetchCount(db),
                    isOpenGroupInvitation: (try? linkPreview
                        .filter(LinkPreview.Columns.variant == LinkPreview.Variant.openGroupInvitation)
                        .isNotEmpty(db))
                        .defaulting(to: false)
                )

            case .infoMediaSavedNotification, .infoScreenshotNotification:
                // Note: This should only occur in 'contact' threads so the `threadId`
                // is the contact id
                return Interaction.previewText(
                    variant: self.variant,
                    body: self.body,
                    authorDisplayName: Profile.displayName(db, id: threadId)
                )

            default: return Interaction.previewText(
                variant: self.variant,
                body: self.body
            )
        }
    }
    
    /// This menthod generates the preview text for a given transaction
    static func previewText(
        variant: Variant,
        body: String?,
        authorDisplayName: String = "",
        attachmentDescriptionInfo: Attachment.DescriptionInfo? = nil,
        attachmentCount: Int? = nil,
        isOpenGroupInvitation: Bool = false
    ) -> String {
        switch variant {
            case .standardIncomingDeleted: return ""
                
            case .standardIncoming, .standardOutgoing:
                let attachmentDescription: String? = Attachment.description(
                    for: attachmentDescriptionInfo,
                    count: attachmentCount
                )
                
                if
                    let attachmentDescription: String = attachmentDescription,
                    let body: String = body,
                    !attachmentDescription.isEmpty,
                    !body.isEmpty
                {
                    if CurrentAppContext().isRTL {
                        return "\(body): \(attachmentDescription)"
                    }
                    
                    return "\(attachmentDescription): \(body)"
                }
                
                if let body: String = body, !body.isEmpty {
                    return body
                }
                
                if let attachmentDescription: String = attachmentDescription, !attachmentDescription.isEmpty {
                    return attachmentDescription
                }
                
                if isOpenGroupInvitation {
                    return "😎 Open group invitation"
                }
                
                // TODO: We should do better here
                return ""
                
            case .infoMediaSavedNotification:
                // TODO: Use referencedAttachmentTimestamp to tell the user * which * media was saved
                return String(format: "media_saved".localized(), authorDisplayName)
                
            case .infoScreenshotNotification:
                return String(format: "screenshot_taken".localized(), authorDisplayName)
                
            case .infoClosedGroupCreated: return "GROUP_CREATED".localized()
            case .infoClosedGroupCurrentUserLeft: return "GROUP_YOU_LEFT".localized()
            case .infoClosedGroupUpdated: return (body ?? "GROUP_UPDATED".localized())
            case .infoMessageRequestAccepted: return (body ?? "MESSAGE_REQUESTS_ACCEPTED".localized())
            
            case .infoDisappearingMessagesUpdate:
                guard
                    let infoMessageData: Data = (body ?? "").data(using: .utf8),
                    let messageInfo: DisappearingMessagesConfiguration.MessageInfo = try? JSONDecoder().decode(
                        DisappearingMessagesConfiguration.MessageInfo.self,
                        from: infoMessageData
                    )
                else { return (body ?? "") }
                
                return messageInfo.previewText
        }
    }
    
    func state(_ db: Database) throws -> RecipientState.State {
        let states: [RecipientState.State] = try RecipientState.State
            .fetchAll(
                db,
                recipientStates.select(.state)
            )
        
        return Interaction.state(for: states)
    }
    
    static func state(for states: [RecipientState.State]) -> RecipientState.State {
        // If there are no states then assume this is a new interaction which hasn't been
        // saved yet so has no states
        guard !states.isEmpty else { return .sending }
        
        var hasFailed: Bool = false
        
        for state in states {
            switch state {
                // If there are any "sending" recipients, consider this message "sending"
                case .sending: return .sending
                    
                case .failed:
                    hasFailed = true
                    break
                    
                default: break
            }
        }
        
        // If there are any "failed" recipients, consider this message "failed"
        guard !hasFailed else { return .failed }
        
        // Otherwise, consider the message "sent"
        //
        // Note: This includes messages with no recipients
        return .sent
    }
}
