import Foundation

struct User: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    var avatarUrl: String?
    var showLastSeen: Bool?      // present on /me + auth responses (legacy toggle)
    // §11.5 profile fields (additive on GET /me; absent on older servers).
    var about: String?
    var links: [String]?
    // §11.6 privacy fields — raw enum strings "EVERYBODY" | "FRIENDS" | "NOBODY".
    var lastSeenVisibility: String?
    var aboutVisibility: String?
    var avatarVisibility: String?
    var linksVisibility: String?
    var groupsVisibility: String?
    var statusVisibility: String?
    var silenceUnknownCallers: Bool?
    var readReceipts: Bool?
    // §12.2 email linking (additive on GET /me; absent on older servers).
    var email: String?
    var emailVerified: Bool?
}

/// One GET /me/starred item (§14.4): the message plus the server's enrichment — the
/// sender's public shape and a conversation context stub ({id, type, title}; the title
/// is the group name or the DM peer's display name). Both are optional so older
/// servers still decode; the saved-messages page then falls back to local caches.
struct StarredMessageItem: Decodable, Identifiable {
    var message: Message
    var sender: User?
    var conversation: Context?

    var id: String { message.id }

    struct Context: Decodable, Hashable {
        let id: String
        let type: String
        var title: String?
    }

    init(message: Message, sender: User?, conversation: Context?) {
        self.message = message
        self.sender = sender
        self.conversation = conversation
    }

    init(from decoder: Decoder) throws {
        message = try Message(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sender = try? c.decode(User.self, forKey: .sender)
        conversation = try? c.decode(Context.self, forKey: .conversation)
    }

    private enum CodingKeys: String, CodingKey { case sender, conversation }
}

/// POST /reports response (§12.1).
struct CreatedReport: Decodable {
    let id: String
}

/// §12.1 report categories — raw values match the server enum exactly.
enum ReportCategory: String, CaseIterable, Identifiable {
    case spam = "SPAM"
    case harassment = "HARASSMENT"
    case hateSpeech = "HATE_SPEECH"
    case violence = "VIOLENCE"
    case sexualContent = "SEXUAL_CONTENT"
    case childSafety = "CHILD_SAFETY"
    case scamFraud = "SCAM_FRAUD"
    case impersonation = "IMPERSONATION"
    case illegalActivity = "ILLEGAL_ACTIVITY"
    case other = "OTHER"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam:            return String(localized: "Spam")
        case .harassment:      return String(localized: "Harassment or bullying")
        case .hateSpeech:      return String(localized: "Hate speech")
        case .violence:        return String(localized: "Violence or threats")
        case .sexualContent:   return String(localized: "Sexual content")
        case .childSafety:     return String(localized: "Child safety")
        case .scamFraud:       return String(localized: "Scam or fraud")
        case .impersonation:   return String(localized: "Impersonation")
        case .illegalActivity: return String(localized: "Illegal activity")
        case .other:           return String(localized: "Something else")
        }
    }
}

/// A friend's profile (GET /users/:id). `lastSeenAt`/`online` are nil when hidden by privacy.
struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    var avatarUrl: String?
    var lastSeenAt: String?
    var online: Bool?
    /// §11.5 — present only when shared with the viewer (§11.6 visibility).
    var about: String?
    var links: [String]?
}

/// §11.6 visibility levels — raw values match the server's zod enum exactly.
enum KlicVisibility: String, CaseIterable, Identifiable {
    case everybody = "EVERYBODY"
    case friends = "FRIENDS"
    case nobody = "NOBODY"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .everybody: return String(localized: "Everybody")
        case .friends:   return String(localized: "My friends")
        case .nobody:    return String(localized: "Nobody")
        }
    }
}

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

/// Shared group chat theme (§14.3) — the server wire shape (admin-set, rendered by
/// every member). Field names match the server's zod schema exactly.
struct GroupThemePayload: Codable, Hashable {
    let pattern: Int
    let patternOpacity: Double
    var gradientId: String?
    var gradientIntensity: Double?
    var bubbleColorId: String?
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    var title: String?
    var description: String?
    var avatarUrl: String?
    let createdById: String?
    let members: [Member]
    var lastMessage: Message?
    var unreadCount: Int?   // present on the conversations list; absent elsewhere
    /// §14.3: the group's shared theme (absent on DMs / older servers).
    var theme: GroupThemePayload?

    struct Member: Codable, Hashable {
        let id: String; let username: String; let displayName: String
        var avatarUrl: String?
    }
}

