import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class WiskProfileService {
    private let authService: WiskAuthService
    private let db: Firestore
    private let storage: Storage
    private var listener: ListenerRegistration?
    private var observedUID: String?

    private(set) var photoURL: URL?
    private(set) var syncedGoogleFont: WiskGoogleFont?
    private(set) var isLoading = false
    private(set) var isUploading = false
    private(set) var lastErrorMessage: String?

    init(
        authService: WiskAuthService,
        db: Firestore = Firestore.firestore(),
        storage: Storage = Storage.storage()
    ) {
        self.authService = authService
        self.db = db
        self.storage = storage
    }

    func startObserving() {
        guard let uid = authService.firebaseUID else {
            stopObserving()
            return
        }
        guard observedUID != uid else { return }

        listener?.remove()
        observedUID = uid
        isLoading = true
        photoURL = authService.photoURL

        listener = profileDocument(uid: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                    return
                }

                let rawURL = snapshot?.data()?["photoURL"] as? String
                self.photoURL = rawURL.flatMap(URL.init(string:)) ?? self.authService.photoURL
                self.syncedGoogleFont = Self.googleFont(from: snapshot?.data())
                self.lastErrorMessage = nil
            }
        }
    }

    func stopObserving() {
        listener?.remove()
        listener = nil
        observedUID = nil
        photoURL = nil
        syncedGoogleFont = nil
        isLoading = false
        isUploading = false
    }

    func uploadAvatar(from fileURL: URL) async {
        guard let uid = authService.firebaseUID else {
            lastErrorMessage = "Sign in before updating your profile photo."
            return
        }

        isUploading = true
        lastErrorMessage = nil
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
            isUploading = false
        }

        do {
            let originalData = try Data(contentsOf: fileURL)
            let jpegData = try Self.normalizedJPEGData(from: originalData)
            let reference = avatarReference(uid: uid)
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            try await putData(jpegData, metadata: metadata, reference: reference)
            let downloadURL = try await downloadURL(for: reference)
            try await updateProfile(uid: uid, photoURL: downloadURL)
            photoURL = downloadURL
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func removeAvatar() async {
        guard let uid = authService.firebaseUID else { return }

        isUploading = true
        lastErrorMessage = nil
        defer { isUploading = false }

        do {
            try? await delete(reference: avatarReference(uid: uid))
            try await updateProfile(uid: uid, photoURL: nil)
            photoURL = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func syncGoogleFontSelection(_ selection: WiskEditorFontSelection?) async {
        guard let uid = authService.firebaseUID else { return }

        do {
            var data: [String: Any] = [
                "updatedAt": FieldValue.serverTimestamp(),
            ]

            if selection?.source == .google,
               let family = selection?.googleFamily,
               let variant = selection?.googleVariant,
               let cssURL = selection?.googleCSSURL {
                data["editorFontSource"] = WiskEditorFontSource.google.rawValue
                data["googleFontFamily"] = family
                data["googleFontVariant"] = variant
                data["googleFontCSSURL"] = cssURL.absoluteString
            } else {
                data["editorFontSource"] = FieldValue.delete()
                data["googleFontFamily"] = FieldValue.delete()
                data["googleFontVariant"] = FieldValue.delete()
                data["googleFontCSSURL"] = FieldValue.delete()
            }

            try await setData(data, document: profileDocument(uid: uid))
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func profileDocument(uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    private static func googleFont(from data: [String: Any]?) -> WiskGoogleFont? {
        guard data?["editorFontSource"] as? String == WiskEditorFontSource.google.rawValue,
              let family = data?["googleFontFamily"] as? String,
              let variant = data?["googleFontVariant"] as? String,
              let rawURL = data?["googleFontCSSURL"] as? String,
              let cssURL = URL(string: rawURL) else {
            return nil
        }
        return WiskGoogleFont(family: family, variant: variant, cssURL: cssURL)
    }

    private func avatarReference(uid: String) -> StorageReference {
        storage.reference().child("users/\(uid)/profile/avatar.jpg")
    }

    private func updateProfile(uid: String, photoURL: URL?) async throws {
        var data: [String: Any] = [
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let photoURL {
            data["photoURL"] = photoURL.absoluteString
        } else {
            data["photoURL"] = FieldValue.delete()
        }

        try await setData(data, document: profileDocument(uid: uid))

        if let user = Auth.auth().currentUser, user.uid == uid {
            let request = user.createProfileChangeRequest()
            request.photoURL = photoURL
            try await commit(request: request)
            authService.refreshCurrentUserFromFirebase()
        }
    }

    private static func normalizedJPEGData(from data: Data, maxPixelSize: CGFloat = 512) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WiskProfileError.invalidImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WiskProfileError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw WiskProfileError.invalidImage
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.86,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WiskProfileError.invalidImage
        }

        return output as Data
    }

    private func putData(_ data: Data, metadata: StorageMetadata, reference: StorageReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.putData(data, metadata: metadata) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func downloadURL(for reference: StorageReference) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            reference.downloadURL { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: WiskProfileError.missingDownloadURL)
                }
            }
        }
    }

    private func delete(reference: StorageReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setData(_ data: [String: Any], document: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.setData(data, merge: true) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func commit(request: UserProfileChangeRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            request.commitChanges { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum WiskProfileError: LocalizedError {
    case invalidImage
    case missingDownloadURL

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Choose a JPEG, PNG, or HEIC image."
        case .missingDownloadURL:
            return "Wisk could not read the uploaded profile photo URL."
        }
    }
}
