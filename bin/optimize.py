#!/usr/bin/env python3
# -* encoding: utf8 *-

import argparse
import sys
import yaml

# ---------------------------------------------------------------------------
# TRACKED CHANGE (E): stdlib re by default, optional fallback to third-party regex
#
# If we discover environments where `re` matching differs (unlikely given current
# patterns), flip USE_THIRD_PARTY_REGEX = True to revert behavior.
# ---------------------------------------------------------------------------
USE_THIRD_PARTY_REGEX = False

if USE_THIRD_PARTY_REGEX:
    import regex as re  # type: ignore
else:
    import re  # stdlib


# ---------------------------------------------------------------------------
# SAFETY SWITCH: prevent rewriting requirements.yml
#
# Commenting out the write to dst-requirements is the only way to ensure this
# script does NOT refresh/overwrite requirements.yml.
#
# If/when you want requirements.yml to be generated again, set to True.
# ---------------------------------------------------------------------------
WRITE_DST_REQUIREMENTS_YML = False


parser = argparse.ArgumentParser(
    description="Optimizes the playbook based on enabled components found in vars.yml files"
)
parser.add_argument("--vars-paths", help="Path to vars.yml configuration files to process", required=True)
parser.add_argument("--src-requirements-yml-path", help="Path to source requirements.yml file with all role definitions", required=True)
parser.add_argument("--src-setup-yml-path", help="Path to source setup.yml file", required=True)
parser.add_argument("--src-group-vars-yml-path", help="Path to source group vars file", required=True)
parser.add_argument("--dst-requirements-yml-path", help="Path to destination requirements.yml file, where role definitions will be saved", required=True)
parser.add_argument("--dst-setup-yml-path", help="Path to destination setup.yml file", required=True)
parser.add_argument("--dst-group-vars-yml-path", help="Path to destination group vars file", required=True)

args = parser.parse_args()


def load_yaml_file(path):
    with open(path, "r", encoding="utf-8") as file:
        return yaml.safe_load(file)


# (B) robust vars.yml load: handle empty files and validate structure
def load_combined_variable_names_from_files(vars_yml_file_paths):
    variable_names = set()
    for vars_path in vars_yml_file_paths:
        with open(vars_path, "r", encoding="utf-8") as file:
            yaml_data = yaml.safe_load(file) or {}

            # We only use top-level keys as "variable names" (intended behavior)
            if not isinstance(yaml_data, dict):
                raise Exception(
                    f"Vars file {vars_path} did not parse to a YAML mapping/dict. Got: {type(yaml_data)}"
                )

            variable_names |= set(yaml_data.keys())

    return variable_names


# (H) This is on purpose:
# - if activation_prefix is missing => role is NOT enabled
# (C) simplified + short-circuit
def is_role_definition_in_use(role_definition, used_variable_names):
    prefix = role_definition.get("activation_prefix", None)
    if prefix is None:
        return False

    if prefix == "":
        # Special value indicating "always activate".
        return True

    return any(var_name.startswith(prefix) for var_name in used_variable_names)


# (D) stable YAML output; avoid reordering keys
def write_yaml_to_file(definitions, path):
    with open(path, "w", encoding="utf-8") as file:
        yaml.safe_dump(
            definitions,
            file,
            sort_keys=False,
            default_flow_style=False,
        )


def read_file(path):
    with open(path, "r", encoding="utf-8") as file:
        return file.read()


def write_to_file(contents, path):
    with open(path, "w", encoding="utf-8") as file:
        file.write(contents)


# Matches the beginning of role-specific blocks.
# Example: `# role-specific:playbook_help`
regex_role_specific_block_start = re.compile(r"^\s*#\s*role-specific:\s*([^\s]+)$")

# Matches the end of role-specific blocks.
# Example: `# /role-specific:playbook_help`
regex_role_specific_block_end = re.compile(r"^\s*#\s*/role-specific:\s*([^\s]+)$")


