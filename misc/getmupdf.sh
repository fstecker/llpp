#!/bin/sh
set -eu

MUPDF_OUTPUT_DIR="$1"
u="git://git.ghostscript.com/mupdf"
#u="https://github.com/ArtifexSoftware/mupdf"
MUPDF_URL="${2-$u}"
MUPDF_DESIRED_VERSION="3f050bc65f0a9ba841b57bbf483c7fe378df7c0e"

if [ ! -d ${MUPDF_OUTPUT_DIR} ]; then
    echo "mupdf does not exist, fetching it from ${MUPDF_URL}"
    git clone ${cloneargs-} ${MUPDF_URL} --recursive ${MUPDF_OUTPUT_DIR}
fi

cd ${MUPDF_OUTPUT_DIR}
git remote update
MUPDF_VERSION=$(git rev-parse HEAD)

test "${MUPDF_VERSION}" = "${MUPDF_DESIRED_VERSION}" || {
    printf "mupdf current version is ${MUPDF_VERSION} "
    echo "switching to ${MUPDF_DESIRED_VERSION}"
    git reset --hard ${MUPDF_DESIRED_VERSION}
    git submodule update --init --recursive
}
