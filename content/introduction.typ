#import "/utils/diagram.typ": diagram

= Introduction

Peer review is an established component of university education. When students evaluate each other's work using structured criteria, they develop evaluative judgment, encounter approaches to the same problem that differ from their own, and receive feedback that extends beyond what a single instructor can provide for an entire cohort. Managing peer review manually is impractical: instructors must assign reviewers fairly, enforce submission and review deadlines, collect structured feedback, and reconcile multiple peer evaluations into a single final grade — tasks that consume time that would otherwise go to teaching and grow increasingly burdensome as course enrolment scales.

At the Technical University of Munich (TUM), no dedicated platform exists that automates the full peer review lifecycle while enforcing TUM-specific institutional constraints. Existing learning management systems offer basic peer review capabilities but lack automated reviewer allocation, rubric-based grade computation, and the domain-specific rules that TUM courses require. TUMPeer is a dedicated, automated peer review platform built to fill this gap. It manages the complete peer review lifecycle through a REST API backed by a PostgreSQL database: from user registration and course setup, through file submission and automatic reviewer allocation, to rubric-based grading with outlier detection and anonymised result release. Figures 1 and 2 show the student and instructor dashboards as an initial orientation; these screenshots are included for context only and the backend implementation is the subject of this thesis.

#diagram(
  image("/figures/student_view_final.png", width: 100%),
  caption: "TUMPeer student dashboard. Submissions and review tasks across multiple courses are presented as cards with their current status.",
  short-caption: "TUMPeer student dashboard",
)

#diagram(
  image("/figures/instructor_view.png", width: 100%),
  caption: "TUMPeer instructor dashboard. Courses and assignments are managed from a central view with controls for member management and assignment configuration.",
  short-caption: "TUMPeer instructor dashboard",
)

== Problem

At TUM, courses that include peer review currently rely on a patchwork of manual steps and disconnected tools. Such a workflow could proceed as follows: students upload their submissions to existing platforms; instructors anonymise the files by hand, pair reviewers with submissions manually, and distribute the anonymised work through ad-hoc channels. After the review window closes, instructors collect rubric scores and written comments in spreadsheets and manually strip reviewer identities from the collated data before sharing results with students. Each of these steps is time-consuming, difficult to audit, and fragile at scale: manual anonymisation introduces errors, reviewer allocation lacks consistency, and merging multiple rubric evaluations into a single final score is tedious. The overhead is significant enough that some instructors resign from peer assessment altogether, depriving students of its pedagogical benefits.

Running this workflow without dedicated backend infrastructure creates several further concrete problems. Assigning reviewers fairly — ensuring each reviewer receives the same number of tasks and that no student reviews their own work — requires a combinatorial allocation step that cannot be reliably performed by hand for large cohorts. Enforcing submission and review deadlines requires continuous monitoring; without automation, late submissions or missing reviews are easy to overlook. Detecting outlier peer scores and correcting the final grade accordingly requires explicit business logic that spreadsheet-based approaches cannot provide. Data scattered across multiple tools makes it difficult to reliably maintain anonymity, fairness, and consistency without continuous manual oversight — reviewer identities must remain hidden from submission authors and submission-author identities from reviewers throughout the entire workflow, which ad-hoc tooling struggles to enforce.

TUM courses impose institutional constraints that generic platforms do not accommodate. Registration must be restricted to `@tum.de` and `@mytum.de` email domains.

== Motivation

Research on peer assessment provides strong empirical support for rubric-based peer review as a valid and pedagogically beneficial assessment practice. Topping @topping1998peer reviews studies of peer assessment in higher education and finds that structured, criterion-referenced evaluation is reliable, promotes student engagement, and produces learning effects comparable to instructor feedback. Falchikov and Goldfinch @falchikov2000student conduct a meta-analysis of 48 higher education studies and show that peer grades align more closely with instructor grades when explicit rubrics guide the evaluation than when assessors exercise holistic judgment. Their findings establish structured rubrics as a prerequisite for peer grades to inform final scores reliably.

Berrezueta-Guzman, Krusche, and Wagner @berrezueta2025coders provide direct empirical grounding in TUM's own instructional context. They implement rubric-based, anonymised peer review in a large introductory programming course at TUM and report a Pearson correlation of $r = 0.55$ between peer scores and instructor scores, with a root mean square error of 14.87. A post-assessment survey finds that 83 percent of students reported enjoying the role of evaluator and that most teams considered the peer evaluations fair. These results confirm that structured, anonymous peer review can approximate instructor evaluation with moderate accuracy while fostering positive student engagement.

The same study identifies a further motivation: the rapid adoption of AI-powered coding assistants challenges the validity of traditional code-submission assessments, because submitted artefacts may reflect tool output rather than student understanding @berrezueta2025coders. Rubric-based peer review tests evaluative thinking and communication rather than output alone: a student who cannot assess or articulate the quality of another student's design choices cannot substitute an AI-generated artefact for genuine comprehension. This makes peer review increasingly relevant as a complementary assessment modality alongside automated grading systems.

These findings together motivate TUMPeer: a backend that makes structured, anonymised, automatically allocated peer review available at TUM course scale, without requiring instructors to manage the workflow manually.

== Objectives

TUMPeer is developed by a three-person team. This thesis designs and implements the backend REST API and the PostgreSQL database. A separate thesis covers the React frontend, and a third covers deployment and infrastructure security. The backend is the only component within the scope of this work.

The concrete objectives are as follows. The backend must allow users to register with TUM email addresses and verify their accounts through a one-time email code, and it must authenticate registered users through session-based login with a configurable session lifetime. It must allow instructors to create courses, manage course members individually or through bulk CSV import, and define assignments with configurable submission windows, review windows, rubric questions, and file constraints. It must accept file uploads from students within the configured submission window, allocate reviewers to submissions automatically and equitably after the submission deadline, collect rubric-based peer reviews within the review window, and compute final grades using the ±20 percentage-point outlier detection rule. A background scheduler must enforce deadline-driven status transitions without requiring any client to initiate them. The backend must expose anonymised score statistics to instructors and students after grades are released, and it must protect all operations through session-based authentication, BCrypt password hashing, and per-endpoint request rate limiting.

== Outline

Chapter 2 introduces the technical and pedagogical concepts that underpin TUMPeer: peer assessment in education, the REST architectural style, layered software architecture, the Spring Boot and Java Persistence technology stack, and PostgreSQL. Chapter 3 surveys existing peer review platforms and relevant research on automated assessment, and it identifies the gap that TUMPeer addresses. Chapter 4 specifies the functional requirements, quality attributes, and institutional constraints that the backend must satisfy. Chapter 5 describes the architectural design: the four-layer structure, the persistent data model, the access control model, and the scheduler-driven control flow. Chapter 6 details the implementation of each major subsystem: user authentication, course and assignment management, file submission, review allocation, grading, and score statistics. Chapter 7 summarises the contributions of this thesis and discusses directions for future work.
