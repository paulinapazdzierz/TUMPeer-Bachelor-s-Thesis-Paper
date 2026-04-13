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

= Architecture

This chapter describes the architectural design of the TUMPeer backend. Architecture bridges the requirements stated in the previous chapter and the implementation described in the next: it defines the structural decomposition of the system, the rationale behind key design decisions, the data model, the access control model, and the control flow that drives automated behaviour. The scope of this chapter is the Spring Boot backend and its PostgreSQL database. The React frontend and the NGINX/Docker deployment layer exist as context -- they appear where needed to explain the interfaces the backend exposes -- but their internal design is outside this thesis.

== Design Goals

Design goals translate the quality attributes from Chapter 4 into concrete architectural priorities. Where goals conflict, the following order of priority applies.

*DG1 -- Separation of Concerns.* The backend is structured in four layers: security, controller, service, and repository. Each layer has a single responsibility and communicates only with the layer directly below it. This supports QA5 (maintainability) and makes the service layer independently testable, at the cost of some indirection for simple data-pass-through operations.

*DG2 -- Stateless REST API with Session-Based Authentication.* Each HTTP request carries all the context the backend needs to process it, except for the session identifier held in a cookie. This design satisfies QA4 (scalability) by avoiding server-side affinity for most operations. The design uses session-based authentication rather than stateless tokens for simplicity and to enable server-side session invalidation, which C1 and the concurrent-session limit in FR2 require. The trade-off is that horizontal scaling requires a shared session store, which is acceptable for the current deployment scale.

*DG3 -- Scheduler-Driven Status Automation.* A background scheduler that runs every 60 seconds decouples time-based state changes from request handling. This satisfies QA2 (reliability) without requiring clients to trigger transitions and avoids race conditions that would arise if the system performed deadline checks only at request time. The trade-off is a maximum latency of 60 seconds between a deadline passing and the corresponding status change.

*DG4 -- Relational Data Model with Schema Versioning.* The backend persists all application state in a normalised PostgreSQL schema that Flyway manages through versioned migrations. This satisfies QA3 (correctness) by enforcing referential integrity at the database level and provides a reproducible schema evolution history. The trade-off is the overhead of schema migration management compared to a schema-less approach.

== Subsystem Decomposition <sec-subsystem-decomposition>

The deployment context diagram below shows the operational environment in which the backend runs: HTTP requests arrive through an NGINX reverse proxy, the backend communicates with a PostgreSQL database, and it sends email through Gmail SMTP. The configuration of the reverse proxy and the deployment infrastructure are outside the scope of this thesis. The same applies to the React frontend, which consumes the backend API but whose implementation is not covered here. The remainder of this section describes the internal structure of the backend exclusively.

#pagebreak()
#diagram(
  pad(bottom: 1em, image("/figures/componentdagramfinal.drawio.png", width: 100%)),
  caption: "Deployment context of the TUMPeer backend. The Spring Boot application runs inside a Docker container and is reached through an NGINX reverse proxy. It communicates with a PostgreSQL database container, sends email via Gmail SMTP, and stores uploaded submission files in a Docker volume (uploads_data). The configuration of NGINX, Docker, and the deployment infrastructure are outside the scope of this thesis.",
  short-caption: "Deployment context of the TUMPeer backend",
)
#pagebreak()

The backend is structured as a four-layer architecture, visible in Figure 2 within the `spring_backend` component. Each incoming HTTP request traverses the layers from top to bottom; responses travel back in the opposite direction.

The *Security Layer* uses Spring Security to handle every request before it reaches any application logic. It validates the JSESSIONID session cookie, establishes the authenticated principal in the security context, and enforces CORS policy. Rate limiting runs at the filter level via Bucket4j: the login endpoint (`/api/auth/login`) allows at most 20 requests per minute per IP; all other API endpoints allow at most 200 requests per minute per IP. HTTPS termination and IP-level rate limiting are handled by the NGINX reverse proxy in front of the backend, so the security layer deals only with application-level concerns.

