#import "/layout/thesis_template.typ": *
#import "/metadata.typ": *

#set document(title: titleEnglish, author: author)

#show: thesis.with(
  title: titleEnglish,
  titleGerman: titleGerman,
  degree: degree,
  program: program,
  examiner: examiner,
  supervisors: supervisors,
  author: author,
  startDate: startDate,
  submissionDate: submissionDate,
  abstract_en: include "/content/abstract_en.typ",
  abstract_de: include "/content/abstract_de.typ",
  acknowledgement: include "/content/acknowledgement.typ",
  transparency_ai_tools: include "/content/transparency_ai_tools.typ",
)

#include "/content/introduction.typ"
#pagebreak()
#include "/content/background.typ"
#pagebreak()
#include "/content/related_work.typ"
#pagebreak()
#include "/content/requirements.typ"
#pagebreak()
#include "/content/system_design.typ"
#pagebreak()
#include "/content/implementation.typ"
#pagebreak()
#include "/content/summary.typ"