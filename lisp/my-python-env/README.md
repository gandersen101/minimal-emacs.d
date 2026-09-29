# my-python-env

`my-python-env` sets up Eglot and pylsp for each Python file. It uses the tools of the nearest venv above the file:

| Feature | Source | Fallback |
| --- | --- | --- |
| Jedi (xref, completion) | Nearest venv | pylsp tool environment |
| Ruff (lint + format) | Nearest venv with `bin/ruff` | `ruff` in the pylsp tool environment |
| Mypy (type check) | Nearest venv with `bin/mypy` | `mypy` in the pylsp tool environment |

A directory counts as a venv when it is named `.venv` or `venv` and contains `pyvenv.cfg`. The last fallback for each tool is `exec-path`.

The package starts Eglot only for buffers that visit a local file. Special buffers (`*scratch*`, dired, org-src edit buffers) and remote files do not start Eglot.

## Requirements

Install pylsp and its plugins in one uv tool environment:

```sh
uv tool install python-lsp-server --with python-lsp-ruff --with pylsp-mypy
```

- uv links only `pylsp` into `~/.local/bin`.
- `python-lsp-ruff` depends on `ruff`, and `pylsp-mypy` depends on `mypy`. They stay in the tool environment's `bin/` directory, off PATH. The package finds them through `my/python-env-fallback-bin`.
- `uv tool upgrade python-lsp-server` upgrades all four packages together.
- To also get `ruff` and `mypy` in the shell, add `--with-executables-from ruff,mypy`.

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

pylsp settings apply to a whole workspace, not to one file. Eglot starts one server for each `project.el` project. Thus the package changes what "project" means for Eglot only:

1. Eglot binds `eglot-lsp-context` to `t` while it looks up the project for a buffer.
2. `my/python-env-project-find` runs before `project-try-vc` in `project-find-functions`. In the Eglot context, it returns a project rooted at the directory that holds the nearest venv.
3. Other lookups (`C-x p`, consult, etc.) keep the normal VC project.
4. Eglot computes the workspace configuration with `default-directory` set to the server root. `my/python-env-workspace-configuration` builds the pylsp settings for that root.

Each venv root gets its own pylsp process. All files under a root have the same ancestor directories. Thus a lookup from the root gives the same Ruff and Mypy result as a lookup from each file under it.

Example from ds-monorepo: `libs/termtool/.venv` has `mypy` but no `ruff`, and the worktree root `.venv` has both. A file in `libs/termtool/` gets a server rooted at `libs/termtool/`. The server uses the termtool venv for Jedi and Mypy, and the root venv's Ruff.

A cache keyed by directory stores venv and tool lookups. The cache also stores "not found" results. `my/python-env-reload` clears it.

If a directory has no venv above it, the normal VC project applies. The tools then come from the fallback directory.

## pylsp settings

- **Jedi:** `environment` is the nearest venv. Without a venv, Jedi uses the pylsp tool environment.
- **Ruff:** lint and format are on. The package sets `executable`, `extendSelect ["I"]`, and `format ["I"]`.
- **Mypy (pylsp-mypy):** runs on save only (`live_mode` off). No daemon (`dmypy` off). `mypy_command` is the resolved mypy. `follow-imports` is `normal`.
- **Off:** Pylint, Flake8, pyflakes, pycodestyle, mccabe, pydocstyle, isort, autopep8, and yapf. Ruff covers them.

A `.dir-locals.el` value for `eglot-workspace-configuration` replaces these settings for that directory.

## Project config

Put lint, format, and type-check policy in each project's `pyproject.toml`.

### Ruff

- pylsp-ruff gives Ruff the file path. Ruff uses the nearest `pyproject.toml` with `[tool.ruff]`, or a `ruff.toml`, the same as the CLI.
- A nested config does not merge with its parent unless it sets `extend`.
- Config edits apply on the next check.
- `extendSelect ["I"]` and `format ["I"]` apply to every project, also when a project has its own config.

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

`M-x eglot-format-buffer` runs `ruff format`, then `ruff check --fix` with only the `I` rules (import sorting).

- Nothing formats on save.
- pylsp-ruff formats only the whole document, so region formatting probably does nothing.

## Caveats

- **Security:** pylsp-mypy honors `mypy_command` only when `PYLSP_MYPY_ALLOW_DANGEROUS_CODE_EXECUTION` is set, so the server command sets it. The variable also lets a project's `[tool.pylsp-mypy]` table choose the mypy command. The venv's own `ruff` and `mypy` also run from the project. Open only projects that you trust.
- **Old mypy results:** mypy runs only on save. On other changes, pylsp-mypy sends the last results again, while Ruff runs again. A mypy `[syntax]` error from a save in the middle of an edit stays until the next save.
- **Python version:** mypy parses for the Python version of its interpreter, unless the config sets `python_version`. Newer syntax causes a mypy `[syntax]` error in an older venv.
- **Standard library files:** these files have no venv above them. A jump into one starts a separate pylsp server with the fallback tools.

## Testing

- In a Python buffer, run `my/python-env-describe` to see the resolved tools.
- In `M-x eglot-events-buffer`, look at `workspace/didChangeConfiguration` for the settings that Eglot sent.
