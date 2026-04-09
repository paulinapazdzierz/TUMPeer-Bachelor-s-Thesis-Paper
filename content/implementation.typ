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

The backend organises functionality around the peer review lifecycle. An instructor registers, creates a course with an assignment and a rubric, and enrolls students. Once the submission window opens, students upload their work; once the submission deadline passes, the scheduler transitions submitted work to the review phase and allocates peer reviewers automatically. During the review period, each assigned reviewer evaluates the submission using the rubric. After the review deadline, the scheduler marks incomplete reviews as overdue. The instructor optionally provides a direct grade per submission, then triggers grade release, which applies the outlier-detection rule, computes the final score for every submission, and makes results visible. The following sections describe each component of this lifecycle in the order it executes.

== Authentication and Email Verification

The authentication subsystem covers user registration, login, session management, and password reset. All authentication endpoints reside under `/api/auth/` and accept requests without a session.

=== Registration Flow

Registration follows a two-step email verification flow, driven by the constraint that only users with a TUM-issued email address may access the platform. In the first step, the client sends a `POST /api/auth/send-verification-code` request with the user's TUM email, password, first name, last name, and matriculation identifier. The `AuthenticationService` first checks that the email ends with `@tum.de` or `@mytum.de`; any other domain produces a 400 response. The service then verifies that neither the email address nor the matriculation identifier belongs to an existing account. A four-rule password policy applies server-side: the password must contain at least eight characters, one uppercase letter, one digit, and one special character.

When all validations pass, the service generates a six-digit code via `SecureRandom` and stores the code together with the full signup payload in a `ConcurrentHashMap` inside `VerificationCodeStorage`, keyed by the lowercased email address. The entry expires after 15 minutes. The `EmailService` then dispatches the code to the user's address via Spring Mail, which connects to a Gmail SMTP account. The user account does not yet exist in the database at this point.

In the second step, the client submits the code via `POST /api/auth/verify-code`. The service looks up the pending entry, confirms the code matches and has not expired, and creates the `AppUser` record in the database. BCrypt at strength 10 hashes the password before storage. The service removes the pending entry from memory immediately to prevent reuse, and the `AuthController` establishes an HTTP session so the user is logged in upon registration without a separate login step.

The registration flow also handles users whom an instructor adds to a course before those users have registered. In this case, a partial `AppUser` record with no password hash already exists; `verifyCodeAndCreateAccount` detects it and completes the account in place rather than creating a duplicate. The mechanism is described in full in @sec-course-member-management.

#placeholder(
  "Activity diagram of the TUMPeer registration flow. The diagram shows three swimlanes: User, Backend, and Gmail SMTP. It covers the two-step process from form submission through verification code dispatch to account creation and session establishment.",
  short: "Registration activity diagram",
)

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

#placeholder(
  [Accepted CSV formats for bulk member import. The file must contain the columns `first_name`, `last_name`, `tum_id`, and `tum_email`. Both comma-separated and semicolon-separated variants are supported; the backend detects the delimiter automatically.],
  short: "Accepted CSV formats for bulk member import",
) <fig-csv-format>

Beyond adding members, the backend exposes endpoints for updating and removing memberships. `PUT /api/courses/{courseId}/members/{userId}` and `PATCH /api/courses/{courseId}/members/{userId}` both update the role a user holds in a course; neither triggers an automatic recalculation of the user's `globalRole`. `DELETE /api/courses/{courseId}/members/{userId}` removes the membership record and immediately recalculates the user's `globalRole`. How `globalRole` is derived from per-course memberships and why this matters for user permissions is explained in the Role Management section below.

=== Role Management

As described in the Architecture chapter, TUMPeer derives each user's effective interface from the roles they hold across all their course memberships. Three cases arise: STUDENT memberships only yields the student view; INSTRUCTOR memberships only yields the instructor view; holding both yields a toggle between the two views.

The backend implements this through two fields returned by `GET /api/auth/me`. The first is `globalRole` on `AppUser`, a single enum value (`STUDENT` or `INSTRUCTOR`) that records the highest role the user holds across all course memberships. `UserService.recalculateGlobalRole()` keeps this field in sync: it queries all `CourseMember` records for the user, sets `globalRole` to INSTRUCTOR if any membership carries that role, and sets it to STUDENT otherwise. Storing `globalRole` as a denormalised column avoids recomputing it from course memberships on every request; the trade-off is that it must be explicitly recalculated whenever course memberships change. The second field is `courseRoles`, a deduplicated list of all distinct role values the user holds across their course memberships. The endpoint collects every `CourseMember` record for the user, extracts the role from each, removes duplicates, and returns the result (for example, `["STUDENT", "INSTRUCTOR"]` for a user who holds both roles). The frontend reads `courseRoles` to decide which views to render: a list containing only `"STUDENT"` shows the student view; only `"INSTRUCTOR"` shows the instructor view; both values enable a toggle between the two views. Role update operations via `PUT` and `PATCH` do not trigger recalculation automatically; an instructor who promotes or demotes a member must call `POST /api/users/{userId}/recalculate-role` explicitly to synchronise the `globalRole` field.