struct GroupConversationDetails: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let title: String?
    let description: String?
    var avatarUrl: String?
    let createdById: String?
    var createdAt: String?      // exposed by newer servers — drives the "Created" footer
    let isAdmin: Bool
    let members: [Member]
    /// §14.3: the group's shared theme (absent on DMs / older servers).
    var theme: GroupThemePayload?
    /// §16.3: the conversation's pinned messages, oldest→newest (absent on older servers).
    var pinnedMessages: [ReplyPreview]?

    struct Member: Codable, Identifiable, Hashable {
        let id: String
        let username: String
        let displayName: String
        var avatarUrl: String?
        let joinedAt: String
        let isMe: Bool
        /// §11.5 About line — present when the member shares it with the viewer.
        var about: String? = nil
    }
}

struct CreateConversationRequest: Codable {
    var userId: String?
    var title: String?
    var userIds: [String]?
}

struct UpdateGroupConversationRequest: Codable {
    var title: String?
    var description: String??
    var avatarKey: String??
}

struct Attachment: Codable, Identifiable, Hashable {
    let id: String
    let kind: String            // "IMAGE" | "VOICE" | "VIDEO" | "VIDEO_NOTE" | "FILE"
    let url: String             // presigned download URL — expires ~1h; refresh via /attachments/:id/url
    let contentType: String
    let byteSize: Int
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var waveform: String?       // base64-encoded 5-bit packed waveform (VOICE only)
    var fileName: String?

    var isImage: Bool { kind == "IMAGE" }
    var isVoice: Bool { kind == "VOICE" }
    var isVideo: Bool { kind == "VIDEO" }
    var isVideoNote: Bool { kind == "VIDEO_NOTE" }
    var isFile:  Bool { kind == "FILE" }
}

/// Chat record of a finished call, carried on a CALL_EVENT message.
struct CallEvent: Codable, Hashable {
    let kind: String            // "AUDIO" | "VIDEO"
    let outcome: String         // "completed" | "missed" | "declined" | "canceled" | "failed"
    var durationMs: Int?
    var isVideo: Bool { kind == "VIDEO" }
}

/// Aggregated emoji reaction on a message (one entry per distinct emoji).
struct Reaction: Codable, Hashable {
    let emoji: String
    let count: Int
    let mine: Bool              // whether *I* reacted with this emoji
}

/// Compact media stub carried inside a quote (§16.1): the parent's first attachment,
/// presigned like AttachmentPayload (refreshable via GET /attachments/:id/url).
struct ReplyAttachmentStub: Codable, Hashable {
    var id: String?
    let kind: String            // "IMAGE" | "VOICE" | "VIDEO" | "VIDEO_NOTE" | "FILE"
    let url: String
    let contentType: String
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var fileName: String?

    /// Kinds that draw a thumbnail on the quote card (§16.1).
    var isVisual: Bool {
        kind == "IMAGE" || kind == "VIDEO" || kind == "VIDEO_NOTE"
            || (kind == "FILE" && contentType.hasPrefix("image/"))
    }
    var isVideoLike: Bool { kind == "VIDEO" || kind == "VIDEO_NOTE" }

    /// Bridge to the full attachment shape (thumbnail generation reuse).
    var asAttachment: Attachment {
        Attachment(
            id: id ?? url, kind: kind, url: url, contentType: contentType, byteSize: 0,
            width: width, height: height, durationMs: durationMs, waveform: nil, fileName: fileName
        )
    }
}

/// Compact quote of the message a reply points at (also the shape of a pinned-message
/// preview, §16.3). §16.1 additions decode tolerantly so older payloads still parse.
struct ReplyPreview: Codable, Hashable {
    let id: String
    let senderId: String
    let kind: String
    let preview: String        // truncated body or a kind label ("📷 Photo", …)
    /// The parent's first attachment — drives the quote thumbnail (§16.1).
    var attachment: ReplyAttachmentStub?
    /// Parent was deleted for everyone → "Deleted message", no thumb.
    var deleted: Bool?

    init(id: String, senderId: String, kind: String, preview: String,
         attachment: ReplyAttachmentStub? = nil, deleted: Bool? = nil) {
        self.id = id; self.senderId = senderId; self.kind = kind; self.preview = preview
        self.attachment = attachment; self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        senderId = try c.decode(String.self, forKey: .senderId)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "TEXT"
        preview = (try? c.decode(String.self, forKey: .preview)) ?? ""
        attachment = try? c.decode(ReplyAttachmentStub.self, forKey: .attachment)
        deleted = try? c.decode(Bool.self, forKey: .deleted)
    }
}

