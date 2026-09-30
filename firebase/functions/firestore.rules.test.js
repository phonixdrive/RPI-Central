const fs = require("node:fs");
const {after, before, beforeEach, test} = require("node:test");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const {
  arrayRemove,
  arrayUnion,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  Timestamp,
  updateDoc,
  where,
} = require("firebase/firestore");

const projectId = "demo-rpi-central";
let testEnvironment;

function profile(overrides = {}) {
  return {
    displayName: "Student",
    displayNameLower: "student",
    username: "student",
    usernameLower: "student",
    isGuest: false,
    shareSchedule: false,
    shareLocation: false,
    createdAt: "2026-09-04T12:00:00Z",
    lastScheduleAt: "",
    sharedCourseKeys: [],
    sharedSectionKeys: [],
    ...overrides,
  };
}

before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: fs.readFileSync(`${__dirname}/../firestore.rules`, "utf8"),
    },
  });
});

beforeEach(async () => {
  await testEnvironment.clearFirestore();
});

after(async () => {
  await testEnvironment.cleanup();
});

test("public profiles cannot publish private email addresses", async () => {
  const student = testEnvironment.authenticatedContext("student").firestore();

  await assertFails(setDoc(doc(student, "users/student"), profile({email: "student@example.com"})));
  await assertSucceeds(setDoc(doc(student, "users/student"), profile()));
});

test("users cannot edit moderation state but can remove legacy email", async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "users/student"),
      profile({email: "legacy@example.com", socialBanned: true})
    );
  });

  const student = testEnvironment.authenticatedContext("student").firestore();
  await assertFails(updateDoc(doc(student, "users/student"), {socialBanned: false}));
  await assertSucceeds(updateDoc(doc(student, "users/student"), {email: deleteField()}));
  await assertSucceeds(updateDoc(doc(student, "users/student"), {
    displayName: "Updated Student",
    displayNameLower: "updated student",
  }));
});

test("editable names do not grant moderator access", async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const store = context.firestore();
    await setDoc(doc(store, "users/impostor"), profile({
      displayName: "phonixdrive",
      displayNameLower: "phonixdrive",
      username: "neilshrestha20061",
      usernameLower: "neilshrestha20061",
    }));
    await setDoc(doc(store, "groupChats/test-chat"), {
      memberIDs: ["impostor", "author"],
      sourceKind: "directMessage",
      isCampusWide: false,
    });
    await setDoc(doc(store, "groupChats/test-chat/messages/message-1"), {
      userID: "author",
      body: "hello",
    });
  });

  const impostor = testEnvironment.authenticatedContext("impostor").firestore();
  await assertFails(deleteDoc(doc(impostor, "groupChats/test-chat/messages/message-1")));

  const moderator = testEnvironment.authenticatedContext("moderator", {moderator: true}).firestore();
  await assertSucceeds(deleteDoc(doc(moderator, "groupChats/test-chat/messages/message-1")));
});

test("friendships require a recipient-accepted request", async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const store = context.firestore();
    await setDoc(doc(store, "users/alice"), profile({username: "alice", usernameLower: "alice"}));
    await setDoc(doc(store, "users/bob"), profile({username: "bob", usernameLower: "bob"}));
  });

  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const friendship = {
    members: ["alice", "bob"],
    createdAt: "2026-09-04T12:00:00Z",
    acceptedRequestID: "request-1",
  };

  await assertFails(setDoc(doc(alice, "friendships/alice_bob"), friendship));
  await assertSucceeds(setDoc(doc(alice, "friendRequests/request-1"), {
    fromUserID: "alice",
    toUserID: "bob",
    status: "pending",
    createdAt: "2026-09-04T12:00:00Z",
    respondedAt: "",
  }));
  await assertFails(updateDoc(doc(alice, "friendRequests/request-1"), {
    status: "accepted",
    respondedAt: "2026-09-04T12:01:00Z",
  }));
  await assertSucceeds(updateDoc(doc(bob, "friendRequests/request-1"), {
    status: "accepted",
    respondedAt: "2026-09-04T12:01:00Z",
  }));
  await assertSucceeds(setDoc(doc(bob, "friendships/alice_bob"), friendship));
  await assertSucceeds(getDoc(doc(alice, "friendships/alice_bob")));
});

test("only a user can initiate deletion of their own account", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();

  await assertFails(setDoc(doc(alice, "accountDeletionRequests/bob"), {
    requesterID: "alice",
    requestedAt: "2026-09-04T12:00:00Z",
  }));
  await assertSucceeds(setDoc(doc(alice, "accountDeletionRequests/alice"), {
    requesterID: "alice",
    requestedAt: "2026-09-04T12:00:00Z",
  }));
});

