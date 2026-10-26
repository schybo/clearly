import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class WiskProEntitlementService {
    static let monthlyProductID = "com.schybo.wisk.pro.monthly"
    static let yearlyProductID = "com.schybo.wisk.pro.yearly"

    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false
    private(set) var isRefreshingEntitlements = false
    private(set) var purchaseError: String?

    private var storeKitHasProAccess = false
    private let productIDs: Set<String>
    private var transactionUpdatesTask: Task<Void, Never>?

    #if DEBUG
    private static let debugForceProAccessKey = "wisk.debugForceProAccess"

    var debugForceProAccess: Bool {
        didSet {
            UserDefaults.standard.set(debugForceProAccess, forKey: Self.debugForceProAccessKey)
        }
    }
    #endif

    var hasProAccess: Bool {
        #if DEBUG
        storeKitHasProAccess || debugForceProAccess
        #else
        storeKitHasProAccess
        #endif
    }

    var sortedProducts: [Product] {
        products.sorted(by: Self.sortProducts)
    }

    init(productIDs: Set<String> = ["com.schybo.wisk.pro.monthly", "com.schybo.wisk.pro.yearly"]) {
        self.productIDs = productIDs
        #if DEBUG
        debugForceProAccess = UserDefaults.standard.bool(forKey: Self.debugForceProAccessKey)
        #endif
        transactionUpdatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                switch update {
                case .verified(let transaction):
                    let grantedAccess = applyVerifiedTransaction(transaction)
                    await transaction.finish()
                    if !grantedAccess {
                        await refreshEntitlements()
                    }
                case .unverified:
                    await refreshEntitlements()
                }
            }
        }
    }

    func configure() async {
        await refreshEntitlements()
        await loadProducts()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        purchaseError = nil
        defer { isLoadingProducts = false }

        do {
            let loadedProducts = try await Product.products(for: productIDs)
            products = loadedProducts.sorted(by: Self.sortProducts)
            if products.isEmpty {
                purchaseError = "Wisk Pro plans are not available in this build. Try again after StoreKit finishes syncing."
            }
        } catch {
            products = []
            purchaseError = "Wisk Pro plans could not be loaded. Try again later."
        }
    }

    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseError = "Wisk could not verify this purchase."
                    return
                }
                _ = applyVerifiedTransaction(transaction)
                await transaction.finish()
                purchaseError = nil
            case .pending:
                purchaseError = "Purchase is pending approval."
            case .userCancelled:
                purchaseError = nil
            @unknown default:
                purchaseError = "Purchase could not be completed."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseError = nil
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        guard !isRefreshingEntitlements else { return }
        isRefreshingEntitlements = true
        defer { isRefreshingEntitlements = false }

        var hasActiveSubscription = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if applyVerifiedTransaction(transaction) {
                hasActiveSubscription = true
            }
        }
        storeKitHasProAccess = hasActiveSubscription
        if hasActiveSubscription {
            purchaseError = nil
        }
    }

    @discardableResult
    private func applyVerifiedTransaction(_ transaction: Transaction) -> Bool {
        guard productIDs.contains(transaction.productID), transaction.revocationDate == nil else {
            return false
        }

        storeKitHasProAccess = true
        return true
    }

    private static func sortProducts(_ lhs: Product, _ rhs: Product) -> Bool {
        if lhs.id == yearlyProductID { return true }
        if rhs.id == yearlyProductID { return false }
        if lhs.id == monthlyProductID { return true }
        if rhs.id == monthlyProductID { return false }
        return lhs.displayPrice < rhs.displayPrice
    }
}
