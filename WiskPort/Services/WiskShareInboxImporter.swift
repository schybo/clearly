import Foundation
import SwiftData

#if os(iOS)
enum WiskShareInboxImporter {
    @MainActor
    @discardableResult
    static func ingestPendingItems(
        context: ModelContext,
        attachmentService: WiskAttachmentService,
        syncService: SyncService
    ) async -> [Note] {
        let pending: [(item: WiskShareInbox.Item, imageData: [Data])]
        do {
            pending = try WiskShareInbox.consumePendingItems()
        } catch {
            return []
        }
        guard pending.isEmpty == false else { return [] }

        var created: [Note] = []
        for entry in pending {
            let note = Note(title: entry.item.title, body: entry.item.body, kind: .general)
            note.markdownEnabled = true
            note.snapshotIfNeeded(reason: "share-extension")
            context.insert(note)

            for (index, imageData) in entry.imageData.enumerated() {
                do {
                    let altText = entry.imageData.count == 1 ? "Shared image" : "Shared image \(index + 1)"
                    let result = try attachmentService.makePendingAttachment(
                        from: imageData,
                        note: note,
                        altText: altText
                    )
                    context.insert(result.attachment)
                    if note.attachments.contains(where: { $0.id == result.attachment.id }) == false {
                        note.attachments.append(result.attachment)
                    }
                    let reference = WiskAttachmentMarkdown.reference(
                        title: result.attachment.altText,
                        id: result.attachment.id,
                        isImage: true
                    )
                    note.body = WiskAttachmentMarkdown.appending(reference, to: note.body)
                    Task {
                        await attachmentService.upload(
                            result.attachment,
                            imageData: result.normalizedImage.data,
                            noteID: note.id
                        )
                    }
                } catch {
                    continue
                }
            }

            NoteLibraryIndex.upsert(note, in: context)
            created.append(note)
        }

        if created.isEmpty == false {
            try? context.save()
            syncService.enqueue(notes: created, context: context)
            Task {
                await syncService.syncNow(context: context)
            }
        }
        return created
    }
}
#endif
