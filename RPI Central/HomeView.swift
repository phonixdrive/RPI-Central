//
//  HomeView.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/2/25.
//
import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("RPI Central")
                    .font(.largeTitle.bold())
                
                Text("Quick glance at today’s schedule will live here later.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
