#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
NEO4J_DIR="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "${NEO4J_DIR}/.." >/dev/null 2>&1 && pwd)"

NEO4J_VERSION="${NEO4J_VERSION:-5.20.0}"
MIN_JAVA_MAJOR="${MIN_JAVA_MAJOR:-17}"
NEO4J_JAVA_HOME="${NEO4J_JAVA_HOME:-}"
INSTALL_ROOT="${INSTALL_ROOT:-${NEO4J_DIR}/local}"
NEO4J_HOME="${NEO4J_HOME:-${INSTALL_ROOT}/neo4j-community-${NEO4J_VERSION}}"
NEO4J_TARBALL="${NEO4J_TARBALL:-}"
NEO4J_DOWNLOAD_URL="${NEO4J_DOWNLOAD_URL:-https://dist.neo4j.org/neo4j-community-${NEO4J_VERSION}-unix.tar.gz}"
CSV_SNAPSHOT_DIR="${CSV_SNAPSHOT_DIR:-/home/glaucus/workspace/dataset/bi-sf1-composite-projected-fk/graphs/csv/bi/composite-projected-fk/initial_snapshot}"
RAW_CSV_SNAPSHOT_DIR="${CSV_SNAPSHOT_DIR}"
PREPARE_CSV="${PREPARE_CSV:-auto}"
PREPARED_CSV_ROOT="${PREPARED_CSV_ROOT:-${INSTALL_ROOT}/prepared-csv}"
REFRESH_PREPARED_CSV="${REFRESH_PREPARED_CSV:-0}"
HEADER_DIR="${HEADER_DIR:-${NEO4J_DIR}/headers}"
NEO4J_DATABASE="${NEO4J_DATABASE:-neo4j}"
HEAP_MAX="${HEAP_MAX:-8g}"
PAGECACHE="${PAGECACHE:-8g}"
HTTP_PORT="${HTTP_PORT:-7474}"
BOLT_PORT="${BOLT_PORT:-7687}"
RESET_DB="${RESET_DB:-0}"
START_AFTER_IMPORT="${START_AFTER_IMPORT:-1}"
APOC_JAR="${APOC_JAR:-}"
GDS_JAR="${GDS_JAR:-}"

CSV_ROOT_DIR="$(cd "${CSV_SNAPSHOT_DIR}/.." >/dev/null 2>&1 && pwd)"

info() {
    echo "[local-neo4j] $*"
}

die() {
    echo "[local-neo4j] ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

java_major_version() {
    "$1" -version 2>&1 | awk -F '"' '/version/ {print $2}' | awk -F. '{if ($1 == "1") print $2; else print $1}'
}

is_supported_java_major() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -ge "${MIN_JAVA_MAJOR}" ]]
}

java_home_from_bin() {
    local java_bin="$1"

    if command -v readlink >/dev/null 2>&1; then
        java_bin="$(readlink -f "${java_bin}" 2>/dev/null || printf "%s" "${java_bin}")"
    fi

    if [[ "${java_bin}" == */bin/java ]]; then
        dirname "$(dirname "${java_bin}")"
    fi

    return 0
}

use_java_home() {
    local java_home="$1"
    local java_bin="${java_home}/bin/java"
    local java_major

    [[ -x "${java_bin}" ]] || return 1
    java_major="$(java_major_version "${java_bin}")"
    is_supported_java_major "${java_major}" || return 1

    export JAVA_HOME="${java_home}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    info "Using Java ${java_major}: ${JAVA_HOME}"
}

