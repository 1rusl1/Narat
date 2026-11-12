import StoreKit

struct StoreKitService {
    enum Plan: String, CaseIterable {
        case monthly = "app.narat.plants.pro.monthly"
        case yearly = "app.narat.plants.pro.yearly"

        fileprivate var periodUnit: Product.SubscriptionPeriod.Unit {
            self == .monthly ? .month : .year
        }
    }

    struct Offering {
        let plan: Plan
        let product: Product
        let eligibleTrial: Product.SubscriptionOffer?
    }

    func loadProducts() async throws -> [Offering] {
        let products = try await Product.products(for: Plan.allCases.map(\.rawValue))
        var offerings: [Offering] = []
        for plan in Plan.allCases {
            guard let product = products.first(where: { $0.id == plan.rawValue }),
                  product.type == .autoRenewable,
                  let subscription = product.subscription,
                  subscription.subscriptionPeriod.unit == plan.periodUnit,
                  subscription.subscriptionPeriod.value == 1 else { continue }

            var trial: Product.SubscriptionOffer?
            if plan == .yearly, let intro = subscription.introductoryOffer,
               intro.paymentMode == .freeTrial, intro.periodCount == 1,
               (intro.period.unit == .week && intro.period.value == 1
                || intro.period.unit == .day && intro.period.value == 7),
               await subscription.isEligibleForIntroOffer {
                trial = intro
            }
            offerings.append(Offering(plan: plan, product: product, eligibleTrial: trial))
        }
        try Task.checkCancellation()
        return offerings
    }
}
