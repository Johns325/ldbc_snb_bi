#!/usr/bin/env bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

usage() {
    cat <<'EOF'
Run every parameter row for every LDBC SNB BI query and save per-query result files.

Usage:
  neo4j/scripts/run-bi-all-parameters.sh --sf SF --csv-dir PATH [options]

Options:
  --sf SF              Scale factor, e.g. 1.
  --csv-dir PATH       Datagen CSV directory used by Neo4j /import.
  --parameter-dir PATH Directory containing bi-*.csv query parameters.
                       Defaults to parameters/parameters-sf${SF}.
  --load               Import data before running queries.
  --no-start           Do not start Neo4j before running queries.
  --memory SIZE        Set both Neo4j heap max and page cache, e.g. 20G.
  --install-deps       Install Python dependencies used by the Neo4j benchmark.
  -h, --help           Show this help.

Outputs:
  neo4j/output/output-sf${SF}/bi1-results.csv
  neo4j/output/output-sf${SF}/bi2a-results.csv
  ...
  neo4j/output/output-sf${SF}/bi20b-results.csv
  neo4j/output/output-sf${SF}/timings.csv
EOF
}

run_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sf|--csv-dir|--parameter-dir|--memory)
            run_args+=("$1" "$2")
            shift 2
            ;;
        --load|--no-start|--install-deps)
            run_args+=("$1")
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

scripts/run-queries-local.sh "${run_args[@]}" --all-parameters-per-query-file
