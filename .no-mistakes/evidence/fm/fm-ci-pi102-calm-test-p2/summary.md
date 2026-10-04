# Pi 1.0.2 calm /export regression: before/after

Driver: tests/fm-calm-pi-extension.test.sh (CI lane portable-serial-6of9 member),
run against real npm-installed Pi packages in a disposable global-style prefix,
Node v22.23.3 (Pi 1.0.x requires >=22.19), LANG/LC_ALL=en_US.UTF-8 (CI runs C.UTF-8).

| Commit | Pi | Result |
|---|---|---|
| base 73a9ec36 | 1.0.2 | FAIL: "grep disappeared from /export calm.html HTML while calm mode was on" (same as CI) |
| fix 149b6263 | 1.0.2 | PASS, all 15 cases ok |
| fix 149b6263 | 1.0.0 | PASS, all 15 cases ok (old getToolDefinition key still honored) |

Pi's own createToolHtmlRenderer: 1.0.0 destructures `getToolDefinition`; 1.0.2 destructures `getToolRenderers`.
Logs: base-pi1.0.2.log, fix-pi1.0.2.log, fix-pi1.0.0.log
