# RPI Central

RPI Central is an unofficial iOS campus companion for Rensselaer Polytechnic Institute students. It combines course planning, a term-aware calendar, assignments, campus utilities, and friend features in one SwiftUI app.

> RPI Central is an independent student project. It is not affiliated with or endorsed by Rensselaer Polytechnic Institute.

[Project website](https://phonixdrive.github.io/RPI-Central/) · [Report a bug](https://github.com/phonixdrive/RPI-Central/issues/new?template=bug_report.yml) · [Request a feature](https://github.com/phonixdrive/RPI-Central/issues/new?template=feature_request.yml)

## Highlights

- Fall 2026 course catalog and official academic-calendar dates
- Day, three-day, week, and month calendar layouts
- Current-class refreshes when bundled section details change
- Home dashboard with persistent ordering and 1×1, 1×2, and 2×2 cards
- “Next” view combining the next class, room, and related deadline
- Course search, prerequisite handling, GPA tools, and registration bypass flow
- Assignment reminders and local notifications
- Dining hours, meal swipes, Flex Dollars planning, shuttle tracking, and a study timer
- Friend schedules, current calendar activity, direct messages, group chats, and class communities
- Google/Outlook calendar import through EventKit
- Manual phone/web sync plus weekly recovery backups
- Home-screen calendar widgets

## Requirements

- macOS with Xcode 26 or newer
- iOS 18.6 deployment target
- A Firebase Apple-app configuration for sign-in, social features, cloud sync, and push tokens

The calendar, course catalog, GPA, and local utility features can still be developed without a Firebase configuration. Social and cloud features require it.

## Getting started

1. Clone the repository.
2. Open `RPI Central.xcodeproj` in Xcode.
3. Select the `RPI Central` scheme and an iOS 18.6+ simulator or device.
4. If you need Firebase features, add your own `GoogleService-Info.plist` to the `RPI Central` app target. This file is intentionally ignored by Git.
5. Build and run.

```sh
git clone https://github.com/phonixdrive/RPI-Central.git
cd RPI-Central
open "RPI Central.xcodeproj"
```

## Project structure

| Path | Purpose |
| --- | --- |
| `RPI Central/` | SwiftUI application source |
| `RPI Central/Widgets/` | WidgetKit extension source |
| `Data/semester_data/` | Bundled term catalogs and prerequisite data |
| `Data/academic_calendar_26.json` | 2026–2027 academic calendar data |
| `firebase/` | Firestore rules and notification function support |
| `Tools/scrapers/` | Course-data collection and transformation tools |
| `RPI CentralTests/` | Regression tests for terms, calendar data, widgets, chat, and refresh behavior |
| `docs/` | GitHub Pages website |

## Configuration

### Firebase

See [firebase/README.md](firebase/README.md) for Authentication, Firestore, Cloud Messaging, and rules setup. Never commit Firebase service-account credentials or `GoogleService-Info.plist`.

Deploy updated Firestore rules with:

```sh
firebase deploy --only firestore:rules
```

### Course and calendar data

Term folders use RPI-style semester codes such as:

- `202601` — Spring 2026
- `202605` — Summer 2026
- `202609` — Fall 2026

Each supported term is validated by the test suite to ensure bundled course data can be decoded.

## Testing

Choose an installed simulator and run:

```sh
xcodebuild \
  -project "RPI Central.xcodeproj" \
  -scheme "RPI Central" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The regression suite covers semester selection, academic-calendar boundaries, Thanksgiving break expansion, course-detail refreshes, full-section bypass behavior, unread-message state, calendar display persistence, and Home dashboard persistence.

## Privacy and safety

- Calendar access is requested only for calendar import/sync features.
- Social data is stored in Firebase and protected by the repository’s Firestore rules.
- Shared schedules are opt-in and friend-gated.
- Live person-location sharing is not implemented.
- Secrets and private Firebase configuration must remain outside source control.

Read the project’s [privacy overview](https://phonixdrive.github.io/RPI-Central/privacy.html) and [security policy](SECURITY.md).

## Contributing

Bug reports and focused pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.

## Status

RPI Central is under active student development. Interfaces, data formats, and cloud schemas may change between development builds.