find_compatible_java_home() {
    local roots=()
    local root
    local java_bin
    local java_home
    local java_major

    for root in \
        /usr/lib/jvm \
        /opt/java \
        /opt/jdk \
        "${HOME}/.sdkman/candidates/java" \
        /Library/Java/JavaVirtualMachines
    do
        [[ -d "${root}" ]] && roots+=("${root}")
    done

    [[ "${#roots[@]}" -gt 0 ]] || return 1

    while IFS= read -r java_bin; do
        java_home="$(java_home_from_bin "${java_bin}")"
        [[ -n "${java_home}" ]] || continue
        java_major="$(java_major_version "${java_bin}")"
        if is_supported_java_major "${java_major}"; then
            printf "%s\n" "${java_home}"
            return 0
        fi
    done < <(find "${roots[@]}" -maxdepth 6 \( -path '*/bin/java' -type f -o -path '*/bin/java' -type l \) 2>/dev/null | sort -r)

    return 1
}

print_java_help() {
    cat >&2 <<EOF

Neo4j ${NEO4J_VERSION} requires Java ${MIN_JAVA_MAJOR} or newer.

If Java is not installed, install OpenJDK first. For example:
  Ubuntu/Debian:
    sudo apt update
    sudo apt install -y openjdk-17-jdk

  Fedora/RHEL:
    sudo dnf install -y java-17-openjdk-devel

  Arch:
    sudo pacman -S jdk17-openjdk

If a compatible JDK is already installed but it is not the default Java, run:
  NEO4J_JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 neo4j/scripts/install-and-import-local.sh

To check the current Java:
  java -version
EOF
}

setup_java() {
    local java_bin
    local java_home
    local java_major

    if [[ -n "${NEO4J_JAVA_HOME}" ]]; then
        if use_java_home "${NEO4J_JAVA_HOME}"; then
            return
        fi
        print_java_help
        die "NEO4J_JAVA_HOME is not a compatible JDK ${MIN_JAVA_MAJOR}+ installation: ${NEO4J_JAVA_HOME}"
    fi

    if command -v java >/dev/null 2>&1; then
        java_bin="$(command -v java)"
        java_major="$(java_major_version "${java_bin}")"
        if is_supported_java_major "${java_major}"; then
            java_home="$(java_home_from_bin "${java_bin}")"
            if [[ -n "${java_home}" ]]; then
                export JAVA_HOME="${java_home}"
                export PATH="${JAVA_HOME}/bin:${PATH}"
                info "Using Java ${java_major}: ${JAVA_HOME}"
            else
                info "Using Java ${java_major}: ${java_bin}"
            fi
            return
        fi
        info "Default Java is ${java_major:-unknown}, but Neo4j ${NEO4J_VERSION} needs Java ${MIN_JAVA_MAJOR}+."
    else
        info "Java command not found."
    fi

    if java_home="$(find_compatible_java_home)"; then
        use_java_home "${java_home}"
        return
    fi

    print_java_help
    die "No compatible Java ${MIN_JAVA_MAJOR}+ installation was found."
}

check_inputs() {
    require_command tar
    require_command awk
    require_command find
    require_command sort
    setup_java

    [[ -d "${CSV_SNAPSHOT_DIR}/static" ]] || die "Missing static directory: ${CSV_SNAPSHOT_DIR}/static"
    [[ -d "${CSV_SNAPSHOT_DIR}/dynamic" ]] || die "Missing dynamic directory: ${CSV_SNAPSHOT_DIR}/dynamic"
    [[ -d "${HEADER_DIR}/static" ]] || die "Missing header directory: ${HEADER_DIR}/static"
    [[ -d "${HEADER_DIR}/dynamic" ]] || die "Missing header directory: ${HEADER_DIR}/dynamic"
}

