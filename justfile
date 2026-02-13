# Shows help
default:
    @{{ just_executable() }} --list --justfile {{ justfile() }}

# Paths
ROOT := justfile_directory()
RUN_DIR := ROOT + "/run"
TEMPLATES_DIR := ROOT + "/templates"
OPT_STATE := RUN_DIR + "/optimization-vars-files.state"

# Convenience: invoke this justfile explicitly
JUST := just_executable() + " --justfile " + justfile()

# -----------------------------
# Roles / updates
# -----------------------------

# Pulls external Ansible roles
roles: _requirements-yml
    #!/usr/bin/env sh
    set -eu

    if command -v agru >/dev/null 2>&1; then
        echo "[NOTE] This command just updates the roles, but if you want to update everything at once (playbook, roles, etc.) - use 'just update'"
        agru -r "{{ ROOT }}/requirements.yml"
    else
        echo "[NOTE] You are using the standard ansible-galaxy tool to install roles, which is slow and lacks other features. We recommend installing the 'agru' tool to speed up the process: https://github.com/etkecc/agru#where-to-get"
        echo "[NOTE] This command just updates the roles, but if you want to update everything at once (playbook, roles, etc.) - use 'just update'"
        rm -rf roles/galaxy
        ansible-galaxy install -r "{{ ROOT }}/requirements.yml" -p roles/galaxy/ --force
    fi

# Updates the playbook and installs the necessary Ansible roles pinned in requirements.yml.
# If -u is passed, updates requirements.yml with new role versions (if available)
update *flags: _requirements-yml update-playbook-only
    #!/usr/bin/env sh
    set -eu

    if command -v agru >/dev/null 2>&1; then
        case "{{ flags }}" in
            "")  echo "Installing roles pinned in requirements.yml..." ;;
            "-u") echo "Updating roles and pinning new versions in requirements.yml..." ;;
            *)   echo "Unknown flags passed: {{ flags }}" ;;
        esac
        agru -r "{{ ROOT }}/requirements.yml" {{ flags }}
    else
        echo "[NOTE] You are using the standard ansible-galaxy tool to install roles, which is slow and lacks other features. We recommend installing the 'agru' tool to speed up the process: https://github.com/etkecc/agru#where-to-get"
        echo "Installing roles..."
        rm -rf roles/galaxy
        ansible-galaxy install -r "{{ ROOT }}/requirements.yml" -p roles/galaxy/ --force
    fi

    if [ "{{ flags }}" = "-u" ]; then
        {{ JUST }} versions
        {{ JUST }} opml
    fi

# Updates the playbook without installing/updating Ansible roles
# NOTE: Git operations temporarily disabled to prevent requirements.yml refresh.
# Re-enable if repository sync is needed.
update-playbook-only:
    @echo "Updating playbook..."
    @echo "[INFO] Git operations disabled (stash/pull/pop skipped)."

    # @git stash -q
    # @git pull -q
    # @-git stash pop -q

# -----------------------------
# Optimization
# -----------------------------

# Optimizes the playbook based on stored configuration (vars.yml paths)
optimize-restore:
    #!/usr/bin/env sh
    set -eu

    if [ -f "{{ OPT_STATE }}" ]; then
        {{ JUST }} _optimize-for-var-paths $(cat "{{ OPT_STATE }}")
    else
        echo "Cannot restore optimization state from a file ({{ OPT_STATE }}), because it doesn't exist"
        exit 1
    fi

