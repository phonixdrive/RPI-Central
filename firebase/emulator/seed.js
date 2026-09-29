#!/usr/bin/env node
// Fills the local Firebase emulators with sample people, chats, groups,
// shared schedules, locations, and activity posts for working on the Social
// tab. It only ever talks to the emulators; see README.md in this folder.

const fs = require('fs');
const path = require('path');

process.env.FIRESTORE_EMULATOR_HOST ||= '127.0.0.1:8080';
process.env.FIREBASE_AUTH_EMULATOR_HOST ||= '127.0.0.1:9099';

// Uses the Cloud Functions' copy of firebase-admin (run `npm ci` there first).
const requireAdmin = (name) => require(require.resolve(`firebase-admin/${name}`, {
  paths: [path.join(__dirname, '..', 'functions')],
}));
const { initializeApp } = requireAdmin('app');
const { getAuth } = requireAdmin('auth');
const { FieldValue, Timestamp, getFirestore } = requireAdmin('firestore');

// Must match PROJECT_ID in the app's GoogleService-Info.plist.
const PROJECT_ID = process.env.GCLOUD_PROJECT || 'rpi-central';
// Emulator-only password shared by every seeded account.
const TEST_PASSWORD = 'emulator-only-password';
const CAMPUS_THREAD_ID = 'campusGroup_all_rpi_students';
const TERM = '202609';

const people = {
  alex: { name: 'Alex Kim', shareSchedule: true },
  maya: { name: 'Maya Patel', shareSchedule: true, location: { building: 'dcc', minutesAgo: 3 } },
  jordan: { name: 'Jordan Lee', shareSchedule: true, location: { building: 'folsom', minutesAgo: 8 } },
  chris: { name: 'Chris Nguyen', shareSchedule: true },
  ava: { name: 'Ava Brooks', location: { building: 'dcc', minutesAgo: 12 } },
  sam: { name: 'Sam Rivera', shareSchedule: true, location: { building: 'commons', minutesAgo: 95 } },
  priya: { name: 'Priya Shah' },
  ethan: { name: 'Ethan Wright' },
  lena: { name: 'Lena Park' },
  omar: { name: 'Omar Haddad' },
  zoe: { name: 'Zoe Chen' },
};
const viewer = 'alex';
const friendsOfViewer = ['maya', 'jordan', 'chris', 'ava', 'sam', 'priya'];

const uid = (key) => `test-${key}`;
const email = (key) => `${key}@example.com`;
const username = (key) => people[key].name.toLowerCase().replace(/[^a-z]/g, '');
// The app parses ISO 8601 without fractional seconds.
const iso = (date) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');
const now = new Date();
const minutes = (count) => new Date(now.getTime() + count * 60 * 1000);

