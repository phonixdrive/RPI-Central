//
//  ClassEvent.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/2/25.
//

import Foundation
import SwiftUI

struct ClassEvent: Identifiable, Hashable {
    let id: UUID
    var title: String
    var location: String
    var startDate: Date
    var endDate: Date
    var color: Color
    
    init(
        id: UUID = UUID(),
        title: String,
        location: String,
        startDate: Date,
        endDate: Date,
        color: Color = .blue
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.color = color
    }
}
