//
//  SocialSignInView.swift
//  RPI Central
//

import SwiftUI

struct SocialSignInView: View {
    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @State private var mode: AuthMode = .login
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(calendarViewModel.themeColor)
                    Text("Campus Social")
                        .font(.title2.bold())
                    Text("Chat with friends, share schedules, and see who’s on campus.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if !socialManager.isFirebaseConfigured {
                Section {
                    Label(socialManager.setupMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if mode.requiresDisplayName {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .textContentType(.name)
                }
                if mode.requiresEmail {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                }
                if mode.requiresPassword {
                    SecureField("Password", text: $password)
                        .textContentType(mode == .register ? .newPassword : .password)
                }
            } footer: {
                if mode == .guest {
                    Text("Guest accounts stay on this phone and can’t be recovered.")
                }
            }

            Section {
                Button(action: submit) {
                    Group {
                        if socialManager.isLoading {
                            ProgressView()
                        } else {
                            Text(mode.buttonTitle)
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(
                    socialManager.isLoading ||
                        !socialManager.isFirebaseConfigured ||
                        !mode.isFormValid(displayName: displayName, email: email, password: password)
                )
            }
        }
    }

    private func submit() {
        Task {
            switch mode {
            case .login:
                await socialManager.login(email: email, password: password)
            case .register:
                await socialManager.register(displayName: displayName, email: email, password: password)
            case .guest:
                await socialManager.continueAsGuest(displayName: displayName.isEmpty ? "Guest" : displayName)
            }
        }
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case login
    case register
    case guest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .login: return "Log In"
        case .register: return "Sign Up"
        case .guest: return "Guest"
        }
    }

    var buttonTitle: String {
        switch self {
        case .login: return "Log In"
        case .register: return "Create Account"
        case .guest: return "Continue as Guest"
        }
    }

    var requiresDisplayName: Bool { self != .login }
    var requiresEmail: Bool { self != .guest }
    var requiresPassword: Bool { self != .guest }

    func isFormValid(displayName: String, email: String, password: String) -> Bool {
        let hasName = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasEmail = !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch self {
        case .login: return hasEmail && !password.isEmpty
        case .register: return hasName && hasEmail && password.count >= 6
        case .guest: return hasName
        }
    }
}
