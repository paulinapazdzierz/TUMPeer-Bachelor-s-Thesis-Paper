#import "/utils/todo.typ": TODO
#import "/utils/diagram.typ": diagram

#let placeholder(caption-text, short: none) = diagram(
  rect(width: 100%, height: 6cm, fill: luma(230), stroke: 0.5pt)[
    #align(center + horizon)[
      #text(style: "italic", fill: luma(100))[Placeholder -- diagram to be inserted]
    ]
  ],
  caption: caption-text,
  short-caption: if short != none { short } else { caption-text },
)

= Implementation

This chapter describes the implementation of the TUMPeer backend, which constitutes the main contribution of this thesis. Each section covers one feature area: the design decisions made, the non-trivial logic implemented, and how the code maps to the requirements and architecture described in the preceding chapters. Code snippets appear where the logic is not self-evident from prose.

The following sections describe each component of the peer review lifecycle in the order it executes, from authentication through grade release.

== Authentication and Email Verification

The authentication subsystem covers user registration, login, session management, and password reset. All authentication endpoints reside under `/api/auth/` and accept requests without a session.

=== Registration Flow

Registration follows a two-step email verification flow, driven by the constraint that only users with a TUM-issued email address may access the platform. In the first step, the client sends a `POST /api/auth/send-verification-code` request with the user's TUM email, password, first name, last name, and matriculation identifier. The `AuthenticationService` first checks that the email ends with `@tum.de` or `@mytum.de`; any other domain produces a 400 response. The service then verifies that neither the email address nor the matriculation identifier belongs to an existing account. A four-rule password policy applies server-side: the password must contain at least eight characters, one uppercase letter, one digit, and one special character.

When all validations pass, the service generates a six-digit code via `SecureRandom` and stores the code together with the full signup payload in a `ConcurrentHashMap` inside `VerificationCodeStorage`, keyed by the lowercased email address. The entry expires after 15 minutes. The `EmailService` then dispatches the code to the user's address via Spring Mail, which connects to a Gmail SMTP account. The user account does not yet exist in the database at this point.

In the second step, the client submits the code via `POST /api/auth/verify-code`. The service looks up the pending entry, confirms the code matches and has not expired, and creates the `AppUser` record in the database. BCrypt at strength 10 hashes the password before storage. The service removes the pending entry from memory immediately to prevent reuse, and the `AuthController` establishes an HTTP session so the user is logged in upon registration without a separate login step.

The registration flow also handles users whom an instructor adds to a course before those users have registered. In this case, a partial `AppUser` record with no password hash already exists; `verifyCodeAndCreateAccount` detects it and completes the account in place rather than creating a duplicate. The mechanism is described in full in @sec-course-member-management.

#diagram(
  image("/figures/activity_diagram_paperr.drawio.png", width: 100%),
  caption: "Activity diagram of the TUMPeer registration flow. The diagram shows three swimlanes: User, Backend, and Gmail SMTP. It covers the two-step process from form submission through verification code dispatch to account creation and session establishment.",
  short-caption: "TUMPeer registration flow activity diagram",
) <fig-registration-flow>

=== Login and Session Management

Login is handled by `POST /api/auth/login`, which accepts an email, a password, and an optional `rememberMe` flag. The `AuthenticationService` validates the TUM email format, retrieves the user record, and verifies the password against the BCrypt hash stored in the database. On success, the `AuthController` creates an `HttpSession` through the servlet container and stores the Spring Security context in it. The session timeout is 30 minutes for standard logins and 30 days when the client sets `rememberMe` to true. Spring Security's concurrent session control caps each user at five active sessions; when a sixth session starts, the system invalidates the oldest one. The servlet container returns the session identifier to the client as an HTTP-only `JSESSIONID` cookie, which the browser attaches to all subsequent requests.

The `GET /api/auth/me` endpoint lets the frontend verify session validity and retrieve the current user's data, including per-course roles, on every page load. A session expiry causes the endpoint to return HTTP 401, which the frontend route guards use to redirect the user to the login page.

