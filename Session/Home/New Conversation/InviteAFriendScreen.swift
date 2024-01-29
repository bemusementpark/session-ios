// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct InviteAFriendScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var copied: Bool = false
    private let accountId: String = getUserHexEncodedPublicKey()
    
    static private let cornerRadius: CGFloat = 13
    
    var body: some View {
        ZStack(alignment: .center) {
            VStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                Text(accountId)
                    .font(.system(size: Values.smallFontSize))
                    .multilineTextAlignment(.center)
                    .foregroundColor(themeColor: .textPrimary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.all, Values.largeSpacing)
                    .overlay(
                        RoundedRectangle(
                            cornerSize: CGSize(
                                width: Self.cornerRadius,
                                height: Self.cornerRadius
                            )
                        )
                        .stroke(themeColor: .borderSeparator)
                    )
                
                Text("invite_a_friend_explanation".localized())
                    .font(.system(size: Values.verySmallFontSize))
                    .multilineTextAlignment(.center)
                    .foregroundColor(themeColor: .textSecondary)
                    .padding(.horizontal, Values.smallSpacing)
                
                HStack(
                    alignment: .center,
                    spacing: 0
                ) {
                    Button {
                        share()
                    } label: {
                        Text("share".localized())
                            .bold()
                            .font(.system(size: Values.mediumFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: Values.mediumButtonHeight,
                                alignment: .center
                            )
                            .overlay(
                                Capsule()
                                    .stroke(themeColor: .textPrimary)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    
                    Spacer(minLength: Values.mediumSpacing)
                    
                    Button {
                        copyAccoounId()
                    } label: {
                        let buttonTitle: String = self.copied ? "copied".localized() : "copy".localized()
                        Text(buttonTitle)
                            .bold()
                            .font(.system(size: Values.mediumFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: Values.mediumButtonHeight,
                                alignment: .center
                            )
                            .overlay(
                                Capsule()
                                    .stroke(themeColor: .textPrimary)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
                
                Spacer()
            }
            .padding(Values.largeSpacing)
        }
        .backgroundColor(themeColor: .backgroundSecondary)
    }
    
    private func copyAccoounId() {
        UIPasteboard.general.string = self.accountId
        self.copied = true
    }
    
    private func share() {
        let invitation: String = "Hey, I've been using Session to chat with complete privacy and security. Come join me! My Account ID is \n\n\(self.accountId) \n\nDownload it at https://getsession.org/"
        
        self.host.controller?.present(
            UIActivityViewController(
                activityItems: [ invitation ],
                applicationActivities: nil
            ),
            animated: true
        )
    }
}

#Preview {
    InviteAFriendScreen()
}