async function seed(documents) {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const store = context.firestore();
    for (const [path, data] of Object.entries(documents)) {
      await setDoc(doc(store, path), data);
    }
  });
}

function locationShare(overrides = {}) {
  return {
    ownerID: "alice",
    viewerIDs: ["bob"],
    latitude: 42.7293,
    longitude: -73.6793,
    accuracy: 12,
    precision: "precise",
    placeID: "dcc",
    placeName: "Darrin Communications Center",
    placeKind: "inside",
    isOnCampus: true,
    updatedAt: "2026-09-28T12:00:00Z",
    expiresAt: "",
    expiresAtTimestamp: null,
    source: "foreground",
    ...overrides,
  };
}

test("private app state is readable only by its owner", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();

  await assertSucceeds(setDoc(doc(alice, "users/alice/private/appState"), {webAppState: {grades: {}}}));
  await assertSucceeds(getDoc(doc(alice, "users/alice/private/appState")));
  await assertFails(getDoc(doc(bob, "users/alice/private/appState")));
  await assertFails(setDoc(doc(bob, "users/alice/private/appState"), {webAppState: {}}));
});

test("shared locations are visible only to chosen viewers", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const mallory = testEnvironment.authenticatedContext("mallory").firestore();

  await assertSucceeds(setDoc(doc(alice, "locationShares/alice"), locationShare()));
  await assertSucceeds(getDoc(doc(bob, "locationShares/alice")));
  await assertFails(getDoc(doc(mallory, "locationShares/alice")));

  // Friends list their visible locations with a query the rules can prove.
  await assertSucceeds(getDocs(query(collection(bob, "locationShares"), where("viewerIDs", "array-contains", "bob"))));
  await assertFails(getDocs(collection(mallory, "locationShares")));
});

test("only the owner can publish a well-formed shared location", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const mallory = testEnvironment.authenticatedContext("mallory").firestore();

  await assertFails(setDoc(doc(mallory, "locationShares/alice"), locationShare()));
  await assertFails(setDoc(doc(alice, "locationShares/alice"), locationShare({latitude: 123})));
  await assertFails(setDoc(doc(alice, "locationShares/alice"), locationShare({viewerIDs: ["alice"]})));
  await assertFails(setDoc(doc(alice, "locationShares/alice"), locationShare({trackingNote: "extra"})));
});

test("a viewer can remove only themselves from a shared location", async () => {
  await seed({"locationShares/alice": locationShare({viewerIDs: ["bob", "carol"]})});
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const mallory = testEnvironment.authenticatedContext("mallory").firestore();

  await assertFails(updateDoc(doc(bob, "locationShares/alice"), {viewerIDs: arrayUnion("mallory")}));
  await assertFails(updateDoc(doc(bob, "locationShares/alice"), {viewerIDs: arrayRemove("carol")}));
  await assertFails(updateDoc(doc(mallory, "locationShares/alice"), {viewerIDs: arrayRemove("bob")}));
  await assertSucceeds(updateDoc(doc(bob, "locationShares/alice"), {viewerIDs: arrayRemove("bob")}));
});

test("nobody can join a private chat by rewriting it", async () => {
  await seed({
    "users/alice": profile({username: "alice"}),
    "users/bob": profile({username: "bob"}),
    "friendships/alice_bob": {members: ["alice", "bob"], createdAt: "2026-09-01T00:00:00Z", acceptedRequestID: "r1"},
    "groupChats/directMessage_alice_bob": {
      memberIDs: ["alice", "bob"],
      sourceKind: "directMessage",
      isCampusWide: false,
    },
    "groupChats/directMessage_alice_bob/messages/m1": {userID: "alice", body: "hi"},
  });
  const mallory = testEnvironment.authenticatedContext("mallory").firestore();
  const alice = testEnvironment.authenticatedContext("alice").firestore();

  await assertFails(updateDoc(doc(mallory, "groupChats/directMessage_alice_bob"), {
    memberIDs: ["alice", "bob", "mallory"],
    sourceKind: "manualGroup",
  }));
  await assertFails(updateDoc(doc(mallory, "groupChats/directMessage_alice_bob"), {
    sourceKind: "campusGroup",
    isCampusWide: true,
  }));
  await assertFails(getDoc(doc(mallory, "groupChats/directMessage_alice_bob/messages/m1")));

  await assertSucceeds(updateDoc(doc(alice, "groupChats/directMessage_alice_bob"), {
    updatedAt: "2026-09-28T12:00:00Z",
    lastSenderID: "alice",
  }));
});