=== Password Reset

The password reset flow consists of three steps. The client first calls `POST /api/auth/forgot-password` with an email address. The endpoint always returns HTTP 200 regardless of whether the email belongs to a registered account, preventing email enumeration. When an account exists, the service generates a UUID reset token, stores it in memory with a 15-minute expiry, and dispatches a reset link by email. The client then optionally calls `GET /api/auth/validate-reset-token` to confirm token validity before presenting the reset form. Finally, `POST /api/auth/reset-password` accepts the token and a new password, validates both, hashes the new password with BCrypt, and consumes the token so it cannot be reused.

== Course and Assignment Management

=== Course and Member Management <sec-course-member-management>

Instructors create courses by calling `POST /api/courses` with a name and a semester identifier. The semester field follows a validated format: winter semesters use `WiSe` followed by the academic year (e.g., `WiSe2025/26`) and summer semesters use `SoSe` followed by the year (e.g., `SoSe2026`). An `isArchived` flag marks whether the course remains active; archived courses do not appear in the default listing; clients retrieve them via the `?includeArchived=true` query parameter.

The `CourseMember` join entity models course membership; its primary key is the composite of `courseId` and `userId`. Each member holds a role -- either STUDENT or INSTRUCTOR -- within that specific course, which allows the same user to hold different roles in different courses simultaneously. How the backend derives the effective role and interface view from these per-course memberships, and when it recalculates them, is described in the Role Management section below.

Instructors add members individually via `POST /api/courses/{courseId}/members`. Before resolving the user, the endpoint validates that the course exists and that all required profile fields are present -- first name, last name, email address, and matriculation identifier. The email must match a TUM domain (`@tum.de` or `@mytum.de`) and the matriculation identifier must follow the expected format (e.g., `go42tum`); the endpoint rejects requests that fail either check with HTTP 400. The endpoint then handles two cases depending on whether the invited person already has an account:

- *Existing account:* the backend locates the `AppUser` by email or TUM identifier, creates a `CourseMember` record for that user, and recalculates their global role.
- *No account yet:* the backend creates a stub `AppUser` record with the supplied name, email, and matriculation identifier but no password hash, then creates the `CourseMember` record against that stub.

In both cases the endpoint checks whether a `CourseMember` record already exists for the resolved user in the given course and returns HTTP 400 if it does, preventing duplicate enrolment. When the invited user later registers with the same email address, the authentication service detects the passwordless stub and completes the account in place: it sets the password hash on the existing record without changing the user identifier. The `CourseMember` records already reference that identifier, so the user sees all pre-assigned course memberships immediately upon first login.

For bulk enrolment, `POST /api/courses/{courseId}/members/import` accepts a CSV file with columns `first_name`, `last_name`, `tum_id`, and `tum_email`. The backend detects the delimiter (comma or semicolon), applies the same two-case logic to each row, and returns a per-row success and error report. @fig-csv-format illustrates the accepted file formats.

Each row undergoes server-side validation against several constraints: required fields (first name, last name, email) must not be empty; the email must match a TUM domain (`@tum.de` or `@mytum.de`); the TUM ID, if provided, must follow the expected format (consonant-vowel-2digits-consonant-vowel-consonant, e.g., `ge57yef`); and within the same import, email addresses and TUM IDs must not be duplicated. Rows that pass all validations are imported; rows that fail include a specific error reason in the report.


#diagram(
  image("/figures/Screenshot 2026-04-12 171315.png", width: 100%),
  caption: "CSV import validation. The backend accepts both comma-separated and semicolon-separated formats and validates each row. Valid rows receive a green checkmark; invalid rows display a red mark with the specific error reason (invalid TUM ID format, invalid email format, etc.). The endpoint returns a per-row success and error report.",
  short-caption: "CSV import validation results",
) <fig-csv-format>

