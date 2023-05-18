// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class Features {
    public static let useOnionRequests: Bool = true
    public static let useTestnet: Bool = false
    
    public static let useSharedUtilForUserConfig: Bool = true   // TODO: Base this off a timestamp

//    public static let useNewDisappearingMessagesConfig: Bool = Date().timeIntervalSince1970 > 1671062400 // 15/12/2022
    public static let useNewDisappearingMessagesConfig: Bool = false
}
