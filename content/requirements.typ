#import "/utils/todo.typ": TODO

= Requirements

This chapter describes what the TUMPeer backend must accomplish, independently of any specific implementation choice. The peer review workflow the platform supports and the institutional context of TUM together drive the requirements stated here. The two actors of the system are students, who submit work and conduct peer reviews, and instructors, who configure assignments, manage course membership, and release results. All requirements stated here apply exclusively to the backend REST API and its PostgreSQL database; the React frontend and the deployment infrastructure are outside the scope of this thesis.

== Overview

The TUMPeer backend mediates the full peer review lifecycle: from course setup and user registration, through file submission and review assignment, to grade calculation and result release. The backend enforces all business rules server-side, including deadline enforcement and grading logic, and exposes these capabilities through a REST API consumed by the frontend.

A successful backend implementation must satisfy three criteria. First, each functional requirement described in this chapter must be realised and verifiable. Second, the quality attributes must hold under normal operating conditions at TUM course scale. Third, the system must correctly enforce the constraints imposed by TUM's academic context throughout the entire lifecycle.

== Proposed System

=== Functional Requirements

The following ten requirements define the capabilities the backend must provide.

*FR1 -- Register User.* The system shall allow a user to create an account by providing a TUM-formatted email address, a matriculation identifier, and a password. Registration follows a two-step email verification flow: the system sends a one-time code to the provided address, and the account is activated only after the user submits the correct code within the validity window. The system also provides a password reset flow via a time-limited token sent to the registered email address.

*FR2 -- Authenticate User.* The system shall authenticate registered users via email and password and maintain authenticated state through a session cookie (JSESSIONID). Sessions expire after 30 minutes by default or after 30 days when the user requests extended persistence. The system shall allow at most five concurrent sessions per user, invalidating the oldest session when this limit is exceeded. Logout shall invalidate the current session immediately.

*FR3 -- Manage Courses and Members.* Instructors shall create and manage courses. Each course has a name and a semester identifier. Instructors shall add and remove course members individually or through a bulk CSV import. Each member holds a role -- either STUDENT or INSTRUCTOR -- within that course. A user may hold different roles in different courses simultaneously: a teaching assistant, for example, may act as an INSTRUCTOR in one course while enrolled as a STUDENT in another. Each role grants a distinct set of permissions and a distinct interface view for that course. The system recalculates a user's global role whenever their course membership changes.

*FR4 -- Manage Assignments and Rubrics.* Instructors shall create assignments within a course. Each assignment configures a submission window, a review window, a required number of reviews per submission, allowed file types, and a maximum file size. Each assignment has exactly one rubric, consisting of one or more scored questions. Each question defines a description and a maximum point value that determines the scoring scale for reviewers.

*FR5 -- Submit Work.* Students shall upload a file as their assignment submission within the configured submission window. The system shall reject uploads outside the window with HTTP 403. Students may delete a submission before the deadline, reverting their status to pending and allowing resubmission. The backend stores each uploaded file on disk under a unique name to prevent collisions and directory traversal.

*FR6 -- Allocate Reviews.* After the submission deadline, the system shall assign peer reviewers to submissions. The allocation algorithm distributes review tasks evenly across students: each student receives the same number of submissions to review, and no student reviews their own submission. Allocation is deterministic and can be triggered either manually by an instructor or automatically by the scheduler when the submission deadline passes and no allocation exists yet.