function assertEmulators() {
  for (const name of ['FIRESTORE_EMULATOR_HOST', 'FIREBASE_AUTH_EMULATOR_HOST']) {
    const host = process.env[name] || '';
    if (!/^(127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(host)) {
      throw new Error(`${name} must point at a local emulator, got "${host}"`);
    }
  }
}

async function clearEmulators() {
  const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST;
  const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  await fetch(`http://${firestoreHost}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`, { method: 'DELETE' });
  await fetch(`http://${authHost}/emulator/v1/projects/${PROJECT_ID}/accounts`, { method: 'DELETE' });
}

function campusBuildings() {
  const file = path.join(__dirname, '..', '..', 'RPI Central', 'Location', 'CampusBuildings.json');
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  return Object.fromEntries(json.buildings.map((building) => [building.id, building]));
}

function directMessageThreadID(a, b) {
  return 'directMessage_' + [uid(a), uid(b)].sort().map((id) => `${Buffer.byteLength(id)}-${id}`).join('_');
}

function scheduleItem(id, title, location, startOffset, endOffset) {
  return {
    id,
    title,
    location,
    startDate: iso(minutes(startOffset)),
    endDate: iso(minutes(endOffset)),
    isAllDay: false,
    kind: 'classMeeting',
    badge: '',
  };
}

async function main() {
  assertEmulators();
  initializeApp({ projectId: PROJECT_ID });
  const db = getFirestore();
  const auth = getAuth();
  await clearEmulators();

  const buildings = campusBuildings();
  const batch = db.batch();
  const set = (docPath, data) => batch.set(db.doc(docPath), data);

  // Accounts and public profiles.
  for (const [key, person] of Object.entries(people)) {
    await auth.createUser({ uid: uid(key), email: email(key), password: TEST_PASSWORD, displayName: person.name });
    set(`users/${uid(key)}`, {
      displayName: person.name,
      displayNameLower: person.name.toLowerCase(),
      username: username(key),
      usernameLower: username(key),
      isGuest: false,
      shareSchedule: !!person.shareSchedule,
      shareLocation: !!person.location,
      createdAt: iso(minutes(-60 * 24 * 30)),
      lastScheduleAt: person.shareSchedule ? iso(minutes(-60)) : '',
      sharedCourseKeys: [],
      sharedSectionKeys: [],
      sharedScheduleItemCount: person.shareSchedule ? 3 : 0,
    });
  }

  // Friendships and pending requests.
  for (const friend of friendsOfViewer) {
    const members = [uid(viewer), uid(friend)].sort();
    set(`friendships/${members.join('_')}`, { members, createdAt: iso(minutes(-60 * 24 * 7)), acceptedRequestID: `seed-${friend}` });
  }
  set('friendRequests/seed-ethan', { fromUserID: uid('ethan'), toUserID: uid(viewer), status: 'pending', createdAt: iso(minutes(-90)), respondedAt: '' });
  set('friendRequests/seed-lena', { fromUserID: uid(viewer), toUserID: uid('lena'), status: 'pending', createdAt: iso(minutes(-60 * 5)), respondedAt: '' });

  // Friend groups.
  set('friendGroups/study-squad', { ownerID: uid(viewer), name: 'Study Squad', createdAt: iso(minutes(-60 * 24 * 3)), memberIDs: [uid('jordan'), uid('maya')] });
  set('friendGroups/climbing', { ownerID: uid('chris'), name: 'Climbing Crew', createdAt: iso(minutes(-60 * 24 * 10)), memberIDs: [uid('ava'), uid(viewer)] });

  // Chats: [threadID, title, subtitle, kind, members, messages as [sender, body, minutesAgo]].
  const chats = [
    ['manualGroup_study-squad', 'Study Squad', '3 members', 'manualGroup', ['alex', 'jordan', 'maya'], [
      ['jordan', 'Anyone at Folsom tonight?', 40],
      ['alex', 'Heading there after dinner', 30],
      ['maya', 'Saving us a table on the 3rd floor', 5],
    ]],
    ['manualGroup_climbing', 'Climbing Crew', '3 members', 'manualGroup', ['alex', 'ava', 'chris'], [
      ['chris', 'Rock gym Saturday at 2?', 60 * 26],
      ['alex', 'I\'m in', 60 * 25],
    ]],
    [directMessageThreadID('alex', 'maya'), 'Maya Patel', '@mayapatel', 'directMessage', ['alex', 'maya'], [
      ['alex', 'Did you finish the HW4 recursion problem?', 20],
      ['maya', 'Almost, want to compare after class?', 2],
    ]],
    [directMessageThreadID('alex', 'jordan'), 'Jordan Lee', '@jordanlee', 'directMessage', ['alex', 'jordan'], [
      ['jordan', 'Thanks for the notes!', 60 * 30],
      ['alex', 'Anytime', 60 * 29],
    ]],
    [CAMPUS_THREAD_ID, 'All RPI Students', 'Campus-wide chat', 'campusGroup', ['alex', 'maya', 'omar', 'zoe'], [
      ['omar', 'Is the Union open late tonight?', 25],
      ['zoe', 'Until midnight on weekdays', 18],
    ]],
  ];
  for (const [threadID, title, subtitle, sourceKind, members, messages] of chats) {
    const last = messages[messages.length - 1];
    const lastID = `m${messages.length}`;
    set(`groupChats/${threadID}`, {
      title,
      subtitle,
      sourceKind,
      memberIDs: members.map(uid).sort(),
      isCampusWide: sourceKind === 'campusGroup',
      createdAt: iso(minutes(-60 * 24 * 14)),
      updatedAt: iso(minutes(-last[2])),
      lastMessageID: lastID,
      lastSenderID: uid(last[0]),
    });
    messages.forEach(([sender, body, minutesAgo], index) => {
      set(`groupChats/${threadID}/messages/m${index + 1}`, {
        threadID,
        userID: uid(sender),
        username: username(sender),
        displayName: people[sender].name,
        body,
        createdAt: iso(minutes(-minutesAgo)),
      });
    });
  }

  // Class groups (only visible in the app for courses the phone is enrolled in).
  const course = (subject, number, title, members) => set(`courseCommunities/course_${subject}_${number}`, {
    kind: 'course',
    courseSubject: subject,
    courseNumber: number,
    courseTitle: title,
    semesterCode: TERM,
    sectionLabel: '',
    memberIDs: members.map(uid).sort(),
    createdAt: iso(minutes(-60 * 24 * 20)),
    updatedAt: iso(minutes(-60)),
  });
  course('CSCI', '1200', 'Data Structures', ['alex', 'maya', 'omar', 'zoe']);
  course('MATH', '1020', 'Calculus II', ['alex', 'chris', 'zoe']);

  // Friends' schedules as the viewer sees them.
  const schedules = {
    maya: [
      scheduleItem('maya-1', 'Data Structures', 'Darrin Communications Center 308', -25, 35),
      scheduleItem('maya-2', 'Intro to Cognitive Science', 'Sage Laboratory 3303', 120, 170),
    ],
    jordan: [scheduleItem('jordan-1', 'Physics II', 'Jonsson Engineering Center 3117', 90, 140)],
    chris: [scheduleItem('chris-1', 'Calculus II', 'Jonsson Engineering Center 3117', -15, 35)],
    sam: [scheduleItem('sam-1', 'Principles of Economics', 'Sage Laboratory 4101', 200, 250)],
  };
  for (const [key, items] of Object.entries(schedules)) {
    const snapshot = {
      ownerID: uid(key),
      viewerID: uid(viewer),
      semesterCode: TERM,
      generatedAt: iso(minutes(-60)),
      coverageStart: iso(minutes(-60 * 24 * 7)),
      coverageEnd: iso(minutes(60 * 24 * 80)),
      schemaVersion: 2,
      items,
    };
    set(`sharedSchedules/${uid(key)}`, { ownerID: uid(key), semesterCode: TERM, updatedAt: iso(minutes(-60)), schemaVersion: 2 });
    set(`sharedSchedules/${uid(key)}/friendViews/${uid(viewer)}`, snapshot);
  }

  // Live locations shared with the viewer.
  for (const [key, person] of Object.entries(people)) {
    if (!person.location) continue;
    const building = buildings[person.location.building];
    set(`locationShares/${uid(key)}`, {
      ownerID: uid(key),
      viewerIDs: [uid(viewer)],
      latitude: building.center[0],
      longitude: building.center[1],
      accuracy: 12,
      precision: 'precise',
      placeID: building.id,
      placeName: building.name,
      placeKind: 'inside',
      isOnCampus: true,
      updatedAt: iso(minutes(-person.location.minutesAgo)),
      updatedAtServer: FieldValue.serverTimestamp(),
      expiresAt: iso(minutes(120)),
      expiresAtTimestamp: Timestamp.fromDate(minutes(120)),
      source: 'seed',
    });
  }

  // Class ratings (averaged on each class page).
  const ratings = [
    ['maya', 5, 4, 8, ['greatLectures', 'toughExams']],
    ['jordan', 4, 4, 10, ['toughExams', 'heavyWorkload']],
    ['chris', 4, 3, 6, ['helpfulTAs', 'clearGrading']],
    ['ava', 5, 4, 7, ['greatLectures', 'helpfulTAs']],
    ['sam', 3, 5, 12, ['heavyWorkload', 'toughExams']],
  ];
  for (const [key, overall, difficulty, hoursPerWeek, tags] of ratings) {
    set(`courseRatings/CSCI-1200/ratings/${uid(key)}`, { overall, difficulty, hoursPerWeek, tags, semesterCode: TERM, updatedAt: iso(minutes(-60 * 24)) });
  }

  await batch.commit();

  // Activity posts live on their owners' profiles; responses on the responders'.
  const post = (key, id, title, location, details, createdAgo, startOffset) => ({
    id,
    ownerID: uid(key),
    ownerUsername: username(key),
    ownerDisplayName: people[key].name,
    title,
    location,
    details,
    createdAt: iso(minutes(-createdAgo)),
    startsAt: iso(minutes(startOffset)),
    endedAt: '',
    visibility: 'friends',
    visibleGroupIDs: [],
  });
  const response = (key, postID, status, minutesAgo) => ({
    postID,
    userID: uid(key),
    username: username(key),
    displayName: people[key].name,
    status,
    respondedAt: iso(minutes(-minutesAgo)),
  });
  await db.doc(`users/${uid('maya')}`).update({
    feedPosts: [post('maya', 'post-maya-study', 'Data Structures study session', 'Folsom Library, 3rd floor', 'Going over HW4 before Thursday.', 30, -10)],
    lastFeedPostAt: iso(minutes(-30)),
  });
  await db.doc(`users/${uid('jordan')}`).update({
    feedPosts: [post('jordan', 'post-jordan-hoops', 'Pickup basketball', "'87 Gym", '', 50, 120)],
    lastFeedPostAt: iso(minutes(-50)),
    feedResponses: [response('jordan', 'post-maya-study', 'here', 6)],
  });
  await db.doc(`users/${uid('sam')}`).update({
    feedResponses: [response('sam', 'post-maya-study', 'going', 12), response('sam', 'post-jordan-hoops', 'going', 20)],
  });

  console.log(`Seeded ${Object.keys(people).length} users into project ${PROJECT_ID}.`);
  console.log(`Sign in as ${email(viewer)} (password in this file).`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