struct MessageEnvelope: Codable, Hashable {
    let deviceId: UInt32
    let type: Int
    let ciphertext: String
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let conversationId: String
    let senderId: String
    let body: String
    let kind: String
    let createdAt: String
    var attachments: [Attachment] = []
    var status: String?          // "sent" | "delivered" | "read" — own messages only
    var stickerId: String?       // STICKER messages
    var stickerUrl: String?
    var call: CallEvent?         // CALL_EVENT messages
    var replyTo: ReplyPreview?   // the quoted message, when this is a reply
    var reactions: [Reaction] = []
    var deletedAt: String?       // set when deleted for everyone
    var starred: Bool?           // whether *I* starred this message (per-requester)
    var editedAt: String?        // §16.4 — set when the body was edited
    var pinnedAt: String?        // §16.3 — set while the message is pinned
    // CIPHERTEXT messages (E2EE): sender's protocol device + the envelopes
    // addressed to this user's devices (this client picks its own by deviceId).
    var senderDeviceId: Int?
    var envelopes: [MessageEnvelope]?

    var isCallEvent: Bool { kind == "CALL_EVENT" }
    var isSticker: Bool { kind == "STICKER" }
    var isSystem: Bool { kind == "SYSTEM" }
    var isDeleted: Bool { deletedAt != nil }
    var isVideoNote: Bool { kind == "VIDEO_NOTE" }
    var isPinned: Bool { pinnedAt != nil }
    var isEdited: Bool { editedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, conversationId, senderId, body, kind, createdAt, attachments, status
        case stickerId, stickerUrl, call, replyTo, reactions, deletedAt, starred
        case editedAt, pinnedAt
        case senderDeviceId, envelopes
    }

    // Tolerant decode (body/kind may be empty; attachments absent on older payloads).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        senderId = try c.decode(String.self, forKey: .senderId)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "TEXT"
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        status = try? c.decode(String.self, forKey: .status)
        stickerId = try? c.decode(String.self, forKey: .stickerId)
        stickerUrl = try? c.decode(String.self, forKey: .stickerUrl)
        call = try? c.decode(CallEvent.self, forKey: .call)
        replyTo = try? c.decode(ReplyPreview.self, forKey: .replyTo)
        reactions = (try? c.decode([Reaction].self, forKey: .reactions)) ?? []
        deletedAt = try? c.decode(String.self, forKey: .deletedAt)
        starred = try? c.decode(Bool.self, forKey: .starred)
        editedAt = try? c.decode(String.self, forKey: .editedAt)
        pinnedAt = try? c.decode(String.self, forKey: .pinnedAt)
        senderDeviceId = try? c.decode(Int.self, forKey: .senderDeviceId)
        envelopes = try? c.decode([MessageEnvelope].self, forKey: .envelopes)
    }

    // Convenience init so building a Message locally stays ergonomic.
    init(id: String, conversationId: String, senderId: String, body: String,
         kind: String, createdAt: String, attachments: [Attachment] = [], status: String? = nil,
         stickerId: String? = nil, stickerUrl: String? = nil, call: CallEvent? = nil,
         replyTo: ReplyPreview? = nil, reactions: [Reaction] = [], deletedAt: String? = nil,
         starred: Bool? = nil, editedAt: String? = nil, pinnedAt: String? = nil,
         senderDeviceId: Int? = nil, envelopes: [MessageEnvelope]? = nil) {
        self.id = id; self.conversationId = conversationId; self.senderId = senderId
        self.body = body; self.kind = kind; self.createdAt = createdAt
        self.attachments = attachments; self.status = status
        self.stickerId = stickerId; self.stickerUrl = stickerUrl; self.call = call
        self.replyTo = replyTo; self.reactions = reactions; self.deletedAt = deletedAt
        self.starred = starred; self.editedAt = editedAt; self.pinnedAt = pinnedAt
        self.senderDeviceId = senderDeviceId; self.envelopes = envelopes
    }
}

/// One row in the Call tab's recent-calls list (GET /calls).
struct RecentCall: Codable, Identifiable {
    let id: String
    let conversationId: String
    let kind: String
    let outgoing: Bool
    let outcome: String         // "completed" | "missed" | "declined" | "canceled" | "failed"
    let startedAt: String
    var durationMs: Int?
    /// Everyone besides me who was on the call (a 1:1 peer is the single-element case).
    var participants: [Peer]?
    /// Pre-group servers sent a single `peer`; kept as a decode fallback.
    var peer: Peer?
    var isVideo: Bool { kind == "VIDEO" }