# Clears optimizations and resets the playbook to a non-optimized state
optimize-reset: && _clean_template_derived_files
    #!/usr/bin/env sh
    set -eu

    rm -f "{{ RUN_DIR }}"/*.srchash
    rm -f "{{ OPT_STATE }}"

# Optimizes the playbook based on the enabled components for all hosts in the inventory
# IMPORTANT: dependency list must only contain recipe names (no var tokens)
optimize inventory_path='inventory': _reconfigure-for-all-hosts

_reconfigure-for-all-hosts inventory_path='inventory':
    #!/usr/bin/env sh
    set -eu

    {{ JUST }} _optimize-for-var-paths \
        $(find "{{ inventory_path }}/host_vars/" -maxdepth 2 -name 'vars.yml' -exec readlink -f {} \;)

# Optimizes the playbook based on the enabled components for a single host
optimize-for-host hostname inventory_path='inventory':
    #!/usr/bin/env sh
    set -eu

    {{ JUST }} _optimize-for-var-paths \
        $(find "{{ inventory_path }}/host_vars/{{ hostname }}" -maxdepth 1 -name 'vars.yml' -exec readlink -f {} \;)

# Optimizes the playbook based on the enabled components found in the given vars.yml files
_optimize-for-var-paths +PATHS:
    #!/usr/bin/env sh
    set -eu

    mkdir -p "{{ RUN_DIR }}"
    echo '{{ PATHS }}' > "{{ OPT_STATE }}"

    {{ JUST }} _save_hash_for_file "{{ TEMPLATES_DIR }}/requirements.yml" "{{ ROOT }}/requirements.yml"
    {{ JUST }} _save_hash_for_file "{{ TEMPLATES_DIR }}/setup.yml" "{{ ROOT }}/setup.yml"
    {{ JUST }} _save_hash_for_file "{{ TEMPLATES_DIR }}/group_vars_mash_servers" "{{ ROOT }}/group_vars/mash_servers"

    /usr/bin/env python "{{ ROOT }}/bin/optimize.py" \
        --vars-paths='{{ PATHS }}' \
        --src-requirements-yml-path="{{ TEMPLATES_DIR }}/requirements.yml" \
        --dst-requirements-yml-path="{{ ROOT }}/requirements.yml" \
        --src-setup-yml-path="{{ TEMPLATES_DIR }}/setup.yml" \
        --dst-setup-yml-path="{{ ROOT }}/setup.yml" \
        --src-group-vars-yml-path="{{ TEMPLATES_DIR }}/group_vars_mash_servers" \
        --dst-group-vars-yml-path="{{ ROOT }}/group_vars/mash_servers"

# -----------------------------
# Lint / metadata
# -----------------------------

lint:
    ansible-lint

opml:
    @echo "generating opml..."
    @python bin/feeds.py . dump

versions:
    @echo "generating versions..."
    @python bin/versions.py

# -----------------------------
# Playbook entrypoints
# -----------------------------

install-all *extra_args: (run-tags "install-all,start" extra_args)
setup-all *extra_args: (run-tags "setup-all,start" extra_args)

install-service service *extra_args:
    {{ JUST }} _run-service "install" {{ service }} {{ extra_args }}

setup-service service *extra_args:
    {{ JUST }} _run-service "setup" {{ service }} {{ extra_args }}

# Runs the playbook with the given list of arguments
run +extra_args: _requirements-yml _setup-yml _group-vars-mash-servers
    ansible-playbook -i inventory/hosts setup.yml {{ extra_args }}

run-tags tags *extra_args:
    {{ JUST }} run --tags={{ tags }} {{ extra_args }}

start-all *extra_args: (run-tags "start-all" extra_args)
stop-all  *extra_args: (run-tags "stop-all" extra_args)

start-group group *extra_args:
    @{{ JUST }} run-tags start-group --extra-vars="group={{ group }}" {{ extra_args }}

stop-group group *extra_args:
    @{{ JUST }} run-tags stop-group --extra-vars="group={{ group }}" {{ extra_args }}

# Shared helper for install/setup-service
_run-service phase service *extra_args:
    {{ JUST }} run \
        --tags={{ phase }}-{{ service }},start-group \
        --extra-vars=group={{ service }} \
        --extra-vars=systemd_service_manager_service_restart_mode=one-by-one {{ extra_args }}

# -----------------------------
# Template-derived files
# -----------------------------

# Prepares the requirements.yml file (COPY ONLY IF MISSING)
_requirements-yml:
    @{{ JUST }} _ensure_file_exists "{{ TEMPLATES_DIR }}/requirements.yml" "{{ ROOT }}/requirements.yml"

# Prepares the setup.yml file (COPY ONLY IF MISSING)
_setup-yml:
    @{{ JUST }} _ensure_file_exists "{{ TEMPLATES_DIR }}/setup.yml" "{{ ROOT }}/setup.yml"

# Prepares the group_vars/mash_servers file (COPY ONLY IF MISSING)
_group-vars-mash-servers:
    @{{ JUST }} _ensure_file_exists "{{ TEMPLATES_DIR }}/group_vars_mash_servers" "{{ ROOT }}/group_vars/mash_servers"

# Copies src -> dst only if dst does not exist. Does NOT overwrite on template changes.
# Writes/updates a .srchash for visibility/debugging.
_ensure_file_exists src_path dst_path:
    #!/usr/bin/env sh
    set -eu

    mkdir -p "{{ RUN_DIR }}"
    dst_file_name=$(basename "{{ dst_path }}")
    hash_path="{{ RUN_DIR }}/${dst_file_name}.srchash"
    src_hash=$(md5sum "{{ src_path }}" | awk '{print $1}')

    if [ ! -f "{{ dst_path }}" ]; then
        cp "{{ src_path }}" "{{ dst_path }}"
        echo "$src_hash" > "$hash_path"
    else
        # dst exists; do not overwrite
        echo "$src_hash" > "$hash_path"
    fi

_save_hash_for_file src_path dst_path:
    #!/usr/bin/env sh
    set -eu

    mkdir -p "{{ RUN_DIR }}"
    dst_file_name=$(basename "{{ dst_path }}")
    hash_path="{{ RUN_DIR }}/${dst_file_name}.srchash"
    src_hash=$(md5sum "{{ src_path }}" | awk '{print $1}')
    echo "$src_hash" > "$hash_path"

_clean_template_derived_files:
    #!/usr/bin/env sh
    set -eu

    rm -f "{{ ROOT }}/requirements.yml"
    rm -f "{{ ROOT }}/setup.yml"
    rm -f "{{ ROOT }}/group_vars/mash_servers"
