# Generating LDBC SNB BI Query Parameters

This document describes how to generate the BI query substitution parameters used by this repository, for example:

```text
parameters/parameters-sf1/bi-1.csv
parameters/parameters-sf1/bi-2a.csv
...
parameters/parameters-sf1/bi-20b.csv
```

The flow is:

1. Build and run Spark Datagen with `--generate-factors`.
2. Copy the generated factor tables into `paramgen/scratch/factors/`.
3. Run `paramgen/scripts/paramgen.sh`.

## 1. Download and Prepare Datagen

Clone the Spark-based LDBC SNB Datagen repository:

```bash
mkdir datagen && cd datagen
git clone https://github.com/ldbc/ldbc_snb_datagen_spark.git
cd ldbc_snb_datagen_spark
```

Then configure the Datagen environment. The Datagen README's local-run path contains four parts:

1. Java.
2. Python tools.
3. Spark.
4. Datagen build.

### 1.1 Java

Spark 3.2.x is the recommended runtime in the Datagen README. With Spark 3.2.2, use Java 8 or Java 11. Do not use Java 17 for this local setup.

Check your Java version:

```bash
java -version
```

If multiple Java versions are installed, set `JAVA_HOME` to Java 8 or Java 11 before building/running Datagen. For example:

```bash
export JAVA_HOME=/path/to/java-11
export PATH="${JAVA_HOME}/bin:${PATH}"
java -version
```

If your machine currently uses Java 17, switch to Java 11 before building/running Datagen.

On Ubuntu/Debian, first install Java 11 if needed:

```bash
sudo apt update
sudo apt install openjdk-11-jdk
```

Then select Java 11 with `update-alternatives`:

```bash
sudo update-alternatives --config java
sudo update-alternatives --config javac
```

Choose the entries that point to Java 11, then verify:

```bash
java -version
javac -version
```

You can also switch only for the current shell by exporting `JAVA_HOME` directly. Common Java 11 paths are:

```bash
# x86_64 Ubuntu/Debian
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# ARM64 Ubuntu/Debian
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-arm64

export PATH="${JAVA_HOME}/bin:${PATH}"
java -version
```

The output should show version `11`, not `17`.

### 1.2 Python Tools

The Datagen helper script `./tools/run.py` needs the Datagen Python tools installed. The upstream README shows a `pyenv` setup, but a regular virtual environment is also fine.

Using Python `venv`:

```bash
cd /path/to/ldbc_snb_datagen_spark
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -U pip
python3 -m pip install ./tools
```

If you use `pyenv`, the upstream README's flow is:

```bash
pyenv install 3.7.13
pyenv virtualenv 3.7.13 ldbc_datagen_tools
pyenv local ldbc_datagen_tools
pip install -U pip
pip install ./tools
```

If you come back later and the virtual environment already exists, reactivate it before running Datagen:

```bash
cd /path/to/ldbc_snb_datagen_spark
. .venv/bin/activate
```

### 1.3 Spark

Download Spark using one of the helper scripts from the Datagen repository.

To install Spark under your home directory:

```bash
cd /path/to/ldbc_snb_datagen_spark
scripts/get-spark-to-home.sh
export SPARK_HOME="${HOME}/spark-3.2.2-bin-hadoop3.2"
export PATH="${SPARK_HOME}/bin:${PATH}"
```

Or, if you want Spark under `/opt`:

```bash
cd /path/to/ldbc_snb_datagen_spark
scripts/get-spark-to-opt.sh
export SPARK_HOME="/opt/spark-3.2.2-bin-hadoop3.2"
export PATH="${SPARK_HOME}/bin:${PATH}"
```

Check Spark:

```bash
spark-submit --version
```

If Spark uses too much `/tmp` space during generation, set `SPARK_LOCAL_DIRS` to a directory with enough free space:

```bash
mkdir -p /path/to/large-disk/spark-tmp
export SPARK_LOCAL_DIRS=/path/to/large-disk/spark-tmp
```

### 1.4 Build Datagen

Build the Datagen project:

```bash
cd /path/to/ldbc_snb_datagen_spark
scripts/build.sh
```

If you prefer to call SBT directly, this is the core build command:

```bash
sbt assembly
```

After the build, set the variables used by `tools/run.py`. Keep these exports in the same shell session where you run Datagen:

```bash
export SF=1
export PLATFORM_VERSION=$(sbt -batch -error 'print platformVersion')
export DATAGEN_VERSION=$(sbt -batch -error 'print version')
export LDBC_SNB_DATAGEN_JAR=$(sbt -batch -error 'print assembly / assemblyOutputPath')
```

Quick sanity check:

```bash
test -f "${LDBC_SNB_DATAGEN_JAR}" && echo "Datagen JAR exists: ${LDBC_SNB_DATAGEN_JAR}"
./tools/run.py --help
./tools/run.py -- --help
```

Choose an output directory:

```bash
export DATAGEN_OUTPUT_DIR=out-sf${SF}
rm -rf "${DATAGEN_OUTPUT_DIR}"
```

## 2. Generate BI Factors

Run Datagen in BI mode with factor generation enabled:

```bash
./tools/run.py -- \
  --memory 12G \
  --format csv \
  --scale-factor "${SF}" \
  --mode bi \
  --output-dir "${DATAGEN_OUTPUT_DIR}" \
  --generate-factors
```

For larger scale factors, pass runtime options before the `--`, for example:

```bash
./tools/run.py \
  --cores "$(nproc)" \
  --memory 64G \
  -- \
  --format csv \
  --scale-factor "${SF}" \
  --mode bi \
  --output-dir "${DATAGEN_OUTPUT_DIR}" \
  --generate-factors
```

After generation, confirm that the factor parquet directory exists:

```bash
ls "${DATAGEN_OUTPUT_DIR}/factors/parquet/raw/composite-merged-fk"
```

This repository's parameter generator reads parquet factors with DuckDB:

```text
paramgen/scratch/factors/<factor-name>/*.parquet
```

So the important Datagen output directory is:

```text
${DATAGEN_OUTPUT_DIR}/factors/parquet/raw/composite-merged-fk/
```

## 3. Install Paramgen Dependencies

In this repository:

```bash
cd /path/to/ldbc_snb_bi/paramgen
scripts/install-dependencies.sh
```

This installs the Python dependencies used by `paramgen.py`, mainly `duckdb` and `pytz`.

## 4. Copy Factors into Paramgen

Set these variables:

```bash
export SF=1
export LDBC_SNB_DATAGEN_DIR=/path/to/ldbc_snb_datagen_spark
export DATAGEN_OUTPUT_DIR=out-sf${SF}
```

The intended generic copy command is:

```bash
cd /path/to/ldbc_snb_bi/paramgen
rm -rf scratch/factors
mkdir -p scratch/factors
cp -r "${LDBC_SNB_DATAGEN_DIR}/${DATAGEN_OUTPUT_DIR}/factors/parquet/raw/composite-merged-fk/"* scratch/factors/
```

Alternatively, use:

```bash
scripts/get-factors.sh
```

Important: check `paramgen/scripts/get-factors.sh` before using it. In this working tree it may contain a hard-coded Datagen output path. If you generated a different SF or output directory, update that script or use the manual `cp -r` command above.

Verify that factors were copied:

```bash
find scratch/factors -maxdepth 2 -type f -name '*.parquet' | head
```

## 5. Generate Parameters

Run:

```bash
cd /path/to/ldbc_snb_bi/paramgen
export SF=1
scripts/paramgen.sh
```

The output will be written to:

```text
/path/to/ldbc_snb_bi/parameters/parameters-sf${SF}/
```

For `SF=1`, the expected output is:

```text
parameters/parameters-sf1/bi-1.csv
parameters/parameters-sf1/bi-2a.csv
parameters/parameters-sf1/bi-2b.csv
...
parameters/parameters-sf1/bi-20a.csv
parameters/parameters-sf1/bi-20b.csv
```

Verify:

```bash
ls ../parameters/parameters-sf${SF}/bi-*.csv
```

## 6. Use the Generated Parameters with Neo4j

When running Neo4j BI queries, pass the generated parameter directory:

```bash
cd /path/to/ldbc_snb_bi

neo4j/scripts/run-bi-all-parameters.sh \
  --sf "${SF}" \
  --csv-dir /path/to/neo4j/no-header/composite-projected-fk \
  --parameter-dir "/path/to/ldbc_snb_bi/parameters/parameters-sf${SF}"
```

This writes one result file per query variant:

```text
neo4j/output/output-sf${SF}/bi1-results.csv
neo4j/output/output-sf${SF}/bi2a-results.csv
...
neo4j/output/output-sf${SF}/bi20b-results.csv
```

## Troubleshooting

If `paramgen.py` fails with missing factor tables, check:

```bash
find paramgen/scratch/factors -maxdepth 2 -type f -name '*.parquet' | head
```

If this returns nothing, the factors were not copied correctly or Datagen did not produce parquet factors.

If the output directory is not what `get-factors.sh` expects, either update `paramgen/scripts/get-factors.sh` or use the manual copy command in step 4.

If `scripts/paramgen.sh` fails because `${SF}` is missing, export it:

```bash
export SF=1
```

If memory is insufficient, rerun Datagen with more memory in the runtime arguments before the `--`, for example:

```bash
./tools/run.py --cores "$(nproc)" --memory 64G -- ...
```

If Datagen fails with this Spark error:

```text
java.lang.IllegalAccessError: class org.apache.spark.storage.StorageUtils$
cannot access class sun.nio.ch.DirectBuffer
```

then Spark is almost certainly running with Java 17. Switch the same shell session to Java 11, then rerun Datagen:

```bash
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export PATH="${JAVA_HOME}/bin:${PATH}"

java -version
javac -version
```

Both commands should report version `11`. Also check what Spark sees:

```bash
spark-submit --version
```

If `spark-submit --version` still reports Java 17, your `SPARK_HOME`/`PATH` or system alternatives are still pointing at Java 17. On Ubuntu/Debian, switch them with:

```bash
sudo update-alternatives --config java
sudo update-alternatives --config javac
```

After switching, run:

```bash
cd /path/to/ldbc_snb_datagen_spark
. .venv/bin/activate

export SF=1
export DATAGEN_OUTPUT_DIR=out-sf${SF}
export PLATFORM_VERSION=$(sbt -batch -error 'print platformVersion')
export DATAGEN_VERSION=$(sbt -batch -error 'print version')
export LDBC_SNB_DATAGEN_JAR=$(sbt -batch -error 'print assembly / assemblyOutputPath')

./tools/run.py -- \
  --format csv \
  --scale-factor "${SF}" \
  --mode bi \
  --output-dir "${DATAGEN_OUTPUT_DIR}" \
  --generate-factors
```