test("chats flagged public by older clients stay private", async () => {
  await seed({
    "groupChats/manualGroup_g1": {memberIDs: ["alice"], sourceKind: "campusGroup", isCampusWide: true},
    "groupChats/manualGroup_g1/messages/m1": {userID: "alice", body: "secret"},
    "groupChats/campusGroup_all_rpi_students": {memberIDs: ["alice"], sourceKind: "campusGroup", isCampusWide: true},
  });
  const mallory = testEnvironment.authenticatedContext("mallory").firestore();

  await assertFails(getDoc(doc(mallory, "groupChats/manualGroup_g1")));
  await assertFails(getDoc(doc(mallory, "groupChats/manualGroup_g1/messages/m1")));
  await assertSucceeds(getDoc(doc(mallory, "groupChats/campusGroup_all_rpi_students")));
});

test("group chat members must belong to the friend group", async () => {
  await seed({
    "friendGroups/g1": {ownerID: "alice", name: "Study", createdAt: "2026-09-01", memberIDs: ["bob"]},
  });
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const mallory = testEnvironment.authenticatedContext("mallory").firestore();
  const chat = {memberIDs: ["alice", "bob"], sourceKind: "manualGroup", isCampusWide: false, title: "Study"};

  await assertSucceeds(setDoc(doc(bob, "groupChats/manualGroup_g1"), chat));
  await assertFails(setDoc(doc(mallory, "groupChats/manualGroup_g1"), {...chat, memberIDs: ["alice", "bob", "mallory"]}));
});

test("friend group members can leave but cannot change membership", async () => {
  await seed({
    "friendGroups/g1": {ownerID: "alice", name: "Study", createdAt: "2026-09-01", memberIDs: ["bob", "carol"]},
  });
  const bob = testEnvironment.authenticatedContext("bob").firestore();

  await assertFails(updateDoc(doc(bob, "friendGroups/g1"), {memberIDs: ["bob", "carol", "mallory"]}));
  await assertFails(updateDoc(doc(bob, "friendGroups/g1"), {memberIDs: ["bob"]}));
  await assertSucceeds(updateDoc(doc(bob, "friendGroups/g1"), {memberIDs: ["carol"]}));
});

test("students can join or leave a class group but not remove others", async () => {
  await seed({
    "courseCommunities/course_CSCI_1200": {
      kind: "course",
      courseSubject: "CSCI",
      courseNumber: "1200",
      courseTitle: "Data Structures",
      memberIDs: ["alice", "bob"],
      createdAt: "2026-09-01",
      updatedAt: "2026-09-01",
    },
  });
  const carol = testEnvironment.authenticatedContext("carol").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();

  await assertSucceeds(updateDoc(doc(carol, "courseCommunities/course_CSCI_1200"), {memberIDs: arrayUnion("carol")}));
  await assertFails(updateDoc(doc(bob, "courseCommunities/course_CSCI_1200"), {memberIDs: ["bob"]}));
  await assertFails(setDoc(doc(carol, "courseCommunities/course_MATH_1010"), {
    kind: "course",
    memberIDs: ["carol", "alice"],
  }));
});

test("poll voters can change only their own vote", async () => {
  await seed({
    "groupChats/manualGroup_g1": {memberIDs: ["alice", "bob"], sourceKind: "manualGroup", isCampusWide: false},
    "groupChats/manualGroup_g1/polls/p1": {
      createdByUserID: "alice",
      question: "Pizza?",
      votesByUserID: {alice: "yes"},
      isClosed: false,
    },
  });
  const bob = testEnvironment.authenticatedContext("bob").firestore();

  await assertSucceeds(updateDoc(doc(bob, "groupChats/manualGroup_g1/polls/p1"), {"votesByUserID.bob": "no"}));
  await assertFails(updateDoc(doc(bob, "groupChats/manualGroup_g1/polls/p1"), {"votesByUserID.alice": "no"}));
  await assertFails(updateDoc(doc(bob, "groupChats/manualGroup_g1/polls/p1"), {isClosed: true}));
});

test("students rate a course once, within the allowed ranges", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const rating = {overall: 4, difficulty: 3, hoursPerWeek: 6, tags: ["greatLectures"], semesterCode: "202609"};

  await assertSucceeds(setDoc(doc(alice, "courseRatings/CSCI-1200/ratings/alice"), rating));
  await assertSucceeds(getDoc(doc(bob, "courseRatings/CSCI-1200/ratings/alice")));
  await assertFails(setDoc(doc(bob, "courseRatings/CSCI-1200/ratings/alice"), rating));
  await assertFails(setDoc(doc(bob, "courseRatings/CSCI-1200/ratings/bob"), {...rating, overall: 9}));
  await assertFails(setDoc(doc(bob, "courseRatings/CSCI-1200/ratings/bob"), {...rating, comment: "hi"}));
  await assertFails(getDoc(doc(testEnvironment.unauthenticatedContext().firestore(), "courseRatings/CSCI-1200/ratings/alice")));
});

