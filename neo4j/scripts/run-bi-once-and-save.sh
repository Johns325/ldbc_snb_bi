#!/usr/bin/env bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

usage() {
    cat <<'EOF'
Run each LDBC SNB BI query parameter variant once and save formatted results.

Usage:
  neo4j/scripts/run-bi-once-and-save.sh --sf SF --csv-dir PATH [options]

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
  neo4j/output/output-sf${SF}/results.csv
  neo4j/output/output-sf${SF}/query-results-once.json
  neo4j/output/output-sf${SF}/query-results-once.md
EOF
}

run_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sf)
            export SF="$2"
            run_args+=("$1" "$2")
            shift 2
            ;;
        --csv-dir|--parameter-dir|--memory)
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

scripts/run-queries-local.sh "${run_args[@]}" --test

. scripts/vars.sh

results_file="output/output-sf${SF}/results.csv"
json_file="output/output-sf${SF}/query-results-once.json"
markdown_file="output/output-sf${SF}/query-results-once.md"

python3 - "${SF}" "${results_file}" "${json_file}" "${markdown_file}" <<'PY'
import json
import sys
from pathlib import Path

sf, results_path, json_path, markdown_path = sys.argv[1:5]
records = []

with open(results_path, "r", encoding="utf-8") as results_file:
    for line_number, line in enumerate(results_file, start=1):
        line = line.rstrip("\n")
        if not line:
            continue

        fields = line.split("|", 3)
        if len(fields) != 4:
            raise ValueError(f"Cannot parse {results_path}:{line_number}: {line}")

        query_num, query_variant, parameters_json, results_json = fields
        records.append(
            {
                "query": f"bi-{query_variant}",
                "queryNumber": int(query_num),
                "queryVariant": query_variant,
                "parameters": json.loads(parameters_json),
                "results": json.loads(results_json),
            }
        )

Path(json_path).write_text(
    json.dumps(records, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)

markdown_lines = [f"# Neo4j LDBC SNB BI Results, SF={sf}", ""]
for record in records:
    markdown_lines.append(f"## {record['query']}")
    markdown_lines.append("")
    markdown_lines.append("### Parameters")
    markdown_lines.append("")
    markdown_lines.append("```json")
    markdown_lines.append(json.dumps(record["parameters"], ensure_ascii=False, indent=2))
    markdown_lines.append("```")
    markdown_lines.append("")
    markdown_lines.append("### Results")
    markdown_lines.append("")
    markdown_lines.append("```json")
    markdown_lines.append(json.dumps(record["results"], ensure_ascii=False, indent=2))
    markdown_lines.append("```")
    markdown_lines.append("")

Path(markdown_path).write_text("\n".join(markdown_lines), encoding="utf-8")

print(f"Wrote {len(records)} query result records.")
print(f"JSON: {json_path}")
print(f"Markdown: {markdown_path}")
PY
