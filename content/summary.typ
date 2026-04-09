#import "/utils/todo.typ": TODO

= Summary
#TODO[
  Briefly introduce this chapter: recap the thesis goal (a scalable backend for rubric-driven peer assessment at TUM), then cover status, conclusion, and future directions.
]

== Status
#TODO[
  Honestly assess what was achieved and what remains open. Reference the functional requirements from Chapter 4.
]

=== Realized Goals
#TODO[
  List the implemented and working backend features, mapped to the functional requirements:
  - FR1-FR2: TUM email registration with verification and session-based authentication
  - FR3-FR4: Course and assignment management with rubric configuration
  - FR5: File submission handling with deadline enforcement
  - FR6: Fair review allocation algorithm
  - FR7: Rubric-based review submission with draft support
  - FR8: Grade calculation with +/-20pp outlier detection
  - FR9: Instructor-triggered grade and review release
  - FR10: Automated status transitions via 60-second scheduler
]

=== Open Goals
#TODO[
  Describe requirements or features that were not fully realized. Examples:
  - Deadline-based resubmission enforcement (allowResubmission flag exists but enforcement not implemented)
  - Edge case: user added to a course before creating an account
  - Advanced statistics endpoints for detailed per-student score breakdowns
  Explain briefly why these were not completed.
]

== Conclusion
#TODO[
  Summarize the thesis contribution: the design and implementation of a scalable, rubric-driven backend for peer assessment at TUM. Recap the key technical contributions: the layered Spring Boot architecture, the fair allocation algorithm, the automated scheduler-driven status machine, and the outlier-based grading system. State how TUMPeer addresses the gap identified in the introduction.
]

== Future Work
#TODO[
  Describe promising directions for extending TUMPeer's backend:
  - OAuth2 integration with TUM's identity provider: access to TUM's OAuth2 infrastructure was obtained only at the end of the development period, making integration infeasible within the thesis timeline. Replacing the current email-based registration with OAuth2 single sign-on would eliminate manual account creation, enforce TUM identity automatically, and significantly simplify the authentication flow.
  - Migration from the current Gmail SMTP account to a TUM-issued email address and the TUM email service, which would give all outgoing verification and notification emails an official institutional sender address.
  - More sophisticated outlier detection beyond the +/-20pp threshold
]
