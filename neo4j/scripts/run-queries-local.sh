#!/usr/bin/env bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

usage() {
    cat <<'EOF'
Run LDBC SNB BI read queries on Neo4j.

Usage:
  neo4j/scripts/run-queries-local.sh --sf SF --csv-dir PATH [options]

Options:
  --sf SF              Scale factor, e.g. 1, 10, 30, 0.1.
  --csv-dir PATH       Datagen CSV directory containing initial_snapshot/.
  --sample             Use the repository sample-data helper.
  --download-sample    Download the sample data set first, then use it.
  --load               Import data, start Neo4j, and create indices before queries.
  --no-start           Do not start Neo4j before running queries.
  --test               Pass --test to benchmark.py: one parameter row per query.
  --validate           Pass --validate to benchmark.py.
  --pgtuning           Pass --pgtuning to benchmark.py: 100 parameter rows per query.
  --parameter-dir PATH Directory containing bi-*.csv query parameters.
  --query-variants LIST
                      Comma- or space-separated variants, e.g.
                      "1,15a-without-date,19a-without-precomputation".
  --parameter-limit N Maximum number of parameter rows per query variant.
  --all-parameters-per-query-file
                      Run every parameter row and write bi*-results.csv files.
  --memory SIZE        Set both Neo4j heap max and page cache, e.g. 20G.
  --worker-threads N   Set Neo4j server.threads.worker_count for container start.
  --install-deps       Install Python dependencies used by the Neo4j benchmark.
  -h, --help           Show this help.

Environment alternatives:
  SF and NEO4J_CSV_DIR may be exported instead of passing --sf/--csv-dir.

Examples:
  SF=1 NEO4J_CSV_DIR=/data/sf1/graphs/csv/bi/composite-projected-fk \
    neo4j/scripts/run-queries-local.sh --load --test

  neo4j/scripts/run-queries-local.sh --sf 1 --csv-dir /data/sf1/... --test
EOF
}

load=false
start=true
install_deps=false
query_args=()
PARAMETER_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sf)
            export SF="$2"
            shift 2
            ;;
        --csv-dir)
            export NEO4J_CSV_DIR="$2"
            shift 2
            ;;
        --sample)
            . scripts/use-sample-data-set.sh
            shift
            ;;
        --download-sample)
            scripts/get-sample-data-set.sh
            . scripts/use-sample-data-set.sh
            shift
            ;;
        --load)
            load=true
            shift
            ;;
        --no-start)
            start=false
            shift
            ;;
        --test|--validate|--pgtuning)
            query_args+=("$1")
            shift
            ;;
        --query-variants)
            query_args+=("--query_variants" "$2")
            shift 2
            ;;
        --parameter-limit)
            query_args+=("--parameter_limit" "$2")
            shift 2
            ;;
        --parameter-dir)
            PARAMETER_DIR="$2"
            shift 2
            ;;
        --all-parameters-per-query-file)
            query_args+=("--all_parameters_per_query_file")
            shift
            ;;
        --memory)
            export NEO4J_ENV_VARS="${NEO4J_ENV_VARS-} --env NEO4J_dbms_memory_pagecache_size=$2 --env NEO4J_dbms_memory_heap_max__size=$2"
            shift 2
            ;;
        --worker-threads)
            export NEO4J_ENV_VARS="${NEO4J_ENV_VARS-} --env NEO4J_server_threads_worker__count=$2"
            shift 2
            ;;
        --install-deps)
            install_deps=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            query_args+=("$@")
            break
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

. scripts/vars.sh

if [[ -z "${SF:-}" ]]; then
    echo "SF is not set. Pass --sf or export SF."
    exit 1
fi

if [[ -z "${NEO4J_CSV_DIR:-}" ]]; then
    echo "NEO4J_CSV_DIR is not set. Pass --csv-dir, --sample, or export NEO4J_CSV_DIR."
    exit 1
fi

if [[ ! -d "${NEO4J_CSV_DIR}" ]]; then
    echo "CSV directory does not exist: ${NEO4J_CSV_DIR}"
    exit 1
fi

if [[ -z "${PARAMETER_DIR}" ]]; then
    PARAMETER_DIR="../parameters/parameters-sf${SF}"
elif [[ ! -d "${PARAMETER_DIR}" && -d "../${PARAMETER_DIR}" ]]; then
    PARAMETER_DIR="../${PARAMETER_DIR}"
fi

if [[ ! -d "${PARAMETER_DIR}" ]]; then
    echo "Missing query parameters: ${PARAMETER_DIR}"
    echo "Generate them with paramgen, or choose an SF that already has parameters."
    exit 1
fi

if ${install_deps}; then
    scripts/install-dependencies.sh
fi

echo "Neo4j LDBC SNB BI query run"
echo "  SF: ${SF}"
echo "  CSV: ${NEO4J_CSV_DIR}"
echo "  parameters: ${PARAMETER_DIR}"
echo "  load: ${load}"
echo "  start: ${start}"
echo

if ${load}; then
    scripts/load-in-one-step.sh
elif ${start}; then
    if docker ps --format '{{.Names}}' | grep -qx "${NEO4J_CONTAINER_NAME}"; then
        echo "Neo4j container ${NEO4J_CONTAINER_NAME} is already running."
    else
        scripts/start.sh
    fi
fi

scripts/queries.sh --parameter_dir "${PARAMETER_DIR}" "${query_args[@]}"

echo
echo "Outputs:"
echo "  neo4j/output/output-sf${SF}/results.csv"
echo "  neo4j/output/output-sf${SF}/timings.csv"
echo "  neo4j/output/output-sf${SF}/bi*-results.csv (with --all-parameters-per-query-file)"
