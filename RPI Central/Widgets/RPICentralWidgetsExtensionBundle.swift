//
//  RPICentralWidgetsExtensionBundle.swift
//  WidgetsExtension
//

import WidgetKit
import SwiftUI

@main
struct RPICentralWidgetsExtensionBundle: WidgetBundle {
    var body: some Widget {
        RPICentralUpNextWidget()
        RPICentralTodayWidget()
        RPICentralDeadlinesWidget()
        RPICentralMonthWidget()
        RPICentralMonthAndTodayWidget()
    }
}
