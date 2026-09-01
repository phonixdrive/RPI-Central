# Contributing to RPI Central

Thanks for helping improve RPI Central.

## Before opening an issue

- Search existing issues first.
- Include the app version, iOS version, and device or simulator model.
- For calendar or course-data problems, include the semester and course/CRN when relevant.
- Remove names, messages, tokens, Firebase files, and other private information from screenshots and logs.

## Development workflow

1. Fork or branch from the latest `main`.
2. Keep each change focused.
3. Preserve user data and existing migrations.
4. Add or update regression tests for behavior changes.
5. Run the app build and test suite before opening a pull request.

Use a descriptive commit message and explain both the visible change and any storage/schema impact in the pull request.

## Data changes

Course and academic-calendar files are bundled app resources. When changing them:

- keep semester directory names in `YYYYMM` form;
- verify JSON decoding for every supported term;
- avoid adding duplicate resource references to the Xcode project;
- document the source and retrieval date in the pull request.

## Firebase changes

Never commit credentials, private keys, exported user data, or `GoogleService-Info.plist`. Rule changes should be validated with the local Firestore emulator before deployment.

## Style

- Prefer small SwiftUI views and plain-language labels.
- Keep loading work nonblocking.
- Respect accessibility labels and full-size tap targets.
- Preserve offline/local behavior when cloud services are unavailable.
