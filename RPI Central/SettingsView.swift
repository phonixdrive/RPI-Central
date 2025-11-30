//
//  SettingsView.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/2/25.
//
import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("General")) {
                    Toggle("Dark Mode (placeholder)", isOn: .constant(false))
                    Toggle("Show weekend in calendar (placeholder)", isOn: .constant(true))
                }
                
                Section {
                    Text("More settings coming later.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