    /// The counterpart shown on the row — first fellow participant, or the legacy peer.
    var primaryPeer: Peer? { participants?.first ?? peer }
    var peerNames: String {
        let names = (participants ?? []).map(\.displayName)
        if names.isEmpty { return peer?.displayName ?? "Unknown" }
        return names.joined(separator: ", ")
    }

    struct Peer: Codable, Identifiable {
        let id: String
        let username: String
        let displayName: String
        var avatarUrl: String?
    }
}

/// One sticker in the pack catalog (GET /stickers).
struct Sticker: Codable, Identifiable {
    let id: String
    let url: String
}

struct FriendRequest: Codable, Identifiable {
    let requestId: String
    let from: From
    var id: String { requestId }

    struct From: Codable {
        let id: String
        let username: String
        let displayName: String
        var avatarUrl: String?
    }
}

struct CallSession: Codable, Identifiable {
    let callId: String
    let roomName: String
    let livekitUrl: String
    let token: String
    var kind: String?
    var id: String { callId }
}

/// An in-progress call on a conversation (GET /conversations/:id/active-call, 404 when none).
/// Drives the "Join call" banner in group chats.
struct ActiveCallInfo: Codable, Identifiable {
    let callId: String
    let conversationId: String
    let roomName: String
    let livekitUrl: String
    let kind: String
    let status: String          // "RINGING" | "ANSWERING" | "ONGOING" | "RECONNECTING"
    let startedBy: String
    let participants: [Participant]
    var id: String { callId }
    /// Participants whose media actually joined the room (joinedAt set).
    var joinedCount: Int { participants.filter { $0.joinedAt != nil }.count }

    struct Participant: Codable {
        let userId: String
        let joinedAt: String?
    }
}

// MARK: - Notification / conversation prefs (CALLS.md §8.2)

/// Global per-user push toggles (GET/PUT /me/notification-prefs). Defaults are all-on.
struct NotificationPrefs: Codable, Equatable {
    var messages: Bool
    var groups: Bool
    var calls: Bool
    var friendRequests: Bool

    static let defaults = NotificationPrefs(messages: true, groups: true, calls: true, friendRequests: true)
}

/// Per-conversation mute state (GET/PUT /conversations/:id/prefs).
/// ISO date strings or nil; "Always" muted = 9999-12-31T00:00:00Z.
struct ConversationPrefs: Codable, Equatable {
    var messagesMutedUntil: String?
    var muteMentions: Bool?
    var callsMutedUntil: String?
}

/// One row from GET /conversations/:id/attachments — attachment fields plus the
/// message context needed by the "Media, links, docs" browser.
struct ConversationAttachment: Codable, Identifiable, Hashable {
    let id: String
    let kind: String            // "IMAGE" | "VOICE" | "VIDEO" | "FILE"
    let url: String
    let contentType: String
    let byteSize: Int
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var fileName: String?
    let messageId: String
    let senderId: String
    let createdAt: String

    var asAttachment: Attachment {
        Attachment(
            id: id, kind: kind, url: url, contentType: contentType, byteSize: byteSize,
            width: width, height: height, durationMs: durationMs, waveform: nil, fileName: fileName
        )
    }
}

// MARK: - Privacy & Security (§10.4)

/// One row from GET /blocks.
struct BlockedUser: Codable, Identifiable {
    let user: User
    let blockedAt: String
    var id: String { user.id }
}

/// One passkey from GET /me/passkeys.
struct PasskeyCredentialInfo: Codable, Identifiable {
    let id: String
    var label: String?
    var createdAt: String?
    var lastUsedAt: String?
}

// MARK: - Uploads

/// Server response from POST /uploads — a presigned PUT URL the client uploads to.
struct UploadTicket: Decodable {
    let key: String
    let uploadUrl: String
    let expiresAt: String
    let maxBytes: Int
}

/// One attachment to reference when sending a message (after its bytes are uploaded).
struct AttachmentDraft {
    let key: String
    let kind: String            // "IMAGE" | "VOICE" | "VIDEO" | "FILE"
    let contentType: String
    let byteSize: Int
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var waveform: Data?         // 5-bit packed waveform bytes to send as base64 (VOICE only)
    var fileName: String?
}