install_neo4j() {
    if [[ -x "${NEO4J_HOME}/bin/neo4j" && -x "${NEO4J_HOME}/bin/neo4j-admin" ]]; then
        info "Neo4j already installed: ${NEO4J_HOME}"
        return
    fi

    mkdir -p "${INSTALL_ROOT}/dist"
    local archive="${NEO4J_TARBALL}"
    if [[ -z "${archive}" ]]; then
        archive="${INSTALL_ROOT}/dist/neo4j-community-${NEO4J_VERSION}-unix.tar.gz"
        if [[ ! -f "${archive}" ]]; then
            info "Downloading Neo4j ${NEO4J_VERSION}: ${NEO4J_DOWNLOAD_URL}"
            if command -v curl >/dev/null 2>&1; then
                curl -L "${NEO4J_DOWNLOAD_URL}" -o "${archive}"
            elif command -v wget >/dev/null 2>&1; then
                wget -O "${archive}" "${NEO4J_DOWNLOAD_URL}"
            else
                die "Neither curl nor wget is available. Set NEO4J_TARBALL=/path/to/neo4j-community-${NEO4J_VERSION}-unix.tar.gz."
            fi
        fi
    fi

    [[ -f "${archive}" ]] || die "Neo4j archive not found: ${archive}"
    info "Extracting ${archive} into ${INSTALL_ROOT}"
    tar -xzf "${archive}" -C "${INSTALL_ROOT}"
    [[ -x "${NEO4J_HOME}/bin/neo4j" ]] || die "Neo4j executable not found after extraction: ${NEO4J_HOME}/bin/neo4j"
}

install_optional_plugins() {
    mkdir -p "${NEO4J_HOME}/plugins"

    if [[ -n "${APOC_JAR}" ]]; then
        [[ -f "${APOC_JAR}" ]] || die "APOC_JAR does not exist: ${APOC_JAR}"
        info "Installing APOC jar: ${APOC_JAR}"
        cp "${APOC_JAR}" "${NEO4J_HOME}/plugins/"
    fi

    if [[ -n "${GDS_JAR}" ]]; then
        [[ -f "${GDS_JAR}" ]] || die "GDS_JAR does not exist: ${GDS_JAR}"
        info "Installing GDS jar: ${GDS_JAR}"
        cp "${GDS_JAR}" "${NEO4J_HOME}/plugins/"
    fi
}

csv_has_header_rows() {
    local sample_file
    sample_file="$(find "${CSV_SNAPSHOT_DIR}" -type f \( -name 'part-*.csv' -o -name 'part-*.csv.gz' \) | sort | head -n 1)"
    [[ -n "${sample_file}" ]] || die "No part CSV files found under ${CSV_SNAPSHOT_DIR}"

    local first_line
    if [[ "${sample_file}" == *.gz ]]; then
        first_line="$(gzip -cd "${sample_file}" | head -n 1)"
    else
        first_line="$(head -n 1 "${sample_file}")"
    fi

    [[ "${first_line}" == *"|"* && ! "${first_line}" =~ ^[0-9-] ]]
}

