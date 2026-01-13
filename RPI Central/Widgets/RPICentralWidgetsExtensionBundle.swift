//
//  RPICentralWidgetsExtensionBundle.swift
//  WidgetsExtension
//

import WidgetKit
import SwiftUI

@main
struct RPICentralWidgetsExtensionBundle: WidgetBundle {
    var body: some Widget {
        RPICentralMonthWidget()

        // Optional: keep NextUp widget too if you want it
        // RPICentralNextUpWidget()
    }
}
