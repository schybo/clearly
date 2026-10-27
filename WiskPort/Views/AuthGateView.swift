import AuthenticationServices
import SwiftUI

#if os(macOS)
private let macAuthButtonHeight: CGFloat = 40
private let macAuthButtonCornerRadius: CGFloat = 8
#endif

#if os(iOS)
private let iosAuthCardMaxWidth: CGFloat = 400
private let iosAuthButtonHeight: CGFloat = 52
private let iosGoogleText = Color(red: 0.122, green: 0.122, blue: 0.122)
private let iosGoogleBorder = Color(red: 0.455, green: 0.467, blue: 0.459)
#endif

struct AuthGateView: View {
    @Environment(WiskAuthService.self) private var authService
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    var body: some View {
        #if os(macOS)
        macAuthBody
        #else
        iosAuthBody
        #endif
    }

    #if os(iOS)
    private var isSigningIn: Bool {
        authService.authState == .signingIn
    }

    private var iosAuthBody: some View {
        ZStack {
            LiquidBackground()
                .accessibilityHidden(true)

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: Spacing.xxl) {
                        hero
                        providerCard
                        privacyFooter
                    }
                    .frame(maxWidth: iosAuthCardMaxWidth)
                    .readableWidth()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xxl)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityIdentifier("wisk.auth.screen")
        .disabled(isSigningIn)
        .overlay {
            if isSigningIn {
                signingInOverlay
            }
        }
    }

    private var hero: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                if !reduceTransparency && !reduceMotion {
                    Circle()
                        .fill(Color.accent.opacity(0.18))
                        .blur(radius: 36)
                        .frame(width: 148, height: 148)
                }

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.accent.opacity(0.28), lineWidth: 1)
                    )
                    .frame(width: 88, height: 88)

                Image("WiskLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityHidden(true)

            Text("WISK")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Your notes, everywhere.")
                    .font(AppFont.hero)
                    .foregroundStyle(Color.wiskPrimaryText)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)

                Text("Sign in once to keep Wisk synced across iPhone and Mac.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerCard: some View {
        VStack(spacing: Spacing.md) {
            appleButton
            googleButton

            if !isSigningIn, let message = authService.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .accessibilityIdentifier("wisk.auth.error")
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .cardStyle(cornerRadius: 22)
    }

    private var privacyFooter: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "lock.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
            Text("Private by default. Synced securely with your account only after you sign in.")
                .font(.caption)
                .foregroundStyle(Color.wiskTertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            authService.configureAppleRequest(request)
        } onCompletion: { result in
            Task {
                await authService.handleAppleCompletion(result)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .id(colorScheme)
        .frame(maxWidth: .infinity)
        .frame(height: iosAuthButtonHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .accessibilityIdentifier("wisk.auth.appleButton")
        .accessibilityLabel("Continue with Apple")
        .accessibilityAddTraits(.isButton)
    }

    private var googleButton: some View {
        Button {
            Task {
                await authService.signInWithGoogle()
            }
        } label: {
            Group {
                if isSigningIn {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(iosGoogleText)
                        Text("Signing in…")
                            .font(AppFont.buttonLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                } else {
                    HStack(spacing: Spacing.sm) {
                        GoogleGIcon()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                        Text("Continue with Google")
                            .font(AppFont.buttonLabel)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .foregroundStyle(iosGoogleText)
            .frame(maxWidth: .infinity)
            .frame(height: iosAuthButtonHeight)
            .padding(.horizontal, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .strokeBorder(iosGoogleBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(height: iosAuthButtonHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .accessibilityIdentifier("wisk.auth.googleButton")
        .accessibilityLabel("Continue with Google")
        .accessibilityValue(isSigningIn ? "In progress" : "")
        .accessibilityAddTraits(.isButton)
    }

    private var signingInOverlay: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.35 : 0.18)
                .ignoresSafeArea()
            ProgressView("Signing in…")
                .font(.body)
                .padding(Spacing.xl)
                .wiskGlassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signing in")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }
    #endif

    #if os(macOS)
    private var macAuthBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 34)

            VStack(spacing: 20) {
                macWiskMark

                VStack(spacing: 7) {
                    Text("Sign in to Wisk")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.wiskPrimaryText)
                        .accessibilityAddTraits(.isHeader)

                    Text("Keep your notes synced across iPhone and Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    macAppleButton
                    macGoogleButton
                }
                .disabled(authService.authState == .signingIn)

                macAuthStatus

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Private by default. Sync starts after you sign in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(width: 340)

            Spacer(minLength: 28)
        }
        .frame(width: 460, height: 390)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var macWiskMark: some View {
        Image("WiskLogo")
            .resizable()
            .scaledToFit()
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    private var macAppleButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous)
                .fill(Color.black)
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 20, height: 20)
                Text("Continue with Apple")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            SignInWithAppleButton(.continue) { request in
                authService.configureAppleRequest(request)
            } onCompletion: { result in
                Task {
                    await authService.handleAppleCompletion(result)
                }
            }
            .signInWithAppleButtonStyle(.black)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(0.02)
            .accessibilityIdentifier("wisk.auth.appleButton")
            .accessibilityAddTraits(.isButton)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: macAuthButtonHeight,
            maxHeight: macAuthButtonHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous))
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous))
    }

    private var macGoogleButton: some View {
        Button {
            Task {
                await authService.signInWithGoogle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous)
                            .strokeBorder(
                                Color(red: 0.455, green: 0.467, blue: 0.459),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)
                    }

                HStack(spacing: 8) {
                    GoogleGIcon()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text("Continue with Google")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color(red: 0.122, green: 0.122, blue: 0.122))
                .frame(maxWidth: .infinity)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: macAuthButtonHeight,
                maxHeight: macAuthButtonHeight
            )
        }
        .buttonStyle(.plain)
        .frame(
            maxWidth: .infinity,
            minHeight: macAuthButtonHeight,
            maxHeight: macAuthButtonHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous))
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: macAuthButtonCornerRadius, style: .continuous))
        .accessibilityIdentifier("wisk.auth.googleButton")
        .accessibilityLabel("Continue with Google")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var macAuthStatus: some View {
        if authService.authState == .signingIn {
            Label {
                Text("Signing in...")
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let message = authService.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif
}
