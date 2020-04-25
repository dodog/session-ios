import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • Consider making it the caller's responsibility to manage the database transaction (this helps avoid nested or unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.
// • Document the expected cases for everything.
// • Express those cases in tests.

@objc(LKMultiDeviceProtocol)
public final class MultiDeviceProtocol : NSObject {

    private static var _lastDeviceLinkUpdate: [String:Date] = [:]
    /// A mapping from hex encoded public key to date updated.
    public static var lastDeviceLinkUpdate: [String:Date] {
        get { LokiAPI.stateQueue.sync { _lastDeviceLinkUpdate } }
        set { LokiAPI.stateQueue.sync { _lastDeviceLinkUpdate = newValue } }
    }

    // TODO: I don't think this stateQueue stuff actually helps avoid race conditions

    internal static var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }

    // MARK: - Settings
    public static let deviceLinkUpdateInterval: TimeInterval = 20
    
    // MARK: - Multi Device Destination
    public struct MultiDeviceDestination : Hashable {
        public let hexEncodedPublicKey: String
        public let kind: Kind

        public enum Kind : String { case master, slave }
    }

    // MARK: - Initialization
    private override init() { }

    // MARK: - Sending (Part 1)
    @objc(isMultiDeviceRequiredForMessage:)
    public static func isMultiDeviceRequired(for message: TSOutgoingMessage) -> Bool {
        return !(message is DeviceLinkMessage)
    }

    @objc(sendMessageToDestinationAndLinkedDevices:in:)
    public static func sendMessageToDestinationAndLinkedDevices(_ messageSend: OWSMessageSend, in transaction: YapDatabaseReadWriteTransaction) {
        // TODO: I'm pretty sure there are quite a few holes in this logic
        let message = messageSend.message
        let recipientID = messageSend.recipient.recipientId()
        let thread = messageSend.thread ?? TSContactThread.getOrCreateThread(withContactId: recipientID, transaction: transaction) // TODO: This seems really iffy
        let isGroupMessage = thread.isGroupThread()
        let isOpenGroupMessage = (thread as? TSGroupThread)?.isPublicChat == true
        let isDeviceLinkMessage = message is DeviceLinkMessage
        let messageSender = SSKEnvironment.shared.messageSender
        guard !isOpenGroupMessage && !isDeviceLinkMessage else {
            return messageSender.sendMessage(messageSend)
        }
        let isSilentMessage = message.isSilent || message is EphemeralMessage || message is OWSOutgoingSyncMessage
        let isFriendRequestMessage = message is FriendRequestMessage
        let isSessionRequestMessage = message is LKSessionRequestMessage
        getMultiDeviceDestinations(for: recipientID, in: transaction).done(on: OWSDispatch.sendingQueue()) { destinations in
            // Send to master destination
            if let masterDestination = destinations.first(where: { $0.kind == .master }) {
                let thread = TSContactThread.getOrCreateThread(contactId: masterDestination.hexEncodedPublicKey) // TODO: I guess it's okay this starts a new transaction?
                if thread.isContactFriend || isSilentMessage || isFriendRequestMessage || isSessionRequestMessage || isGroupMessage {
                    let messageSendCopy = messageSend.copy(with: masterDestination)
                    messageSender.sendMessage(messageSendCopy)
                } else {
                    var frMessageSend: OWSMessageSend!
                    storage.dbReadWriteConnection.readWrite { transaction in // TODO: Yet another transaction
                        frMessageSend = getAutoGeneratedMultiDeviceFRMessageSend(for: masterDestination.hexEncodedPublicKey, in: transaction)
                    }
                    messageSender.sendMessage(frMessageSend)
                }
            }
            // Send to slave destinations (using a best attempt approach (i.e. ignoring the message send result) for now)
            let slaveDestinations = destinations.filter { $0.kind == .slave }
            for slaveDestination in slaveDestinations {
                let thread = TSContactThread.getOrCreateThread(contactId: slaveDestination.hexEncodedPublicKey) // TODO: I guess it's okay this starts a new transaction?
                if thread.isContactFriend || isSilentMessage || isFriendRequestMessage || isSessionRequestMessage || isGroupMessage {
                    let messageSendCopy = messageSend.copy(with: slaveDestination)
                    messageSender.sendMessage(messageSendCopy)
                } else {
                    var frMessageSend: OWSMessageSend!
                    storage.dbReadWriteConnection.readWrite { transaction in  // TODO: Yet another transaction
                        frMessageSend = getAutoGeneratedMultiDeviceFRMessageSend(for: slaveDestination.hexEncodedPublicKey, in: transaction)
                    }
                    messageSender.sendMessage(frMessageSend)
                }
            }
        }.catch(on: OWSDispatch.sendingQueue()) { error in
            // Proceed even if updating the linked devices map failed so that message sending
            // is independent of whether the file server is up
            messageSender.sendMessage(messageSend)
        }.retainUntilComplete()
    }

    @objc(updateDeviceLinksIfNeededForHexEncodedPublicKey:in:)
    public static func updateDeviceLinksIfNeeded(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> AnyPromise {
        let promise = getMultiDeviceDestinations(for: hexEncodedPublicKey, in: transaction)
        return AnyPromise.from(promise)
    }

    @objc(getAutoGeneratedMultiDeviceFRMessageForHexEncodedPublicKey:in:)
    public static func getAutoGeneratedMultiDeviceFRMessage(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> FriendRequestMessage {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction)
        let isSlaveDeviceThread = masterHexEncodedPublicKey != hexEncodedPublicKey
        thread.isForceHidden = isSlaveDeviceThread
        if thread.friendRequestStatus == .none || thread.friendRequestStatus == .requestExpired {
            thread.saveFriendRequestStatus(.requestSent, with: transaction) // TODO: Should we always immediately mark the slave device as a friend?
        }
        thread.save(with: transaction)
        let result = FriendRequestMessage(outgoingMessageWithTimestamp: NSDate.ows_millisecondTimeStamp(), in: thread,
            messageBody: "Please accept to enable messages to be synced across devices",
            attachmentIds: [], expiresInSeconds: 0, expireStartedAt: 0, isVoiceMessage: false,
            groupMetaMessage: .unspecified, quotedMessage: nil, contactShare: nil, linkPreview: nil)
        result.skipSave = true // TODO: Why is this necessary again?
        return result
    }

    @objc(getAutoGeneratedMultiDeviceFRMessageSendForHexEncodedPublicKey:in:)
    public static func getAutoGeneratedMultiDeviceFRMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> OWSMessageSend {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let message = getAutoGeneratedMultiDeviceFRMessage(for: hexEncodedPublicKey, in: transaction)
        let recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: hexEncodedPublicKey, transaction: transaction)
        let udManager = SSKEnvironment.shared.udManager
        let senderCertificate = udManager.getSenderCertificate()
        var recipientUDAccess: OWSUDAccess?
        if let senderCertificate = senderCertificate {
            recipientUDAccess = udManager.udAccess(forRecipientId: hexEncodedPublicKey, requireSyncAccess: true)
        }
        return OWSMessageSend(message: message, thread: thread, recipient: recipient, senderCertificate: senderCertificate,
            udAccess: recipientUDAccess, localNumber: getUserHexEncodedPublicKey(), success: {

        }, failure: { error in

        })
    }

    // MARK: - Receiving
    @objc(handleDeviceLinkMessageIfNeeded:wrappedIn:using:)
    public static func handleDeviceLinkMessageIfNeeded(_ protoContent: SSKProtoContent, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        // The envelope source is set during UD decryption
        let hexEncodedPublicKey = envelope.source!
        guard let deviceLinkMessage = protoContent.lokiDeviceLinkMessage, let master = deviceLinkMessage.masterHexEncodedPublicKey,
            let slave = deviceLinkMessage.slaveHexEncodedPublicKey, let slaveSignature = deviceLinkMessage.slaveSignature else {
            print("[Loki] Received an invalid device link message.")
            return
        }
        let deviceLinkingSession = DeviceLinkingSession.current
        if let masterSignature = deviceLinkMessage.masterSignature { // Authorization
            print("[Loki] Received a device link authorization from: \(hexEncodedPublicKey).") // Intentionally not `master`
            if let deviceLinkingSession = deviceLinkingSession {
                deviceLinkingSession.processLinkingAuthorization(from: master, for: slave, masterSignature: masterSignature, slaveSignature: slaveSignature)
            } else {
                print("[Loki] Received a device link authorization without a session; ignoring.")
            }
            // Set any profile info (the device link authorization also includes the master device's profile info)
            if let dataMessage = protoContent.dataMessage {
                SessionProtocol.updateDisplayNameIfNeeded(for: master, using: dataMessage, appendingShortID: false, in: transaction)
                SessionProtocol.updateProfileKeyIfNeeded(for: master, using: dataMessage)
            }
        } else { // Request
            print("[Loki] Received a device link request from: \(hexEncodedPublicKey).") // Intentionally not `slave`
            if let deviceLinkingSession = deviceLinkingSession {
                deviceLinkingSession.processLinkingRequest(from: slave, to: master, with: slaveSignature)
            } else {
                NotificationCenter.default.post(name: .unexpectedDeviceLinkRequestReceived, object: nil)
            }
        }
    }

    @objc(isUnlinkDeviceMessage:)
    public static func isUnlinkDeviceMessage(_ dataMessage: SSKProtoDataMessage) -> Bool {
        let unlinkDeviceFlag = SSKProtoDataMessage.SSKProtoDataMessageFlags.unlinkDevice
        return dataMessage.flags & UInt32(unlinkDeviceFlag.rawValue) != 0
    }

    @objc(handleUnlinkDeviceMessage:wrappedIn:using:)
    public static func handleUnlinkDeviceMessage(_ dataMessage: SSKProtoDataMessage, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        // The envelope source is set during UD decryption
        let hexEncodedPublicKey = envelope.source!
        guard let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: getUserHexEncodedPublicKey(), in: transaction) else { return }
        let wasSentByMasterDevice = (masterHexEncodedPublicKey == hexEncodedPublicKey)
        guard wasSentByMasterDevice else { return }
        let deviceLinks = storage.getDeviceLinks(for: hexEncodedPublicKey, in: transaction)
        if !deviceLinks.contains(where: { $0.master.hexEncodedPublicKey == hexEncodedPublicKey && $0.slave.hexEncodedPublicKey == getUserHexEncodedPublicKey() }) {
            return
        }
        LokiFileServerAPI.getDeviceLinks(associatedWith: getUserHexEncodedPublicKey(), in: transaction).done(on: .main) { deviceLinks in
            if deviceLinks.contains(where: { $0.master.hexEncodedPublicKey == hexEncodedPublicKey && $0.slave.hexEncodedPublicKey == getUserHexEncodedPublicKey() }) {
                UserDefaults.standard[.wasUnlinked] = true
                NotificationCenter.default.post(name: .dataNukeRequested, object: nil)
            }
        }
    }
}