*FR7 -- Conduct Peer Review.* Students shall complete a rubric-based review for each assigned submission. A review consists of a score per rubric question (an integer from 1 to the question's maximum points) and optional text comments. Students may save a review as a draft before final submission. A submitted review cannot be edited.

*FR8 -- Grade Submissions by Instructor.* Instructors shall optionally score a submission using the same rubric as peer reviewers. The system stores the instructor score as a percentage, which serves as the reference value for outlier detection during grade calculation.

*FR9 -- Calculate and Release Grades.* The system shall compute a final grade for each submission when the instructor triggers grade release. The calculation applies the following rule: if any peer score deviates by more than 20 percentage points from the instructor score, the instructor score becomes the final grade; otherwise, the final grade is the average of the instructor score and all peer scores. When no instructor score exists, the system averages the peer scores. The instructor shall release the computed grades and the anonymous review feedback to students via a dedicated endpoint.

*FR10 -- Automate Status Transitions.* The system shall run a scheduled task every 60 seconds to enforce deadline-driven state changes. The scheduler transitions submission statuses when the submission deadline passes (`SUBMITTED` to `UNDER_REVIEW`, `PENDING` to `NO_SUBMISSION`) and review statuses when the review deadline passes (`"READY FOR REVIEW"` and `"DRAFT REVIEW"` to `"NO REVIEW SUBMITTED"`). The scheduler also auto-allocates reviews after the submission deadline if no allocation exists.

=== Quality Attributes

*QA1 -- Security.* The system shall store passwords as BCrypt hashes and never persist them in plaintext. The system shall apply rate limiting at the HTTP level to reduce the risk of brute-force attacks: the login endpoint allows at most 20 requests per minute per IP address, and all other API endpoints allow at most 200 requests per minute per IP address. Session identifiers shall be stored in HTTP-only cookies to prevent client-side access.

*QA2 -- Reliability.* The scheduler shall execute status transitions within 60 seconds of a deadline passing under normal server load. All status transition logic shall be idempotent: running the scheduler on already-transitioned records shall have no effect.

*QA3 -- Correctness.* Grade calculations shall faithfully implement the ±20pp outlier rule. Deadline enforcement shall reject any submission or review attempt outside the configured window, regardless of client state. The review allocation algorithm shall produce a valid, even distribution for any valid input (at least two students with submitted work).

*QA4 -- Scalability.* The layered, stateless REST design shall allow the backend to handle concurrent requests from large courses without correctness failures. Individual requests shall not block on other users' operations.

*QA5 -- Maintainability.* The separation of controller, service, and repository layers shall make business logic testable independently of the HTTP and persistence layers.

=== Constraints

*C1 -- TUM Identity.* The system accepts only email addresses that match the `@tum.de` or `@mytum.de` domain. Registration attempts with any other email format are rejected.

*C2 -- Double-Blind Anonymity.* The system shall not expose reviewer identities to submission authors, nor expose submission author identities to reviewers, at any point in the workflow. Submission authors see a reviewer label (e.g., Reviewer #2) in place of the actual reviewer name; reviewers receive their assigned review task without the submission identifier or any student-identifying information.

*C3 -- Hard Deadline Enforcement.* The submission and review windows are hard boundaries. The backend returns HTTP 403 for any upload or review submission that falls outside the configured window.

*C4 -- Technology Stack.* The backend uses Java 21, Spring Boot, and PostgreSQL. Flyway manages database schema evolution through versioned migrations.

*C5 -- File Format and Size.* Uploaded submission files must be in PDF format. The file size must not exceed the per-assignment maximum, up to an absolute limit of 50 MB enforced at the server level.

== System Models

This section presents the use case model that captures the functional scope of the backend from the perspective of its two actors. Further system models — the entity model and the deployment context diagram — are presented in Chapter 5, where they serve as the foundation for the architectural design.

=== Use Case Model

#import "/utils/diagram.typ": diagram
#diagram(
  image("/figures/use_case_diagram.drawio.png", width: 100%),
  caption: "Use case model of TUMPeer. The two actors — Student and Instructor — interact with the system through distinct sets of use cases covering registration, submission, peer review, and grade management.",
  short-caption: "TUMPeer use case model",
)

The use case model captures the functional boundary of the TUMPeer backend from the perspective of its two actors. The Student actor covers all actions a course member with the STUDENT role may perform: registering an account, logging in, uploading a submission within the submission window, conducting assigned peer reviews, and viewing received feedback and final grades after release. The Instructor actor covers course and assignment management, rubric configuration, manual review allocation when needed, instructor scoring of submissions, and grade release. Both actors share the authentication use cases (register, login, reset password). The model reflects the role-scoped access control described in the constraints: every use case is accessible only to the actor whose role grants the required permission in the relevant course.
