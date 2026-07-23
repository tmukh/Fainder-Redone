# DIMA Thesis Template

This Repository contains the DIMA Thesis Template.

You can compile it using PDFLaTeX or XeLaTeX:

```bash
pdflatex Template.tex
```

You can find the compiled version of this document [here](https://git.tu-berlin.de/dima/teaching/thesis-template/-/jobs/artifacts/main/raw/Template.pdf?job=build).

## Writing the Thesis

Within this document, you can find instructions on how to use the template to write your thesis.

## Making this document your own

To write your thesis, you should only need to edit the `Template.tex` file and the files in the `chapters/` folder.

Proceed as follows:

1. In `Template.tex`, replace the placeholder information (author name, title, etc.) with your own information.
2. Write your thesis in the files located in the `chapters/` folder.
3. Remove either the English or German Declaration of Authorship from the included files in the `Template.tex` file, depending on your language of choice.
4. Fill out the `misc/declaration-of-aids.tex` file to document your use of aids.
5. Compile the document using PDFLaTeX or XeLaTeX.


## Use of (AI) Tools


### Levels of Use[^lou]

Use the following levels of use to categorize your use of aids.
Only list tools that you did not explicitly state in your thesis (e.g., if your prototype is written in C and runs on a Linux machine, this should be written in your thesis and therefore does not need to be entered here).
If youused multiple tools in one phase, add multiple lines for that phase.

| Level of use | Characterization     | Examples                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------ | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1            | For inspiration only | • Asked the system for topic proposals.<br>• Used tools to turn your own notes into thematic focal points.<br>• Had the system suggest wording.<br>• Used spelling/grammar checking.                                                                                                                                                                                                                                                                  |
| 2            | supplementary        | • Asked for possible research questions.<br>• Requested explanations of individual terms in the assignment or passages in the literature.<br>• Had the system propose outlines for your own notes.<br>• Asked it to summarise your own texts.<br>• Generated a *reverse outline* for your text (an outline created from the written material).                                                                                                        |
| 3            | supportive           | • Asked the system to explain the task requirements (e.g., the structure of a term paper).<br>• Requested literature summaries and suggested possible topic outlines.<br>• Refined the research question or wrote text sections in a dialogue with the model, iteratively adding the model’s output.<br>• Asked for revision suggestions concerning readability and style.<br>• Asked for a Code Review<br>• Asked for writing Tests to existing Code |
| 4            | content-shaping      | • Generated background knowledge for the assignment or answers to the research question.<br>• Provided a topic outline and let the model fill it in.<br>• Let the LLM make cuts, add material, or directly adopt LLM‑generated text.<br>• Let the LLM write multiple lines of code by itself                                                                                                                                                          |

[^lou]: adapted from: https://pubdata.leuphana.de/server/api/core/bitstreams/f4c7f7f2-3974-410c-a07b-4e545390561e/content, pp. 20 and 24