// MARK: - Sending (Part 2)
// Here (in a non-@objc extension) because it doesn't interoperate well with Obj-C
public extension MultiDeviceProtocol {

    fileprivate static func getMultiDeviceDestinations(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> Promise<Set<MultiDeviceDestination>> {
        // FIXME: Threading
        let (promise, seal) = Promise<Set<MultiDeviceDestination>>.pending()
        func getDestinations(in transaction: YapDatabaseReadTransaction? = nil) {
            storage.dbReadConnection.read { transaction in
                var destinations: Set<MultiDeviceDestination> = []
                let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
                let masterDestination = MultiDeviceDestination(hexEncodedPublicKey: masterHexEncodedPublicKey, kind: .master)
                destinations.insert(masterDestination)
                let deviceLinks = storage.getDeviceLinks(for: masterHexEncodedPublicKey, in: transaction)
                let slaveDestinations = deviceLinks.map { MultiDeviceDestination(hexEncodedPublicKey: $0.slave.hexEncodedPublicKey, kind: .slave) }
                destinations.formUnion(slaveDestinations)
                seal.fulfill(destinations)
            }
        }
        let timeSinceLastUpdate: TimeInterval
        if let lastDeviceLinkUpdate = lastDeviceLinkUpdate[hexEncodedPublicKey] {
            timeSinceLastUpdate = Date().timeIntervalSince(lastDeviceLinkUpdate)
        } else {
            timeSinceLastUpdate = .infinity
        }
        if timeSinceLastUpdate > deviceLinkUpdateInterval {
            let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
            LokiFileServerAPI.getDeviceLinks(associatedWith: masterHexEncodedPublicKey, in: transaction).done(on: LokiAPI.workQueue) { _ in
                getDestinations()
                lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
            }.catch(on: LokiAPI.workQueue) { error in
                if (error as? LokiDotNetAPI.LokiDotNetAPIError) == LokiDotNetAPI.LokiDotNetAPIError.parsingFailed {
                    // Don't immediately re-fetch in case of failure due to a parsing error
                    lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
                    getDestinations()
                } else {
                    print("[Loki] Failed to get device links due to error: \(error).")
                    seal.reject(error)
                }
            }
        } else {
            getDestinations()
        }
        return promise
    }
}