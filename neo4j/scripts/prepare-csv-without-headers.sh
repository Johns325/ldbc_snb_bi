#!/usr/bin/env bash

set -eu
set -o pipefail

usage() {
    cat <<'EOF'
Copy an LDBC SNB BI CSV directory and remove Datagen header rows from part files.

The Neo4j importer in this repository supplies headers from neo4j/headers, so
the data files themselves must not contain header rows.

Usage:
  neo4j/scripts/prepare-csv-without-headers.sh SRC_DIR DST_DIR

Example:
  neo4j/scripts/prepare-csv-without-headers.sh \
    neo4j/bi-sf1-composite-projected-fk/graphs/csv/bi/composite-projected-fk \
    neo4j/bi-sf1-composite-projected-fk-noheaders/graphs/csv/bi/composite-projected-fk
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

src_dir="$1"
dst_dir="$2"

if [[ ! -d "${src_dir}" ]]; then
    echo "Source directory does not exist: ${src_dir}"
    exit 1
fi

if [[ -e "${dst_dir}" ]]; then
    echo "Destination already exists: ${dst_dir}"
    echo "Choose a new directory, or remove it yourself if you want to recreate it."
    exit 1
fi

mkdir -p "$(dirname "${dst_dir}")"
cp -a "${src_dir}" "${dst_dir}"

echo "Removing first line from uncompressed part CSV files..."
while IFS= read -r csv_file; do
    sed -i '1d' "${csv_file}"
done < <(find "${dst_dir}" -type f -name 'part-*.csv')

echo "Removing first line from compressed part CSV files..."
while IFS= read -r gz_file; do
    tmp_file="${gz_file}.tmp"
    gzip -cd "${gz_file}" | tail -n +2 | gzip > "${tmp_file}"
    mv "${tmp_file}" "${gz_file}"
done < <(find "${dst_dir}" -type f -name 'part-*.csv.gz')

echo "Prepared Neo4j CSV directory:"
echo "  ${dst_dir}"