test("anyone can report, but only moderators read reports", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const report = {
    reporterID: "alice",
    reportedUserID: "bob",
    kind: "message",
    contextID: "directMessage_x/m1",
    excerpt: "rude",
    reason: "harassment",
  };

  await assertSucceeds(setDoc(doc(alice, "reports/r1"), report));
  await assertFails(setDoc(doc(alice, "reports/r2"), {...report, reporterID: "bob"}));
  await assertFails(setDoc(doc(alice, "reports/r3"), {...report, reportedUserID: "alice"}));
  await assertFails(getDoc(doc(alice, "reports/r1")));
});

test("a user's block list is private", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();

  await assertSucceeds(setDoc(doc(alice, "users/alice/private/blocks"), {userIDs: ["bob"]}));
  await assertFails(getDoc(doc(bob, "users/alice/private/blocks")));
});

test("server spaces are invite-only and only the owner sets the status", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const carol = testEnvironment.authenticatedContext("carol").firestore();
  const space = {
    name: "Minecraft SMP",
    address: "play.example.com",
    ownerID: "alice",
    ownerName: "Alice",
    memberIDs: ["alice", "bob"],
    serverOnline: false,
  };

  await assertSucceeds(setDoc(doc(alice, "serverSpaces/s1"), space));
  await assertFails(setDoc(doc(carol, "serverSpaces/s2"), space));
  await assertSucceeds(getDoc(doc(bob, "serverSpaces/s1")));
  await assertFails(getDoc(doc(carol, "serverSpaces/s1")));

  // Only the owner turns it on or invites people.
  await assertFails(updateDoc(doc(bob, "serverSpaces/s1"), {serverOnline: true}));
  await assertFails(updateDoc(doc(bob, "serverSpaces/s1"), {memberIDs: arrayUnion("carol")}));
  await assertSucceeds(updateDoc(doc(alice, "serverSpaces/s1"), {serverOnline: true, statusUpdatedByName: "Alice"}));

  // Members can ask for it to be started, as themselves.
  await assertSucceeds(updateDoc(doc(bob, "serverSpaces/s1"), {requestedByID: "bob", requestedByName: "Bob"}));
  await assertFails(updateDoc(doc(bob, "serverSpaces/s1"), {requestedByID: "alice", requestedByName: "Alice"}));
});

test("server presence is your own and lasts at most a day", async () => {
  const alice = testEnvironment.authenticatedContext("alice").firestore();
  const bob = testEnvironment.authenticatedContext("bob").firestore();
  const carol = testEnvironment.authenticatedContext("carol").firestore();
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), "serverSpaces/s1"), {
      name: "SMP", address: "", ownerID: "alice", ownerName: "Alice", memberIDs: ["alice", "bob"], serverOnline: true,
    });
  });
  const now = Date.now();
  const inHours = (h) => Timestamp.fromMillis(now + h * 3600 * 1000);

  await assertSucceeds(setDoc(doc(bob, "serverSpaces/s1/presence/bob"), {displayName: "Bob", since: inHours(0), expiresAt: inHours(24)}));
  await assertFails(setDoc(doc(bob, "serverSpaces/s1/presence/bob"), {displayName: "Bob", since: inHours(0), expiresAt: inHours(48)}));
  await assertFails(setDoc(doc(bob, "serverSpaces/s1/presence/alice"), {displayName: "Alice", since: inHours(0), expiresAt: inHours(1)}));
  await assertFails(setDoc(doc(carol, "serverSpaces/s1/presence/carol"), {displayName: "Carol", since: inHours(0), expiresAt: inHours(1)}));
  await assertFails(getDoc(doc(carol, "serverSpaces/s1/presence/bob")));
  // The owner can mark someone offline.
  await assertSucceeds(deleteDoc(doc(alice, "serverSpaces/s1/presence/bob")));

  // Members can leave, but can't remove others.
  await assertFails(updateDoc(doc(bob, "serverSpaces/s1"), {memberIDs: ["bob"]}));
  await assertSucceeds(updateDoc(doc(bob, "serverSpaces/s1"), {memberIDs: arrayRemove("bob")}));
});