=== Assignment and Rubric Configuration

Instructors create assignments via `POST /api/assignments` with the course identifier, title, description, submission and review windows, file constraints, and an initial set of rubric questions. The backend creates the `Assignment` and its associated `Rubric` record in a single request, then inserts each provided `RubricQuestion` in the declared sort order. A unique constraint on `rubric.assignment_id` enforces the one-rubric-per-assignment invariant at the database level.

Each `RubricQuestion` carries a `description` (the question text shown to reviewers), a `maxPoints` value defining the maximum score a reviewer may award for that criterion, and a `sortOrder` controlling the display sequence. The `maxPoints` value serves a dual purpose: it defines the scoring scale and caps the question's contribution to the review total. Instructors may update deadline fields individually via PATCH endpoints for each timestamp. When the submission deadline extends from a past time to a future time, the backend reverts all `NO_SUBMISSION` submissions to `PENDING` and all `UNDER_REVIEW` submissions to `SUBMITTED`, reopening the assignment for late submission. The same reversal logic applies to the review deadline: an extension reverts `NO REVIEW SUBMITTED` review assignments to `READY FOR REVIEW` or to `DRAFT REVIEW` when the student previously saved draft content.

== Submission Handling

=== Upload and Storage

Students submit work via `POST /api/submissions` as a `multipart/form-data` request containing the assignment identifier, the student identifier, and the file. The controller applies a sequence of validation checks before writing any data: the assignment must exist; the current time must fall within the submission window, and the backend returns HTTP 403 for requests outside it; the student must hold a STUDENT role in the course; the file size must not exceed the assignment's `maxFileSizeBytes`; and the file extension must be `pdf`.

When all checks pass, the backend generates a UUID, prefixes it to the original filename as `{uuid}_{originalName}`, and writes the file to `/app/uploads` inside the Docker container, which the `uploads_data` volume backs persistently. The UUID prefix prevents filename collisions between concurrent uploads. The `Submission` record stores the file path rather than the file bytes. Clients retrieve files via `GET /api/submissions/{id}/download` (with `Content-Disposition: attachment`) or view them inline via `GET /api/submissions/{id}/view` (with `Content-Disposition: inline`). When a student deletes a submission via `DELETE /api/submissions/{submissionId}`, the backend removes the physical file from disk, clears the file metadata fields, sets `deletedAt`, and reverts the submission status to `PENDING`.

== Review Allocation Algorithm

After the submission deadline passes, the backend must assign peer reviewers to submissions. Each student who submitted work becomes both a candidate reviewer and the owner of a submission that needs reviewers. The allocation must satisfy two constraints: no student may review their own submission, and the review workload must distribute as evenly as possible across all eligible reviewers.

The algorithm runs in `ReviewService.allocateReviewsForAssignment()`. It takes the list of submissions -- and therefore the list of reviewer candidates, one per submission -- and the configured number of reviews per submission (`requiredNumberOfReviewsForSubmission`). For each submission, the algorithm selects reviewers from the pool of all other students by sorting candidates first by their current review count (ascending) and then by user identifier as a stable tie-breaker. It assigns the first N candidates from the sorted list as reviewers for the current submission and increments their review counts before moving to the next submission.

```
for each submission S in submissions:
    candidates = all reviewers except S.studentId
    sort candidates by (reviewCount[c] ASC, c.userId ASC)
    assign candidates[0..N-1] as reviewers for S
    increment reviewCount for each assigned reviewer
```

Sorting by user identifier as a tie-breaker ensures the algorithm produces identical results for identical inputs, making re-allocation predictable. Each `ReviewAssignment` record receives status `"READY FOR REVIEW"` and a `reviewerLabel` integer (1, 2, 3, ...) that the frontend displays to the submission author in place of the actual reviewer name, preserving reviewer anonymity. When the number of available reviewers falls below the required reviews per submission, the method throws an `IllegalArgumentException` and creates no assignments. Allocation runs either manually via `POST /api/assignments/{assignmentId}/review-assignments` or automatically by the scheduler after the submission deadline, provided no review assignments exist yet for the assignment.

== Status Management

The peer review lifecycle is divided into five phases, each bounded by one of the assignment's four timestamps: submission start, submission end, review start, and review end. Each phase defines which actions the instructor and students may perform, which status values are active, and what transitions occur at the phase boundary. The diagram below shows all phases on a shared timeline, together with the submission statuses visible to students, the review statuses visible to reviewers, and the assignment period visible to the instructor.

