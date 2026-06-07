#!/usr/bin/env python3

import argparse
from pathlib import Path


ENDPOINT_COLUMN_TYPES = {
    "classYear": "classYear:LONG",
    "creationDate": "creationDate:DATETIME",
    "workFrom": "workFrom:LONG",
}


def read_first_line(path):
    with path.open("r", encoding="utf-8") as input_file:
        return input_file.readline().rstrip("\n")


def typed_base_name(column):
    if column.startswith(":"):
        return column
    return column.split(":", 1)[0]


def load_existing_columns(header_dir, group, entity):
    header_path = header_dir / group / f"{entity}.csv"
    return read_first_line(header_path).split("|")


def source_columns(csv_dir, group, entity):
    entity_dir = csv_dir / "initial_snapshot" / group / entity
    part_file = next(iter(sorted(entity_dir.glob("part-*.csv"))), None)
    if part_file is None:
        part_file = next(iter(sorted(entity_dir.glob("part-*.csv.gz"))), None)
    if part_file is None:
        raise FileNotFoundError(f"No part CSV found for {group}/{entity}")
    if part_file.suffix == ".gz":
        raise ValueError(f"Compressed CSV header generation is not supported yet: {part_file}")
    return read_first_line(part_file).split("|")


def node_column(entity, source_column, existing_by_name):
    if source_column == "id":
        return f"id:ID({entity})"
    if source_column == "type" and entity in {"Organisation", "Place"}:
        return ":LABEL"
    if entity == "Person" and source_column == "language":
        return existing_by_name["speaks"]
    return existing_by_name[source_column]


def relationship_columns(source, existing):
    endpoint_types = [column for column in existing if column.startswith(":")]
    endpoint_index = 0
    generated = []

    for column in source:
        if column in ENDPOINT_COLUMN_TYPES:
            generated.append(ENDPOINT_COLUMN_TYPES[column])
        else:
            generated.append(endpoint_types[endpoint_index])
            endpoint_index += 1

    if endpoint_index != len(endpoint_types):
        raise ValueError(f"Used {endpoint_index} endpoints, expected {len(endpoint_types)} for source {source}")

    return generated


def generate_header(csv_dir, existing_header_dir, output_header_dir, group, entity):
    source = source_columns(csv_dir, group, entity)
    existing = load_existing_columns(existing_header_dir, group, entity)

    if any(column.startswith(":START_ID") or column.startswith(":END_ID") for column in existing):
        generated = relationship_columns(source, existing)
    else:
        existing_by_name = {typed_base_name(column): column for column in existing}
        generated = [node_column(entity, column, existing_by_name) for column in source]

    output_path = output_header_dir / group / f"{entity}.csv"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("|".join(generated) + "\n", encoding="utf-8")
    print(f"{group}/{entity}: {'|'.join(generated)}")


def main():
    parser = argparse.ArgumentParser(description="Generate Neo4j import headers matching CSV column order.")
    parser.add_argument("csv_dir", help="Directory containing initial_snapshot/")
    parser.add_argument("existing_header_dir", help="Typed Neo4j header directory to reuse for types")
    parser.add_argument("output_header_dir", help="Destination header directory")
    args = parser.parse_args()

    csv_dir = Path(args.csv_dir)
    existing_header_dir = Path(args.existing_header_dir)
    output_header_dir = Path(args.output_header_dir)

    for group in ("static", "dynamic"):
        for existing_header in sorted((existing_header_dir / group).glob("*.csv")):
            generate_header(csv_dir, existing_header_dir, output_header_dir, group, existing_header.stem)

    print("Generated Neo4j CSV headers:")
    print(f"  {output_header_dir}")


if __name__ == "__main__":
    main()
