import AuthenticationServices
import SwiftUI

struct SignInWithApple: View {
    @ObservedObject var authentication: AuthenticationService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignInWithAppleButton(.signIn) { request in
                authentication.prepareAppleRequest(request)
            } onCompletion: { result in
                Task {
                    await authentication.completeAppleSignIn(result)
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 44)
            .disabled(authentication.isWorking)

            if let error = authentication.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