prepare_csv_for_import() {
    local prepared_snapshot="${PREPARED_CSV_ROOT}/initial_snapshot"

    if [[ "${PREPARE_CSV}" == "0" || "${PREPARE_CSV}" == "false" ]]; then
        info "CSV preparation disabled. Importing directly from ${CSV_SNAPSHOT_DIR}"
        return
    fi

    if [[ "${PREPARE_CSV}" == "auto" ]] && ! csv_has_header_rows; then
        info "CSV files appear to be already prepared. Importing directly from ${CSV_SNAPSHOT_DIR}"
        return
    fi

    require_command python3

    if [[ -d "${prepared_snapshot}" && "${REFRESH_PREPARED_CSV}" != "1" ]]; then
        info "Using existing prepared CSV directory: ${prepared_snapshot}"
    else
        if [[ -d "${prepared_snapshot}" ]]; then
            info "Refreshing prepared CSV directory: ${prepared_snapshot}"
            rm -rf "${prepared_snapshot}"
        else
            info "Preparing CSV files for Neo4j import: ${prepared_snapshot}"
        fi

        mkdir -p "${prepared_snapshot}"
        python3 - "${CSV_SNAPSHOT_DIR}" "${prepared_snapshot}" "${HEADER_DIR}" <<'PY'
import csv
import gzip
import shutil
import sys
from pathlib import Path

src_snapshot = Path(sys.argv[1])
dst_snapshot = Path(sys.argv[2])
header_root = Path(sys.argv[3])

relationship_columns = {
    "Organisation_isLocatedIn_Place": ("OrganisationId", "PlaceId"),
    "Place_isPartOf_Place": ("Place1Id", "Place2Id"),
    "TagClass_isSubclassOf_TagClass": ("TagClass1Id", "TagClass2Id"),
    "Tag_hasType_TagClass": ("TagId", "TagClassId"),
    "Comment_hasCreator_Person": ("CommentId", "PersonId"),
    "Comment_hasTag_Tag": ("CommentId", "TagId"),
    "Comment_isLocatedIn_Country": ("CommentId", "CountryId"),
    "Comment_replyOf_Comment": ("Comment1Id", "Comment2Id"),
    "Comment_replyOf_Post": ("CommentId", "PostId"),
    "Forum_containerOf_Post": ("ForumId", "PostId"),
    "Forum_hasMember_Person": ("ForumId", "PersonId"),
    "Forum_hasModerator_Person": ("ForumId", "PersonId"),
    "Forum_hasTag_Tag": ("ForumId", "TagId"),
    "Person_hasInterest_Tag": ("personId", "interestId"),
    "Person_isLocatedIn_City": ("PersonId", "CityId"),
    "Person_knows_Person": ("Person1Id", "Person2Id"),
    "Person_likes_Comment": ("PersonId", "CommentId"),
    "Person_likes_Post": ("PersonId", "PostId"),
    "Person_studyAt_University": ("PersonId", "UniversityId"),
    "Person_workAt_Company": ("PersonId", "CompanyId"),
    "Post_hasCreator_Person": ("PostId", "PersonId"),
    "Post_hasTag_Tag": ("PostId", "TagId"),
    "Post_isLocatedIn_Country": ("PostId", "CountryId"),
}

column_aliases = {
    "speaks": "language",
}

def open_text(path, mode):
    if path.suffix == ".gz":
        return gzip.open(path, mode, newline="")
    return path.open(mode, newline="")

def target_columns(section, entity):
    header_file = header_root / section / f"{entity}.csv"
    target_header = header_file.read_text().strip().split("|")
    columns = []
    rel_pos = 0
    for token in target_header:
        if token.startswith(":LABEL"):
            columns.append("type")
        elif token.startswith(":START_ID") or token.startswith(":END_ID"):
            columns.append(relationship_columns[entity][rel_pos])
            rel_pos += 1
        else:
            name = token.split(":", 1)[0]
            columns.append(column_aliases.get(name, name))
    return columns

def transform_file(src_file, dst_file, columns):
    dst_file.parent.mkdir(parents=True, exist_ok=True)
    with open_text(src_file, "rt") as src, open_text(dst_file, "wt") as dst:
        reader = csv.reader(src, delimiter="|")
        writer = csv.writer(dst, delimiter="|", lineterminator="\n")
        try:
            source_header = next(reader)
        except StopIteration:
            return
        index = {name: pos for pos, name in enumerate(source_header)}
        missing = [name for name in columns if name not in index]
        if missing:
            raise RuntimeError(f"{src_file}: missing columns {missing}; source header is {source_header}")
        positions = [index[name] for name in columns]
        for row in reader:
            if not row:
                continue
            writer.writerow([row[pos] for pos in positions])

for section in ("static", "dynamic"):
    for entity_dir in sorted((src_snapshot / section).iterdir()):
        if not entity_dir.is_dir():
            continue
        entity = entity_dir.name
        if not (header_root / section / f"{entity}.csv").exists():
            continue
        columns = target_columns(section, entity)
        for src_file in sorted(entity_dir.glob("part-*.csv*")):
            rel = src_file.relative_to(src_snapshot)
            transform_file(src_file, dst_snapshot / rel, columns)

print(f"Prepared Neo4j CSV directory: {dst_snapshot}")
PY
    fi

    CSV_SNAPSHOT_DIR="${prepared_snapshot}"
    CSV_ROOT_DIR="$(cd "${CSV_SNAPSHOT_DIR}/.." >/dev/null 2>&1 && pwd)"
}