#diagram(
  image("/figures/csv import.png", width: 100%),
  caption: "Bulk member import interface displaying validation results. The backend returns per-row success and error information which the interface presents clearly to the instructor: a summary line showing the number of successful imports and errors, followed by a detailed list of validation errors with line numbers and specific reasons, and a table of successfully imported participants with their assigned roles.",
  short-caption: "Bulk member import interface with validation results",
) <fig-csv-import-ui>

Beyond adding members, the backend exposes endpoints for updating and removing memberships. `PUT /api/courses/{courseId}/members/{userId}` and `PATCH /api/courses/{courseId}/members/{userId}` both update the role a user holds in a course; neither triggers an automatic recalculation of the user's `globalRole`. `DELETE /api/courses/{courseId}/members/{userId}` removes the membership record and immediately recalculates the user's `globalRole`. How `globalRole` is derived from per-course memberships and why this matters for user permissions is explained in the Role Management section below.

=== Role Management

As described in the Architecture chapter, TUMPeer derives each user's effective interface from the roles they hold across all their course memberships. Three cases arise: STUDENT memberships only yields the student view; INSTRUCTOR memberships only yields the instructor view; holding both yields a toggle between the two views. Figure~@fig-switch-button shows the toggle as it appears in the student dashboard for a user who also holds an instructor role.

#diagram(
  image("/figures/switch_button_updated.png", width: 100%),
  caption: "Student dashboard for a user who also holds an instructor role in another course. The \"Switch to Instructor\" button in the navigation bar lets the user toggle to the instructor view; the backend determines which button to expose based on the roles returned by GET /api/auth/me.",
  short-caption: "Role toggle button in the student dashboard",
) <fig-switch-button>

The backend implements this through two fields returned by `GET /api/auth/me`. The first is `globalRole` on `AppUser`, a single enum value (`STUDENT` or `INSTRUCTOR`) that records the highest role the user holds across all course memberships. `UserService.recalculateGlobalRole()` keeps this field in sync: it queries all `CourseMember` records for the user, sets `globalRole` to INSTRUCTOR if any membership carries that role, and sets it to STUDENT otherwise. Storing `globalRole` as a denormalised column avoids recomputing it from course memberships on every request; the trade-off is that it must be explicitly recalculated whenever course memberships change. The second field is `courseRoles`, a deduplicated list of all distinct role values the user holds across their course memberships. The endpoint collects every `CourseMember` record for the user, extracts the role from each, removes duplicates, and returns the result (for example, `["STUDENT", "INSTRUCTOR"]` for a user who holds both roles). The frontend reads `courseRoles` to decide which views to render: a list containing only `"STUDENT"` shows the student view; only `"INSTRUCTOR"` shows the instructor view; both values enable a toggle between the two views. Role update operations via `PUT` and `PATCH` do not trigger recalculation automatically; an instructor who promotes or demotes a member must call `POST /api/users/{userId}/recalculate-role` explicitly to synchronise the `globalRole` field.

=== Assignment and Rubric Configuration

Instructors create assignments via `POST /api/assignments` with the course identifier, title, description, submission and review windows, file constraints, and an initial set of rubric questions. The backend creates the `Assignment` and its associated `Rubric` record in a single request, then inserts each provided `RubricQuestion` in the declared sort order. A unique constraint on `rubric.assignment_id` enforces the one-rubric-per-assignment invariant at the database level.

Each `RubricQuestion` carries a `description` (the question text shown to reviewers), a `maxPoints` value defining the maximum score a reviewer may award for that criterion, and a `sortOrder` controlling the display sequence. The `maxPoints` value serves a dual purpose: it defines the scoring scale and caps the question's contribution to the review total. Instructors may update deadline fields individually via PATCH endpoints for each timestamp. When the submission deadline extends from a past time to a future time, the backend reverts all `NO_SUBMISSION` submissions to `PENDING` and all `UNDER_REVIEW` submissions to `SUBMITTED`, reopening the assignment for late submission. The same reversal logic applies to the review deadline: an extension reverts `NO REVIEW SUBMITTED` review assignments to `READY FOR REVIEW` or to `DRAFT REVIEW` when the student previously saved draft content.

