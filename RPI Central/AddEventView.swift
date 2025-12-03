//
//  AddEventView.swift
//  RPI Central
//
//  Created by Neil Shrestha on 12/2/25.
//
import SwiftUI

struct AddEventView: View {
    @EnvironmentObject var viewModel: CalendarViewModel
    
    let date: Date
    @Binding var isPresented: Bool
    
    @State private var title: String = ""
    @State private var location: String = ""
    @State private var startTime: Date
    @State private var endTime: Date
    
    init(date: Date, isPresented: Binding<Bool>) {
        self.date = date
        self._isPresented = isPresented
        
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        let defaultEnd = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: date) ?? date
        
        _startTime = State(initialValue: defaultStart)
        _endTime = State(initialValue: defaultEnd)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Class info")) {
                    TextField("Title (e.g. FOCS)", text: $title)
                    TextField("Location (e.g. DCC 308)", text: $location)
                }
                
                Section(header: Text("Time")) {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                }
            }
            .navigationTitle("Add Class")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        
                        viewModel.addEvent(
                            title: title,
                            location: location,
                            date: date,
                            startTime: startTime,
                            endTime: endTime
                        )
                        isPresented = false
                    }
                }
            }
        }
    }
}
