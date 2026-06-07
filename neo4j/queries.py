import datetime
import time
import re
import json
import sys
import csv
sys.path.append('../common')
from result_mapping import result_mapping


def query_base_variant(query_variant):
    return query_variant.split("-")[0]


def query_number(query_variant):
    return int(re.sub("[^0-9]", "", query_base_variant(query_variant)))


def query_subvariant(query_variant):
    return re.sub("[^ab]", "", query_base_variant(query_variant))


def query_file_name(query_variant):
    query_num = query_number(query_variant)
    if query_num == 15 and "without-date" in query_variant:
        return "queries/bi-15-without-date.cypher"
    if query_num == 19 and "without-precomputation" in query_variant:
        return "queries/bi-19-without-precomputation.cypher"
    return f"queries/bi-{query_num}.cypher"


def read_query_spec(query_variant):
    with open(query_file_name(query_variant), "r") as query_file:
        return query_file.read()


def convert_value_to_string(value, result_type, input):
    if result_type == "ID[]" or result_type == "INT[]" or result_type == "INT32[]" or result_type == "INT64[]":
        return [int(x) for x in value]
    elif result_type == "ID" or result_type == "INT" or result_type == "INT32" or result_type == "INT64":
        return int(value)
    elif result_type == "FLOAT" or result_type == "FLOAT32" or result_type == "FLOAT64":
        return float(value)
    elif result_type == "STRING[]":
        return value
    elif result_type == "STRING":
        return value
    elif result_type == "DATETIME":
        if input:
            return f"{datetime.datetime.strftime(value, '%Y-%m-%dT%H:%M:%S.%f')[:-3]}+00:00"
        else:
            return f"{datetime.datetime.strftime(value.to_native(), '%Y-%m-%dT%H:%M:%S.%f')[:-3]}+00:00"
    elif result_type == "DATE":
        if input:
            return datetime.datetime.strftime(value, '%Y-%m-%d')
        else:
            return datetime.datetime.strftime(value.to_native(), '%Y-%m-%d')
    elif result_type == "BOOL":
        return bool(value)
    else:
        raise ValueError(f"Result type {result_type} not found")

def cast_parameter_to_driver_input(value, parameter_type):
    if parameter_type == "ID[]" or parameter_type == "INT[]" or parameter_type == "INT32[]" or parameter_type == "INT64[]":
        return [int(x) for x in value.split(";")]
    elif parameter_type == "ID" or parameter_type == "INT" or parameter_type == "INT32" or parameter_type == "INT64":
        return int(value)
    elif parameter_type == "STRING[]":
        return value.split(";")
    elif parameter_type == "STRING":
        return value
    elif parameter_type == "DATETIME":
        dt = datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%S.%f+00:00')
        return datetime.datetime(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.microsecond, tzinfo=datetime.timezone.utc)
    elif parameter_type == "DATE":
        dt = datetime.datetime.strptime(value, '%Y-%m-%d')
        return datetime.datetime(dt.year, dt.month, dt.day, tzinfo=datetime.timezone.utc)
    else:
        raise ValueError(f"Parameter type {parameter_type} not found")

def read_query_fun(tx, query_num, query_spec, query_parameters):
    results = tx.run(query_spec, query_parameters)
    mapping = result_mapping[query_num]
    result_tuples = [
            {
                result_descriptor["name"]: convert_value_to_string(result[i], result_descriptor["type"], False)
                for i, result_descriptor in enumerate(mapping)
            }
            for result in results
        ]

    return json.dumps(result_tuples)


def write_query_fun(tx, query_spec):
    tx.run(query_spec, {})


def run_query(session, query_num, query_variant, query_spec, query_parameters, test):
    if test:
        print(f'Q{query_variant}: {query_parameters}')

    start = time.time()
    results = session.write_transaction(read_query_fun, query_num, query_spec, query_parameters)
    end = time.time()
    duration = end - start
    if test:
        print(f"-> {duration:.4f} seconds")
        print(f"-> {results}")
    return (results, duration)


def write_summary(summary_file, query_variant, durations):
    if not durations:
        return

    durations_ms = [duration * 1000 for duration in durations]
    total = sum(durations_ms)
    count = len(durations)
    avg = total / count
    summary_file.write(
        f"{query_variant}|{count}|{total:.3f}|{avg:.3f}|{min(durations_ms):.3f}|{max(durations_ms):.3f}\n"
    )
    summary_file.flush()
    print(
        f"Summary Q{query_variant}: count = {count} , avg = {avg:.3f} ms, "
        f"min = {min(durations_ms):.3f} ms, max = {max(durations_ms):.3f} ms"
    )


