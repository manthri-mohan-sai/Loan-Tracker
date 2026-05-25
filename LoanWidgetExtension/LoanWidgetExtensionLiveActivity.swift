//
//  LoanWidgetExtensionLiveActivity.swift
//  LoanWidgetExtension
//
//  Created by Mohan Manthri on 22/05/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct LoanWidgetExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct LoanWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoanWidgetExtensionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension LoanWidgetExtensionAttributes {
    fileprivate static var preview: LoanWidgetExtensionAttributes {
        LoanWidgetExtensionAttributes(name: "World")
    }
}

extension LoanWidgetExtensionAttributes.ContentState {
    fileprivate static var smiley: LoanWidgetExtensionAttributes.ContentState {
        LoanWidgetExtensionAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: LoanWidgetExtensionAttributes.ContentState {
         LoanWidgetExtensionAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: LoanWidgetExtensionAttributes.preview) {
   LoanWidgetExtensionLiveActivity()
} contentStates: {
    LoanWidgetExtensionAttributes.ContentState.smiley
    LoanWidgetExtensionAttributes.ContentState.starEyes
}