configure_neo4j() {
    local conf="${NEO4J_HOME}/conf/neo4j.conf"
    local tmp
    tmp="$(mktemp)"

    awk '
        /# BEGIN ldbc local config/ {skip=1; next}
        /# END ldbc local config/ {skip=0; next}
        !skip && /^[[:space:]]*(server\.default_listen_address|server\.http\.listen_address|server\.bolt\.listen_address|server\.memory\.heap\.max_size|server\.memory\.pagecache\.size|dbms\.security\.auth_enabled|server\.directories\.import|dbms\.security\.procedures\.unrestricted|dbms\.security\.procedures\.allowlist)[[:space:]]*=/ {next}
        !skip {print}
    ' "${conf}" > "${tmp}"
    cat "${tmp}" > "${conf}"
    rm -f "${tmp}"

    cat >> "${conf}" <<EOF

# BEGIN ldbc local config
server.default_listen_address=0.0.0.0
server.http.listen_address=:${HTTP_PORT}
server.bolt.listen_address=:${BOLT_PORT}
server.memory.heap.max_size=${HEAP_MAX}
server.memory.pagecache.size=${PAGECACHE}
dbms.security.auth_enabled=false
server.directories.import=${CSV_ROOT_DIR}
dbms.security.procedures.unrestricted=apoc.*,gds.*
dbms.security.procedures.allowlist=apoc.*,gds.*
# END ldbc local config
EOF
}

stop_if_running() {
    if [[ -x "${NEO4J_HOME}/bin/neo4j" ]]; then
        "${NEO4J_HOME}/bin/neo4j" stop >/dev/null 2>&1 || true
    fi
}

reset_database_if_needed() {
    local db_dir="${NEO4J_HOME}/data/databases/${NEO4J_DATABASE}"
    local tx_dir="${NEO4J_HOME}/data/transactions/${NEO4J_DATABASE}"

    if [[ -d "${db_dir}" || -d "${tx_dir}" ]]; then
        if [[ "${RESET_DB}" != "1" ]]; then
            die "Database already exists. Re-run with RESET_DB=1 to delete and re-import ${NEO4J_DATABASE}."
        fi
        info "Removing existing local database ${NEO4J_DATABASE}"
        rm -rf "${db_dir}" "${tx_dir}"
    fi
}

build_spec() {
    local section="$1"
    local entity="$2"
    local header="${HEADER_DIR}/${section}/${entity}.csv"
    local data_dir="${CSV_SNAPSHOT_DIR}/${section}/${entity}"
    local files=()

    [[ -f "${header}" ]] || die "Missing header file: ${header}"
    [[ -d "${data_dir}" ]] || die "Missing CSV entity directory: ${data_dir}"

    mapfile -t files < <(find "${data_dir}" -type f -name 'part-*.csv*' | sort)
    [[ "${#files[@]}" -gt 0 ]] || die "No part-*.csv or part-*.csv.gz files under ${data_dir}"

    printf "%s" "${header}"
    local file
    for file in "${files[@]}"; do
        printf ",%s" "${file}"
    done
}