#placeholder(
  "Status implementation diagram for TUMPeer. A shared horizontal timeline is divided into five phases by four milestones: Submission Start Date, Submission End Date, Review Start Date, and Review End Date. The top track shows student submission statuses and their transitions. The middle track shows student review statuses and their transitions. The bottom track shows the instructor assignment period label at each phase. Arrows indicate whether a transition is triggered by a student action, an instructor action, or the background scheduler.",
  short: "TUMPeer status implementation diagram",
)

=== Phase 1: Assignment Created to Submission Start

After the instructor creates an assignment, the assignment period is `"Scheduled"`. The assignment is not yet visible on the student dashboard. The instructor may still modify the assignment configuration, adjust deadlines, and edit the rubric. No submission or review activity is possible. Phase 1 ends when the `submissionStart` timestamp passes; this is a time-based gate enforced at the endpoint level, not a scheduler action.

=== Phase 2: Submission Start to Submission End

Once `submissionStart` passes, the assignment period advances to `"Submission Period"` and the assignment becomes visible to enrolled students. Each student receives a submission record with status `PENDING`, indicating that a file upload is expected. The student may upload a PDF file via `POST /api/submissions`, which transitions the status to `SUBMITTED`. The student may delete the submission at any time during this phase, which reverts the status to `PENDING` and removes the physical file from disk. Resubmission is permitted as long as the submission window remains open. The submission endpoint enforces the deadline strictly: requests made before `submissionStart` or after `submissionEnd` receive HTTP 403. The instructor may monitor submission progress via the assignment overview endpoint and may continue to adjust the assignment configuration and deadlines during this phase. Review activity is not yet possible.

Phase 2 ends when `submissionEnd` passes. The scheduler detects this on its next 60-second cycle and applies the boundary transitions described in Phase 3.

=== Phase 3: Submission End to Review Start

At the `submissionEnd` boundary, the scheduler transitions every `SUBMITTED` submission to `UNDER_REVIEW` and every `PENDING` submission to `NO_SUBMISSION`. Submissions in `UNDER_REVIEW` are locked: the upload and delete endpoints return HTTP 403 for any further student requests. `NO_SUBMISSION` records remain unchanged for the rest of the lifecycle and contribute zero points to the student's course statistics. The scheduler also checks whether `ReviewAssignment` records exist for the assignment; when none do, it calls the allocation algorithm automatically, creating one `ReviewAssignment` per reviewer-submission pair with status `"READY FOR REVIEW"`.

During Phase 3, the instructor sees the assignment period as `"Review Period"`. The instructor may view which students submitted and which did not, may enter instructor grades per submission, and may still adjust the number of reviewers per submission and re-trigger the allocation algorithm. Adjusting reviewer count and re-running allocation remains possible until `reviewStart`, because that is the point at which the review form becomes accessible to students. Students see their submission status as `UNDER_REVIEW` and see their assigned review tasks with status `"READY FOR REVIEW"`, but the review form is not yet accessible.

Phase 3 ends when `reviewStart` passes. The diagram below summarises all submission status transitions across Phases 2 and 3, showing which trigger — student action or scheduler — drives each transition.

#placeholder(
  "Submission status state diagram. Shows all possible submission statuses (PENDING, SUBMITTED, UNDER_REVIEW, NO_SUBMISSION) and the transitions between them. PENDING transitions to SUBMITTED on student file upload and back to PENDING on student deletion. At the submission deadline, the scheduler transitions SUBMITTED to UNDER_REVIEW and PENDING to NO_SUBMISSION.",
  short: "Submission status state diagram",
)

=== Phase 4: Review Start to Review End

Once `reviewStart` passes, the review form becomes accessible to students. A reviewer may open the form and save a draft via `POST /api/reviews/assignments/{reviewAssignmentId}/draft`, which transitions the review status to `"DRAFT REVIEW"`. The reviewer may save multiple drafts, each overwriting the previous content. Submitting the review via `POST /api/reviews/assignments/{reviewAssignmentId}/submit` transitions the status to `"REVIEW SUBMITTED"` and locks the review permanently: any subsequent draft or submit request returns HTTP 403. Both endpoints enforce the review window: requests made outside the `reviewStart`--`reviewEnd` interval receive HTTP 403. The instructor may monitor review progress per student and may continue to enter or update instructor grades for any submission during this phase.

Phase 4 ends when `reviewEnd` passes. The scheduler detects this on its next 60-second cycle and applies the boundary transitions described in Phase 5.

=== Phase 5: Review End to Grade Release