# (F) simplified: one pass, 1-based line numbers, inline blank-line compaction
# (G) use sets for enabled_role_names / known_role_names membership checks
def process_file_contents(file_name, enabled_role_names_set, known_role_names_set):
    contents = read_file(file_name)

    role_specific_stack = []
    out_lines = []
    sequential_blank_lines_count = 0

    # enumerate(..., start=1) for human-friendly line numbers
    for line_number, line in enumerate(contents.split("\n"), start=1):
        # Stage 1: role-specific start
        start_match = regex_role_specific_block_start.match(line)
        if start_match is not None:
            role_name = start_match.group(1)
            if role_name not in known_role_names_set:
                raise Exception(
                    "Found start block for role {0} on line {1} in file {2}, but it is not a known role name found among: {3}".format(
                        role_name,
                        line_number,
                        file_name,
                        sorted(known_role_names_set),
                    )
                )
            role_specific_stack.append(role_name)
            continue

        # Stage 2: role-specific end
        end_match = regex_role_specific_block_end.match(line)
        if end_match is not None:
            role_name = end_match.group(1)
            if role_name not in known_role_names_set:
                raise Exception(
                    "Found end block for role {0} on line {1} in file {2}, but it is not a known role name found among: {3}".format(
                        role_name,
                        line_number,
                        file_name,
                        sorted(known_role_names_set),
                    )
                )

            if len(role_specific_stack) == 0:
                raise Exception(
                    "Found end block for role {0} on line {1} in file {2}, but there is no opening statement for it".format(
                        role_name,
                        line_number,
                        file_name,
                    )
                )

            last_role_name = role_specific_stack[-1]
            if role_name != last_role_name:
                raise Exception(
                    "Found end block for role {0} on line {1} in file {2}, but the last starting block was for role {3}".format(
                        role_name,
                        line_number,
                        file_name,
                        last_role_name,
                    )
                )

            role_specific_stack.pop()
            continue

        # Stage 3: regular line
        # Preserve only if ALL roles in stack are enabled
        if any(role_name not in enabled_role_names_set for role_name in role_specific_stack):
            continue

        # Blank-line compaction (keep at most 2 sequential blank lines)
        if line == "":
            if sequential_blank_lines_count <= 1:
                out_lines.append(line)
                sequential_blank_lines_count += 1
            # else drop
        else:
            out_lines.append(line)
            sequential_blank_lines_count = 0

    if len(role_specific_stack) != 0:
        raise Exception(
            "Expected one or more closing block for role-specific tags in file {0}: {1}".format(
                file_name, role_specific_stack
            )
        )

    return "\n".join(out_lines)


# (A) whitespace-safe split
vars_paths = args.vars_paths.split()
used_variable_names = load_combined_variable_names_from_files(vars_paths)

all_role_definitions = load_yaml_file(args.src_requirements_yml_path)
if all_role_definitions is None:
    raise Exception(f"Source requirements.yml parsed as empty: {args.src_requirements_yml_path}")
if not isinstance(all_role_definitions, list):
    raise Exception(
        f"Source requirements.yml must be a YAML list. Got: {type(all_role_definitions)} from {args.src_requirements_yml_path}"
    )

enabled_role_definitions = []
for role_definition in all_role_definitions:
    if not isinstance(role_definition, dict):
        raise Exception(f"Role definition must be a dict, got {type(role_definition)}: {role_definition}")

    if "name" not in role_definition:
        raise Exception("Role definition does not have a name and should be adjusted to have one: {0}".format(role_definition))

    if is_role_definition_in_use(role_definition, used_variable_names):
        enabled_role_definitions.append(role_definition)

# (G) sets for membership checks
known_role_names = {definition["name"] for definition in all_role_definitions}
enabled_role_names = {definition["name"] for definition in enabled_role_definitions}

# ---------------------------------------------------------------------------
# REQUIREMENTS REFRESH IS DISABLED (requested)
# ---------------------------------------------------------------------------
# write_yaml_to_file(enabled_role_definitions, args.dst_requirements_yml_path)

# If you need visibility during runs without writing, you can optionally print:
# print(f"[INFO] Enabled roles: {sorted(enabled_role_names)}", file=sys.stderr)

setup_yml_processed = process_file_contents(args.src_setup_yml_path, enabled_role_names, known_role_names)
write_to_file(setup_yml_processed, args.dst_setup_yml_path)

group_vars_yml_processed = process_file_contents(args.src_group_vars_yml_path, enabled_role_names, known_role_names)
write_to_file(group_vars_yml_processed, args.dst_group_vars_yml_path)
