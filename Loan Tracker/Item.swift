//
//  Item.swift
//  Loan Tracker
//
//  Created by Mohan Manthri on 22/05/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