Phase 5 formally begins when `reviewEnd` passes, but no change is immediately visible to students at that moment. The scheduler transitions every `ReviewAssignment` with status `"READY FOR REVIEW"` to `"NO REVIEW SUBMITTED"`. For assignments with status `"DRAFT REVIEW"`, it calls `clearDraftReviewAnswers()`, which clears the saved scores and comment text and also sets the status to `"NO REVIEW SUBMITTED"`. Only reviews with status `"REVIEW SUBMITTED"` contribute to grade calculation; incomplete and overdue reviews are excluded. The assignment period remains `"Review Period"` on the instructor dashboard.

The first change visible to students occurs only when the instructor explicitly triggers grade release via `POST /api/assignments/{assignmentId}/release-grades`. The endpoint computes the final score for every submission using the peer review scores and the instructor score, applies the ±20pp outlier detection rule described in the following section, transitions every `UNDER_REVIEW` submission to `GRADED`, and sets `assignment.resultsReleaseAt` to the current time. The assignment period advances to `"Grades Released"`. Students with status `GRADED` can now view their final score and the reviews they received. `NO_SUBMISSION` records are not advanced and remain excluded from the visible results. The diagram below summarises all review status transitions across Phases 4 and 5.

#placeholder(
  "Review status state diagram. Shows all possible review statuses (READY FOR REVIEW, DRAFT REVIEW, REVIEW SUBMITTED, NO REVIEW SUBMITTED) and the transitions between them. READY FOR REVIEW transitions to DRAFT REVIEW when the reviewer saves a draft, and from DRAFT REVIEW the reviewer may save further drafts or submit, transitioning to REVIEW SUBMITTED. REVIEW SUBMITTED is a terminal state. At the review deadline, the scheduler transitions both READY FOR REVIEW and DRAFT REVIEW to NO REVIEW SUBMITTED.",
  short: "Review status state diagram",
)

=== Scheduler

All time-based transitions are driven by `SubmissionStatusScheduler`, annotated with `@Scheduled(fixedRate = 60000)`, which Spring executes every 60 seconds independently of any client activity. On each execution the scheduler loads all assignments, reads the current time in the Europe/Berlin timezone, and evaluates the deadline conditions for each assignment. All transitions are idempotent: records already in the target status are skipped, so repeated executions produce no side effects.

The design uses a polling scheduler rather than an event-driven approach because it requires no message broker, tolerates application restarts without losing pending transitions, and keeps all time-based logic in a single auditable component. The 60-second interval means a status transition completes within at most one minute of a deadline passing, which is an acceptable latency for an academic workflow.

== Grading System

The grading system offers two independently invocable operations: per-submission peer grade calculation and bulk grade release with outlier detection.

=== Peer Grade Calculation

The endpoint `POST /api/submissions/{submissionId}/calculate-grade` computes the final score for a single submission from its completed peer reviews. For each `ReviewAssignment` linked to the submission, the service retrieves the associated `Review` record. Only reviews with status `"REVIEW SUBMITTED"` and non-null point totals contribute to the calculation. Each qualifying review yields a percentage score: `(totalPointsAwarded / totalPointsMax) × 100`. The final score is the arithmetic mean of all contributing percentages, rounded to two decimal places. When no completed reviews exist, the final score is zero. The service stores the result in the `SubmissionGrade` record and sets `assignment.resultsReleaseAt` to the current time, making the grade visible in the statistics endpoints.

=== Bulk Grade Release with Outlier Detection

The endpoint `POST /api/assignments/{assignmentId}/release-grades` processes all submissions in an assignment within a single transactional operation. For each submission, the service collects peer review percentages -- excluding any review the instructor submitted -- and the instructor score from `submission_grade.instructor_score` if one exists. Four branches determine the final score. When neither score type is available, the final score is zero. When only peer scores exist, the final score is the peer average. When only the instructor score exists, it becomes the final score directly. When both are present, the service checks whether any peer score deviates by more than 20 percentage points from the instructor score; if so, the instructor score overrides the peer average entirely; otherwise the final score is the average of the instructor score and all peer scores.

The `calculation` field in `SubmissionGrade` records which branch applied (`"no_scores"`, `"peer_average"`, `"instructor_only"`, `"instructor_score_outlier"`, or `"average_all"`), making the grading decision auditable after the fact. After computing final scores, the endpoint marks every non-`NO_SUBMISSION` submission as `GRADED` and sets `assignment.resultsReleaseAt` to the current time. The ±20pp threshold uses a strict inequality: the absolute difference must exceed 20 percentage points for the outlier rule to activate. The threshold captures meaningful disagreement between a peer and the instructor while tolerating the normal variation inherent in subjective rubric-based assessment. When the outlier rule applies, the instructor score serves as the authoritative final grade, reflecting the assumption that significant peer-instructor discrepancy signals an unreliable peer evaluation.