def should_stop_after_parameter(i, test, pgtuning, parameter_limit):
    if parameter_limit is not None:
        return i >= parameter_limit
    return (test) or (not pgtuning and i == 30) or (pgtuning and i == 100)


def run_queries(query_variants, parameter_csvs, session, sf, batch_id, batch_type, test, pgtuning, timings_file, results_file, summary_file, parameter_limit=None):
    start = time.time()

    for query_variant in query_variants:
        query_num = query_number(query_variant)
        subvariant = query_subvariant(query_variant)

        print(f"========================= Q {query_num:02d}{subvariant.rjust(1)} =========================")
        query_spec = read_query_spec(query_variant)

        parameters_csv = parameter_csvs[query_variant]

        i = 0
        durations = []
        for query_parameters in parameters_csv:
            i = i + 1

            query_parameters_converted = {k.split(":")[0]: cast_parameter_to_driver_input(v, k.split(":")[1]) for k, v in query_parameters.items()}

            query_parameters_split = {k.split(":")[0]: v for k, v in query_parameters.items()}
            query_parameters_in_order = json.dumps(query_parameters_split)

            (results, duration) = run_query(session, query_num, query_variant, query_spec, query_parameters_converted, test)
            durations.append(duration)

            timings_file.write(f"Neo4j|{sf}|{batch_id}|{batch_type}|{query_variant}|{query_parameters_in_order}|{duration}\n")
            timings_file.flush()
            results_file.write(f"{query_num}|{query_variant}|{query_parameters_in_order}|{results}\n")
            results_file.flush()

            if should_stop_after_parameter(i, test, pgtuning, parameter_limit):
                break

        write_summary(summary_file, query_variant, durations)

    return time.time() - start


def run_all_parameters_per_query_file(query_variants, parameter_csvs, session, sf, batch_id, batch_type, timings_file, summary_file, output_dir, parameter_limit=None):
    start = time.time()

    for query_variant in query_variants:
        query_num = query_number(query_variant)
        subvariant = query_subvariant(query_variant)

        print(f"========================= Q {query_num:02d}{subvariant.rjust(1)} =========================")
        query_spec = read_query_spec(query_variant)

        results_path = output_dir / f"bi{query_variant}-results.csv"
        with open(results_path, "w", newline="", encoding="utf-8") as per_query_results_file:
            writer = csv.writer(per_query_results_file)
            writer.writerow(["query", "parameter_index", "parameters", "results", "time_seconds"])

            durations = []
            for i, query_parameters in enumerate(parameter_csvs[query_variant], start=1):
                query_parameters_converted = {k.split(":")[0]: cast_parameter_to_driver_input(v, k.split(":")[1]) for k, v in query_parameters.items()}

                query_parameters_split = {k.split(":")[0]: v for k, v in query_parameters.items()}
                query_parameters_in_order = json.dumps(query_parameters_split, ensure_ascii=False)

                print(f"Q{query_variant} parameter #{i}: {query_parameters_split}")
                (results, duration) = run_query(session, query_num, query_variant, query_spec, query_parameters_converted, False)
                durations.append(duration)

                timings_file.write(f"Neo4j|{sf}|{batch_id}|{batch_type}|{query_variant}|{query_parameters_in_order}|{duration}\n")
                timings_file.flush()
                writer.writerow([f"bi{query_variant}", i, query_parameters_in_order, results, f"{duration:.6f}"])

                if parameter_limit is not None and i >= parameter_limit:
                    break

        print(f"Wrote {results_path}")
        write_summary(summary_file, query_variant, durations)

    return time.time() - start


def run_precomputations(sf, query_variants, session, batch_date, batch_type, timings_file):
    if any(query_base_variant(variant) in ("19a", "19b") and "without-precomputation" not in variant for variant in query_variants):
        start = time.time()
        print("Creating graph (precomputing weights) for Q19")
        session.write_transaction(write_query_fun, open(f'queries/bi-19-drop-graph.cypher', 'r').read())
        session.write_transaction(write_query_fun, open(f'queries/bi-19-create-graph.cypher', 'r').read())
        end = time.time()
        duration = end - start
        timings_file.write(f"Neo4j|{sf}|{batch_date}|{batch_type}|q19precomputation||{duration}\n")

    if any(query_base_variant(variant) in ("20a", "20b") for variant in query_variants):
        start = time.time()
        print("Creating graph (precomputing weights) for Q20")
        session.write_transaction(write_query_fun, open(f'queries/bi-20-drop-graph.cypher', 'r').read())
        session.write_transaction(write_query_fun, open(f'queries/bi-20-create-graph.cypher', 'r').read())
        end = time.time()
        duration = end - start
        timings_file.write(f"Neo4j|{sf}|{batch_date}|{batch_type}|q20precomputation||{duration}\n")
