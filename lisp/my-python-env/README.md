# my-python-env

`my-python-env` sets up Eglot, pylsp, Flymake, and Apheleia for each Python file. It uses the tools of the nearest venv above the file:

| Feature | Runs through | Source | Fallback |
| --- | --- | --- | --- |
| Jedi (xref, completion, hover) | pylsp | Nearest venv | pylsp tool environment |
| Ruff lint | Flymake | Nearest venv with `bin/ruff` | `ruff` in the pylsp tool environment |
| Ruff import sort and format on save | Apheleia | Nearest venv with `bin/ruff` | `ruff` in the pylsp tool environment |
| Mypy (type check) | pylsp-mypy | Nearest venv with `bin/mypy` | `mypy` in the pylsp tool environment |

A directory counts as a venv when it is named `.venv` or `venv` and contains `pyvenv.cfg`. The last fallback for each tool is `exec-path`.

The package starts Eglot only for buffers that visit a local file. Special buffers (`*scratch*`, dired, org-src edit buffers) and remote files do not start Eglot.

## Requirements

Install pylsp, its mypy plugin, and Ruff in one uv tool environment:

```sh
uv tool install python-lsp-server --with pylsp-mypy --with ruff
```

- uv links only `pylsp` into `~/.local/bin`.
- `ruff` and `mypy` stay in the tool environment's `bin/` directory, off PATH. The package finds them through `my/python-env-fallback-bin`.
- `uv tool upgrade python-lsp-server` upgrades all packages together.
- To also get `ruff` and `mypy` in the shell, add `--with-executables-from ruff,mypy`.
- An older install with `--with python-lsp-ruff` also works. The package turns that plugin off, and its `ruff` dependency is the fallback.

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
         (python-ts-mode . my/python-eglot-ensure)))