import_database() {
    local args=(
        database import full
        --id-type=INTEGER
        --ignore-empty-strings=true
        --bad-tolerance=0
        "--nodes=Place=$(build_spec static Place)"
        "--nodes=Organisation=$(build_spec static Organisation)"
        "--nodes=TagClass=$(build_spec static TagClass)"
        "--nodes=Tag=$(build_spec static Tag)"
        "--nodes=Forum=$(build_spec dynamic Forum)"
        "--nodes=Person=$(build_spec dynamic Person)"
        "--nodes=Message:Comment=$(build_spec dynamic Comment)"
        "--nodes=Message:Post=$(build_spec dynamic Post)"
        "--relationships=IS_PART_OF=$(build_spec static Place_isPartOf_Place)"
        "--relationships=IS_SUBCLASS_OF=$(build_spec static TagClass_isSubclassOf_TagClass)"
        "--relationships=IS_LOCATED_IN=$(build_spec static Organisation_isLocatedIn_Place)"
        "--relationships=HAS_TYPE=$(build_spec static Tag_hasType_TagClass)"
        "--relationships=HAS_CREATOR=$(build_spec dynamic Comment_hasCreator_Person)"
        "--relationships=IS_LOCATED_IN=$(build_spec dynamic Comment_isLocatedIn_Country)"
        "--relationships=REPLY_OF=$(build_spec dynamic Comment_replyOf_Comment)"
        "--relationships=REPLY_OF=$(build_spec dynamic Comment_replyOf_Post)"
        "--relationships=CONTAINER_OF=$(build_spec dynamic Forum_containerOf_Post)"
        "--relationships=HAS_MEMBER=$(build_spec dynamic Forum_hasMember_Person)"
        "--relationships=HAS_MODERATOR=$(build_spec dynamic Forum_hasModerator_Person)"
        "--relationships=HAS_TAG=$(build_spec dynamic Forum_hasTag_Tag)"
        "--relationships=HAS_INTEREST=$(build_spec dynamic Person_hasInterest_Tag)"
        "--relationships=IS_LOCATED_IN=$(build_spec dynamic Person_isLocatedIn_City)"
        "--relationships=KNOWS=$(build_spec dynamic Person_knows_Person)"
        "--relationships=LIKES=$(build_spec dynamic Person_likes_Comment)"
        "--relationships=LIKES=$(build_spec dynamic Person_likes_Post)"
        "--relationships=HAS_CREATOR=$(build_spec dynamic Post_hasCreator_Person)"
        "--relationships=HAS_TAG=$(build_spec dynamic Comment_hasTag_Tag)"
        "--relationships=HAS_TAG=$(build_spec dynamic Post_hasTag_Tag)"
        "--relationships=IS_LOCATED_IN=$(build_spec dynamic Post_isLocatedIn_Country)"
        "--relationships=STUDY_AT=$(build_spec dynamic Person_studyAt_University)"
        "--relationships=WORK_AT=$(build_spec dynamic Person_workAt_Company)"
        --delimiter '|'
        "${NEO4J_DATABASE}"
    )

    info "Importing CSV snapshot into database ${NEO4J_DATABASE}"
    "${NEO4J_HOME}/bin/neo4j-admin" "${args[@]}"
}

start_database() {
    if [[ "${START_AFTER_IMPORT}" != "1" ]]; then
        return 0
    fi

    info "Starting Neo4j"
    "${NEO4J_HOME}/bin/neo4j" start

    info "Waiting for Bolt on port ${BOLT_PORT}"
    until "${NEO4J_HOME}/bin/cypher-shell" -a "bolt://localhost:${BOLT_PORT}" "RETURN 1" >/dev/null 2>&1; do
        sleep 1
        printf "."
    done
    echo
}

create_indices() {
    if [[ "${START_AFTER_IMPORT}" != "1" ]]; then
        return 0
    fi

    info "Creating indexes and constraints"
    "${NEO4J_HOME}/bin/cypher-shell" -a "bolt://localhost:${BOLT_PORT}" < "${NEO4J_DIR}/ddl/indices.cypher"
}

main() {
    info "Repository: ${REPO_ROOT}"
    info "Neo4j home: ${NEO4J_HOME}"
    info "CSV snapshot: ${RAW_CSV_SNAPSHOT_DIR}"
    info "Headers: ${HEADER_DIR}"
    check_inputs
    install_neo4j
    install_optional_plugins
    prepare_csv_for_import
    info "Import CSV snapshot: ${CSV_SNAPSHOT_DIR}"
    configure_neo4j
    stop_if_running
    reset_database_if_needed
    import_database
    start_database
    create_indices
    info "Done. Browser: http://localhost:${HTTP_PORT}, Bolt: bolt://localhost:${BOLT_PORT}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