== Submission Handling

=== Upload and Storage

Students submit work via `POST /api/submissions` as a `multipart/form-data` request containing the assignment identifier, the student identifier, and the file. The controller applies a sequence of validation checks before writing any data: the assignment must exist; the current time must fall within the submission window, and the backend returns HTTP 403 for requests outside it; the student must hold a STUDENT role in the course; the file size must not exceed the assignment's `maxFileSizeBytes`; and the file extension must be `pdf`.

When all checks pass, the backend generates a UUID, prefixes it to the original filename as `{uuid}_{originalName}`, and writes the file to `/app/uploads` inside the Docker container, which the `uploads_data` volume backs persistently. The UUID prefix prevents filename collisions between concurrent uploads. The `Submission` record stores the file path rather than the file bytes. Clients retrieve files via `GET /api/submissions/{id}/download` (with `Content-Disposition: attachment`) or view them inline via `GET /api/submissions/{id}/view` (with `Content-Disposition: inline`). When a student deletes a submission via `DELETE /api/submissions/{submissionId}`, the backend removes the physical file from disk, clears the file metadata fields, sets `deletedAt`, and reverts the submission status to `PENDING`.

== Review Allocation Algorithm

The allocation requirements — no self-review, equal workload distribution, deterministic results — are specified in FR6. The algorithm that satisfies them runs in `ReviewService.allocateReviewsForAssignment()`. It takes the list of submissions -- and therefore the list of reviewer candidates, one per submission -- and that configured number of reviews per submission.

The algorithm first sorts submissions by their database identifier to establish a deterministic, stable processing order. It records the position of each reviewer in this sorted list as their base position (0-indexed). For each submission, the algorithm selects all N reviewers before updating any review counts. This means that when k reviewers must be chosen simultaneously and several candidates are tied on load count, the tie-breaker determines all k picks at once. Without a careful tie-breaker, students with a low identifier would win every tie in every round, ending up assigned more reviews than others purely due to their identifier. The rotating position tie-breaker fixes this by shifting the starting point of the candidate order by one slot for each successive submission, so the student who wins a tie rotates around the cohort rather than always being the same person. The rotating position is computed as `(basePosition[c] − subIdx mod n + n) mod n`, where `n` is the total number of reviewers and `subIdx` is the index of the current submission.

The following pseudocode summarises the core loop:

#block(fill: luma(240), inset: (x: 1em, y: 0.8em), radius: 3pt, width: 100%)[
  #raw(block: true,
"sort submissions by submissionId
basePosition[reviewer_i] ← i   for each reviewer in sorted order
n ← number of reviewers
k ← required reviews per submission
for each submission S at index subIdx:
    candidates  ←  all reviewers where reviewer ≠ S.student
    sort candidates by (reviewCount[c] ASC,
                        (basePosition[c] − subIdx mod n + n) mod n ASC)
    assign candidates[0 .. k-1] as reviewers for S
    increment reviewCount for each assigned reviewer")
]

Sorting by rotating position as a tie-breaker preserves load-balance as the primary criterion while distributing reviewer pairings more evenly, making re-allocation produce identical results for identical inputs. Each `ReviewAssignment` record receives status `"READY FOR REVIEW"` and a `reviewerLabel` integer (1, 2, 3, ...) that all student-facing endpoints expose in place of the actual reviewer identity, enforcing the double-blind anonymity constraint described in @sec-access-control. When the number of available reviewers falls below the required reviews per submission, the method throws an `IllegalArgumentException` and creates no assignments. Allocation runs either manually via `POST /api/assignments/{assignmentId}/review-assignments` or automatically by the scheduler after the submission deadline, provided no review assignments exist yet for the assignment.