(use-package eglot
  :ensure nil
  :commands (eglot-ensure
             eglot-rename
             eglot-format-buffer)
  :config
  (require 'my-python-env)
  (my/python-env-setup))

(use-package apheleia
  :commands (apheleia-mode
             apheleia-format-buffer)
  :hook ((python-mode . apheleia-mode)
         (python-ts-mode . apheleia-mode))
  :config
  (require 'my-python-env)
  (my/python-env-apheleia-setup))
```

## Commands

- `my/python-env-describe`: show the venv, Ruff, Mypy, pylsp, and Eglot root for the current buffer.
- `my/python-env-reload`: clear the cache and restart the pylsp servers for all Python file buffers. Use it after these changes:
  - You create or delete a venv.
  - You add a mypy config file where there was none.
  - You change the settings in `my-python-env.el`.

  Buffers other than the current one reconnect the next time you use them.

`my/python-eglot-ensure` is the mode hook. It calls `eglot-ensure` only for a local file.

## Options

- `my/python-env-venv-names`: the venv directory names to check, in order. Default: `(".venv" "venv")`.
- `my/python-env-fallback-bin`: the `bin/` directory of the pylsp tool environment. The default follows the uv rules: `$UV_TOOL_DIR`, else `$XDG_DATA_HOME/uv/tools`, else `~/.local/share/uv/tools`, then `python-lsp-server/bin`.
  - GUI Emacs gets only PATH and the variables in `exec-path-from-shell-variables` from the shell. If you set `UV_TOOL_DIR` in the shell, add it to that list too.

## How it works

### pylsp servers

pylsp settings apply to a whole workspace, not to one file. Eglot starts one server for each `project.el` project. Thus the package changes what "project" means for Eglot only:

1. Eglot binds `eglot-lsp-context` to `t` while it looks up the project for a buffer.
2. `my/python-env-project-find` runs before `project-try-vc` in `project-find-functions`. In the Eglot context, it returns a project rooted at the directory that holds the nearest venv.
3. Other lookups (`C-x p`, consult, etc.) keep the normal VC project.
4. Eglot computes the workspace configuration with `default-directory` set to the server root. `my/python-env-workspace-configuration` builds the pylsp settings for that root.

Each venv root gets its own pylsp process. All files under a root have the same ancestor directories. Thus a lookup from the root gives the same Mypy result as a lookup from each file under it.

Example from ds-monorepo: `libs/termtool/.venv` has `mypy` but no `ruff`, and the worktree root `.venv` has both. A file in `libs/termtool/` gets a server rooted at `libs/termtool/`. The server uses the termtool venv for Jedi and Mypy. Ruff for that file comes from the root venv.

A cache keyed by directory stores venv and tool lookups. The cache also stores "not found" results. `my/python-env-reload` clears it.

If a directory has no venv above it, the normal VC project applies. The tools then come from the fallback directory.

### Ruff

Ruff runs outside pylsp. Each Ruff run looks up `ruff` from the directory of the buffer's file, not from the server root. Each run reads the buffer from stdin, and `--stdin-filename` gives Ruff the path of the file.

- **Lint:** `my/python-env-ruff-flymake` is a Flymake backend. It runs `ruff check --output-format json` asynchronously. A new check stops the check before it.
  - Eglot replaces `flymake-diagnostic-functions` in each buffer that it manages. Thus `eglot-managed-mode-hook` adds the Ruff backend beside `eglot-flymake-backend`, and then starts Flymake again.
  - Syntax errors and Pyflakes (`F`) rules are errors. All other rules are warnings. These are the same severities as python-lsp-ruff.
  - If Ruff fails, for example on an invalid config, its message shows as an error on the first line. The next check after the fix removes it.
- **Format:** Apheleia runs two formatters on save, in this order:
  1. `my/python-env-ruff-isort`: `ruff check --select I --fix-only`, which sorts the imports.
  2. `my/python-env-ruff-format`: `ruff format`.

  Apheleia evaluates the first element of each command in the buffer, so each formatter uses the Ruff for that file.

## pylsp settings

- **Jedi:** `environment` is the nearest venv. Without a venv, Jedi uses the pylsp tool environment.
- **Ruff (python-lsp-ruff):** off.
- **Mypy (pylsp-mypy):** runs on save only (`live_mode` off). No daemon (`dmypy` off). `hover` is on. `mypy_command` is the resolved mypy. `follow-imports` is `normal`.
- **Off:** Pylint, Flake8, pyflakes, pycodestyle, mccabe, pydocstyle, isort, autopep8, and yapf. Ruff covers them.

A `.dir-locals.el` value for `eglot-workspace-configuration` replaces these settings for that directory.

## Project config

Put lint, format, and type-check policy in each project's `pyproject.toml`.

### Ruff

- Ruff uses the nearest `pyproject.toml` with `[tool.ruff]`, or a `ruff.toml`, above the file. This is the same as the CLI.
- A nested config does not merge with its parent unless it sets `extend`.
- Config edits apply on the next check.
- Lint adds `--extend-select I` for every project, also when a project has its own config.
- Lint and format pass `--force-exclude`, so Ruff skips the files that a project's `exclude` lists.
- Neither command sets `--line-length`, so `fill-column` has no effect. The line length comes from the project's config.

### Mypy

- pylsp-mypy searches upward from the server root for the first `mypy.ini`, `.mypy.ini`, `pyproject.toml` with `[tool.mypy]`, or `setup.cfg` with `[mypy]`. It passes that file with `--config-file`.
- mypy resolves relative paths in the config (for example `mypy_path = "src"`) from its working directory. That is the server root, the same as a CLI run from the project directory.
- The config is chosen for each server, not for each file. A package without its own venv joins the server of the parent venv, so its own mypy config does not apply.
- pylsp-mypy finds the config file one time, at server start. Edits to that file apply on the next save.

### Why `follow-imports` is `normal`

pylsp-mypy passes only the current file to a new mypy process on each save. By default, it adds `--follow-imports silent` to hide errors in imported modules.

mypy saves its options in `.mypy_cache`. A CLI run with the mypy default `normal` and an editor run with `silent` make each other discard the cache. Thus the package sets `normal`, the same as the CLI.

The cost: mypy also reports errors in imported modules. pylsp-mypy discards them and logs a warning for each one.

## Formatting

Apheleia formats the buffer when you save it. Apheleia keeps point in place, and then saves the formatted buffer again.

- `auto-save-visited-mode` saves through `save-buffer`. Thus Apheleia also formats a Python buffer when that mode saves it. That mode saves a buffer only if it has changes, after `auto-save-visited-interval` seconds without input.
- If you edit the buffer while Ruff runs, Apheleia discards Ruff's result.
- If Ruff fails, for example on a syntax error, Apheleia does not change the buffer. Apheleia writes Ruff's error to `*apheleia-ruff-log*`.
- `M-x apheleia-format-buffer` formats without a save.
- `eglot-format-buffer` no longer formats Python, because pylsp has no formatter turned on.

### Undo

- After a format from an auto-save, the first `C-/` undoes the format change and your last typed text together. The auto-save runs from a timer, so Emacs adds no undo boundary between them.
- After `C-x C-s`, the first `C-/` undoes only the format change. The save command adds an undo boundary after your typing.
- An auto-save can format the buffer during a pause in a series of undos. Then later `C-/` (`undo`) presses redo, and the text does not change. `C-z` (`undo-fu-only-undo`) never redoes, so it continues back through the history.

## Hover

Jedi writes the hover text. mypy has no part in it.

- **Functions:** the hover shows the signature with its annotations, for example `greet(name: str, times: int = 1) -> list[str]`.
- **Values:** the hover starts with the class of the value, then the docstring of that class. Jedi gives the class, but not its type parameters: `list`, not `list[str]`.
- **Echo area:** it shows the first line of the hover. Press `C-h .` (`eldoc-doc-buffer`) to see the full hover.

pylsp-mypy's `hover` setting gives the class line. Without `dmypy`, that setting runs no mypy. It replaces pylsp's normal hover with a different Jedi hover. pylsp's normal hover shows only the docstring of the class. In one test, it also showed the docstring of `list` for a `str` parameter.

### Why `dmypy` is off

With `dmypy`, the hover also shows the mypy type, for example `Mypy type: list[str]`. A test in ds-monorepo on 2026-10-25 showed these problems:

- In `libs/unified-directory` (mypy 1.11.2), the daemon crashed on every second check of a file, also after an edit: `RuntimeError: Max number of iterations (1000) reached`.
- The daemon does not read `.mypy_cache`. Thus each new pylsp server starts with a full check: 5 to 12 seconds in the larger projects.
- pylsp-mypy gives the daemon only the current file. After a save of another file, a return to the first file costs a new check, which took 4 seconds. Plain mypy with a warm `.mypy_cache` took less than 2 seconds in each project.
- `dmypy inspect` knows only the file of the last check. pylsp-mypy 0.8.0 also sends it a 0-based column, so no type shows on the first character of a name.
- When no daemon runs, pylsp-mypy 0.8.0 starts one with a bare `dmypy` from PATH.
- Eglot does not shut down its servers when Emacs exits, so each daemon keeps running after the exit.

## Caveats

- **Security:** pylsp-mypy honors `mypy_command` only when `PYLSP_MYPY_ALLOW_DANGEROUS_CODE_EXECUTION` is set, so the server command sets it. The variable also lets a project's `[tool.pylsp-mypy]` table choose the mypy command. The venv's own `ruff` and `mypy` also run from the project. Open only projects that you trust.
- **Old mypy results:** mypy runs only on save. On other changes, pylsp-mypy sends the last results again, while Ruff runs again. A mypy `[syntax]` error from a save in the middle of an edit stays until the next save.
- **Python version:** mypy parses for the Python version of its interpreter, unless the config sets `python_version`. Newer syntax causes a mypy `[syntax]` error in an older venv.
- **Standard library files:** these files have no venv above them. A jump into one starts a separate pylsp server with the fallback tools.

## Testing

- In a Python buffer, run `my/python-env-describe` to see the resolved tools.
- Run `M-x flymake-running-backends` to see `my/python-env-ruff-flymake` beside `eglot-flymake-backend`. Flymake writes backend errors to `*Flymake log*`.
- In `M-x eglot-events-buffer`, look at `workspace/didChangeConfiguration` for the settings that Eglot sent. The upstream `init.el` turns off the event log unless Emacs starts with `--debug-init`.
