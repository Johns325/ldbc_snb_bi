#!/usr/bin/env bash

set -eu
set -o pipefail

cd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd ..

rm -rf scratch/factors/
mkdir -p scratch/factors/
# cp -r ${LDBC_SNB_DATAGEN_DIR}/out-sf${SF}/factors/parquet/raw/composite-merged-fk/* scratch/factors/
cp -r /home/glaucus/workspace/ldbc_snb_datagen_spark/out-sf1-1773926863/factors/parquet/raw/composite-merged-fk/* scratch/factors/