The algorithm runs in $O(n^2 log n)$ time, where $n$ is the number of submitting students. The dominant cost is the candidate sort executed once per submission: sorting $n - 1$ candidates takes $O(n log n)$, repeated $n$ times yields $O(n^2 log n)$ overall. At typical course enrolment of 20 to 300 students, allocation completes in single-digit milliseconds and executes exactly once per assignment, so the quadratic factor carries no practical cost. A priority-queue-based variant could reduce the overall complexity to $O(n log n)$ by maintaining a sorted structure of reviewer loads across iterations, but at substantially higher implementation complexity for negligible benefit at this scale. Random allocation was rejected because it is non-deterministic and cannot guarantee equal load distribution; bipartite matching would guarantee an optimal assignment but imposes unnecessary complexity given that the equal-load constraint is already met by the greedy load-sort approach.

== Status Management

The peer review lifecycle is divided into five phases, each bounded by one of the assignment's four timestamps: submission start, submission end, review start, and review end. Each phase defines which actions the instructor and students may perform, which status values are active, and what transitions occur at the phase boundary. The diagram below shows all phases on a shared timeline, together with the submission statuses visible to students, the review statuses visible to reviewers, and the assignment period visible to the instructor.

#diagram(
  image("/figures/assignment_status_table_tum 2 (1).png", width: 100%),
  caption: "Status implementation diagram for TUMPeer. A timeline shows five phases divided by four assignment milestones: Assignment Created, Submission Start Date, Submission End Date, Review Start Date, and Review End Date. The top track displays student submission statuses (not visible, PENDING, SUBMITTED, NO_SUBMISSION, UNDER_REVIEW, GRADED) and their transitions. The middle track shows review statuses (READY FOR REVIEW, DRAFT REVIEW, REVIEW SUBMITTED, NO REVIEW SUBMITTED). The bottom track displays the instructor's assignment period label for each phase (Scheduled, Submission period, Review period, Grades Released). Annotations indicate when the scheduler runs to change statuses.",
  short-caption: "TUMPeer status implementation diagram",
) <fig-status-diagram>

=== Phase 1: Assignment Created to Submission Start

After the instructor creates an assignment, the assignment period is `"Scheduled"`. The assignment is not yet visible on the student dashboard. The instructor may still modify the assignment configuration, adjust deadlines, and edit the rubric. No submission or review activity is possible. Phase 1 ends when the `submissionStart` timestamp passes; this is a time-based gate enforced at the endpoint level, not a scheduler action.

=== Phase 2: Submission Start to Submission End

Once `submissionStart` passes, the assignment period advances to `"Submission Period"` and the assignment becomes visible to enrolled students. Each student receives a submission record with status `PENDING`, indicating that a file upload is expected. The student may upload a PDF file via `POST /api/submissions`, which transitions the status to `SUBMITTED`. The student may delete the submission at any time during this phase, which reverts the status to `PENDING` and removes the physical file from disk. Resubmission is permitted as long as the submission window remains open. The submission endpoint enforces the deadline strictly: requests made before `submissionStart` or after `submissionEnd` receive HTTP 403. The instructor may monitor submission progress via the assignment overview endpoint and may continue to adjust the assignment configuration and deadlines during this phase. Review activity is not yet possible.

Phase 2 ends when `submissionEnd` passes. The scheduler detects this on its next 60-second cycle and applies the boundary transitions described in Phase 3.

=== Phase 3: Submission End to Review Start

At the `submissionEnd` boundary, the scheduler transitions every `SUBMITTED` submission to `UNDER_REVIEW` and every `PENDING` submission to `NO_SUBMISSION`. Submissions in `UNDER_REVIEW` are locked: the upload and delete endpoints return HTTP 403 for any further student requests. `NO_SUBMISSION` records remain unchanged for the rest of the lifecycle and contribute zero points to the student's course statistics. The scheduler also checks whether `ReviewAssignment` records exist for the assignment; when none do, it calls the allocation algorithm automatically, creating one `ReviewAssignment` per reviewer-submission pair with status `"READY FOR REVIEW"`.

