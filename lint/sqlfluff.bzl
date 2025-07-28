"""API for declaring a sqlfluff lint aspect that visits sql files.

Typical usage:

First, fetch the sqlfluff package via your standard requirements file and pip calls.

Then, declare a binary target for it, typically in `tools/lint/BUILD.bazel`:

```starlark
load("@rules_python//python/entry_points:py_console_script_binary.bzl", "py_console_script_binary")
py_console_script_binary(
    name = "sqlfluff
    pkg = "@pip//sqlfluff:pkg",
)
```

Finally, create the linter aspect, typically in `tools/lint/linters.bzl`:

```starlark
load("@aspect_rules_lint//lint:sqlfluff.bzl", "lint_flake8_aspect")

sqlfluff = lint_flake8_aspect(
    binary = "@@//tools/lint:sqlfluff",
    config = ["@@//:.sqlfluff"],
)
```
"""

load("//lint/private:lint_aspect.bzl", "LintOptionsInfo", "OPTIONAL_SARIF_PARSER_TOOLCHAIN", "OUTFILE_FORMAT", "filter_srcs", "noop_lint_action", "output_files", "parse_to_sarif_action", "should_visit")

_MNEMONIC = "AspectRulesLintSQLFluff"

def sqlfluff_action(ctx, executable, srcs, config, stdout, exit_code = None, options = []):
    """Run sqlfluff as an action under Bazel.

    Based on https://sqlfluff.pycqa.org/en/latest/user/invocation.html

    Args:
        ctx: Bazel Rule or Aspect evaluation context
        executable: label of the the sqlfluff program
        srcs: python files to be linted
        config: labels of the sqlfluff config files (setup.cfg, tox.ini, pep8.ini, .sqlfluff, pyproject.toml)
        stdout: output file containing stdout of sqlfluff
        exit_code: output file containing exit code of sqlfluff
            If None, then fail the build when sqlfluff exits non-zero.
        options: command-line options to pass to sqlfluff
    """
    inputs = srcs + config
    outputs = [stdout]

    # Wire command-line options, see
    # https://docs.sqlfluff.com/en/stable/reference/cli.html#cliref
    #
    # sqlfluff needs a config file, but it's not passed as a command-line argument.
    # By naming it as an input Bazel will ensure it is available in the action's sandbox.
    args = ctx.actions.args()
    args.add("lint")
    args.add_all(options)
    args.add_all(srcs)

    if exit_code:
        command = "{sqlfluff} $@ 2>{stdout}; echo $? > " + exit_code.path
        outputs.append(exit_code)
    else:
        # Create empty file on success, as Bazel expects one
        command = "{sqlfluff} $@ && touch {stdout}"

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outputs,
        tools = [executable],
        command = command.format(sqlfluff = executable.path, stdout = stdout.path),
        arguments = [args],
        mnemonic = _MNEMONIC,
        progress_message = "Linting %{label} with SQLFluff",
    )

# buildifier: disable=function-docstring
def _sqlfluff_aspect_impl(target, ctx):
    if not should_visit(ctx.rule, [], ctx.attr._filegroup_tags):
        return []

    outputs, info = output_files(_MNEMONIC, target, ctx)

    files_to_lint = filter_srcs(ctx.rule)

    if len(files_to_lint) == 0:
        # No files to lint, so just return the info
        noop_lint_action(ctx, outputs)
        return [info]

    # https://docs.sqlfluff.com/en/stable/reference/cli.html#cliref
    color_options = ["--color"] if ctx.attr._options[LintOptionsInfo].color else ["--nocolor"]
    sqlfluff_action(ctx, ctx.executable._sqlfluff, files_to_lint, ctx.files._config_files, outputs.human.out, outputs.human.exit_code, color_options)
    raw_machine_report = ctx.actions.declare_file(OUTFILE_FORMAT.format(label = target.label.name, mnemonic = _MNEMONIC, suffix = "raw_machine_report"))
    sqlfluff_action(ctx, ctx.executable._sqlfluff, files_to_lint, ctx.files._config_files, raw_machine_report, outputs.machine.exit_code)
    parse_to_sarif_action(ctx, _MNEMONIC, raw_machine_report, outputs.machine.out)
    return [info]

def lint_sqlfluff_aspect(binary, configs, filegroup_tags = ["lint-with-sqlfluff"]):
    """A factory function to create a linter aspect.

    Attrs:
        binary: a sqlfluff executable. Can be obtained from rules_python like so:

            ```
            load("@rules_python//python/entry_points:py_console_script_binary.bzl", "py_console_script_binary")

            py_console_script_binary(
                name = "sqlfluff",
                pkg = "@pip//sqlfluff:pkg",
            )
            ```

        config: label(s) for the sqlfluff config file (setup.cfg, tox.ini, pep8.ini, .sqlfluff, pyproject.toml)
        filegroup_tags: tags to filter the files to be linted.
            Defaults to `["lint-with-sqlfluff"]`, which is the default tag for sqlfluff files in this repo.
    """

    if type(configs) == "string":
        configs = [configs]

    return aspect(
        implementation = _sqlfluff_aspect_impl,
        # Edges we need to walk up the graph from the selected targets.
        # Needed for linters that need semantic information like transitive type declarations.
        # attr_aspects = ["deps"],
        attrs = {
            "_options": attr.label(
                default = "//lint:options",
                providers = [LintOptionsInfo],
            ),
            "_sqlfluff": attr.label(
                default = binary,
                executable = True,
                cfg = "exec",
            ),
            "_config_files": attr.label_list(
                default = configs,
                allow_files = True,
            ),
            "_filegroup_tags": attr.string_list(
                default = filegroup_tags,
                doc = "Tags to filter the files to be linted. Defaults to ['lint-with-sqlfluff'].",
            ),
        },
        toolchains = [OPTIONAL_SARIF_PARSER_TOOLCHAIN],
    )
