# Security policy

## Reporting a vulnerability

Please do not open a public issue for authentication bypasses, exposed credentials, private-data access, Firestore-rule weaknesses, or notification-relay vulnerabilities.

Report sensitive findings privately through GitHub’s security-advisory feature for this repository. Include reproduction steps, affected versions, and the smallest safe proof of concept.

## Supported version

Security fixes target the latest `main` branch and current development build.

## Secrets

The repository must not contain Firebase service-account files, APNs keys, access tokens, production environment variables, or `GoogleService-Info.plist`. If a secret is exposed, revoke it immediately before removing it from source history.