During Phase 3, the instructor sees the assignment period as `"Review Period"`. The instructor may view which students submitted and which did not, may enter instructor grades per submission, and may still adjust the number of reviewers per submission and re-trigger the allocation algorithm. Adjusting reviewer count and re-running allocation remains possible until `reviewStart`, because that is the point at which the review form becomes accessible to students. Students see their submission status as `UNDER_REVIEW` and see their assigned review tasks with status `"READY FOR REVIEW"`, but the review form is not yet accessible.

Phase 3 ends when `reviewStart` passes.

=== Phase 4: Review Start to Review End

Once `reviewStart` passes, the review form becomes accessible to students. A reviewer may open the form and save a draft via `POST /api/reviews/assignments/{reviewAssignmentId}/draft`, which transitions the review status to `"DRAFT REVIEW"`. The reviewer may save multiple drafts, each overwriting the previous content. Submitting the review via `POST /api/reviews/assignments/{reviewAssignmentId}/submit` transitions the status to `"REVIEW SUBMITTED"` and locks the review permanently: any subsequent draft or submit request returns HTTP 403. Both endpoints enforce the review window: requests made outside the `reviewStart`--`reviewEnd` interval receive HTTP 403. The instructor may monitor review progress per student and may continue to enter or update instructor grades for any submission during this phase.

Phase 4 ends when `reviewEnd` passes. The scheduler detects this on its next 60-second cycle and applies the boundary transitions described in Phase 5.

=== Phase 5: Review End to Grade Release

Phase 5 formally begins when `reviewEnd` passes, but no change is immediately visible to students at that moment. The scheduler transitions every `ReviewAssignment` with status `"READY FOR REVIEW"` to `"NO REVIEW SUBMITTED"`. For assignments with status `"DRAFT REVIEW"`, it calls `clearDraftReviewAnswers()`, which clears the saved scores and comment text and also sets the status to `"NO REVIEW SUBMITTED"`. Only reviews with status `"REVIEW SUBMITTED"` contribute to grade calculation; incomplete and overdue reviews are excluded. The assignment period remains `"Review Period"` on the instructor dashboard.

The first change visible to students occurs only when the instructor explicitly triggers grade release via `POST /api/assignments/{assignmentId}/release-grades`. The endpoint computes the final score for every submission using the peer review scores and the instructor score, applies the ±20pp outlier detection rule described in the following section, transitions every `UNDER_REVIEW` submission to `GRADED`, and sets `assignment.resultsReleaseAt` to the current time. The assignment period advances to `"Grades Released"`. Students with status `GRADED` can now view their final score and the reviews they received. `NO_SUBMISSION` records are not advanced and remain excluded from the visible results. 
=== Scheduler

The design rationale for the polling scheduler — why it was chosen over an event-driven approach and what the 60-second interval implies — is covered in @sec-control-flow. The implementation detail worth noting here is that all transitions are idempotent: the scheduler checks each assignment's current status before acting, so records already in the target status are silently skipped. Repeated executions therefore produce no side effects. The scheduler reads the current time in the Europe/Berlin timezone on every execution to ensure consistent behaviour across daylight saving time transitions.

== Grading System

Every submission is evaluated using the same rubric by the assigned peer reviewers and, optionally, by the instructor. Each evaluation produces a percentage score computed as `(totalPointsAwarded / totalPointsMax) × 100`. The backend tracks which `ReviewAssignment` records belong to the instructor by checking course membership, and keeps the two sets of scores separate for outlier detection. The instructor may submit their rubric evaluation at any point after the review period starts; peer reviewers work within the review window as described in the previous section.

=== Peer Grade Preview

Before triggering bulk grade release, the instructor can call `POST /api/submissions/{submissionId}/calculate-grade` to view an intermediate peer-only score for a single submission. This endpoint considers only completed peer reviews and does not incorporate the instructor score or apply the outlier detection rule. It serves purely as an inspection tool; the definitive final grade is determined only when the instructor triggers bulk grade release.

