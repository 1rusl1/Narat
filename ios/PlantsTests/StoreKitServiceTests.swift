import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import Plants

final class StoreKitServiceTests: XCTestCase {
    @MainActor
    func testLoadsConfiguredSubscriptionsAndOnlyTheEligibleYearlyTrial() async throws {
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StoreKit", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: config)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer { session.resetToDefaultState() }

        let plans = try await StoreKitService().loadProducts()
        XCTAssertEqual(plans.map(\.plan), [.monthly, .yearly])
        XCTAssertEqual(plans.map(\.product.id), ["app.narat.plants.pro.monthly", "app.narat.plants.pro.yearly"])
        let decimalLocale = Locale(identifier: "en_US_POSIX")
        let prices = try ["49.99", "199.99"].map { try XCTUnwrap(Decimal(string: $0, locale: decimalLocale)) }
        XCTAssertEqual(plans.map(\.product.price), prices)
        for plan in plans {
            XCTAssertEqual(plan.product.priceFormatStyle.currencyCode, "PLN")
            XCTAssertFalse(plan.product.displayPrice.isEmpty)
        }

        let monthly = try XCTUnwrap(plans.first)
        XCTAssertNil(monthly.eligibleTrial)
        let yearly = try XCTUnwrap(plans.last)
        let trial = try XCTUnwrap(yearly.eligibleTrial)
        XCTAssertEqual(trial.paymentMode, .freeTrial)
        XCTAssertEqual(trial.period.unit, .week)
        XCTAssertEqual(trial.period.value, 1)
        XCTAssertEqual(trial.periodCount, 1)
        XCTAssertTrue(session.allTransactions().isEmpty)
    }
}