The *Controller Layer* maps HTTP endpoints to application operations. Each controller class groups a cohesive set of endpoints -- for example, `AssignmentController` handles all assignment lifecycle operations. Controllers are responsible for deserialising request bodies, extracting path and query parameters, invoking the appropriate service method, and serialising the response. They also perform role checks and validate that the requesting user is authorised for the specific resource (for example, that a student belongs to the course whose assignment they are accessing). Controllers do not contain business logic.

The *Service Layer* contains all business logic. This includes the review allocation algorithm, the ±20pp outlier grading rule, deadline enforcement decisions, and status transition logic. Spring injects service beans into controllers. The service layer is the only layer that coordinates between multiple repositories or applies rules that span more than one entity.

The *Repository Layer* provides access to the PostgreSQL database through Spring Data JPA. Each repository interface declares the queries needed by the service layer. Hibernate translates repository calls to SQL and manages the object-relational mapping between Java entities and database tables.

Two cross-cutting subsystems operate across layers. The *email subsystem* uses Spring Mail connected to a Gmail SMTP account to send account verification codes and password reset tokens. The authentication service invokes it synchronously; a failure propagates as an exception and aborts the current request. The *file storage subsystem* writes uploaded submission files to a directory on disk (`/app/uploads`) that is backed by a Docker volume (`uploads_data`). Files are named `{uuid}_{originalName}` to prevent filename collisions. The submission service writes and deletes files; the submission controller streams them back to clients on download and view requests.

== Persistent Data Management <sec-data-model>

The backend persists all application state in a PostgreSQL 17 database. Flyway manages the schema by applying versioned SQL migration scripts on application startup. This guarantees a reproducible schema at every deployment and provides a full history of schema changes. Hibernate, configured through Spring Data JPA, maps the relational schema to Java entity classes and translates JPQL and method-name-derived queries to SQL.

#pagebreak()
#diagram(
  pad(bottom: 1em, image("/figures/tumpeer-er-diagram-TUMPeer ER Diagram.drawio.png", width: 120%)),
  caption: "Entity model of the TUMPeer backend. The diagram shows all eleven entities (AppUser, Course, CourseMember, Assignment, Rubric, RubricQuestion, Submission, SubmissionGrade, ReviewAssignment, Review, ReviewScore) and their relationships.",
  short-caption: "TUMPeer entity model",
)
#pagebreak()

The domain model consists of eleven entities. `AppUser` represents a platform user with a TUM email address, a matriculation identifier, and a global role. `Course` groups assignments under a semester context. `CourseMember` is a join entity that records the role a specific user holds in a specific course; its primary key is the composite of `courseId` and `userId`. This design allows a user to hold different roles in different courses simultaneously.

`Assignment` belongs to a course and stores the submission window, the review window, the reviewer count configuration, and file constraints. Each assignment has exactly one `Rubric`, which in turn owns an ordered list of `RubricQuestion` records. Each question defines a description and a `maxPoints` value that determines both the scoring scale and the maximum contribution of that question to the total rubric score.

`Submission` records a student's uploaded file for an assignment, together with the file metadata and the current submission status. `SubmissionGrade` stores the computed final grade for a submission, the optional instructor score, the instructor comment, and a `calculation` field that records which branch of the grading rule was applied. The separation of `Submission` and `SubmissionGrade` allows the submission record to exist before any grading takes place.

`ReviewAssignment` records the assignment of a reviewer to a submission after the allocation algorithm runs. It carries the anonymising `reviewerLabel` integer that students see in place of the actual reviewer name. `Review` stores the content of a completed or draft review: text comments, total points awarded, and the current review status. `ReviewScore` records the score a reviewer awarded for a single rubric question; its primary key is the composite of `reviewId` and `questionId`, enforcing one score per question per review.

The backend stores and serialises all timestamp columns in the Europe/Berlin timezone, configured through the Hibernate JDBC timezone property and the Jackson serialiser. Deadline comparisons in the scheduler and in the submission controller use `LocalDateTime.now(ZoneId.of("Europe/Berlin"))` to ensure consistent behaviour across daylight saving time transitions.

