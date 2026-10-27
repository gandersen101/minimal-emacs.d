# my-python-env

`my-python-env` sets up Eglot, pyrefly, Flymake, and Apheleia for each Python file. It uses the tools of the nearest venv above the file:

| Feature | Runs through | Source | Fallback |
| --- | --- | --- | --- |
| Type check, hover, xref, completion | pyrefly through Eglot | Nearest venv with `bin/pyrefly` | `pyrefly` on PATH |
| Ruff lint | Flymake | Nearest venv with `bin/ruff` | `ruff` on PATH |
| Ruff import sort and format on save | Apheleia | Nearest venv with `bin/ruff` | `ruff` on PATH |

A directory counts as a venv when it is named `.venv` or `venv` and contains `pyvenv.cfg`. The fallback for each tool is `exec-path`, which holds the directories in PATH. `uv tool install` links each tool into `~/.local/bin`, on PATH.

The package starts Eglot only for buffers that visit a local file. Special buffers (`*scratch*`, dired, org-src edit buffers) and remote files do not start Eglot.

## Requirements

- pyrefly in the project's venv. In ds-monorepo, the root `.venv` of each worktree has it.
- For a file with no venv pyrefly above it, a `pyrefly` on PATH. `uv tool install pyrefly` puts one there. Without it, see [Files without pyrefly](#files-without-pyrefly).
- For a file with no venv Ruff above it, a `ruff` on PATH. `uv tool install ruff` puts one there. Without it, Flymake turns off the Ruff backend for the file, and Apheleia does not format the file.

`use-package` installs Apheleia from MELPA.

## Setup

`post-init.el` adds each directory under `lisp/` to `load-path`. Then it loads the package:

```elisp
(use-package my-python-env
  :ensure nil
  :commands (my/python-eglot-ensure
             my/python-env-reload
             my/python-env-describe)
  :hook ((python-mode . my/python-eglot-ensure)
         (python-ts-mode . my/python-eglot-ensure))
  ;; The package loads Eglot.
  :config
  (my/python-env-setup))

(use-package eglot
  :ensure nil
  :commands (eglot-ensure
             eglot-rename
             eglot-format-buffer))

(use-package apheleia
  :commands (apheleia-mode
             apheleia-format-buffer)
  :hook ((python-mode . apheleia-mode)
         (python-ts-mode . apheleia-mode))
  :config
  (require 'my-python-env)
  (my/python-env-apheleia-setup))
```

The package requires Eglot, because it defines a subclass of Eglot's server class. Thus the `eglot` form must not require the package: when the package loads first, that `require` would load the package again.

## Commands

- `my/python-env-describe`: show the pyrefly, Ruff, and Eglot root for the current buffer.
- `my/python-env-reload`: clear the cache and restart the pyrefly servers for all Python file buffers. Use it after these changes:
  - You create or delete a venv.
  - You install pyrefly in a venv, or remove it.
  - You change the settings in `my-python-env.el`.

  Buffers other than the current one reconnect the next time you use them.

`my/python-eglot-ensure` is the mode hook. It calls `eglot-ensure` only for a local file.

## Options

- `my/python-env-venv-names`: the venv directory names to check, in order. Default: `(".venv" "venv")`.
- `my/python-env-pyrefly-arguments`: the arguments after `pyrefly lsp`. Default: `("--workspace-indexing-limit" "0")`. See [Workspace index](#workspace-index).
- `my/python-env-pyrefly-ignored-codes`: the codes of the pyrefly diagnostics that Eglot does not show. Default: `("unused-import" "unused-variable")`. See [Diagnostics](#diagnostics).

## How it works

### pyrefly servers

Eglot starts one server for each `project.el` project. Thus the package changes what "project" means for Eglot only:

1. Eglot binds `eglot-lsp-context` to `t` while it looks up the project for a buffer.
2. `my/python-env-project-find` runs before `project-try-vc` in `project-find-functions`. In the Eglot context, it returns a project rooted at the directory that holds the nearest venv with `bin/pyrefly`.
3. Other lookups (`C-x p`, consult, etc.) keep the normal VC project.
4. `my/python-env-server-contact` starts the pyrefly that a lookup from the root finds. No venv between a file and its root has pyrefly, so this is the pyrefly of each file under the root.

pyrefly chooses the config and the interpreter for each file itself. The `pyrefly` CLI does the same for `pyrefly check FILE`:

- **Config:** the nearest `pyrefly.toml`, or `pyproject.toml` with `[tool.pyrefly]`, above the file. A `pyproject.toml` without that table does not stop the search when a config is above it.
- **Interpreter:** the config's `python-interpreter-path`. Without it, the nearest `.venv`, `venv`, or `env` above the project root, then `python3` on PATH.

`pyrefly dump-config FILE` shows both for a file.

Example from ds-monorepo: the worktree's root `.venv` has pyrefly, and the project venvs do not. Thus each worktree gets one pyrefly server, rooted at the worktree. A file in `libs/core/` uses `libs/core/pyproject.toml` and `libs/core/.venv/bin/python`. A file in `libs/datavant/` uses the datavant config and venv in the same server.

One server for the worktree has these results:

- A jump to a file in another lib stays in the same server.
- Find references covers the files of each config that the server has loaded.
- Only one pyrefly process runs for each worktree.

A cache keyed by directory stores venv and tool lookups. The cache also stores "not found" results. `my/python-env-reload` clears it.

If a directory has no venv with pyrefly above it, the normal VC project applies, or the file's directory when no VC project applies. pyrefly then comes from PATH.

### File watches

pyrefly asks Eglot to watch the Python files and config files under the server root, and then under each config directory, search path, and site-packages directory. Eglot gets the directories to watch from `project-files`.

The package gives its projects a `project-files` method that uses the VC project. Thus Eglot does not watch directories that Git ignores, such as venvs and their site-packages. The generic method also lists the files in each venv. In ds-monorepo, it walked about 127,000 directories, blocked Emacs for 2 minutes, and then ran out of file descriptors.

With the VC method, the first request blocks Emacs for about 1 second at server start in ds-monorepo. It watches about 2,000 directories that Git does not ignore. Then pyrefly replaces that request with one for its configs, which used 15 watches for `libs/core`.

### Workspace index

By default, pyrefly indexes up to 2000 files of the workspace, in addition to the files of each config that it loads. The workspace is the server root. In ds-monorepo, that is the whole worktree, so the index took 2000 files from many projects.

| Server for `libs/core/src/thds/core/files.py` | Memory |
| --- | --- |
| Default index | 2.5 GB |
| `--workspace-indexing-limit 0` | 150 MB |
| `--workspace-indexing-limit 0`, with the core, datavant, and root configs loaded | 250 MB |

Without the workspace index, find references still covers the files of each loaded config. A project without a pyrefly config has no config index. In a test project without a config, find references did not find a use in a file that was not open. With the default index, it found that use. `pyrefly init` writes a config for a project.

### Diagnostics

Eglot shows pyrefly's severities as Flymake types:

| pyrefly | Flymake |
| --- | --- |
| `error` | error |
| `warn` | warning |
| `info`, and an error in the config's `baseline` file | note |

`pyrefly check` with no file arguments uses one config for the whole project. It also hides warnings, info, and baseline errors. To see the same diagnostics as Emacs, run `pyrefly check FILE --min-severity info --baseline-error-level info`.

pyrefly also sends three diagnostics that only an editor gets: `unused-import`, `unused-variable`, and `unused-parameter`. Ruff reports the first two as F401 and F841, so the package drops them. A pyrefly config cannot turn them off. The package uses its own server class, `my/python-env-pyrefly-server`, to drop them. `unused-parameter` stays, because the Ruff config in ds-monorepo does not select the `ARG` rules.

### Ruff

Ruff runs outside pyrefly. Each Ruff run looks up `ruff` from the directory of the buffer's file, not from the server root. Each run reads the buffer from stdin, and `--stdin-filename` gives Ruff the path of the file.

- **Lint:** `my/python-env-ruff-flymake` is a Flymake backend. It runs `ruff check --output-format json` asynchronously. A new check stops the check before it.
  - Eglot replaces `flymake-diagnostic-functions` in each buffer that it manages. Thus `eglot-managed-mode-hook` adds the Ruff backend beside `eglot-flymake-backend`, and then starts Flymake again.
  - Syntax errors and Pyflakes (`F`) rules are errors. All other rules are warnings. Ruff's JSON output has no severity, so the package sets one. Pyflakes rules find likely bugs, and most other rules are about style.
  - If Ruff fails, for example on an invalid config, its message shows as an error on the first line. The next check after the fix removes it.
- **Format:** Apheleia runs two formatters on save, in this order:
  1. `my/python-env-ruff-isort`: `ruff check --select I --fix-only`, which sorts the imports.
  2. `my/python-env-ruff-format`: `ruff format`.

  Apheleia evaluates the first element of each command in the buffer, so each formatter uses the Ruff for that file.

pyrefly has no formatter, so it does not change the buffer.

## Project config

Put lint, format, and type-check policy in each project's `pyproject.toml`.

### Ruff

- Ruff uses the nearest `pyproject.toml` with `[tool.ruff]`, or a `ruff.toml`, above the file. This is the same as the CLI.
- A nested config does not merge with its parent unless it sets `extend`.
- Config edits apply on the next check.
- Lint adds `--extend-select I` for every project, also when a project has its own config.
- Lint and format pass `--force-exclude`, so Ruff skips the files that a project's `exclude` lists.
- Neither command sets `--line-length`, so `fill-column` has no effect. The line length comes from the project's config.

### pyrefly

- Each file uses its nearest config, as [pyrefly servers](#pyrefly-servers) says.
- pyrefly resolves relative paths in the config, such as `python-interpreter-path` and `search-path`, from the config's directory.
- pyrefly asks Eglot to watch `pyrefly.toml`, `pyproject.toml`, and `uv.lock` in each config directory.
- A file without a config gets the `basic` preset. If a `[tool.mypy]` or pyright config is above the file, pyrefly translates it in memory and uses that instead.

## Formatting

Apheleia formats the buffer when you save it. Apheleia keeps point in place, and then saves the formatted buffer again.

- `auto-save-visited-mode` saves through `save-buffer`. Thus Apheleia also formats a Python buffer when that mode saves it. That mode saves a buffer only if it has changes, after `auto-save-visited-interval` seconds without input.
- If you edit the buffer while Ruff runs, Apheleia discards Ruff's result.
- If Ruff fails, for example on a syntax error, Apheleia does not change the buffer. Apheleia writes Ruff's error to `*apheleia-ruff-log*`.
- `M-x apheleia-format-buffer` formats without a save.
- `eglot-format-buffer` does not format Python, because pyrefly has no formatter.

### Undo

- After a format from an auto-save, the first `C-/` undoes the format change and your last typed text together. The auto-save runs from a timer, so Emacs adds no undo boundary between them.
- After `C-x C-s`, the first `C-/` undoes only the format change. The save command adds an undo boundary after your typing.
- An auto-save can format the buffer during a pause in a series of undos. Then later `C-/` (`undo`) presses redo, and the text does not change. `C-z` (`undo-fu-only-undo`) never redoes, so it continues back through the history.

## Hover

pyrefly writes the hover text in Markdown. Eglot renders it with `gfm-view-mode` from markdown-mode.

- **Values:** the hover shows the full type, for example `(variable) names: list[str]`.
- **Functions:** the hover shows the signature with its annotations, then the docstring.
- **Links:** "Go to" links point to the type's definition. For a standard library type, the link goes to pyrefly's copy of typeshed in the system temp directory.
- **Echo area:** it shows the first visible line of the hover. Press `C-h .` (`eldoc-doc-buffer`) to see the full hover.

## Inlay hints

Eglot turns on `eglot-inlay-hints-mode` when the server supports it. pyrefly shows the inferred type after the name in an assignment without an annotation, for example `project_root: Path`.

- `M-x eglot-inlay-hints-mode` turns the hints off in one buffer.
- To turn them off for all servers, add `:inlayHintProvider` to `eglot-ignored-server-capabilities`.

## Files without pyrefly

If no venv above a file has pyrefly, and PATH has no `pyrefly`, Eglot does not start for the file. Eglot shows the warning `Cannot find pyrefly for DIR`.

- Eglot turns on Flymake. Without Eglot, the file gets no Flymake checks, so Ruff does not lint the file.
- Apheleia still formats the file on save with Ruff.
- A jump into the standard library opens pyrefly's typeshed copy in the system temp directory. No venv is above that file, so the same rules apply.
- `eglot-extend-to-xref` does not help here. The upstream `init.el` sets `find-file-visit-truename`, so the buffer visits `/private/var/...`, but Eglot records the path as `/var/...`.

With a `pyrefly` on PATH, each such file gets a server rooted at its VC project or directory, with the `basic` preset or a translated mypy config.

## Caveats

- **Security:** pyrefly runs the interpreter from the config or the venv to find its search paths. The venv's own `pyrefly` and `ruff` also run from the project. Open only projects that you trust.
- **Python version:** pyrefly checks for the Python version of the file's interpreter, unless the config sets `python-version`. For example, `import tomllib` is an error in a Python 3.10 venv.

## Testing

- In a Python buffer, run `my/python-env-describe` to see the resolved tools.
- Run `M-x flymake-running-backends` to see `my/python-env-ruff-flymake` beside `eglot-flymake-backend`. Flymake writes backend errors to `*Flymake log*`.
- Run `pyrefly dump-config FILE` to see the config and interpreter that pyrefly uses for a file.
- In `M-x eglot-events-buffer`, look at `client/registerCapability` for the watched files, and at `textDocument/publishDiagnostics` for all diagnostics before the package drops some. The upstream `init.el` turns off the event log unless Emacs starts with `--debug-init`.
