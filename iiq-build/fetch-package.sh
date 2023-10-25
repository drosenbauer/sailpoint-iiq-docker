#!/bin/bash

set -e

BASE_URL="https://git.identityworksllc.com"
API_URL="${BASE_URL}/api/v4"
IIQ_COMMON_REPO_ID=157

PACKAGE_JSON=$(curl -s -m 30 "${API_URL}/projects/${IIQ_COMMON_REPO_ID}/packages?sort=desc" |  jq 'map(select(.name == "com/identityworksllc/iiq/common/minimal/iiq-common-public")) | .[0]')

PACKAGE_ID=$(echo "${PACKAGE_JSON}" | jq '.id')

echo "Package ID is ${PACKAGE_ID}"

if [[ -z "${PACKAGE_ID}" ]]; then
  echo "Could not find a package in the IIQCommon Public project??"
  exit 1
fi

FILE_JSON=$(curl -s -m 30 "${API_URL}/projects/${IIQ_COMMON_REPO_ID}/packages/${PACKAGE_ID}/package_files" | jq 'map(select(.file_name|test("iiq-common-public-[0123456789\\.]+jar$"))) | .[0]')

FILE_ID=$(echo "${FILE_JSON}" | jq '.id')
FILE_HASH=$(echo "${FILE_JSON}" | jq -r '.file_sha1')

echo "File ID is ${FILE_ID} and SHA-1 hash is ${FILE_HASH}"

FILE_URL="${BASE_URL}/pub/iiqcommon/-/package_files/${FILE_ID}/download"

# Download the actual file. Note the longer timeout, for slow Internet situations
curl -s -m 240 "${FILE_URL}" > iiq-common-public.jar

DOWNLOADED_HASH=$(shasum iiq-common-public.jar | awk '{print $1}')

if [[ ${FILE_HASH} != ${DOWNLOADED_HASH} ]]; then
  echo "Downloaded file's hash does not match the registry (${DOWNLOADED_HASH} vs ${FILE_HASH})"
  rm iiq-common-public.jar
  exit 2
else
  echo "Successfully downloaded iiq-common-public.jar"
fi