#!/usr/bin/env bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

usage() {
    cat <<'EOF'
Import and run LDBC SNB BI SF1 queries on local Neo4j 5.20.0.

Usage:
  neo4j/scripts/run-bi-sf1-local.sh [options]

Options:
  --queries LIST       Queries to run. Defaults to all BI queries.
                       Accepts forms such as "all", "1,3,15,19", "15a 19b".
  --sf SF              Scale factor. Default: 1.
  --csv-dir PATH       CSV directory. May be either the directory containing
                       initial_snapshot/ or initial_snapshot/ itself.
                       Default:
                       ~/workspace/dataset/ldbc/data/bi/bi-sf1-composite-projected-fk/graphs/csv/bi/composite-projected-fk/initial_snapshot
  --parameter-dir PATH Directory containing bi-*.csv parameter files.
                       Default:
                       ~/workspace/dataset/ldbc/parameters/bi_parameters/bi-parameters-sf1
  --prepared-csv-dir PATH
                       Destination for an auto-prepared no-header CSV copy.
                       Default: neo4j/local/prepared-csv/bi-sf1-composite-projected-fk
  --prepared-header-dir PATH
                       Destination for generated Neo4j headers matching CSV order.
                       Default: neo4j/local/prepared-headers/bi-sf1-composite-projected-fk
  --no-prepare-csv     Do not auto-remove CSV headers before import.
  --memory SIZE        Set both Neo4j heap max and page cache, e.g. 20G.
  --worker-threads N   Set Neo4j server.threads.worker_count for container start.
  --http-port PORT     Host HTTP port for Neo4j Browser. Default: 7474.
  --bolt-port PORT     Host Bolt port for benchmark queries. Default: 7687.
  --python PATH        Python executable for the Neo4j benchmark driver.
  --neo4j-version VER  Neo4j Docker image version. Default: 5.20.0.
  --mode MODE          test, regular, pgtuning, or all-parameters.
                       Default: all-parameters.
  --parameter-count N  Run at most N parameter rows per query variant and
                       report average execution time.
  --skip-load          Do not import data; start existing database if needed.
  --no-start           Do not start Neo4j before running queries.
  --install-deps       Install Python dependencies used by the benchmark.
  --dry-run            Print the resolved command without executing it.
  -h, --help           Show this help.

Special query choices:
  BI15 uses bi-15-without-date.cypher and bi-15*-without-date.csv when those
  parameter files exist.
  BI19 uses bi-19-without-precomputation.cypher.
EOF
}

expand_path() {
    local path="$1"
    case "${path}" in
        "~")
            printf '%s\n' "${HOME}"
            ;;
        "~/"*)
            printf '%s/%s\n' "${HOME}" "${path#\~/}"
            ;;
        *)
            printf '%s\n' "${path}"
            ;;
    esac
}

