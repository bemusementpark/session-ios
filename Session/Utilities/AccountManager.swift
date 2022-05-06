//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalUtilitiesKit

/**
 * Signal is actually two services - textSecure for messages and red phone (for calls). 
 * AccountManager delegates to both.
 */
@objc
public class AccountManager: NSObject {

    // MARK: - Dependencies

    private var preferences: OWSPreferences {
        return Environment.shared.preferences
    }

    private var tsAccountManager: TSAccountManager {
        return TSAccountManager.sharedInstance()
    }

    // MARK: -

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)
    }

    // MARK: registration

    @objc func registerObjc(verificationCode: String,
                            pin: String?) -> AnyPromise {
        return AnyPromise(register(verificationCode: verificationCode, pin: pin))
    }

    func register(verificationCode: String,
                  pin: String?) -> Promise<Void> {
        guard verificationCode.count > 0 else {
            let error = OWSErrorWithCodeDescription(.userError,
                                                    NSLocalizedString("REGISTRATION_ERROR_BLANK_VERIFICATION_CODE",
                                                                      comment: "alert body during registration"))
            return Promise(error: error)
        }

        Logger.debug("registering with signal server")
        let registrationPromise: Promise<Void> = firstly {
            return self.registerForTextSecure(verificationCode: verificationCode, pin: pin)
        }.then { _ -> Promise<Void> in
            return self.syncPushTokens().recover { (error) -> Promise<Void> in
                switch error {
                case PushRegistrationError.pushNotSupported(let description):
                    // This can happen with:
                    // - simulators, none of which support receiving push notifications
                    // - on iOS11 devices which have disabled "Allow Notifications" and disabled "Enable Background Refresh" in the system settings.
                    Logger.info("Recovered push registration error. Registering for manual message fetcher because push not supported: \(description)")
                    return self.enableManualMessageFetching()
                default:
                    throw error
                }
            }
        }.done { (_) -> Void in
            self.completeRegistration()
        }

        registrationPromise.retainUntilComplete()

        return registrationPromise
    }

    private func registerForTextSecure(verificationCode: String,
                                       pin: String?) -> Promise<Void> {
        return Promise { resolver in
            tsAccountManager.verifyAccount(withCode: verificationCode,
                                           pin: pin,
                                           success: { resolver.fulfill(()) },
                                           failure: resolver.reject)
        }
    }

    private func syncPushTokens() -> Promise<Void> {
        Logger.info("")
        
        guard let job: Job = Job(
            variant: .syncPushTokens,
            details: SyncPushTokensJob.Details(
                uploadOnlyIfStale: false
            )
        )
        else { return Promise(error: GRDBStorageError.decodingFailed) }
        
        let (promise, seal) = Promise<Void>.pending()
        
        SyncPushTokensJob.run(
            job,
            success: { _, _ in seal.fulfill(()) },
            failure: { _, error, _ in seal.reject(error ?? GRDBStorageError.generic) },
            deferred: { _ in seal.reject(GRDBStorageError.generic) }
        )
        
        return promise
    }

    private func completeRegistration() {
        Logger.info("")
        tsAccountManager.didRegister()
    }

    // MARK: Message Delivery

    func updatePushTokens(pushToken: String, voipToken: String, isForcedUpdate: Bool) -> Promise<Void> {
        return Promise { resolver in
            tsAccountManager.registerForPushNotifications(pushToken: pushToken,
                                                          voipToken: voipToken,
                                                     isForcedUpdate: isForcedUpdate,
                                                            success: { resolver.fulfill(()) },
                                                            failure: resolver.reject)
        }
    }

    func enableManualMessageFetching() -> Promise<Void> {
        let anyPromise = tsAccountManager.setIsManualMessageFetchEnabled(true)
        return Promise(anyPromise).asVoid()
    }
}