== Access Control <sec-access-control>

TUMPeer uses two roles: STUDENT and INSTRUCTOR. Roles are scoped to individual courses: a user may be an INSTRUCTOR in one course and a STUDENT in another. This design directly supports the tutor role common in university settings, where a teaching assistant manages a course section while simultaneously attending another as a student. Each role grants a distinct set of permissions within that course: INSTRUCTOR members create and manage assignments, trigger grade release, and view aggregate statistics, while STUDENT members submit work, conduct peer reviews, and view their own results. A user who holds both roles across different courses receives the corresponding permissions and interface view for each course independently. In addition, each `AppUser` record carries a `globalRole` field that reflects the highest role the user holds across all their course memberships. The `globalRole` is recalculated whenever a course membership is created or deleted.

Spring Security manages session state at the HTTP level. Each request carries a `JSESSIONID` cookie that Spring Security uses to restore the authenticated principal. Controller methods apply role-based checks: before performing a course-level operation, the controller verifies that the authenticated user holds the required role in that specific course. This per-resource check is necessary because a user's global role does not determine their permissions in a given course.

Session management applies several constraints derived from FR2. The backend binds sessions to an HTTP-only cookie, preventing client-side JavaScript access. The session timeout is 30 minutes by default, or 30 days when the user selects the extended-persistence option at login. The backend maintains a limit of five concurrent sessions per user: when a sixth session is created, the oldest active session is invalidated.

The backend implements rate limiting at the filter level using Bucket4j with a Caffeine-backed in-memory cache keyed by client IP address. The login endpoint (`/api/auth/login`) is limited to 20 requests per minute per IP; all other API endpoints share a separate bucket capped at 200 requests per minute per IP. The filter extracts the client IP address from request headers, checking `X-Forwarded-For` and `X-Real-IP` before falling back to the direct remote address. Buckets evict from the cache after 10 minutes of inactivity to prevent unbounded memory growth.

== Software Control Flow <sec-control-flow>

The backend responds to two categories of triggers: HTTP requests from clients, and scheduled tasks driven by an internal timer.

Explicit HTTP requests trigger all client-facing state changes -- creating a submission, saving a review draft, submitting a final review, releasing grades. The controller receives the request, the service applies the business rule, and the repository persists the result. This synchronous path handles all operations that a user initiates.

A separate component, `SubmissionStatusScheduler`, annotated with Spring's `@Scheduled(fixedRate = 60000)`, handles time-based state changes. The scheduler runs every 60 seconds independently of any client activity. On each execution it loads all assignments from the database, checks each assignment's deadlines against the current Berlin time, and performs the following transitions:

- For assignments whose submission deadline has passed: transitions each `SUBMITTED` submission to `UNDER_REVIEW` and each `PENDING` submission to `NO_SUBMISSION`.
- For assignments whose submission deadline has passed and for which no review assignments have been created yet: runs the review allocation algorithm automatically, without requiring instructor intervention.
- For assignments whose review deadline has passed: transitions each `"READY FOR REVIEW"` review assignment to `"NO REVIEW SUBMITTED"`; for `"DRAFT REVIEW"` assignments, clears the saved answer content and likewise transitions the status to `"NO REVIEW SUBMITTED"`.

The complete set of status values and the transitions between them is shown in @fig-status-diagram.

This design decouples time-based logic from the request path entirely. A client can submit their work at any point during the submission window; the scheduler will move it to the correct next state at the appropriate time, regardless of whether any client is active at that moment. The 60-second polling interval means that status transitions occur within at most one minute of a deadline, which is an acceptable latency for an academic workflow.

The one manual trigger that bypasses this automatic flow is grade release. The instructor must explicitly call `POST /api/assignments/{assignmentId}/release-grades` to compute final grades and make them visible to students. This is intentional: grade release is a deliberate instructor decision, not an automatic consequence of the review deadline passing.
