#import "/utils/todo.typ": TODO

= Background
#TODO[
  Introduce the key concepts and technologies needed to understand this thesis. Each subsection covers one concept: what it is, why it matters for TUMPeer, and relevant literature.
]

== Peer Review in Education
#TODO[
  Summarize the concept of peer assessment in educational contexts. Define rubric-based peer review and explain how anonymous peer grading reduces bias. Reference key literature including Berrezueta-Guzman et al. ("From Coders to Critics"). Explain the role of automated systems in making peer review scalable.
]

== Representational State Transfer
#TODO[
  Describe the REST architectural style: stateless communication, resource-based endpoints, HTTP methods (GET, POST, PUT, DELETE). Explain why REST is a suitable choice for the TUMPeer backend API. Reference Fielding's original dissertation or a well-established textbook.
]

== Layered Software Architecture
#TODO[
  Explain the layered architecture pattern (Presentation / API / Service / Repository). Describe how each layer has a defined responsibility and how this promotes separation of concerns, testability, and maintainability. Reference Bruegge and Dutoit @bruegge2004object.
]

== Spring Boot and Java Persistence
#TODO[
  Briefly introduce Spring Boot as a framework for building REST APIs in Java. Describe the role of Spring Security for authentication, Spring Data JPA and Hibernate for object-relational mapping, and Flyway for database schema migrations.
]

== PostgreSQL and Relational Data Modeling
#TODO[
  Introduce PostgreSQL as a relational database management system. Explain entity relationships, foreign keys, and how relational modeling maps to the domain of peer review (users, courses, assignments, submissions, reviews).
]