//
//  LoanWidgetExtensionBundle.swift
//  LoanWidgetExtension
//
//  Created by Mohan Manthri on 22/05/26.
//

import WidgetKit
import SwiftUI


@main
struct LoanWidgetBundle: WidgetBundle {
    var body: some Widget {
        RingProgressWidget()
        OverviewWidget()
        LoanListWidget()
        NextEMIWidget()
        AddPaymentWidget()
    }
}