=== Bulk Grade Release with Outlier Detection

The endpoint `POST /api/assignments/{assignmentId}/release-grades` processes all submissions in a single transactional operation and computes the definitive final grade for each. For each submission, the service collects all submitted peer reviews into two sets. `allPeerScores` contains the percentage score from every `ReviewAssignment` with status `REVIEW SUBMITTED`, including the instructor's when they graded. `studentPeerScores` is the subset restricted to non-instructor reviewers and is used exclusively for the outlier check. The instructor grades a submission through the same rubric form as student reviewers; this single action creates a `ReviewAssignment` for the instructor and simultaneously stores the computed percentage to `SubmissionGrade.instructorScore`, which the outlier check uses as its reference value. Four cases determine the final score.

- *No peer reviews and no instructor score:* the final score is zero (`"no_scores"`).
- *No instructor score:* the final score is the arithmetic mean of all submitted peer review scores in `allPeerScores` (`"peer_average"`).
- *No peer reviews submitted:* the instructor score becomes the final score directly (`"instructor_only"`).
- *Both peer reviews and instructor score present:* the service checks whether any score in `studentPeerScores` deviates from the instructor score by more than 20 percentage points. If an outlier is found, the instructor score overrides the peer scores entirely (`"instructor_score_outlier"`), on the assumption that a large peer-instructor discrepancy signals an unreliable peer evaluation. Otherwise, the final score is the arithmetic mean of all scores in `allPeerScores`, which includes the instructor's score (`"average_all"`).

The ±20pp threshold uses a strict inequality, is checked per individual score, and applies only to student reviewers, so an instructor's own peer review submission does not trigger the outlier rule against their own direct grade. The threshold was set as a project requirement by the supervising instructor. It was chosen to be slightly more lenient than the typical peer-instructor deviation observed in a prior rubric-based peer review study at TUM, which reported a root mean square error of 14.87 percentage points @berrezueta2025coders; a 20pp boundary therefore tolerates borderline disagreements during the initial deployment of the platform while still catching clear outliers. The threshold is a configurable starting point — a statistical replacement such as a z-score or interquartile-range-based rule is identified as future work.

#figure(
  image("/figures/Screenshot 2026-04-10 224552.png", width: 100%),
  caption: "Submission Reviews table in the instructor view, showing the final score, peer average, instructor score, and grading calculation per student.",
) <fig-submission-reviews>

The `calculation` field in `SubmissionGrade` records which case applied, making the grading decision auditable after the fact. After computing all final scores, the endpoint transitions every non-`NO_SUBMISSION` submission to `GRADED` and sets `assignment.resultsReleaseAt` to the current time, advancing the assignment period to `"Grades Released"` and making results visible to students.

== Score Statistics

Once the instructor triggers grade release, the score statistics dashboard becomes available immediately to both instructors and students. The `StatisticsService` exposes four endpoints under `/api/statistics/` and applies a single visibility condition to all of them: an assignment's results are included only when `resultsReleaseAt` is set and its value is in the past. Since `release-grades` sets this field, no additional instructor action is required to unlock the statistics.

The instructor statistics view provides two levels of aggregation. The course-level endpoint (`GET /api/statistics/courses/{courseId}/achievement`) computes the overall achievement percentage across all `GRADED` submissions in all released assignments in the course. The per-assignment endpoint (`GET /api/statistics/courses/{courseId}/assignments`) breaks this down further, returning the average final score percentage across all students for each released assignment individually.

The student statistics view mirrors this structure but scopes the data to the individual student. The course-level endpoint (`GET /api/statistics/students/{studentId}/courses/{courseId}/achievement`) computes the student's own overall achievement: `GRADED` submissions contribute their actual final score and `NO_SUBMISSION` records contribute zero, so a student who missed an assignment sees their overall average penalised accordingly. The per-assignment endpoint (`GET /api/statistics/students/{studentId}/courses/{courseId}/assignments`) returns the student's individual final score for each released assignment.