absolute_path() {
    local path="$1"
    if [[ "${path}" = /* ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s/%s\n' "$(pwd)" "${path}"
    fi
}

csv_has_headers() {
    local csv_dir="$1"
    local sample_file
    sample_file="$(find "${csv_dir}/initial_snapshot/static/Place" -type f -name 'part-*.csv' -print -quit)"
    if [[ -z "${sample_file}" ]]; then
        return 1
    fi

    IFS= read -r first_line < "${sample_file}"
    [[ "${first_line}" == id\|name\|url\|type ]]
}

csv_header_fingerprint() {
    local csv_dir="$1"
    local sample_file
    sample_file="$(find "${csv_dir}/initial_snapshot/dynamic/Person" -type f -name 'part-*.csv' -print -quit)"
    if [[ -z "${sample_file}" ]]; then
        sample_file="$(find "${csv_dir}/initial_snapshot/static/Place" -type f -name 'part-*.csv' -print -quit)"
    fi
    if [[ -z "${sample_file}" ]]; then
        printf '%s\n' "unknown"
        return
    fi

    IFS= read -r first_line < "${sample_file}"
    printf '%s' "${first_line}" | sha256sum | awk '{print substr($1, 1, 12)}'
}

python_has_benchmark_deps() {
    local python_bin="$1"
    "${python_bin}" -c 'import dateutil; from neo4j import GraphDatabase' >/dev/null 2>&1
}

resolve_python() {
    if [[ -n "${NEO4J_PYTHON:-}" ]]; then
        printf '%s\n' "${NEO4J_PYTHON}"
        return
    fi

    local candidates=()
    candidates+=("python3")
    candidates+=("${HOME}/miniconda3/bin/python3")
    candidates+=("${HOME}/.pyenv/versions/ldbc_datagen_tools/bin/python3")

    local candidate
    for candidate in "${candidates[@]}"; do
        if command -v "${candidate}" >/dev/null 2>&1 && python_has_benchmark_deps "${candidate}"; then
            printf '%s\n' "${candidate}"
            return
        fi
    done

    printf '%s\n' "python3"
}

add_variant() {
    local variant="$1"
    local base="${variant%%-*}"
    local resolved="${variant}"

    if [[ "${base}" == 15* && "${variant}" != *without-date* ]]; then
        if [[ -f "${PARAMETER_DIR}/bi-${base}-without-date.csv" ]]; then
            resolved="${base}-without-date"
        fi
    fi

    if [[ "${base}" == 19* && "${variant}" != *without-precomputation* ]]; then
        resolved="${base}-without-precomputation"
    fi

    QUERY_VARIANTS+=("${resolved}")
}

expand_query_token() {
    local token="$1"
    token="${token#bi-}"
    token="${token#bi}"

    case "${token}" in
        all)
            local default_variants=(1 2a 2b 3 4 5 6 7 8a 8b 9 10a 10b 11 12 13 14a 14b 15a 15b 16a 16b 17 18 19a 19b 20a 20b)
            local variant
            for variant in "${default_variants[@]}"; do
                add_variant "${variant}"
            done
            ;;
        2|8|10|14|15|16|19|20)
            add_variant "${token}a"
            add_variant "${token}b"
            ;;
        *)
            add_variant "${token}"
            ;;
    esac
}

SF=1
CSV_DIR="~/workspace/dataset/ldbc/data/bi/bi-sf1-composite-projected-fk/graphs/csv/bi/composite-projected-fk/initial_snapshot"
PARAMETER_DIR="~/workspace/dataset/ldbc/parameters/bi_parameters/bi-parameters-sf1"
PREPARED_CSV_DIR="local/prepared-csv/bi-sf1-composite-projected-fk"
PREPARED_HEADER_DIR="local/prepared-headers/bi-sf1-composite-projected-fk"
PREPARED_CSV_DIR_SET=false
PREPARED_HEADER_DIR_SET=false
QUERY_LIST="all"
MODE="all-parameters"
LOAD=true
START=true
INSTALL_DEPS=false
DRY_RUN=false
PREPARE_CSV=true
MEMORY=""
WORKER_THREADS=""
HTTP_PORT=""
BOLT_PORT=""
PYTHON_BIN=""
PARAMETER_COUNT=""
export NEO4J_VERSION="${NEO4J_VERSION:-5.20.0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --queries)
            QUERY_LIST="$2"
            shift 2
            ;;
        --sf)
            SF="$2"
            shift 2
            ;;
        --csv-dir)
            CSV_DIR="$2"
            shift 2
            ;;
        --parameter-dir)
            PARAMETER_DIR="$2"
            shift 2
            ;;
        --prepared-csv-dir)
            PREPARED_CSV_DIR="$2"
            PREPARED_CSV_DIR_SET=true
            shift 2
            ;;
        --prepared-header-dir)
            PREPARED_HEADER_DIR="$2"
            PREPARED_HEADER_DIR_SET=true
            shift 2
            ;;
        --no-prepare-csv)
            PREPARE_CSV=false
            shift
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --worker-threads)
            WORKER_THREADS="$2"
            shift 2
            ;;
        --http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --bolt-port)
            BOLT_PORT="$2"
            shift 2
            ;;
        --python)
            PYTHON_BIN="$2"
            shift 2
            ;;
        --neo4j-version)
            export NEO4J_VERSION="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --parameter-count)
            PARAMETER_COUNT="$2"
            shift 2
            ;;
        --skip-load)
            LOAD=false
            shift
            ;;
        --no-start)
            START=false
            shift
            ;;
        --install-deps)
            INSTALL_DEPS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

CSV_DIR="$(expand_path "${CSV_DIR}")"
PARAMETER_DIR="$(expand_path "${PARAMETER_DIR}")"
PREPARED_CSV_DIR="$(expand_path "${PREPARED_CSV_DIR}")"
PREPARED_HEADER_DIR="$(expand_path "${PREPARED_HEADER_DIR}")"
PYTHON_BIN="$(expand_path "${PYTHON_BIN:-$(resolve_python)}")"
export NEO4J_PYTHON="${PYTHON_BIN}"

CSV_DIR="$(absolute_path "${CSV_DIR}")"
PARAMETER_DIR="$(absolute_path "${PARAMETER_DIR}")"
PREPARED_CSV_DIR="$(absolute_path "${PREPARED_CSV_DIR}")"
PREPARED_HEADER_DIR="$(absolute_path "${PREPARED_HEADER_DIR}")"

if [[ "$(basename "${CSV_DIR}")" == "initial_snapshot" ]]; then
    CSV_DIR="$(dirname "${CSV_DIR}")"
fi

if [[ ! -d "${CSV_DIR}/initial_snapshot" ]]; then
    echo "CSV directory must contain initial_snapshot/: ${CSV_DIR}"
    exit 1
fi

if [[ ! -d "${PARAMETER_DIR}" ]]; then
    echo "Parameter directory does not exist: ${PARAMETER_DIR}"
    exit 1
fi

IMPORT_CSV_DIR="${CSV_DIR}"
IMPORT_HEADER_DIR="$(pwd)/headers"
if ${LOAD} && ${PREPARE_CSV} && csv_has_headers "${CSV_DIR}"; then
    fingerprint="$(csv_header_fingerprint "${CSV_DIR}")"
    if [[ "${PREPARED_CSV_DIR_SET}" == false ]]; then
        PREPARED_CSV_DIR="${PREPARED_CSV_DIR}-${fingerprint}"
    fi
    if [[ "${PREPARED_HEADER_DIR_SET}" == false ]]; then
        PREPARED_HEADER_DIR="${PREPARED_HEADER_DIR}-${fingerprint}"
    fi
    IMPORT_CSV_DIR="${PREPARED_CSV_DIR}"
    IMPORT_HEADER_DIR="${PREPARED_HEADER_DIR}"
    if [[ ! -d "${IMPORT_CSV_DIR}/initial_snapshot" && "${DRY_RUN}" == false ]]; then
        echo "Preparing no-header CSV copy for Neo4j import:"
        echo "  source: ${CSV_DIR}"
        echo "  target: ${IMPORT_CSV_DIR}"
        scripts/prepare-csv-without-headers.sh "${CSV_DIR}" "${IMPORT_CSV_DIR}"
    fi
    if [[ ! -d "${IMPORT_HEADER_DIR}/static" && "${DRY_RUN}" == false ]]; then
        echo "Generating Neo4j headers matching CSV column order:"
        echo "  source CSV: ${CSV_DIR}"
        echo "  target headers: ${IMPORT_HEADER_DIR}"
        scripts/generate-headers-from-csv.py "${CSV_DIR}" "$(pwd)/headers" "${IMPORT_HEADER_DIR}"
    fi
fi
export NEO4J_HEADER_DIR="${IMPORT_HEADER_DIR}"

QUERY_VARIANTS=()
QUERY_LIST="${QUERY_LIST//,/ }"
for token in ${QUERY_LIST}; do
    expand_query_token "${token}"
done

if [[ ${#QUERY_VARIANTS[@]} -eq 0 ]]; then
    echo "No queries selected."
    exit 1
fi

if [[ "${DRY_RUN}" == false && "${INSTALL_DEPS}" == false ]]; then
    if ! python_has_benchmark_deps "${NEO4J_PYTHON}"; then
        echo "Missing Python benchmark dependencies. Re-run with --install-deps."
        echo "The repository installer will run: ${NEO4J_PYTHON} -m pip install --user neo4j==5.21.0 python-dateutil"
        echo "Or pass --python PATH to a Python environment that already has neo4j and python-dateutil."
        exit 1
    fi
fi

run_args=(--sf "${SF}" --csv-dir "${IMPORT_CSV_DIR}" --parameter-dir "${PARAMETER_DIR}" --query-variants "${QUERY_VARIANTS[*]}")

if ${LOAD}; then
    run_args+=(--load)
elif ! ${START}; then
    run_args+=(--no-start)
fi

if ${INSTALL_DEPS}; then
    run_args+=(--install-deps)
fi

if [[ -n "${MEMORY}" ]]; then
    run_args+=(--memory "${MEMORY}")
fi

if [[ -n "${WORKER_THREADS}" ]]; then
    run_args+=(--worker-threads "${WORKER_THREADS}")
fi

if [[ -n "${HTTP_PORT}" ]]; then
    run_args+=(--http-port "${HTTP_PORT}")
fi

if [[ -n "${BOLT_PORT}" ]]; then
    run_args+=(--bolt-port "${BOLT_PORT}")
fi

if [[ -n "${PARAMETER_COUNT}" ]]; then
    run_args+=(--parameter-limit "${PARAMETER_COUNT}")
fi

case "${MODE}" in
    test)
        run_args+=(--test)
        ;;
    regular)
        ;;
    pgtuning)
        run_args+=(--pgtuning)
        ;;
    all-parameters)
        run_args+=(--all-parameters-per-query-file)
        ;;
    *)
        echo "Unknown mode: ${MODE}"
        usage
        exit 1
        ;;
esac

echo "Neo4j BI SF${SF} local run"
echo "  Neo4j version: ${NEO4J_VERSION}"
echo "  Source CSV directory: ${CSV_DIR}"
echo "  Import CSV directory: ${IMPORT_CSV_DIR}"
echo "  Header directory: ${NEO4J_HEADER_DIR}"
echo "  Parameter directory: ${PARAMETER_DIR}"
echo "  Python: ${NEO4J_PYTHON}"
echo "  Query variants: ${QUERY_VARIANTS[*]}"
echo "  Mode: ${MODE}"
echo "  Parameter count: ${PARAMETER_COUNT:-default}"
echo "  Worker threads: ${WORKER_THREADS:-default}"
echo "  HTTP port: ${HTTP_PORT:-7474}"
echo "  Bolt port: ${BOLT_PORT:-7687}"
echo "  Load: ${LOAD}"
echo

if ${DRY_RUN}; then
    printf 'Command: scripts/run-queries-local.sh'
    printf ' %q' "${run_args[@]}"
    printf '\n'
    exit 0
fi

scripts/run-queries-local.sh "${run_args[@]}"
