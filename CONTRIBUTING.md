# Contributing

Issues and pull requests are welcome. A few guidelines:

- **Every piece of the harness should earn its place.** It exists because a model, at some point, could not be
  trusted to do that on its own. If you add a piece, explain the failure it prevents; if newer models make a piece
  unnecessary, removing it is a welcome contribution too.
- **Run the tests**: `tests/run-tests.sh` (no network, no cost) and `shellcheck -S warning loopkit kit/*.sh`.
  Behaviour changes in `run.sh` need a scenario in `tests/run-tests.sh`.
- **Keep it dependency-light**: bash, git, jq, curl, python3 standard library. The roadmap is one HTML file with no
  build step.
- **Prompts are code.** Changes to `kit/prompts/` should say what went wrong without them, ideally with numbers from
  a real run (failure rate, cost, lines per feature).
- Real-world reports (what you built, how long it took, what broke) are as valuable as code: open an issue.
